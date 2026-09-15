package engine

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type queuedSend struct {
	ID        string    `json:"id"`
	SessionID string    `json:"sessionId"`
	PeerID    string    `json:"peerId"`
	PeerName  string    `json:"peerName"`
	Host      string    `json:"host"`
	Port      uint16    `json:"port"`
	Paths     []string  `json:"paths"`
	Text      string    `json:"text"`
	Title     string    `json:"title"`
	Total     uint64    `json:"total"`
	FileCount int       `json:"fileCount"`
	LastTry   time.Time `json:"-"`
}

func sendQueuePath() string {
	return filepath.Join(filepath.Dir(settingsPath()), "send-queue.json")
}

func loadSendQueue(deviceID string) []queuedSend {
	if deviceID == "selftest-node" {
		return nil
	}
	raw, err := os.ReadFile(sendQueuePath())
	if err != nil {
		return nil
	}
	var list []queuedSend
	if json.Unmarshal(raw, &list) != nil {
		return nil
	}
	return list
}

func (n *Node) persistSendQueue() {
	if n.settingsCopy().isSelfTest() {
		return
	}
	n.mu.Lock()
	list := append([]queuedSend(nil), n.sendQueue...)
	n.mu.Unlock()
	raw, err := json.MarshalIndent(list, "", "  ")
	if err != nil {
		return
	}
	_ = os.MkdirAll(filepath.Dir(sendQueuePath()), 0o755)
	_ = os.WriteFile(sendQueuePath(), raw, 0o644)
}

func (n *Node) restoreQueuedItems() {
	n.mu.Lock()
	jobs := append([]queuedSend(nil), n.sendQueue...)
	have := map[string]bool{}
	for _, it := range n.items {
		have[it.ID] = true
	}
	n.mu.Unlock()
	for _, job := range jobs {
		if have[job.ID] {
			continue
		}
		n.addItem(TransferItem{
			ID: job.ID, SessionID: job.SessionID, Direction: "send", PeerName: job.PeerName,
			PeerID: job.PeerID, Title: job.Title, Total: job.Total, State: "等待对方上线",
			Detail: "网络中断，会自动接着传（已传过的部分会跳过）", FileCount: job.FileCount, Time: time.Now(),
			LocalPath: firstPath(job.Paths),
		})
	}
}

func firstPath(paths []string) string {
	if len(paths) == 0 {
		return ""
	}
	return paths[0]
}

func (n *Node) canQueue(p Peer) bool {
	return p.ID != "" && p.ID != "phone-web"
}

func (n *Node) shouldQueue(p Peer) bool {
	return n.canQueue(p) && !peerOnline(p, time.Now())
}

func isUnreachable(err error) bool {
	if err == nil {
		return false
	}
	s := err.Error()
	if strings.Contains(s, "分块多次校验失败") || strings.Contains(s, "对方还是旧版") ||
		strings.Contains(s, "协议不匹配") || strings.Contains(s, "对方拒绝") ||
		strings.Contains(s, "已取消") {
		return false
	}
	keys := []string{
		"连不上对方", "连接超时", "连接已断开", "等待数据超时", "数据通道",
		"握手失败", "对方没有回应",
		"connection refused", "i/o timeout", "broken pipe", "connection reset",
		"network is unreachable", "no route to host", "host is down",
		"use of closed network connection", "forcibly closed", "wsasend", "wsarecv",
		"software caused connection abort", "connection timed out",
	}
	low := strings.ToLower(s)
	for _, k := range keys {
		if strings.Contains(low, strings.ToLower(k)) {
			return true
		}
	}
	return false
}

func (n *Node) enqueueLocked(job queuedSend) {
	for i, old := range n.sendQueue {
		if old.ID == job.ID {
			n.sendQueue[i] = job
			return
		}
	}
	n.sendQueue = append(n.sendQueue, job)
}

func (n *Node) enqueue(job queuedSend) {
	n.mu.Lock()
	n.enqueueLocked(job)
	n.mu.Unlock()
	n.persistSendQueue()
}

func (n *Node) dropQueued(id, session string) {
	n.mu.Lock()
	out := n.sendQueue[:0]
	for _, job := range n.sendQueue {
		if job.ID == id || job.SessionID == session {
			continue
		}
		out = append(out, job)
	}
	n.sendQueue = out
	n.mu.Unlock()
	n.persistSendQueue()
}

func (n *Node) takeReadyJob(peerID string) (queuedSend, bool) {
	n.mu.Lock()
	defer n.mu.Unlock()
	now := time.Now()
	for i, job := range n.sendQueue {
		if job.PeerID != peerID {
			continue
		}
		if !job.LastTry.IsZero() && now.Sub(job.LastTry) < 20*time.Second {
			continue
		}
		n.sendQueue = append(n.sendQueue[:i], n.sendQueue[i+1:]...)
		return job, true
	}
	return queuedSend{}, false
}

func (n *Node) queueFiles(peer Peer, files []LocalFile, itemID, sessionID string) {
	if itemID == "" {
		itemID = newUUID()
	}
	if sessionID == "" {
		sessionID = newUUID()
	}
	var total uint64
	paths := make([]string, len(files))
	for i, f := range files {
		total += f.Size
		paths[i] = f.Path
	}
	title := files[0].Rel
	if len(files) > 1 {
		title = fmtCount(len(files))
	}
	n.updateOrAddWaiting(TransferItem{
		ID: itemID, SessionID: sessionID, Direction: "send", PeerName: peer.Name, PeerID: peer.ID,
		Title: title, Total: total, State: "等待对方上线", Detail: "网络中断，会自动接着传（已传过的部分会跳过）",
		FileCount: len(files), Time: time.Now(), LocalPath: files[0].Path,
	})
	n.enqueue(queuedSend{
		ID: itemID, SessionID: sessionID, PeerID: peer.ID, PeerName: peer.Name,
		Host: peer.Host, Port: peer.Port, Paths: paths, Title: title,
		Total: total, FileCount: len(files),
	})
}

func (n *Node) queueText(peer Peer, text string, itemID, sessionID string, cooldown bool) {
	if itemID == "" {
		itemID = newUUID()
	}
	if sessionID == "" {
		sessionID = newUUID()
	}
	title := text
	if len([]rune(title)) > 36 {
		title = string([]rune(title)[:36]) + "…"
	}
	n.updateOrAddWaiting(TransferItem{
		ID: itemID, SessionID: sessionID, Direction: "send", PeerName: peer.Name, PeerID: peer.ID,
		Title: title, State: "等待对方上线", Detail: "网络中断，会自动接着传（已传过的部分会跳过）", Time: time.Now(),
	})
	job := queuedSend{
		ID: itemID, SessionID: sessionID, PeerID: peer.ID, PeerName: peer.Name,
		Host: peer.Host, Port: peer.Port, Text: text, Title: title,
	}
	if cooldown {
		job.LastTry = time.Now()
	}
	n.enqueue(job)
}

func (n *Node) updateOrAddWaiting(it TransferItem) {
	n.mu.Lock()
	for i := range n.items {
		if n.items[i].ID == it.ID {
			n.items[i].State = it.State
			n.items[i].Detail = it.Detail
			n.items[i].Speed = 0
			n.mu.Unlock()
			return
		}
	}
	n.items = append([]TransferItem{it}, n.items...)
	n.mu.Unlock()
}

func fmtCount(n int) string {
	return fmt.Sprintf("%d 个文件", n)
}

func (n *Node) flushOnlineQueued() {
	n.mu.Lock()
	ids := map[string]bool{}
	for _, job := range n.sendQueue {
		ids[job.PeerID] = true
	}
	n.mu.Unlock()
	now := time.Now()
	for id := range ids {
		p, ok := n.PeerByID(id)
		if !ok || !peerOnline(p, now) {
			continue
		}
		go n.flushSendQueue(p)
	}
}

func (n *Node) flushSendQueue(peer Peer) {
	if peer.ID == "" || peer.ID == "phone-web" {
		return
	}
	n.mu.Lock()
	if n.flushing[peer.ID] {
		n.mu.Unlock()
		return
	}
	n.flushing[peer.ID] = true
	n.mu.Unlock()
	defer func() {
		n.mu.Lock()
		delete(n.flushing, peer.ID)
		n.mu.Unlock()
	}()
	for {
		job, ok := n.takeReadyJob(peer.ID)
		if !ok {
			n.persistSendQueue()
			return
		}
		n.persistSendQueue()
		if n.isCancelled(job.SessionID) {
			continue
		}
		live, found := n.PeerByID(peer.ID)
		if !found {
			live = peer
		}
		if !peerOnline(live, time.Now()) {
			job.Host, job.Port = live.Host, live.Port
			n.enqueue(job)
			return
		}
		n.runQueued(live, job)
	}
}

func (n *Node) runQueued(peer Peer, job queuedSend) {
	if job.Text != "" {
		n.deliverText(peer, job.Text, job.ID, job.SessionID)
		return
	}
	files, err := Collect(job.Paths)
	if err != nil {
		n.updateItem(job.ID, func(it TransferItem) TransferItem {
			it.State = "失败"
			it.Detail = "文件已经不在了"
			it.Speed = 0
			return it
		})
		return
	}
	n.sendFiles(peer, files, &TransferItem{ID: job.ID, SessionID: job.SessionID})
}

func (n *Node) requeueUnreachable(peer Peer, files []LocalFile, itemID, sessionID string) {
	job := queuedSend{
		ID: itemID, SessionID: sessionID, PeerID: peer.ID, PeerName: peer.Name,
		Host: peer.Host, Port: peer.Port, Title: "", LastTry: time.Now(),
	}
	if len(files) > 0 {
		job.Paths = make([]string, len(files))
		var total uint64
		for i, f := range files {
			job.Paths[i] = f.Path
			total += f.Size
		}
		job.Total = total
		job.FileCount = len(files)
		job.Title = files[0].Rel
		if len(files) > 1 {
			job.Title = fmtCount(len(files))
		}
	}
	n.enqueue(job)
	n.updateItem(itemID, func(it TransferItem) TransferItem {
		it.State = "等待对方上线"
		it.Detail = "网络中断，会自动接着传（已传过的部分会跳过）"
		it.Speed = 0
		return it
	})
}
