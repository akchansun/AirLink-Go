package engine

import (
	"archive/zip"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"huchuan/protocol"
)

type phoneOutFile struct {
	ID        string
	SessionID string
	Name      string
	Path      string
	Size      int64
	TempZip   bool
	FromID    string
}

type phoneOutText struct {
	ID   string
	Text string
}

func (n *Node) ensurePhonePeer() {
	n.ensurePhonePeerHost("")
}

func (n *Node) ensurePhonePeerHost(host string) {
	s := n.settingsCopy()
	n.mu.Lock()
	existing := ""
	for _, p := range n.peers {
		if p.ID == "phone-web" {
			existing = p.Host
			break
		}
	}
	n.mu.Unlock()
	if host == "" || host == "127.0.0.1" || host == "::1" || host == "localhost" {
		if existing != "" && existing != "网页" && existing != "手机" {
			host = existing
		} else if host == "" {
			host = "手机"
		}
	}
	n.upsert(Peer{
		ID: "phone-web", Name: "手机网页", Host: host, Port: s.Port,
		HTTPPort: HTTPPort(s.Port), OS: "手机", Via: "手机网页",
		LastSeen: time.Now(),
	})
}

func requestHost(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil || host == "" {
		host = r.RemoteAddr
	}
	return normalizePhoneIP(host)
}

func normalizePhoneIP(host string) string {
	host = strings.TrimSpace(host)
	if i := strings.IndexByte(host, '%'); i >= 0 {
		host = host[:i]
	}
	host = strings.TrimPrefix(host, "[")
	host = strings.TrimSuffix(host, "]")
	host = strings.TrimPrefix(host, "::ffff:")
	if host == "" {
		return "手机"
	}
	if ip := net.ParseIP(host); ip != nil {
		if v4 := ip.To4(); v4 != nil {
			return v4.String()
		}
		return ip.String()
	}
	return host
}

func (n *Node) notePhoneOnline(host string) {
	host = normalizePhoneIP(host)
	if host != "127.0.0.1" && host != "::1" && host != "localhost" && host != "手机" {
		n.mu.Lock()
		for _, p := range n.peers {
			if p.ID != "phone-web" && normalizePhoneIP(p.Host) == host {
				n.mu.Unlock()
				return
			}
		}
		n.mu.Unlock()
	}
	n.mu.Lock()
	first := !n.phoneLiveLocked()
	page := n.page
	waiting := n.waitingForPhone
	n.mu.Unlock()
	n.ensurePhonePeerHost(host)
	if waiting || page == "welcome" {
		n.mu.Lock()
		n.waitingForPhone = false
		n.selectedID = "phone-web"
		n.page = "chat"
		already := false
		if first {
			for _, m := range n.messages {
				if m.PeerID == "phone-web" && strings.Contains(m.Text, "已连通") {
					already = true
					break
				}
			}
			if !already {
				n.messages = append(n.messages, ChatLine{
					ID: newUUID(), PeerID: "phone-web", PeerName: "手机网页",
					Outgoing: false, Text: "手机已连通，可以发文件或说话了", Time: time.Now().UnixMilli(),
				})
			}
		}
		n.mu.Unlock()
		if first && host != "127.0.0.1" && host != "::1" && host != "localhost" && host != "手机" {
			Alert("手机已连通", "可以给手机发文件了")
		}
	}
	if host != "127.0.0.1" && host != "::1" && host != "localhost" && host != "手机" {
		n.broadcastPhoneClaim(host)
	}
}

func (n *Node) touchPhone(host string) {
	n.mu.Lock()
	found := false
	for _, p := range n.peers {
		if p.ID == "phone-web" {
			found = true
			break
		}
	}
	n.mu.Unlock()
	if !found {
		return
	}
	n.ensurePhonePeerHost(host)
}

func (n *Node) dropPhoneClaimed(ip string) {
	ip = normalizePhoneIP(ip)
	if ip == "" || ip == "手机" {
		return
	}
	n.mu.Lock()
	idx := -1
	host := ""
	for i, p := range n.peers {
		if p.ID == "phone-web" {
			idx = i
			host = p.Host
			break
		}
	}
	if idx < 0 || normalizePhoneIP(host) != ip {
		n.mu.Unlock()
		return
	}
	n.peers = append(n.peers[:idx], n.peers[idx+1:]...)
	if n.selectedID == "phone-web" {
		n.selectedID = ""
		if n.page == "chat" {
			n.page = "welcome"
		}
	}
	n.mu.Unlock()
	n.refreshStatus()
}

func (n *Node) broadcastPhoneClaim(ip string) {
	n.mu.Lock()
	if !n.lastPhoneClaim.IsZero() && time.Since(n.lastPhoneClaim) < 1500*time.Millisecond {
		n.mu.Unlock()
		return
	}
	n.lastPhoneClaim = time.Now()
	n.mu.Unlock()
	s := n.settingsCopy()
	pkt := protocol.DiscoveryPacket{
		V: 1, ID: s.DeviceID, Name: s.DeviceName,
		Port: s.Port, HTTPPort: HTTPPort(s.Port), OS: OSName(),
		Reply: true, PhoneClaim: ip,
	}
	data, _ := json.Marshal(pkt)
	udp := UDPPort(s.Port)
	n.sendDiscover(data, "255.255.255.255", udp)
	n.sendDiscover(data, multicastGroup, udp)
	n.mu.Lock()
	ips := append([]string(nil), n.localIPs...)
	n.mu.Unlock()
	for _, local := range ips {
		if b := guessBroadcast(local); b != "" {
			n.sendDiscover(data, b, udp)
		}
	}
}

func (n *Node) sendToPhone(paths []string) {
	n.ensurePhonePeer()
	files, err := Collect(paths)
	if err != nil {
		n.fail("手机网页", err.Error())
		return
	}
	sessionID := newUUID()
	itemID := newUUID()
	outPath := files[0].Path
	title := filepath.Base(files[0].Path)
	size := files[0].Size
	tempZip := false
	if len(files) > 1 {
		zp, zsize, err := zipLocalFiles(files)
		if err != nil {
			n.fail("手机网页", err.Error())
			return
		}
		outPath = zp
		title = "互传文件.zip"
		size = zsize
		tempZip = true
	}
	n.mu.Lock()
	n.outFiles = append(n.outFiles, phoneOutFile{
		ID: newUUID(), SessionID: sessionID, Name: title,
		Path: outPath, Size: int64(size), TempZip: tempZip,
	})
	n.mu.Unlock()
	display := title
	if len(files) > 1 {
		display = fmt.Sprintf("%d 个文件", len(files))
	}
	n.addItem(TransferItem{
		ID: itemID, SessionID: sessionID, Direction: "send",
		PeerName: "手机网页", PeerID: "phone-web", Title: display,
		Total: size, State: "等手机来收", Detail: "手机打开网页后点「保存到手机」",
		FileCount: len(files), Time: time.Now(), LocalPath: outPath,
	})
}

func zipLocalFiles(files []LocalFile) (string, uint64, error) {
	tmp := filepath.Join(os.TempDir(), "huchuan-out-"+newUUID()+".zip")
	f, err := os.Create(tmp)
	if err != nil {
		return "", 0, err
	}
	zw := zip.NewWriter(f)
	for _, file := range files {
		w, err := zw.Create(file.Rel)
		if err != nil {
			_ = zw.Close()
			_ = f.Close()
			_ = os.Remove(tmp)
			return "", 0, err
		}
		src, err := os.Open(file.Path)
		if err != nil {
			continue
		}
		_, err = io.Copy(w, src)
		src.Close()
		if err != nil {
			_ = zw.Close()
			_ = f.Close()
			_ = os.Remove(tmp)
			return "", 0, err
		}
	}
	if err := zw.Close(); err != nil {
		_ = f.Close()
		_ = os.Remove(tmp)
		return "", 0, err
	}
	_ = f.Close()
	st, err := os.Stat(tmp)
	if err != nil {
		return tmp, 0, nil
	}
	return tmp, uint64(st.Size()), nil
}

func (n *Node) queuePhoneText(text string) {
	n.mu.Lock()
	n.outTexts = append(n.outTexts, phoneOutText{ID: newUUID(), Text: text})
	if len(n.outTexts) > 50 {
		n.outTexts = n.outTexts[len(n.outTexts)-50:]
	}
	n.mu.Unlock()
}

func (n *Node) outboxJSON(from string) map[string]any {
	n.mu.Lock()
	defer n.mu.Unlock()
	files := make([]map[string]any, 0, len(n.outFiles))
	for _, f := range n.outFiles {
		if from != "" && f.FromID == from {
			continue
		}
		files = append(files, map[string]any{"id": f.ID, "name": f.Name, "size": f.Size, "phone": f.FromID != ""})
	}
	msgs := make([]map[string]any, 0, len(n.outTexts))
	for _, t := range n.outTexts {
		msgs = append(msgs, map[string]any{"id": t.ID, "text": t.Text})
	}
	return map[string]any{"files": files, "messages": msgs}
}

func (n *Node) findOutFile(id string) (phoneOutFile, bool) {
	n.mu.Lock()
	defer n.mu.Unlock()
	for _, f := range n.outFiles {
		if f.ID == id {
			return f, true
		}
	}
	return phoneOutFile{}, false
}

func (n *Node) sharePhoneUpload(dest, from string) {
	st, err := os.Stat(dest)
	var size int64
	if err == nil {
		size = st.Size()
	}
	n.mu.Lock()
	n.outFiles = append(n.outFiles, phoneOutFile{
		ID: newUUID(), Name: filepath.Base(dest), Path: dest, Size: size, FromID: from,
	})
	var dropped []phoneOutFile
	if len(n.outFiles) > 40 {
		dropped = append([]phoneOutFile(nil), n.outFiles[:len(n.outFiles)-40]...)
		n.outFiles = n.outFiles[len(n.outFiles)-40:]
	}
	n.mu.Unlock()
	for _, f := range dropped {
		if f.TempZip {
			_ = os.Remove(f.Path)
		}
	}
}

func (n *Node) markPhoneDownloaded(id string) {
	n.mu.Lock()
	var item phoneOutFile
	found := false
	for _, f := range n.outFiles {
		if f.ID == id {
			item = f
			found = true
			break
		}
	}
	if !found || item.FromID != "" {
		n.mu.Unlock()
		return
	}
	already := false
	for i := range n.items {
		if n.items[i].SessionID == item.SessionID {
			if n.items[i].State == "已完成" {
				already = true
				break
			}
			n.items[i].State = "已完成"
			n.items[i].Detail = "手机已保存"
			n.items[i].Done = n.items[i].Total
			n.items[i].Speed = 0
			break
		}
	}
	n.mu.Unlock()
	if already {
		return
	}
	Alert("已发到手机", item.Name)
}

func (n *Node) cancelPhoneSession(sessionID string) {
	n.mu.Lock()
	var removed []phoneOutFile
	keep := n.outFiles[:0]
	for _, f := range n.outFiles {
		if f.SessionID == sessionID {
			removed = append(removed, f)
			continue
		}
		keep = append(keep, f)
	}
	n.outFiles = keep
	n.mu.Unlock()
	for _, f := range removed {
		if f.TempZip {
			_ = os.Remove(f.Path)
		}
	}
}

func (n *Node) handleOutbox(w http.ResponseWriter, r *http.Request) {
	n.touchPhone(requestHost(r))
	writeJSON(w, n.outboxJSON(r.URL.Query().Get("from")))
}

func mimeOfName(name string) string {
	switch strings.ToLower(filepath.Ext(name)) {
	case ".jpg", ".jpeg":
		return "image/jpeg"
	case ".png":
		return "image/png"
	case ".gif":
		return "image/gif"
	case ".webp":
		return "image/webp"
	case ".heic", ".heif":
		return "image/heic"
	case ".bmp":
		return "image/bmp"
	case ".mp4", ".m4v":
		return "video/mp4"
	case ".mov":
		return "video/quicktime"
	case ".webm":
		return "video/webm"
	case ".mp3":
		return "audio/mpeg"
	case ".m4a":
		return "audio/mp4"
	case ".wav":
		return "audio/wav"
	case ".aac":
		return "audio/aac"
	case ".pdf":
		return "application/pdf"
	case ".zip":
		return "application/zip"
	case ".rar":
		return "application/vnd.rar"
	case ".7z":
		return "application/x-7z-compressed"
	case ".doc":
		return "application/msword"
	case ".docx":
		return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
	case ".xls":
		return "application/vnd.ms-excel"
	case ".xlsx":
		return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
	case ".ppt":
		return "application/vnd.ms-powerpoint"
	case ".pptx":
		return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
	case ".txt", ".csv":
		return "text/plain; charset=utf-8"
	default:
		return "application/octet-stream"
	}
}

func downloadID(r *http.Request) string {
	if id := r.URL.Query().Get("id"); id != "" {
		return id
	}
	p := strings.TrimPrefix(r.URL.Path, "/file/")
	if i := strings.IndexByte(p, '/'); i >= 0 {
		p = p[:i]
	}
	p, err := url.PathUnescape(p)
	if err != nil {
		return p
	}
	return p
}

func (n *Node) handleDownload(w http.ResponseWriter, r *http.Request) {
	id := downloadID(r)
	item, ok := n.findOutFile(id)
	if !ok {
		http.Error(w, "找不到文件", 404)
		return
	}
	st, err := os.Stat(item.Path)
	if err != nil {
		http.Error(w, "找不到文件", 404)
		return
	}
	mime := mimeOfName(item.Name)
	save := r.URL.Query().Get("save") == "1"
	inline := !save && (strings.HasPrefix(mime, "image/") || strings.HasPrefix(mime, "video/") || strings.HasPrefix(mime, "audio/") || mime == "application/pdf")
	disp := "attachment"
	if inline {
		disp = "inline"
	}
	w.Header().Set("Content-Type", mime)
	w.Header().Set("Content-Disposition", disp+"; filename*=UTF-8''"+url.PathEscape(item.Name))
	w.Header().Set("Cache-Control", "no-store, no-cache, must-revalidate")
	w.Header().Set("Pragma", "no-cache")
	w.Header().Set("Content-Length", strconv.FormatInt(st.Size(), 10))
	if r.Method == http.MethodHead {
		w.WriteHeader(http.StatusOK)
		return
	}
	f, err := os.Open(item.Path)
	if err != nil {
		http.Error(w, "找不到文件", 404)
		return
	}
	defer f.Close()
	_, _ = io.Copy(w, f)
	n.markPhoneDownloaded(id)
}
