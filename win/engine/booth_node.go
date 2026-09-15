package engine

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func (n *Node) boothHub() *BoothHub {
	n.mu.Lock()
	h := n.booth
	n.mu.Unlock()
	if h != nil {
		return h
	}
	s := n.settingsCopy()
	h = newBoothHub(s.ReceiveFolder, func(path string) {
		n.rememberBoothFile(path)
	})
	n.mu.Lock()
	if n.booth == nil {
		n.booth = h
	} else {
		h = n.booth
	}
	n.mu.Unlock()
	return h
}

func (n *Node) CurrentBooth() *BoothSession {
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.boothSess == nil {
		return nil
	}
	cp := *n.boothSess
	cp.Files = append([]BoothFile(nil), n.boothSess.Files...)
	return &cp
}

func (n *Node) OpenBooth() *BoothSession {
	s := n.settingsCopy()
	relay := strings.TrimSpace(s.StoreRelayURL)
	if relay != "" {
		return n.openRelayedBooth(s, relay)
	}
	base := strings.TrimSpace(s.StorePublicURL)
	hint := ""
	if base != "" {
		hint = "按设置里填的外网地址亮码。"
	}
	if base == "" {
		n.refreshIPs()
		n.mu.Lock()
		ip := "127.0.0.1"
		if len(n.localIPs) > 0 {
			ip = n.localIPs[0]
		}
		ips := append([]string(nil), n.localIPs...)
		n.mu.Unlock()
		base = fmt.Sprintf("http://%s:%d", ip, HTTPPort(s.Port))
		hint = "请让顾客关掉流量，连店里 Wi-Fi 再扫。不用改设置。"
		sess := n.boothHub().open(s.DeviceName, strings.TrimRight(base, "/"))
		n.mu.Lock()
		n.boothSess = sess
		n.boothErr = ""
		n.boothHint = hint
		n.mu.Unlock()
		if !s.isSelfTest() {
			go n.tryWanBooth(sess.ID, sess.PIN, HTTPPort(s.Port), ips)
		}
		return sess
	}
	sess := n.boothHub().open(s.DeviceName, strings.TrimRight(base, "/"))
	n.mu.Lock()
	n.boothSess = sess
	n.boothErr = ""
	n.boothHint = hint
	n.mu.Unlock()
	return sess
}

func (n *Node) openRelayedBooth(s Settings, relay string) *BoothSession {
	sess, err := openRemoteBooth(relay, s.DeviceName)
	if err != nil {
		n.mu.Lock()
		n.boothErr = "连不上中转。先让顾客连店里 Wi-Fi 扫，或找人看设置里的高级项。"
		n.boothHint = ""
		n.mu.Unlock()
		return nil
	}
	n.boothHub().adopt(*sess)
	n.mu.Lock()
	n.boothSess = sess
	n.boothErr = ""
	n.boothHint = "码给顾客扫。文件直达本机，不走中转的流量。"
	n.mu.Unlock()
	go n.keepDirectBooth(sess.ID)
	return sess
}

func (n *Node) tryWanBooth(id, pin string, port uint16, ips []string) {
	n.mu.Lock()
	if n.boothSess == nil || n.boothSess.ID != id {
		n.mu.Unlock()
		return
	}
	n.boothHint = "正在试着让顾客用流量也能扫…"
	n.mu.Unlock()
	wan, ok := openHTTPPort(port, ips)
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.boothSess == nil || n.boothSess.ID != id {
		closeHTTPPort()
		return
	}
	if ok && wan != "" {
		n.boothSess.URL = strings.TrimRight(wan, "/") + "/b/" + id + "?p=" + pin
		n.boothHint = "顾客可以用手机流量扫，不用连店里网。若打不开，让他连店里 Wi-Fi。"
		return
	}
	n.boothHint = "请让顾客关掉流量，连店里 Wi-Fi 再扫。不用改设置。"
}

func (n *Node) CloseBooth() {
	n.mu.Lock()
	sess := n.boothSess
	n.boothSess = nil
	n.boothHint = ""
	n.boothErr = ""
	n.mu.Unlock()
	if sess == nil {
		return
	}
	closeHTTPPort()
	n.boothHub().close(sess.ID, sess.Token)
	if sess.Remote {
		_ = closeRemoteBooth(n.settingsCopy().StoreRelayURL, sess)
	}
}

func (n *Node) RotateBooth() *BoothSession {
	n.CloseBooth()
	return n.OpenBooth()
}

func (n *Node) rememberBoothFile(path string) {
	name := filepath.Base(path)
	n.addHistory(name, "门店码", path, "", "recv")
	Alert("门店码收到文件", name)
	st, _ := os.Stat(path)
	sz := int64(0)
	if st != nil {
		sz = st.Size()
	}
	n.mu.Lock()
	if n.boothSess != nil {
		n.boothSess.Files = append(n.boothSess.Files, BoothFile{
			ID: newUUID(), Name: name, Size: sz, Path: path, At: time.Now().Unix(),
		})
	}
	n.mu.Unlock()
}

func openRemoteBooth(base, name string) (*BoothSession, error) {
	base = strings.TrimRight(base, "/")
	body, _ := json.Marshal(map[string]string{"name": name})
	resp, err := http.Post(base+"/api/booth/open", "application/json", strings.NewReader(string(body)))
	if err != nil {
		return nil, errMsg("连不上中转。先让顾客连店里 Wi-Fi 扫，或找人看设置里的高级项。")
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 {
		return nil, errMsg("中转没有收下开门请求")
	}
	var sess BoothSession
	if json.Unmarshal(raw, &sess) != nil || sess.ID == "" {
		return nil, errMsg("中转返回的内容不对")
	}
	sess.Remote = true
	return &sess, nil
}

func closeRemoteBooth(base string, sess *BoothSession) error {
	base = strings.TrimRight(base, "/")
	req, err := http.NewRequest(http.MethodPost, base+"/api/booth/"+sess.ID+"/close?token="+sess.Token, nil)
	if err != nil {
		return err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	resp.Body.Close()
	return nil
}

func announceRemoteBooth(base string, sess *BoothSession, lan, wan string) error {
	base = strings.TrimRight(base, "/")
	body, _ := json.Marshal(map[string]string{"token": sess.Token, "lan": lan, "wan": wan})
	req, err := http.NewRequest(http.MethodPost, base+"/api/booth/"+sess.ID+"/announce", strings.NewReader(string(body)))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	resp.Body.Close()
	if resp.StatusCode != 200 {
		return errMsg("中转没有记下店里地址")
	}
	return nil
}

func (n *Node) keepDirectBooth(id string) {
	s := n.settingsCopy()
	port := HTTPPort(s.Port)
	n.refreshIPs()
	n.mu.Lock()
	ip := "127.0.0.1"
	if len(n.localIPs) > 0 {
		ip = n.localIPs[0]
	}
	ips := append([]string(nil), n.localIPs...)
	n.mu.Unlock()
	lan := fmt.Sprintf("http://%s:%d", ip, port)
	wan := strings.TrimSpace(s.StorePublicURL)
	n.announceDirect(id, lan, wan)
	if wan == "" && !s.isSelfTest() {
		n.mu.Lock()
		if n.boothSess != nil && n.boothSess.ID == id {
			n.boothHint = "正在试着让顾客用流量也能转到本机…"
		}
		n.mu.Unlock()
		found, ok := openHTTPPort(port, ips)
		n.mu.Lock()
		live := n.boothSess != nil && n.boothSess.ID == id
		n.mu.Unlock()
		if !live {
			closeHTTPPort()
			return
		}
		if ok && found != "" {
			wan = found
			n.mu.Lock()
			if n.boothSess != nil && n.boothSess.ID == id {
				n.boothHint = "顾客用流量扫码后会转到本机。若打不开，让他连店里 Wi-Fi。"
			}
			n.mu.Unlock()
			n.announceDirect(id, lan, wan)
		} else {
			n.mu.Lock()
			if n.boothSess != nil && n.boothSess.ID == id {
				n.boothHint = "请让顾客关掉流量，连店里 Wi-Fi 再扫。中转只指路，文件不经过服务器。"
			}
			n.mu.Unlock()
		}
	}
	tick := time.NewTicker(25 * time.Second)
	defer tick.Stop()
	for range tick.C {
		n.mu.Lock()
		live := n.boothSess != nil && n.boothSess.ID == id
		n.mu.Unlock()
		if !live {
			return
		}
		n.announceDirect(id, lan, wan)
	}
}

func (n *Node) announceDirect(id, lan, wan string) {
	n.mu.Lock()
	sess := n.boothSess
	n.mu.Unlock()
	if sess == nil || sess.ID != id || !sess.Remote {
		return
	}
	_ = announceRemoteBooth(n.settingsCopy().StoreRelayURL, sess, lan, wan)
}

func (n *Node) OnlinePeers() []Peer {
	n.mu.Lock()
	defer n.mu.Unlock()
	now := time.Now()
	var out []Peer
	for _, p := range n.peers {
		p.Online = peerOnline(p, now)
		if p.Online && p.ID != "phone-web" {
			out = append(out, p)
		}
	}
	return out
}
