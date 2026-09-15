package engine

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"huchuan/protocol"
)

const (
	boothTTL      = 2 * time.Hour
	boothMaxFiles = 200
	boothMaxBytes = 2 * 1024 * 1024 * 1024
	boothMaxOne   = 400 * 1024 * 1024
)

type BoothFile struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Size int64  `json:"size"`
	Path string `json:"path"`
	At   int64  `json:"at"`
}

type BoothSession struct {
	ID      string      `json:"id"`
	PIN     string      `json:"pin"`
	Token   string      `json:"token"`
	Name    string      `json:"name"`
	URL     string      `json:"url"`
	Remote  bool        `json:"remote"`
	Expires int64       `json:"expires"`
	Closed  bool        `json:"closed"`
	Files   []BoothFile `json:"files"`
}

type boothInternal struct {
	BoothSession
	bytes int64
	dir   string
	lan   string
	wan   string
}

type BoothHub struct {
	mu     sync.Mutex
	items  map[string]*boothInternal
	recv   string
	onFile func(path string)
}

func newBoothHub(recv string, onFile func(path string)) *BoothHub {
	return &BoothHub{items: map[string]*boothInternal{}, recv: recv, onFile: onFile}
}

func (h *BoothHub) open(name, publicBase string) *BoothSession {
	h.sweep()
	id := shortRand(5)
	pin := fmt.Sprintf("%04d", randInt(10000))
	token := shortRand(12)
	dir := ""
	if h.recv != "" {
		dir = filepath.Join(os.TempDir(), "huchuan-booth", id)
		_ = os.MkdirAll(dir, 0o755)
	}
	base := strings.TrimRight(publicBase, "/")
	url := fmt.Sprintf("%s/b/%s?p=%s", base, id, pin)
	sess := &boothInternal{
		BoothSession: BoothSession{
			ID: id, PIN: pin, Token: token, Name: name, URL: url,
			Expires: time.Now().Add(boothTTL).Unix(),
		},
		dir: dir,
	}
	h.mu.Lock()
	h.items[id] = sess
	out := sess.BoothSession
	h.mu.Unlock()
	return &out
}

func (h *BoothHub) close(id, token string) {
	h.mu.Lock()
	sess := h.items[id]
	if sess == nil || (token != "" && sess.Token != token) {
		h.mu.Unlock()
		return
	}
	sess.Closed = true
	dir := sess.dir
	delete(h.items, id)
	h.mu.Unlock()
	if dir != "" {
		_ = os.RemoveAll(dir)
	}
}

func (h *BoothHub) adopt(s BoothSession) *BoothSession {
	h.sweep()
	if s.ID == "" {
		return nil
	}
	dir := ""
	if h.recv != "" {
		dir = filepath.Join(os.TempDir(), "huchuan-booth", s.ID)
		_ = os.MkdirAll(dir, 0o755)
	}
	sess := &boothInternal{BoothSession: s, dir: dir}
	h.mu.Lock()
	h.items[s.ID] = sess
	out := sess.BoothSession
	h.mu.Unlock()
	return &out
}

func (h *BoothHub) announce(id, token, lan, wan string) error {
	sess := h.get(id)
	if sess == nil || sess.Closed || (token != "" && sess.Token != token) {
		return errMsg("这次投递已经结束")
	}
	h.mu.Lock()
	if cl := cleanBoothBase(lan); cl != "" || strings.TrimSpace(lan) == "" {
		sess.lan = cl
	}
	if cw := cleanBoothBase(wan); cw != "" || strings.TrimSpace(wan) == "" {
		sess.wan = cw
	}
	h.mu.Unlock()
	return nil
}

func (h *BoothHub) publicInfo(id, pin string) map[string]any {
	sess := h.get(id)
	if sess == nil || sess.Closed {
		return map[string]any{"ok": false, "error": "这个码已经作废"}
	}
	if pin != "" && pin != sess.PIN {
		return map[string]any{"ok": false, "error": "这个码已经作废"}
	}
	if time.Now().Unix() > sess.Expires {
		return map[string]any{"ok": false, "error": "这个码已经作废"}
	}
	h.mu.Lock()
	name, lan, wan, p := sess.Name, sess.lan, sess.wan, sess.PIN
	h.mu.Unlock()
	return map[string]any{
		"ok":   true,
		"name": name,
		"lan":  boothPage(lan, id, p),
		"wan":  boothPage(wan, id, p),
	}
}

func (h *BoothHub) get(id string) *boothInternal {
	h.sweep()
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.items[id]
}

func (h *BoothHub) snapshot(id, token string) *BoothSession {
	sess := h.get(id)
	if sess == nil {
		return nil
	}
	if token != "" && sess.Token != token {
		return nil
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	cp := sess.BoothSession
	cp.Files = append([]BoothFile(nil), sess.Files...)
	return &cp
}

func (h *BoothHub) saveUpload(id, pin, name string, r io.Reader, size int64) (*BoothFile, error) {
	sess := h.get(id)
	if sess == nil || sess.Closed {
		return nil, errMsg("这次投递已经结束，请让店员换一个码")
	}
	if pin != "" && pin != sess.PIN {
		return nil, errMsg("口令不对")
	}
	if time.Now().Unix() > sess.Expires {
		return nil, errMsg("这个码过期了，请让店员换一个")
	}
	safe, ok := protocol.SanitizeRelativePath(name)
	if !ok {
		safe = protocol.SanitizeFileName(name)
	}
	if safe == "" {
		safe = "未命名"
	}
	if size > boothMaxOne {
		return nil, errMsg("单个文件太大")
	}
	h.mu.Lock()
	if len(sess.Files) >= boothMaxFiles {
		h.mu.Unlock()
		return nil, errMsg("这次收得太多了，请让店员换一个码")
	}
	if size > 0 && sess.bytes+size > boothMaxBytes {
		h.mu.Unlock()
		return nil, errMsg("这次体积太大了，请让店员换一个码")
	}
	h.mu.Unlock()

	if h.recv == "" {
		return nil, errMsg("文件请直接发到店里电脑。请关掉流量、连店里 Wi-Fi 再扫。")
	}

	destDir := h.recv
	_ = os.MkdirAll(destDir, 0o755)
	dest := protocol.UniquePath(destDir, safe)
	f, err := os.Create(dest)
	if err != nil {
		return nil, err
	}
	n, err := io.Copy(f, io.LimitReader(r, boothMaxOne+1))
	_ = f.Close()
	if err != nil {
		_ = os.Remove(dest)
		return nil, err
	}
	if n > boothMaxOne {
		_ = os.Remove(dest)
		return nil, errMsg("单个文件太大")
	}
	item := BoothFile{
		ID: shortRand(6), Name: filepath.Base(dest), Size: n, Path: dest, At: time.Now().Unix(),
	}
	h.mu.Lock()
	sess.Files = append(sess.Files, item)
	sess.bytes += n
	h.mu.Unlock()
	if h.recv != "" && h.onFile != nil {
		h.onFile(dest)
	}
	return &item, nil
}

func cleanBoothBase(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" || u.User != nil {
		return ""
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return ""
	}
	return u.Scheme + "://" + u.Host
}

func boothPage(base, id, pin string) string {
	base = cleanBoothBase(base)
	if base == "" || id == "" {
		return ""
	}
	return base + "/b/" + url.PathEscape(id) + "?p=" + url.QueryEscape(pin)
}

func (h *BoothHub) file(id, fid, token string) *BoothFile {
	sess := h.snapshot(id, token)
	if sess == nil {
		return nil
	}
	for i := range sess.Files {
		if sess.Files[i].ID == fid {
			return &sess.Files[i]
		}
	}
	return nil
}

func (h *BoothHub) sweep() {
	now := time.Now().Unix()
	var dirs []string
	h.mu.Lock()
	for id, sess := range h.items {
		if sess.Closed || now > sess.Expires {
			if sess.dir != "" {
				dirs = append(dirs, sess.dir)
			}
			delete(h.items, id)
		}
	}
	h.mu.Unlock()
	for _, d := range dirs {
		_ = os.RemoveAll(d)
	}
}

func shortRand(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return fmt.Sprintf("%d", time.Now().UnixNano())
	}
	return hex.EncodeToString(b)
}

func randInt(mod int) int {
	var b [2]byte
	if _, err := rand.Read(b[:]); err != nil {
		return int(time.Now().UnixNano() % int64(mod))
	}
	n := int(b[0])<<8 | int(b[1])
	if mod <= 0 {
		return n
	}
	return n % mod
}

const boothHTML = `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>互传门店码</title>
<style>
  :root { --bg:#f6f1ea; --ink:#1a1814; --accent:#3d7a6a; --hot:#c4502a; --card:#fffdf8; }
  * { box-sizing:border-box; }
  body { margin:0; font-family:-apple-system,BlinkMacSystemFont,"PingFang SC","Microsoft YaHei",sans-serif; background:var(--bg); color:var(--ink); }
  header { padding:28px 20px 8px; text-align:center; }
  h1 { font-size:22px; margin:0; letter-spacing:.12em; }
  p { color:#6b645b; }
  .card { margin:16px; background:var(--card); border-radius:18px; padding:22px; }
  .drop { border:2px dashed #d7cfc4; border-radius:14px; padding:36px 16px; text-align:center; }
  .drop.over { border-color:var(--accent); background:#eef6f3; }
  button, label.btn { background:var(--hot); color:white; border:0; border-radius:999px; padding:12px 22px; font-size:16px; }
  input { display:none; }
  .row { margin-top:14px; font-size:14px; }
  .bar { height:8px; background:#efe8de; border-radius:99px; overflow:hidden; margin-top:8px; }
  .bar>i { display:block; height:100%; width:0; background:var(--accent); }
  .hint { text-align:center; font-size:13px; margin-top:14px; }
</style>
</head>
<body>
<header>
  <h1>互 传</h1>
  <p id="hello">正在打开门店码…</p>
</header>
<div class="card">
  <div class="drop" id="drop">把要打印或拷贝的文件发到店里电脑</div>
  <p style="text-align:center;margin-top:18px">
    <label class="btn">选择文件<input id="pick" type="file" multiple></label>
    <label class="btn" style="background:#387866;margin-left:8px">选择文件夹<input id="pickdir" type="file" webkitdirectory multiple></label>
  </p>
  <p class="hint">不用加微信。发完可以关掉这个页面。</p>
  <div id="list"></div>
</div>
<script>
const parts = location.pathname.split('/').filter(Boolean);
const sid = parts[1] || '';
const pin = new URLSearchParams(location.search).get('p') || '';
const hello = document.getElementById('hello');
fetch('/api/booth/' + encodeURIComponent(sid) + '/info?p=' + encodeURIComponent(pin)).then(r=>r.json()).then(j=>{
  if(!j || !j.ok){ hello.textContent = j && j.error ? j.error : '这个码已经作废'; return; }
  hello.textContent = '发到「' + (j.name||'店里电脑') + '」';
  document.title = '传到 ' + (j.name||'互传');
}).catch(()=>{ hello.textContent = '连不上店里电脑'; });
const list = document.getElementById('list');
const drop = document.getElementById('drop');
function sendFiles(files){ [...files].forEach(file => upload(file)); }
function setRow(row, pct, text){
  const bar = row.querySelector('i');
  const tip = row.querySelector('span');
  if(pct !== null) bar.style.width = pct + '%';
  tip.textContent = text;
}
function upload(file){
  const name = file.webkitRelativePath || file.name;
  const row = document.createElement('div');
  row.className = 'row';
  row.innerHTML = '<b></b><div class="bar"><i></i></div><span></span>';
  row.querySelector('b').textContent = name;
  list.prepend(row);
  setRow(row, 0, '正在发送…');
  const xhr = new XMLHttpRequest();
  xhr.open('POST', '/b/' + encodeURIComponent(sid) + '/upload?name=' + encodeURIComponent(name) + '&p=' + encodeURIComponent(pin));
  xhr.setRequestHeader('Content-Type', file.type || 'application/octet-stream');
  xhr.timeout = 20 * 60 * 1000;
  xhr.upload.onprogress = e => {
    if(e.lengthComputable && e.total>0){
      const p = Math.min(99, Math.round(e.loaded/e.total*100));
      setRow(row, p, p + '%');
    }
  };
  xhr.onload = () => {
    if(xhr.status===200){ setRow(row, 100, '已送到店里电脑'); return; }
    setRow(row, 0, (xhr.responseText||'').trim() || '没送成，请再试一次');
  };
  xhr.onerror = () => setRow(row, 0, '网络中断，请再试一次');
  xhr.ontimeout = () => setRow(row, 0, '等太久了，请再试一次');
  xhr.send(file);
}
document.getElementById('pick').onchange = e => sendFiles(e.target.files);
document.getElementById('pickdir').onchange = e => sendFiles(e.target.files);
;['dragenter','dragover'].forEach(ev => drop.addEventListener(ev, e => { e.preventDefault(); drop.classList.add('over'); }));
;['dragleave','drop'].forEach(ev => drop.addEventListener(ev, e => { e.preventDefault(); drop.classList.remove('over'); }));
drop.addEventListener('drop', e => sendFiles(e.dataTransfer.files));
</script>
</body></html>`

const boothGuideHTML = `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>互传门店码</title>
<style>
  :root { --bg:#f6f1ea; --ink:#1a1814; --hot:#c4502a; --card:#fffdf8; }
  * { box-sizing:border-box; }
  body { margin:0; font-family:-apple-system,BlinkMacSystemFont,"PingFang SC","Microsoft YaHei",sans-serif; background:var(--bg); color:var(--ink); }
  header { padding:28px 20px 8px; text-align:center; }
  h1 { font-size:22px; margin:0; letter-spacing:.12em; }
  p { color:#6b645b; }
  .card { margin:16px; background:var(--card); border-radius:18px; padding:22px; text-align:center; }
  a.btn { display:inline-block; background:var(--hot); color:#fff; text-decoration:none; border-radius:999px; padding:12px 22px; font-size:16px; }
  a.sub { display:inline-block; margin-top:16px; color:#3d7a6a; }
</style>
</head>
<body>
<header>
  <h1>互 传</h1>
  <p id="hello">正在找到店里电脑…</p>
</header>
<div class="card">
  <p id="tip">文件会直接发到店里电脑，不经过中转。</p>
  <p><a class="btn" id="go" style="display:none">发文件到店里</a></p>
  <p><a class="sub" id="lan" style="display:none">我已连店里 Wi-Fi</a></p>
</div>
<script>
const parts = location.pathname.split('/').filter(Boolean);
const sid = parts[1] || '';
const pin = new URLSearchParams(location.search).get('p') || '';
const hello = document.getElementById('hello');
const tip = document.getElementById('tip');
const go = document.getElementById('go');
const lanBtn = document.getElementById('lan');
fetch('/api/booth/' + encodeURIComponent(sid) + '/info?p=' + encodeURIComponent(pin)).then(r=>r.json()).then(j=>{
  if(!j || !j.ok){ hello.textContent = j && j.error ? j.error : '这个码已经作废'; tip.textContent = '请让店员重新亮一个码。'; return; }
  hello.textContent = '发到「' + (j.name||'店里电脑') + '」';
  document.title = '传到 ' + (j.name||'互传');
  if(j.wan){
    go.href = j.wan;
    go.style.display = '';
    tip.textContent = '正在转到店里电脑。若打不开，请关掉流量、连店里 Wi-Fi，再点「我已连店里 Wi-Fi」。';
    if(j.lan && j.lan !== j.wan){ lanBtn.href = j.lan; lanBtn.style.display = ''; }
    location.replace(j.wan);
    return;
  }
  if(j.lan){
    go.href = j.lan;
    go.style.display = '';
    tip.textContent = '请关掉手机流量，连上店里 Wi-Fi，再点下面按钮。';
    return;
  }
  tip.textContent = '请让店员亮着门店码，或关掉流量连店里 Wi-Fi 再扫。';
}).catch(()=>{ hello.textContent = '连不上店里电脑'; tip.textContent = '请让店员亮着门店码。'; });
</script>
</body></html>`

func boothBaseURL(r *http.Request) string {
	scheme := "http"
	if r.TLS != nil || strings.EqualFold(r.Header.Get("X-Forwarded-Proto"), "https") {
		scheme = "https"
	}
	host := r.Header.Get("X-Forwarded-Host")
	if host == "" {
		host = r.Host
	}
	return scheme + "://" + host
}

func registerBoothMux(mux *http.ServeMux, hub *BoothHub) {
	mux.HandleFunc("/b/", func(w http.ResponseWriter, r *http.Request) {
		cors(w)
		if r.Method == http.MethodOptions {
			w.WriteHeader(204)
			return
		}
		rest := strings.TrimPrefix(r.URL.Path, "/b/")
		parts := strings.Split(strings.Trim(rest, "/"), "/")
		if len(parts) == 0 || parts[0] == "" {
			http.NotFound(w, r)
			return
		}
		id := parts[0]
		if len(parts) >= 2 && parts[1] == "upload" && r.Method == http.MethodPost {
			if hub.recv == "" {
				r.Body = http.MaxBytesReader(w, r.Body, 2048)
				w.Header().Set("Connection", "close")
				http.Error(w, "文件请直接发到店里电脑。请关掉流量、连店里 Wi-Fi 再扫。", 400)
				return
			}
			name := r.URL.Query().Get("name")
			if name == "" {
				name = r.Header.Get("X-File-Name")
			}
			pin := r.URL.Query().Get("p")
			item, err := hub.saveUpload(id, pin, name, r.Body, r.ContentLength)
			if err != nil {
				http.Error(w, err.Error(), 400)
				return
			}
			writeJSON(w, map[string]any{"ok": true, "id": item.ID})
			return
		}
		if r.Method != http.MethodGet {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		page := boothHTML
		if hub.recv == "" {
			page = boothGuideHTML
		}
		_, _ = w.Write([]byte(page))
	})
	mux.HandleFunc("/api/booth/open", func(w http.ResponseWriter, r *http.Request) {
		cors(w)
		if r.Method == http.MethodOptions {
			w.WriteHeader(204)
			return
		}
		if r.Method != http.MethodPost {
			http.Error(w, "method", 405)
			return
		}
		var body struct {
			Name string `json:"name"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		if body.Name == "" {
			body.Name = "店里电脑"
		}
		sess := hub.open(body.Name, boothBaseURL(r))
		writeJSON(w, sess)
	})
	mux.HandleFunc("/api/booth/", func(w http.ResponseWriter, r *http.Request) {
		cors(w)
		if r.Method == http.MethodOptions {
			w.WriteHeader(204)
			return
		}
		rest := strings.TrimPrefix(r.URL.Path, "/api/booth/")
		parts := strings.Split(strings.Trim(rest, "/"), "/")
		if len(parts) < 2 {
			http.NotFound(w, r)
			return
		}
		id := parts[0]
		switch parts[1] {
		case "info":
			writeJSON(w, hub.publicInfo(id, r.URL.Query().Get("p")))
		case "announce":
			if r.Method != http.MethodPost {
				http.Error(w, "method", 405)
				return
			}
			var body struct {
				Token string `json:"token"`
				Lan   string `json:"lan"`
				Wan   string `json:"wan"`
			}
			_ = json.NewDecoder(r.Body).Decode(&body)
			if t := r.URL.Query().Get("token"); t != "" {
				body.Token = t
			}
			if err := hub.announce(id, body.Token, body.Lan, body.Wan); err != nil {
				http.Error(w, err.Error(), 400)
				return
			}
			writeJSON(w, map[string]any{"ok": true})
		case "status":
			token := r.URL.Query().Get("token")
			sess := hub.snapshot(id, token)
			if sess == nil {
				writeJSON(w, map[string]any{"ok": false})
				return
			}
			writeJSON(w, map[string]any{"ok": true, "session": sess})
		case "close":
			token := r.URL.Query().Get("token")
			if token == "" {
				var body struct {
					Token string `json:"token"`
				}
				_ = json.NewDecoder(r.Body).Decode(&body)
				token = body.Token
			}
			hub.close(id, token)
			writeJSON(w, map[string]any{"ok": true})
		case "file":
			if len(parts) < 3 {
				http.NotFound(w, r)
				return
			}
			token := r.URL.Query().Get("token")
			item := hub.file(id, parts[2], token)
			if item == nil {
				http.NotFound(w, r)
				return
			}
			http.ServeFile(w, r, item.Path)
		default:
			http.NotFound(w, r)
		}
	})
}

func cors(w http.ResponseWriter) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type, X-File-Name")
}

func RunStoreRelay(addr string) error {
	if addr == "" {
		addr = ":8088"
	}
	hub := newBoothHub("", nil)
	mux := http.NewServeMux()
	registerBoothMux(mux, hub)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = io.WriteString(w, "互传门店中转已启动。只给顾客指路，文件不经过这台机器。")
	})
	fmt.Println("门店中转已启动：", addr)
	srv := &http.Server{Addr: addr, Handler: mux, ReadHeaderTimeout: 20 * time.Second}
	return srv.ListenAndServe()
}
