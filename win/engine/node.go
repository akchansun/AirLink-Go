package engine

import (
	"context"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"

	"huchuan/protocol"
)

type Peer struct {
	ID       string    `json:"id"`
	Name     string    `json:"name"`
	Host     string    `json:"host"`
	Port     uint16    `json:"port"`
	HTTPPort uint16    `json:"httpPort"`
	OS       string    `json:"os"`
	Via      string    `json:"via"`
	Favorite bool      `json:"favorite"`
	LastSeen time.Time `json:"-"`
	Online   bool      `json:"online"`
}

type TransferItem struct {
	ID        string    `json:"id"`
	SessionID string    `json:"sessionId"`
	Direction string    `json:"direction"`
	PeerName  string    `json:"peerName"`
	PeerID    string    `json:"peerId"`
	Title     string    `json:"title"`
	Total     uint64    `json:"total"`
	Done      uint64    `json:"done"`
	Speed     float64   `json:"speed"`
	State     string    `json:"state"`
	Detail    string    `json:"detail"`
	FileCount int       `json:"fileCount"`
	Time      time.Time `json:"time"`
	LocalPath string    `json:"localPath"`
}

type ChatLine struct {
	ID       string `json:"id"`
	PeerID   string `json:"peerId"`
	PeerName string `json:"peerName"`
	Outgoing bool   `json:"outgoing"`
	Text     string `json:"text"`
	Time     int64  `json:"time"`
}

type IncomingOffer struct {
	ID       string               `json:"id"`
	PeerName string               `json:"peerName"`
	Files    []protocol.FileOffer `json:"files"`
	Total    uint64               `json:"total"`
}

type IncomingText struct {
	PeerName string `json:"peerName"`
	Body     string `json:"body"`
}

type Node struct {
	mu              sync.Mutex
	settings        Settings
	peers           []Peer
	items           []TransferItem
	messages        []ChatLine
	incoming        *IncomingOffer
	incomingText    *IncomingText
	offerWait       chan bool
	selectedID      string
	page            string
	waitingForPhone bool
	status          string
	localIPs        []string
	hub             *RecvHub
	cancelled       map[string]bool
	tcpLn           net.Listener
	udpConn         *net.UDPConn
	phoneSrv        httpStop
	uiLn            net.Listener
	uiAddr          string
	log             *logMu
	stopCh          chan struct{}
	stopped         bool
	listening       bool
	lastUni         map[string]time.Time
	recvCount       int
	echoCount       int
	scanMu          sync.Mutex
	tcpScanMu       sync.Mutex
	sweepN          int
	mdnsServer      mdnsService
	mdnsCancel      context.CancelFunc
	outFiles        []phoneOutFile
	outTexts        []phoneOutText
	lastPhoneClaim  time.Time
	history         []HistoryItem
	pickingMany     bool
	multiIDs        []string
	sendQueue       []queuedSend
	flushing        map[string]bool
	booth           *BoothHub
	boothSess       *BoothSession
	boothErr        string
	boothHint       string
}

type httpStop interface{ Close() error }

func NewNode(s Settings) *Node {
	if s.DeviceID == "" {
		s.DeviceID = newUUID()
	}
	s.NormalizeReceiveMode()
	return &Node{
		settings:  s,
		page:      "welcome",
		status:    "正在寻找附近设备…",
		hub:       newHub(),
		cancelled: map[string]bool{},
		flushing:  map[string]bool{},
		log:       openLog(),
		stopCh:    make(chan struct{}),
		lastUni:   map[string]time.Time{},
		history:   loadHistory(s.DeviceID),
		sendQueue: loadSendQueue(s.DeviceID),
	}
}

func (n *Node) settingsCopy() Settings {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.settings
}

func (n *Node) DeviceID() string { return n.settingsCopy().DeviceID }

func (n *Node) UIAddr() string {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.uiAddr
}

func (n *Node) Listening() bool {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.listening
}

func (n *Node) WaitListening(d time.Duration) error {
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if n.Listening() {
			return nil
		}
		time.Sleep(50 * time.Millisecond)
	}
	return errMsg(fmt.Sprintf("没有成功监听端口 %d", n.settingsCopy().Port))
}

func (n *Node) Start() error {
	s := n.settingsCopy()
	_ = os.MkdirAll(s.ReceiveFolder, 0o755)
	ln, err := net.Listen("tcp4", fmt.Sprintf("0.0.0.0:%d", s.Port))
	if err != nil {
		n.setStatus(fmt.Sprintf("无法监听端口 %d，请在设置里换一个", s.Port))
		return err
	}
	n.mu.Lock()
	n.tcpLn = ln
	n.listening = true
	n.mu.Unlock()
	go n.acceptLoop(ln)
	allowFirewall(s.Port)
	_ = n.listenUDP()
	n.refreshIPs()
	n.startMDNS()
	n.startPhoneHTTP()
	n.mergeFavorites()
	n.restoreQueuedItems()
	go n.tick()
	n.broadcast()
	n.flushOnlineQueued()
	return nil
}

func (n *Node) Stop() {
	n.mu.Lock()
	if n.stopped {
		n.mu.Unlock()
		return
	}
	n.stopped = true
	n.listening = false
	close(n.stopCh)
	if n.tcpLn != nil {
		_ = n.tcpLn.Close()
	}
	if n.udpConn != nil {
		_ = n.udpConn.Close()
	}
	if n.phoneSrv != nil {
		_ = n.phoneSrv.Close()
	}
	mdns := n.mdnsServer
	cancel := n.mdnsCancel
	n.mdnsServer = nil
	n.mdnsCancel = nil
	n.mu.Unlock()
	if cancel != nil {
		cancel()
	}
	if mdns != nil {
		mdns.Shutdown()
	}
}

func (n *Node) acceptLoop(ln net.Listener) {
	for {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		go n.handleConn(c)
	}
}

func (n *Node) tick() {
	t := time.NewTicker(1500 * time.Millisecond)
	defer t.Stop()
	for {
		select {
		case <-n.stopCh:
			return
		case <-t.C:
			n.broadcast()
			n.prune()
			go n.udpLanSweep()
			n.mu.Lock()
			n.sweepN++
			doTCP := n.sweepN%4 == 0
			doFlush := n.sweepN%5 == 0
			n.mu.Unlock()
			if doTCP {
				go n.tcpLanSweep()
			}
			if doFlush {
				n.flushOnlineQueued()
			}
		}
	}
}

func (n *Node) setStatus(s string) {
	n.mu.Lock()
	n.status = s
	n.mu.Unlock()
}

func (n *Node) refreshIPs() {
	n.mu.Lock()
	ips := rankIPv4(localIPv4())
	if len(ips) == 0 {
		ips = rankIPv4(allOwnIPv4())
	}
	n.localIPs = ips
	n.mu.Unlock()
}

func (n *Node) Refresh() {
	n.refreshIPs()
	n.broadcast()
	n.prune()
}

func (n *Node) upsert(p Peer) {
	s := n.settingsCopy()
	if p.ID != "phone-web" {
		if p.ID == s.DeviceID {
			return
		}
		if isOwnHost(p.Host) {
			return
		}
	}
	if !n.allowPeer(p.ID, p.Via) {
		return
	}
	cameOnline := false
	var live Peer
	n.mu.Lock()
	idx := -1
	for i, old := range n.peers {
		if old.ID == p.ID || (old.Host == p.Host && old.Port == p.Port) {
			idx = i
			break
		}
	}
	now := time.Now()
	if idx >= 0 {
		old := n.peers[idx]
		wasOnline := peerOnline(old, now)
		old.Name, old.Host, old.Port, old.HTTPPort, old.OS, old.LastSeen, old.Via = p.Name, p.Host, p.Port, p.HTTPPort, p.OS, p.LastSeen, p.Via
		if len(p.ID) < 8 || p.ID[:8] != "bonjour-" {
			old.ID = p.ID
		}
		old.Favorite = s.IsFavorite(old.ID)
		n.peers[idx] = old
		if !wasOnline && peerOnline(old, now) && old.ID != "phone-web" {
			cameOnline = true
			live = old
		}
	} else {
		p.Favorite = s.IsFavorite(p.ID)
		n.peers = append(n.peers, p)
		if peerOnline(p, now) && p.ID != "phone-web" {
			cameOnline = true
			live = p
		}
	}
	sort.Slice(n.peers, func(i, j int) bool {
		if n.peers[i].Favorite != n.peers[j].Favorite {
			return n.peers[i].Favorite
		}
		return n.peers[i].Name < n.peers[j].Name
	})
	n.refreshStatusLocked()
	n.mu.Unlock()
	if cameOnline {
		go n.flushSendQueue(live)
	}
}

func (n *Node) prune() {
	n.mu.Lock()
	defer n.mu.Unlock()
	s := n.settings
	now := time.Now()
	out := n.peers[:0]
	for _, p := range n.peers {
		if now.Sub(p.LastSeen) <= 45*time.Second || p.Via == "手动添加" || p.Favorite || s.IsFavorite(p.ID) {
			out = append(out, p)
		}
	}
	n.peers = out
	n.refreshStatusLocked()
}

func (n *Node) refreshStatus() {
	n.mu.Lock()
	defer n.mu.Unlock()
	n.refreshStatusLocked()
}

func (n *Node) allowPeer(id, via string) bool {
	if id == "phone-web" || strings.HasPrefix(id, "manual-") || via == "手动添加" || via == "收藏" {
		return true
	}
	s := n.settingsCopy()
	switch s.DiscoverMode {
	case "off":
		return false
	case "favorites":
		return s.IsFavorite(id)
	default:
		return true
	}
}

func (n *Node) refreshStatusLocked() {
	switch n.settings.DiscoverMode {
	case "off":
		n.status = "已关闭发现，别人找不到这台电脑"
		return
	case "favorites":
		if len(n.peers) == 0 {
			n.status = "只让收藏的人发现我"
		} else {
			n.status = fmt.Sprintf("收藏范围内 %d 台设备", len(n.peers))
		}
		return
	}
	if len(n.peers) == 0 {
		ip := ""
		if len(n.localIPs) > 0 {
			ip = n.localIPs[0] + " · "
		}
		n.status = fmt.Sprintf("%s端口 %d · 对方的包 %d 个，自己的回声 %d 个", ip, n.settings.Port, n.recvCount, n.echoCount)
	} else {
		n.status = fmt.Sprintf("发现 %d 台设备", len(n.peers))
	}
}

func (n *Node) AddManual(host string, port uint16) {
	host = trim(host)
	if host == "" {
		return
	}
	if port == 0 {
		port = DefaultPort
	}
	n.upsert(Peer{
		ID: fmt.Sprintf("manual-%s-%d", host, port), Name: host, Host: host,
		Port: port, HTTPPort: HTTPPort(port), OS: "手动", Via: "手动添加",
		LastSeen: time.Now().Add(time.Hour),
	})
	n.mu.Lock()
	for _, p := range n.peers {
		if p.Host == host && p.Port == port {
			n.selectedID = p.ID
			n.page = "chat"
			break
		}
	}
	n.mu.Unlock()
}

func trim(s string) string {
	b := []byte(s)
	i, j := 0, len(b)
	for i < j && (b[i] == ' ' || b[i] == '\t' || b[i] == '\n' || b[i] == '\r') {
		i++
	}
	for j > i && (b[j-1] == ' ' || b[j-1] == '\t' || b[j-1] == '\n' || b[j-1] == '\r') {
		j--
	}
	return string(b[i:j])
}

func (n *Node) Select(id string) {
	n.mu.Lock()
	n.selectedID = id
	if id != "" {
		n.page = "chat"
	} else {
		n.page = "welcome"
	}
	n.mu.Unlock()
}

func (n *Node) SetPage(page string) {
	n.mu.Lock()
	n.page = page
	if page == "phone" {
		n.waitingForPhone = !n.phoneLiveLocked()
	}
	needBooth := page == "store" && n.boothSess == nil
	n.mu.Unlock()
	if needBooth {
		n.OpenBooth()
	}
}

func (n *Node) phoneLiveLocked() bool {
	now := time.Now()
	for _, p := range n.peers {
		if p.ID == "phone-web" && now.Sub(p.LastSeen) <= 12*time.Second {
			return true
		}
	}
	return false
}

func (n *Node) selectedPeer() (Peer, bool) {
	n.mu.Lock()
	defer n.mu.Unlock()
	id := n.selectedID
	for _, p := range n.peers {
		if p.ID == id {
			return p, true
		}
	}
	return Peer{}, false
}

func (n *Node) PeerByID(id string) (Peer, bool) {
	n.mu.Lock()
	defer n.mu.Unlock()
	for _, p := range n.peers {
		if p.ID == id {
			return p, true
		}
	}
	return Peer{}, false
}

func (n *Node) LoopPeer() Peer {
	s := n.settingsCopy()
	return Peer{
		ID: "loop", Name: s.DeviceName, Host: "127.0.0.1",
		Port: s.Port, HTTPPort: HTTPPort(s.Port), OS: OSName(), Via: "自检",
		LastSeen: time.Now(),
	}
}

func (n *Node) SendText(text string) {
	text = trim(text)
	peer, ok := n.selectedPeer()
	if !ok || text == "" {
		return
	}
	n.SendTextTo(peer, text)
	if peer.ID == "phone-web" {
		n.queuePhoneText(text)
	}
	n.mu.Lock()
	n.messages = append(n.messages, ChatLine{
		ID: newUUID(), PeerID: peer.ID, PeerName: peer.Name, Outgoing: true, Text: text, Time: time.Now().UnixMilli(),
	})
	n.mu.Unlock()
}

func (n *Node) askOffer(offer protocol.Envelope, peerName, peerID string) bool {
	s := n.settingsCopy()
	if d := s.ShouldAutoAccept(peerID, peerName); d != nil {
		return *d
	}
	var total uint64
	for _, f := range offer.Files {
		total += f.Size
	}
	n.mu.Lock()
	if n.offerWait != nil {
		select {
		case n.offerWait <- false:
		default:
		}
	}
	ch := make(chan bool, 1)
	n.offerWait = ch
	n.incoming = &IncomingOffer{ID: offer.SessionID, PeerName: peerName, Files: offer.Files, Total: total}
	n.mu.Unlock()
	Alert("有人发文件过来", peerName+" 要发给你")
	timer := time.NewTimer(120 * time.Second)
	defer timer.Stop()
	select {
	case v := <-ch:
		return v
	case <-timer.C:
		n.RejectIncoming()
		return false
	}
}

func (n *Node) AcceptIncoming() {
	n.mu.Lock()
	n.incoming = nil
	ch := n.offerWait
	n.offerWait = nil
	n.mu.Unlock()
	if ch != nil {
		ch <- true
	}
}

func (n *Node) RejectIncoming() {
	n.mu.Lock()
	n.incoming = nil
	ch := n.offerWait
	n.offerWait = nil
	n.mu.Unlock()
	if ch != nil {
		ch <- false
	}
}

func (n *Node) DismissText() {
	n.mu.Lock()
	n.incomingText = nil
	n.mu.Unlock()
}

func (n *Node) showText(name, body string) {
	n.mu.Lock()
	peerID := name
	for _, p := range n.peers {
		if p.Name == name {
			peerID = p.ID
			n.selectedID = p.ID
			n.page = "chat"
			break
		}
	}
	n.messages = append(n.messages, ChatLine{
		ID: newUUID(), PeerID: peerID, PeerName: name, Outgoing: false, Text: body, Time: time.Now().UnixMilli(),
	})
	n.incomingText = &IncomingText{PeerName: name, Body: body}
	n.mu.Unlock()
	n.addHistory(body, name, "", body, "recv")
	if n.settingsCopy().AutoCopyText {
		copyText(body)
	}
	Alert("收到文字", name+" 发来一段文字")
}

func (n *Node) IncomingText() *IncomingText {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.incomingText
}

func (n *Node) Incoming() *IncomingOffer {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.incoming
}

func (n *Node) Items() []TransferItem {
	n.mu.Lock()
	defer n.mu.Unlock()
	out := make([]TransferItem, len(n.items))
	copy(out, n.items)
	return out
}

func (n *Node) addItem(it TransferItem) {
	n.mu.Lock()
	n.items = append([]TransferItem{it}, n.items...)
	n.mu.Unlock()
}

func (n *Node) updateItem(id string, fn func(TransferItem) TransferItem) {
	n.mu.Lock()
	defer n.mu.Unlock()
	for i := range n.items {
		if n.items[i].ID == id {
			n.items[i] = fn(n.items[i])
			return
		}
	}
}

func (n *Node) bump(sessionID string, added uint64, speed float64) {
	n.mu.Lock()
	defer n.mu.Unlock()
	for i := range n.items {
		if n.items[i].SessionID == sessionID {
			n.items[i].Done += added
			if n.items[i].Done > n.items[i].Total {
				n.items[i].Done = n.items[i].Total
			}
			n.items[i].Speed = speed
			n.items[i].State = "传输中"
			n.items[i].Detail = protocol.FormatSpeed(speed) + " · " + protocol.FormatETA(n.items[i].Total-n.items[i].Done, speed)
			return
		}
	}
}

func (n *Node) markItem(sessionID, state, detail string) {
	n.mu.Lock()
	defer n.mu.Unlock()
	for i := range n.items {
		if n.items[i].SessionID == sessionID {
			n.items[i].State = state
			n.items[i].Detail = detail
			n.items[i].Speed = 0
			if state == "已完成" {
				n.items[i].Done = n.items[i].Total
			}
			return
		}
	}
}

func (n *Node) fail(peerName, message string) {
	n.mu.Lock()
	defer n.mu.Unlock()
	for i := range n.items {
		if n.items[i].PeerName == peerName && (n.items[i].State == "等待中" || n.items[i].State == "等待对方上线" || n.items[i].State == "传输中") {
			n.items[i].State = "失败"
			n.items[i].Detail = message
			n.items[i].Speed = 0
			return
		}
	}
	n.items = append([]TransferItem{{
		ID: newUUID(), SessionID: newUUID(), Direction: "send", PeerName: peerName,
		Title: "发送失败", State: "失败", Detail: message, Time: time.Now(),
	}}, n.items...)
}

func (n *Node) Cancel(id string) {
	n.mu.Lock()
	var session string
	for i := range n.items {
		if n.items[i].ID == id {
			session = n.items[i].SessionID
			n.items[i].State = "已取消"
			n.items[i].Detail = "已取消"
			n.items[i].Speed = 0
			break
		}
	}
	if session != "" {
		n.cancelled[session] = true
		if sess := n.hub.get(session); sess != nil {
			sess.cancelled.Store(true)
		}
	}
	n.mu.Unlock()
	n.dropQueued(id, session)
	if session != "" {
		n.cancelPhoneSession(session)
	}
}

func (n *Node) isCancelled(sessionID string) bool {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.cancelled[sessionID]
}

func (n *Node) UpdateSettings(s Settings) {
	n.mu.Lock()
	cur := n.settings
	favs := cur.Favorites
	if s.DeviceName != "" {
		cur.DeviceName = s.DeviceName
	}
	if s.ReceiveFolder != "" {
		cur.ReceiveFolder = s.ReceiveFolder
	}
	if s.ReceiveMode != "" {
		cur.ReceiveMode = s.ReceiveMode
	} else if s.AutoAccept {
		cur.ReceiveMode = "auto"
	} else if cur.ReceiveMode == "auto" {
		cur.ReceiveMode = "ask"
	}
	cur.NormalizeReceiveMode()
	cur.Pin = s.Pin
	if s.MaxConnections > 0 {
		cur.MaxConnections = s.MaxConnections
	}
	if s.Port > 0 {
		cur.Port = s.Port
	}
	if !cur.isSelfTest() {
		cur.LaunchAtLogin = s.LaunchAtLogin
	}
	cur.Favorites = favs
	if s.DiscoverMode != "" {
		cur.DiscoverMode = s.DiscoverMode
	}
	cur.AutoCopyText = s.AutoCopyText
	cur.StoreRelayURL = strings.TrimSpace(s.StoreRelayURL)
	cur.StorePublicURL = strings.TrimSpace(s.StorePublicURL)
	cur.StoreWifiName = strings.TrimSpace(s.StoreWifiName)
	cur.StoreWifiPassword = s.StoreWifiPassword
	switch cur.DiscoverMode {
	case "everyone", "favorites", "off":
	default:
		cur.DiscoverMode = "everyone"
	}
	n.settings = cur
	n.mu.Unlock()
	cur.Save()
	if !cur.isSelfTest() {
		SetLaunchAtLogin(cur.LaunchAtLogin)
	}
	_ = os.MkdirAll(cur.ReceiveFolder, 0o755)
}

func (n *Node) OpenRecv() {
	folder := n.settingsCopy().ReceiveFolder
	_ = os.MkdirAll(folder, 0o755)
	n.openOSPath(folder, false)
}

func (n *Node) OpenPath(p string) {
	p = n.safeOpenPath(p)
	if p == "" {
		n.OpenRecv()
		return
	}
	n.openOSPath(p, false)
}

func (n *Node) RevealPath(p string) {
	p = n.safeOpenPath(p)
	if p == "" {
		n.OpenRecv()
		return
	}
	n.openOSPath(p, true)
}

func (n *Node) safeOpenPath(p string) string {
	p = filepath.Clean(p)
	if p == "" || p == "." {
		return ""
	}
	recv := n.settingsCopy().ReceiveFolder
	n.mu.Lock()
	items := append([]TransferItem(nil), n.items...)
	hist := append([]HistoryItem(nil), n.history...)
	n.mu.Unlock()
	if recv != "" && (p == recv || strings.HasPrefix(p, recv+string(os.PathSeparator))) {
		return p
	}
	for _, it := range items {
		if it.LocalPath != "" && filepath.Clean(it.LocalPath) == p {
			return p
		}
	}
	for _, h := range hist {
		if h.Path != "" && filepath.Clean(h.Path) == p {
			return p
		}
	}
	return ""
}

func (n *Node) openOSPath(p string, reveal bool) {
	switch runtime.GOOS {
	case "windows":
		if reveal {
			_ = exec.Command("explorer", "/select,", p).Start()
			return
		}
		_ = exec.Command("cmd", "/C", "start", "", p).Start()
	case "darwin":
		if reveal {
			_ = exec.Command("open", "-R", p).Start()
			return
		}
		_ = exec.Command("open", p).Start()
	default:
		if reveal {
			_ = exec.Command("xdg-open", filepath.Dir(p)).Start()
			return
		}
		_ = exec.Command("xdg-open", p).Start()
	}
}

func (n *Node) NotePhoneFile(name, dest string, size int64) {
	n.notePhoneOnline("手机")
	n.addItem(TransferItem{
		ID: newUUID(), SessionID: newUUID(), Direction: "receive",
		PeerName: "手机网页", PeerID: "phone-web", Title: name,
		Total: uint64(size), Done: uint64(size), State: "已完成", Detail: "已保存",
		FileCount: 1, Time: time.Now(), LocalPath: dest,
	})
	n.addHistory(name, "手机网页", dest, "", "recv")
	n.mu.Lock()
	n.selectedID = "phone-web"
	n.page = "chat"
	n.waitingForPhone = false
	n.mu.Unlock()
	Alert("手机发来文件", name)
}

func (n *Node) PhoneURL() string {
	s := n.settingsCopy()
	n.mu.Lock()
	ips := append([]string(nil), n.localIPs...)
	n.mu.Unlock()
	ip := "127.0.0.1"
	if len(ips) > 0 {
		ip = ips[0]
	}
	return fmt.Sprintf("http://%s:%d", ip, HTTPPort(s.Port))
}

func peerOnline(p Peer, now time.Time) bool {
	if p.ID == "phone-web" {
		return now.Sub(p.LastSeen) <= 12*time.Second
	}
	return now.Sub(p.LastSeen) <= 45*time.Second
}

func (n *Node) Snapshot() map[string]any {
	s := n.settingsCopy()
	n.mu.Lock()
	peers := make([]Peer, len(n.peers))
	copy(peers, n.peers)
	now := time.Now()
	for i := range peers {
		peers[i].Online = peerOnline(peers[i], now)
	}
	items := make([]TransferItem, len(n.items))
	copy(items, n.items)
	msgs := make([]ChatLine, len(n.messages))
	copy(msgs, n.messages)
	ips := append([]string(nil), n.localIPs...)
	page := n.page
	selectedID := n.selectedID
	status := n.status
	incoming := n.incoming
	incomingText := n.incomingText
	listening := n.listening
	recvCount := n.recvCount
	echoCount := n.echoCount
	history := append([]HistoryItem(nil), n.history...)
	pickingMany := n.pickingMany
	multiIDs := append([]string(nil), n.multiIDs...)
	booth := n.boothSess
	boothErr := n.boothErr
	boothHint := n.boothHint
	n.mu.Unlock()
	ip := "127.0.0.1"
	if len(ips) > 0 {
		ip = ips[0]
	}
	phone := fmt.Sprintf("http://%s:%d", ip, HTTPPort(s.Port))
	qr := ""
	if page == "phone" {
		qr = PhoneQRDataURI(phone)
	}
	boothQR := ""
	wifiQR := ""
	if page == "store" && booth != nil {
		boothQR = PhoneQRDataURI(booth.URL)
		if payload := WifiQRPayload(s.StoreWifiName, s.StoreWifiPassword); payload != "" {
			wifiQR = PhoneQRDataURI(payload)
		}
	}
	meet := ""
	if selectedID != "" && selectedID != "phone-web" {
		meet = protocol.MeetCode(s.DeviceID, selectedID)
	}
	return map[string]any{
		"me": map[string]any{
			"name": s.DeviceName, "id": s.DeviceID, "port": s.Port,
			"httpPort": HTTPPort(s.Port), "ips": ips, "os": OSName(),
		},
		"page": page, "selectedId": selectedID, "status": status,
		"peers": peers, "items": items, "messages": msgs,
		"incoming": incoming, "incomingText": incomingText,
		"settings": s, "phoneURL": phone, "phoneQR": qr, "listening": listening,
		"recvCount": recvCount, "echoCount": echoCount,
		"history": history, "pickingMany": pickingMany, "multiIds": multiIDs,
		"booth": booth, "boothQR": boothQR, "wifiQR": wifiQR, "currentSSID": CurrentSSID(), "boothError": boothErr, "boothHint": boothHint, "meetCode": meet,
	}
}

func (n *Node) mergeFavorites() {
	s := n.settingsCopy()
	n.mu.Lock()
	have := map[string]bool{}
	for _, p := range n.peers {
		have[p.ID] = true
	}
	n.mu.Unlock()
	for _, fav := range s.Favorites {
		if fav.ID == "" || fav.ID == "phone-web" || have[fav.ID] {
			continue
		}
		n.upsert(Peer{
			ID: fav.ID, Name: fav.Name, Host: fav.Host, Port: fav.Port,
			HTTPPort: HTTPPort(fav.Port), OS: "收藏", Via: "收藏",
			Favorite: true, LastSeen: time.Time{},
		})
	}
	n.mu.Lock()
	defer n.mu.Unlock()
	for i := range n.peers {
		n.peers[i].Favorite = s.IsFavorite(n.peers[i].ID)
	}
	sort.Slice(n.peers, func(i, j int) bool {
		if n.peers[i].Favorite != n.peers[j].Favorite {
			return n.peers[i].Favorite
		}
		return n.peers[i].Name < n.peers[j].Name
	})
}

func (n *Node) ToggleFavorite(id string) {
	if id == "" || id == "phone-web" {
		return
	}
	p, ok := n.PeerByID(id)
	n.mu.Lock()
	s := n.settings
	favs := append([]FavoritePeer(nil), s.Favorites...)
	found := -1
	for i, f := range favs {
		if f.ID == id {
			found = i
			break
		}
	}
	if found >= 0 {
		favs = append(favs[:found], favs[found+1:]...)
	} else if ok {
		favs = append(favs, FavoritePeer{ID: p.ID, Name: p.Name, Host: p.Host, Port: p.Port})
	}
	s.Favorites = favs
	n.settings = s
	n.mu.Unlock()
	s.Save()
	n.mergeFavorites()
}

func (n *Node) SetPicking(on bool) {
	n.mu.Lock()
	n.pickingMany = on
	if !on {
		n.multiIDs = nil
	}
	n.mu.Unlock()
}

func (n *Node) ToggleMulti(id string) {
	if id == "" {
		return
	}
	n.mu.Lock()
	defer n.mu.Unlock()
	for i, x := range n.multiIDs {
		if x == id {
			n.multiIDs = append(n.multiIDs[:i], n.multiIDs[i+1:]...)
			return
		}
	}
	n.multiIDs = append(n.multiIDs, id)
}

func (n *Node) SendToIDs(ids []string, paths []string) {
	if len(ids) == 0 || len(paths) == 0 {
		return
	}
	for _, id := range ids {
		if p, ok := n.PeerByID(id); ok {
			n.SendPaths(p, paths)
		}
	}
	n.mu.Lock()
	n.pickingMany = false
	n.multiIDs = nil
	n.selectedID = ids[0]
	n.page = "chat"
	n.mu.Unlock()
}
