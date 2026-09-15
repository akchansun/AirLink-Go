package engine

import (
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"

	"huchuan/protocol"
)

type RecvSession struct {
	id, token  string
	files      []*os.File
	plans      []protocol.ChunkPlan
	bitmaps    []protocol.ChunkBitmap
	bitsPaths  []string
	partPaths  []string
	finalPaths []string
	saveNames  []string
	already    uint64
	cancelled  atomic.Bool
	mu         sync.Mutex
	persist    int
}

func (s *RecvSession) mark(file, chunk int) {
	s.mu.Lock()
	s.bitmaps[file].Insert(chunk)
	s.persist++
	should := s.persist%8 == 0
	data := s.bitmaps[file].Data()
	path := s.bitsPaths[file]
	s.mu.Unlock()
	if should {
		_ = os.WriteFile(path, data, 0o644)
	}
}

func (s *RecvSession) syncAll() {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range s.bitmaps {
		_ = os.WriteFile(s.bitsPaths[i], s.bitmaps[i].Data(), 0o644)
		_ = s.files[i].Sync()
	}
}

func (s *RecvSession) closeFiles() {
	for _, f := range s.files {
		if f != nil {
			_ = f.Close()
		}
	}
}

type RecvHub struct {
	mu sync.Mutex
	m  map[string]*RecvSession
}

func newHub() *RecvHub { return &RecvHub{m: map[string]*RecvSession{}} }

func (h *RecvHub) put(s *RecvSession) {
	h.mu.Lock()
	h.m[s.id] = s
	h.mu.Unlock()
}

func (h *RecvHub) get(id string) *RecvSession {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.m[id]
}

func (h *RecvHub) remove(id string) {
	h.mu.Lock()
	delete(h.m, id)
	h.mu.Unlock()
}

type job struct{ file, chunk int }

type workQueue struct {
	mu   sync.Mutex
	jobs []job
	i    int
}

func (q *workQueue) add(file, chunk int) {
	q.mu.Lock()
	q.jobs = append(q.jobs, job{file, chunk})
	q.mu.Unlock()
}

func (q *workQueue) next() (job, bool) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.i >= len(q.jobs) {
		return job{}, false
	}
	j := q.jobs[q.i]
	q.i++
	return j, true
}

func (q *workQueue) count() int {
	q.mu.Lock()
	defer q.mu.Unlock()
	return len(q.jobs)
}

type speedMeter struct {
	mu          sync.Mutex
	windowStart time.Time
	windowBytes uint64
	ema         float64
}

func (m *speedMeter) add(n uint64) float64 {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.windowStart.IsZero() {
		m.windowStart = time.Now()
	}
	m.windowBytes += n
	dt := time.Since(m.windowStart).Seconds()
	if dt >= 0.35 {
		inst := float64(m.windowBytes) / maxf(dt, 0.001)
		if m.ema == 0 {
			m.ema = inst
		} else {
			m.ema = m.ema*0.65 + inst*0.35
		}
		m.windowBytes = 0
		m.windowStart = time.Now()
	}
	return m.ema
}

func maxf(a, b float64) float64 {
	if a > b {
		return a
	}
	return b
}

func (n *Node) handleConn(c net.Conn) {
	defer c.Close()
	if tc, ok := c.(*net.TCPConn); ok {
		_ = tc.SetNoDelay(true)
		_ = tc.SetKeepAlive(true)
	}
	io := NewWire(c, true)
	frame, err := io.Recv(30 * time.Second)
	if err != nil {
		return
	}
	if frame.Kind != protocol.KindJSON {
		return
	}
	msg, err := protocol.UnmarshalEnv(frame.Payload)
	if err != nil {
		return
	}
	switch msg.T {
	case "hello":
		n.rememberHello(c, msg)
		_ = n.receiverControl(io, msg)
	case "join":
		_ = n.receiverWorker(io, msg)
	}
}

func (n *Node) rememberHello(c net.Conn, hello protocol.Envelope) {
	if hello.DeviceID == "" || hello.DeviceID == "local" {
		return
	}
	host, _, err := net.SplitHostPort(c.RemoteAddr().String())
	if err != nil {
		return
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return
	}
	v4 := ip.To4()
	if v4 == nil {
		return
	}
	host = v4.String()
	if isOwnHost(host) {
		return
	}
	s := n.settingsCopy()
	if hello.DeviceID == s.DeviceID {
		return
	}
	port := hello.Port
	if port == 0 {
		port = s.Port
	}
	httpPort := hello.HTTPPort
	if httpPort == 0 {
		httpPort = HTTPPort(port)
	}
	osname := hello.OS
	if osname == "" {
		osname = "电脑"
	}
	name := hello.Name
	if name == "" {
		name = host
	}
	n.upsert(Peer{
		ID: hello.DeviceID, Name: name, Host: host, Port: port,
		HTTPPort: httpPort, OS: osname, Via: "对方连过来", LastSeen: time.Now(),
	})
}

func (n *Node) helloEnv() protocol.Envelope {
	s := n.settingsCopy()
	return protocol.Envelope{
		T: "helloOk", DeviceID: s.DeviceID, Name: s.DeviceName, Port: s.Port,
		HTTPPort: HTTPPort(s.Port), OS: OSName(), AppVersion: AppVersion,
	}
}

func (n *Node) receiverControl(io *Wire, hello protocol.Envelope) error {
	s := n.settingsCopy()
	if s.Pin != "" && (hello.Pin == nil || *hello.Pin != s.Pin) {
		_ = io.SendJSON(protocol.Envelope{T: "reject", Reason: "口令不对"})
		return nil
	}
	if err := io.SendJSON(n.helloEnv()); err != nil {
		return err
	}
	for {
		frame, err := io.Recv(180 * time.Second)
		if err != nil {
			return err
		}
		switch frame.Kind {
		case protocol.KindPing:
			_ = io.SendPong()
		case protocol.KindJSON:
			msg, err := protocol.UnmarshalEnv(frame.Payload)
			if err != nil {
				return err
			}
			switch msg.T {
			case "offer":
				accepted := n.askOffer(msg, hello.Name, hello.DeviceID)
				if !accepted {
					_ = io.SendJSON(protocol.Envelope{T: "reject", SessionID: msg.SessionID, Reason: "用户拒绝"})
					return nil
				}
				session, err := n.prepareRecv(msg, msg.Token)
				if err != nil {
					_ = io.SendJSON(protocol.Envelope{T: "reject", SessionID: msg.SessionID, Reason: err.Error()})
					return err
				}
				n.hub.put(session)
				title := "文件"
				if len(session.saveNames) == 1 {
					title = session.saveNames[0]
				} else if len(msg.Files) > 1 {
					title = fmt.Sprintf("%d 个文件", len(msg.Files))
				}
				var total uint64
				for _, f := range msg.Files {
					total += f.Size
				}
				detail := "正在接收"
				if session.already > 0 {
					detail = "接着上次继续收"
				}
				n.addItem(TransferItem{
					ID: newUUID(), SessionID: msg.SessionID, Direction: "receive",
					PeerName: hello.Name, Title: title, Total: total, Done: session.already,
					State: "传输中", Detail: detail, FileCount: len(msg.Files), Time: time.Now(),
				})
				bits := make([]string, len(session.bitmaps))
				for i, b := range session.bitmaps {
					bits[i] = b.Base64()
				}
				acc := true
				_ = io.SendJSON(protocol.Envelope{
					T: "offerReply", SessionID: msg.SessionID, Accepted: &acc,
					SaveNames: session.saveNames, ResumeBits: bits,
				})
			case "text":
				n.showText(hello.Name, msg.Body)
			case "finish":
				n.finalize(msg.SessionID)
				return nil
			case "cancel":
				if sess := n.hub.get(msg.SessionID); sess != nil {
					sess.cancelled.Store(true)
				}
				n.markItem(msg.SessionID, "已取消", msg.Reason)
				return nil
			}
		}
	}
}

func (n *Node) receiverWorker(io *Wire, join protocol.Envelope) error {
	session := n.hub.get(join.SessionID)
	if session == nil || session.token != join.Token {
		return nil
	}
	meter := &speedMeter{}
	for !session.cancelled.Load() {
		frame, err := io.Recv(60 * time.Second)
		if err != nil {
			return err
		}
		switch frame.Kind {
		case protocol.KindChunk:
			packet, err := protocol.DecodeChunk(frame.Payload)
			if err != nil {
				return err
			}
			ok := packet.HashOk()
			if ok {
				idx := int(packet.FileIndex)
				if idx < 0 || idx >= len(session.files) {
					return errMsg("文件序号不对")
				}
				start, _ := session.plans[idx].ByteRange(int(packet.ChunkIndex))
				if err := writeAt(session.files[idx], start, packet.Data); err != nil {
					ok = false
				} else {
					session.mark(idx, int(packet.ChunkIndex))
					spd := meter.add(uint64(len(packet.Data)))
					n.bump(join.SessionID, uint64(len(packet.Data)), spd)
				}
			}
			_ = io.SendAck(protocol.ChunkAck{FileIndex: packet.FileIndex, ChunkIndex: packet.ChunkIndex, OK: ok})
		case protocol.KindPing:
			_ = io.SendPong()
		default:
			return nil
		}
	}
	return nil
}

func (n *Node) prepareRecv(offer protocol.Envelope, token string) (*RecvSession, error) {
	s := n.settingsCopy()
	if err := os.MkdirAll(s.ReceiveFolder, 0o755); err != nil {
		return nil, err
	}
	sess := &RecvSession{id: offer.SessionID, token: token}
	for _, file := range offer.Files {
		rel, ok := protocol.SanitizeRelativePath(file.RelativePath)
		if !ok {
			sess.closeFiles()
			return nil, errMsg("文件名不合法：" + file.RelativePath)
		}
		plan := protocol.Plan(file.Size)
		final := protocol.UniquePath(s.ReceiveFolder, rel)
		part := final + ".huchuanpart"
		bits := final + ".huchuanbits"
		bitmap := protocol.NewBitmap(plan.ChunkCount())
		if fileExists(part) && fileSize(part) == file.Size {
			if data, err := os.ReadFile(bits); err == nil {
				bitmap = protocol.BitmapFromData(plan.ChunkCount(), data)
				for i := 0; i < plan.ChunkCount(); i++ {
					if bitmap.Contains(i) {
						sess.already += uint64(plan.Length(i))
					}
				}
			}
		}
		h, err := createPart(part, file.Size)
		if err != nil {
			sess.closeFiles()
			return nil, err
		}
		sess.files = append(sess.files, h)
		sess.plans = append(sess.plans, plan)
		sess.bitmaps = append(sess.bitmaps, bitmap)
		sess.bitsPaths = append(sess.bitsPaths, bits)
		sess.partPaths = append(sess.partPaths, part)
		sess.finalPaths = append(sess.finalPaths, final)
		sess.saveNames = append(sess.saveNames, lastName(final))
	}
	return sess, nil
}

func lastName(path string) string {
	for i := len(path) - 1; i >= 0; i-- {
		if path[i] == '/' || path[i] == '\\' {
			return path[i+1:]
		}
	}
	return path
}

func (n *Node) finalize(sessionID string) {
	session := n.hub.get(sessionID)
	if session == nil {
		return
	}
	session.syncAll()
	session.closeFiles()
	for i := range session.finalPaths {
		_ = os.Remove(session.finalPaths[i])
		_ = os.Rename(session.partPaths[i], session.finalPaths[i])
		_ = os.Remove(session.bitsPaths[i])
	}
	title := "文件已保存"
	peerName := ""
	path := ""
	n.mu.Lock()
	for i := range n.items {
		if n.items[i].SessionID == sessionID {
			n.items[i].State = "已完成"
			n.items[i].Detail = "已保存到接收文件夹"
			n.items[i].Speed = 0
			n.items[i].Done = n.items[i].Total
			peerName = n.items[i].PeerName
			if len(session.finalPaths) > 0 {
				n.items[i].LocalPath = session.finalPaths[0]
				title = filepath.Base(session.finalPaths[0])
				path = session.finalPaths[0]
			} else if n.items[i].Title != "" {
				title = n.items[i].Title
			}
			break
		}
	}
	n.mu.Unlock()
	if peerName != "" {
		n.addHistory(title, peerName, path, "", "recv")
	}
	Alert("接收完成", title)
	n.hub.remove(sessionID)
}

func (n *Node) SendPaths(peer Peer, paths []string) {
	if peer.ID == "phone-web" {
		go n.sendToPhone(paths)
		return
	}
	go func() {
		if live, ok := n.PeerByID(peer.ID); ok {
			peer = live
		}
		files, err := Collect(paths)
		if err != nil {
			n.fail(peer.Name, err.Error())
			return
		}
		if n.shouldQueue(peer) {
			n.queueFiles(peer, files, "", "")
			return
		}
		n.sendFiles(peer, files, nil)
	}()
}

func (n *Node) sendFiles(peer Peer, files []LocalFile, existing *TransferItem) {
	s := n.settingsCopy()
	offers := make([]protocol.FileOffer, len(files))
	var total uint64
	for i, f := range files {
		offers[i] = protocol.FileOffer{Index: i, RelativePath: f.Rel, Size: f.Size, Modified: f.Modified}
		total += f.Size
	}
	sessionID := newUUID()
	itemID := newUUID()
	if existing != nil && existing.ID != "" {
		itemID = existing.ID
		sessionID = existing.SessionID
	}
	title := files[0].Rel
	if len(files) > 1 {
		title = fmt.Sprintf("%d 个文件", len(files))
	}
	if existing == nil {
		n.addItem(TransferItem{
			ID: itemID, SessionID: sessionID, Direction: "send", PeerName: peer.Name, PeerID: peer.ID,
			Title: title, Total: total, State: "等待中", Detail: "正在连接 " + peer.Host,
			FileCount: len(files), Time: time.Now(), LocalPath: files[0].Path,
		})
	} else {
		n.updateItem(itemID, func(it TransferItem) TransferItem {
			it.State = "等待中"
			it.Detail = "正在连接 " + peer.Host
			it.Speed = 0
			return it
		})
	}
	if err := n.runSend(peer, files, offers, sessionID, itemID, s); err != nil {
		if n.isCancelled(sessionID) {
			n.updateItem(itemID, func(it TransferItem) TransferItem {
				it.State = "已取消"
				it.Detail = "已取消"
				it.Speed = 0
				return it
			})
			return
		}
		if isUnreachable(err) && n.canQueue(peer) {
			n.requeueUnreachable(peer, files, itemID, sessionID)
			return
		}
		n.updateItem(itemID, func(it TransferItem) TransferItem {
			it.State = "失败"
			it.Detail = err.Error()
			it.Speed = 0
			return it
		})
		return
	}
	path := ""
	if len(files) > 0 {
		path = files[0].Path
	}
	n.addHistory(title, peer.Name, path, "", "send")
}

func (n *Node) runSend(peer Peer, files []LocalFile, offers []protocol.FileOffer, sessionID, itemID string, s Settings) error {
	conn, err := dialTCP(peer.Host, peer.Port, 12*time.Second)
	if err != nil {
		return errMsg("连不上对方，请确认同一 Wi-Fi，并允许互传通过防火墙")
	}
	defer conn.Close()
	control := NewWire(conn, false)
	hello := protocol.Envelope{
		T: "hello", DeviceID: s.DeviceID, Name: s.DeviceName, Port: s.Port,
		HTTPPort: HTTPPort(s.Port), OS: OSName(), AppVersion: AppVersion,
	}
	if s.Pin != "" {
		p := s.Pin
		hello.Pin = &p
	}
	if err := control.SendJSON(hello); err != nil {
		return err
	}
	msg, err := control.RecvJSON(15 * time.Second)
	if err != nil {
		return errMsg("握手失败")
	}
	if msg.T == "reject" {
		return errMsg(msg.Reason)
	}
	if msg.T != "helloOk" {
		return errMsg("握手失败")
	}
	token := newUUID()
	if err := control.SendJSON(protocol.Envelope{T: "offer", SessionID: sessionID, Token: token, Files: offers}); err != nil {
		return err
	}
	n.updateItem(itemID, func(it TransferItem) TransferItem {
		it.Detail = "等待 " + peer.Name + " 同意"
		return it
	})
	reply, err := control.RecvJSON(125 * time.Second)
	if err != nil {
		return errMsg("对方没有回应")
	}
	if reply.T == "reject" {
		return errMsg(reply.Reason)
	}
	if reply.T != "offerReply" || reply.Accepted == nil || !*reply.Accepted {
		return errMsg("对方拒绝接收")
	}
	bitmaps := make([]protocol.ChunkBitmap, len(offers))
	var already uint64
	for i, file := range offers {
		plan := protocol.Plan(file.Size)
		b64 := ""
		if i < len(reply.ResumeBits) {
			b64 = reply.ResumeBits[i]
		}
		bitmaps[i] = protocol.BitmapFromBase64(b64, plan.ChunkCount())
		for c := 0; c < plan.ChunkCount(); c++ {
			if bitmaps[i].Contains(c) {
				already += uint64(plan.Length(c))
			}
		}
	}
	n.updateItem(itemID, func(it TransferItem) TransferItem {
		it.State = "传输中"
		it.Done = already
		if already > 0 {
			it.Detail = "断点续传中"
		} else {
			it.Detail = "正在发送"
		}
		return it
	})
	q := &workQueue{}
	for i, file := range offers {
		plan := protocol.Plan(file.Size)
		for c := 0; c < plan.ChunkCount(); c++ {
			if !bitmaps[i].Contains(c) {
				q.add(i, c)
			}
		}
	}
	if q.count() == 0 {
		_ = control.SendJSON(protocol.Envelope{T: "finish", SessionID: sessionID})
		n.updateItem(itemID, func(it TransferItem) TransferItem {
			it.State = "已完成"
			it.Done = it.Total
			it.Speed = 0
			it.Detail = "已完成（无需重传）"
			return it
		})
		return nil
	}
	var biggest uint64
	for _, f := range offers {
		if f.Size > biggest {
			biggest = f.Size
		}
	}
	workers := protocol.ParallelConnections(biggest, s.MaxConnections)
	n.updateItem(itemID, func(it TransferItem) TransferItem {
		it.Detail = fmt.Sprintf("%d 路并行发送", workers)
		return it
	})
	meter := &speedMeter{}
	var wg sync.WaitGroup
	errCh := make(chan error, workers)
	for w := 0; w < workers; w++ {
		wg.Add(1)
		w := w
		go func() {
			defer wg.Done()
			if err := n.runSendWorker(peer.Host, peer.Port, sessionID, token, w, files, offers, q, meter, itemID); err != nil {
				errCh <- err
			}
		}()
	}
	wg.Wait()
	select {
	case err := <-errCh:
		if n.isCancelled(sessionID) {
			_ = control.SendJSON(protocol.Envelope{T: "cancel", SessionID: sessionID, Reason: "发送方取消"})
			return errMsg("已取消")
		}
		return err
	default:
	}
	if n.isCancelled(sessionID) {
		_ = control.SendJSON(protocol.Envelope{T: "cancel", SessionID: sessionID, Reason: "发送方取消"})
		return errMsg("已取消")
	}
	if err := control.SendJSON(protocol.Envelope{T: "finish", SessionID: sessionID}); err != nil {
		return err
	}
	n.updateItem(itemID, func(it TransferItem) TransferItem {
		it.State = "已完成"
		it.Done = it.Total
		it.Speed = 0
		it.Detail = "已送达"
		return it
	})
	return nil
}

func (n *Node) runSendWorker(host string, port uint16, sessionID, token string, workerID int, files []LocalFile, offers []protocol.FileOffer, q *workQueue, meter *speedMeter, itemID string) error {
	conn, err := dialTCP(host, port, 12*time.Second)
	if err != nil {
		return errMsg("数据通道连不上")
	}
	defer conn.Close()
	io := NewWire(conn, false)
	if err := io.SendJSON(protocol.Envelope{T: "join", SessionID: sessionID, Token: token, WorkerID: workerID}); err != nil {
		return err
	}
	for {
		if n.isCancelled(sessionID) {
			return nil
		}
		j, ok := q.next()
		if !ok {
			return nil
		}
		file := offers[j.file]
		plan := protocol.Plan(file.Size)
		start, end := plan.ByteRange(j.chunk)
		attempt := 0
		for {
			attempt++
			data, err := readAt(files[j.file].Path, start, int(end-start))
			if err != nil {
				return err
			}
			if err := io.SendChunk(protocol.NewChunk(uint32(j.file), uint32(j.chunk), data)); err != nil {
				return err
			}
			frame, err := io.Recv(45 * time.Second)
			if err != nil {
				return errMsg("数据通道异常")
			}
			if frame.Kind != protocol.KindChunkAck {
				return errMsg("数据通道异常")
			}
			ack, err := protocol.DecodeAck(frame.Payload)
			if err != nil {
				return err
			}
			if ack.OK {
				spd := meter.add(uint64(len(data)))
				n.updateItem(itemID, func(it TransferItem) TransferItem {
					it.Done += uint64(len(data))
					if it.Done > it.Total {
						it.Done = it.Total
					}
					it.Speed = spd
					it.State = "传输中"
					it.Detail = protocol.FormatSpeed(spd) + " · " + protocol.FormatETA(it.Total-it.Done, spd)
					return it
				})
				break
			}
			if attempt >= 4 {
				return errMsg("分块多次校验失败：" + file.RelativePath)
			}
		}
	}
}

func (n *Node) SendTextTo(peer Peer, text string) {
	if peer.ID == "phone-web" {
		return
	}
	go n.deliverText(peer, text, "", "")
}

func (n *Node) deliverText(peer Peer, text, itemID, sessionID string) {
	if live, ok := n.PeerByID(peer.ID); ok {
		peer = live
	}
	if itemID == "" && n.shouldQueue(peer) {
		n.queueText(peer, text, "", "", false)
		return
	}
	s := n.settingsCopy()
	conn, err := dialTCP(peer.Host, peer.Port, 12*time.Second)
	if err != nil {
		if n.canQueue(peer) {
			n.queueText(peer, text, itemID, sessionID, itemID != "")
			return
		}
		n.fail(peer.Name, "文字没发出去")
		return
	}
	defer conn.Close()
	io := NewWire(conn, false)
	hello := protocol.Envelope{
		T: "hello", DeviceID: s.DeviceID, Name: s.DeviceName, Port: s.Port,
		HTTPPort: HTTPPort(s.Port), OS: OSName(), AppVersion: AppVersion,
	}
	if s.Pin != "" {
		p := s.Pin
		hello.Pin = &p
	}
	if err := io.SendJSON(hello); err != nil {
		n.fail(peer.Name, "文字没发出去")
		return
	}
	if _, err := io.RecvJSON(15 * time.Second); err != nil {
		n.fail(peer.Name, "文字没发出去")
		return
	}
	_ = io.SendJSON(protocol.Envelope{T: "text", SessionID: newUUID(), Body: text})
	if itemID != "" {
		n.updateItem(itemID, func(it TransferItem) TransferItem {
			it.State = "已完成"
			it.Detail = "已发出"
			it.Speed = 0
			return it
		})
	}
}
