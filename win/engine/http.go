package engine

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"huchuan/protocol"
)

const phoneHTML = `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<meta http-equiv="Cache-Control" content="no-store"/>
<title>互传</title>
<style>
  :root { --bg:#f6f1ea; --ink:#1a1814; --accent:#3d7a6a; --hot:#c4502a; --card:#fffdf8; }
  * { box-sizing:border-box; }
  body { margin:0; font-family:-apple-system,BlinkMacSystemFont,"PingFang SC","Microsoft YaHei",sans-serif; background:var(--bg); color:var(--ink); }
  header { padding:28px 20px 8px; text-align:center; }
  h1 { font-size:22px; margin:0; letter-spacing:.12em; }
  p { color:#6b645b; }
  .card { margin:16px; background:var(--card); border-radius:18px; padding:22px; box-shadow:0 10px 30px rgba(80,50,20,.06); }
  .drop { border:2px dashed #d7cfc4; border-radius:14px; padding:36px 16px; text-align:center; }
  .drop.over { border-color:var(--accent); background:#eef6f3; }
  button, label.btn, a.btn { background:var(--hot); color:white; border:0; border-radius:999px; padding:12px 22px; font-size:16px; text-decoration:none; display:inline-block; }
  input { display:none; }
  .row { margin-top:14px; font-size:14px; }
  .bar { height:8px; background:#efe8de; border-radius:99px; overflow:hidden; margin-top:8px; }
  .bar>i { display:block; height:100%; width:0; background:var(--accent); }
  .hint { text-align:center; font-size:13px; margin-top:14px; }
  a.site { color:#6b645b; text-decoration:none; }
  a.site:hover { color:var(--accent); text-decoration:underline; }
  img.preview { display:block; max-width:100%; margin:12px auto 0; border-radius:12px; background:#fff; -webkit-touch-callout:default; -webkit-user-select:none; user-select:none; }
  video.preview, audio.preview { display:block; width:100%; max-width:360px; margin:12px auto 0; border-radius:12px; background:#111; }
</style>
</head>
<body>
<header>
  <h1>互 传</h1>
  <p id="hello">正在连到电脑…</p>
  <p class="hint"><a class="site" href="https://www.ak129.cn/" target="_blank" rel="noopener">喜相逢科技 · www.ak129.cn</a></p>
</header>
<div class="card">
  <div class="drop" id="drop">发给这台电脑，扫了同一个码的另一部手机也能收到</div>
  <p style="text-align:center;margin-top:18px">
    <label class="btn">选择文件<input id="pick" type="file" multiple></label>
    <label class="btn" style="background:#387866;margin-left:8px">选择文件夹<input id="pickdir" type="file" webkitdirectory multiple></label>
  </p>
  <p class="hint">两部手机互传：都连同一 Wi-Fi，都打开这个网页，一部发出去，另一部点「保存到手机」。电脑上也会留一份。</p>
  <div id="list"></div>
</div>
<div class="card">
  <div class="drop" style="border-style:solid;padding:20px 16px">电脑或另一部手机发给你的文件会出现在这里</div>
  <div id="inbox"></div>
</div>
<script>
async function info(){
  try{
    const r = await fetch('/api/info');
    const j = await r.json();
    document.getElementById('hello').textContent = '发给「' + j.name + '」，另一部手机也能收到';
    document.title = '互传到 ' + j.name;
  }catch(e){}
}
info();
let phoneId = localStorage.getItem('huchuanPhone') || '';
if(!phoneId){
  phoneId = 'p' + Math.random().toString(36).slice(2) + Date.now().toString(36);
  localStorage.setItem('huchuanPhone', phoneId);
}
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
  setRow(row, 0, '正在准备…');
  prepare(file).then(body => postFile(file, name, body, row)).catch(() => {
    setRow(row, 0, '读不出这个文件');
  });
}
function prepare(file){
  const max = 80 * 1024 * 1024;
  if(file && file.size > max){
    return Promise.resolve(file);
  }
  const toBlob = buf => new Blob([buf], {type: file.type || 'application/octet-stream'});
  if(file && file.arrayBuffer){
    return file.arrayBuffer().then(toBlob);
  }
  return new Promise((resolve, reject) => {
    const r = new FileReader();
    r.onload = () => resolve(toBlob(r.result));
    r.onerror = () => reject(r.error);
    r.readAsArrayBuffer(file);
  });
}
function postFile(file, name, body, row){
  const xhr = new XMLHttpRequest();
  xhr.open('POST','/upload?name=' + encodeURIComponent(name) + '&from=' + encodeURIComponent(phoneId));
  xhr.setRequestHeader('Content-Type', (body && body.type) || file.type || 'application/octet-stream');
  xhr.timeout = 20 * 60 * 1000;
  let sent = false;
  let settled = false;
  function finish(text, pct){
    if(settled) return;
    settled = true;
    setRow(row, pct, text);
  }
  xhr.upload.onprogress = e => {
    if(e.lengthComputable && e.total > 0){
      const p = Math.min(99, Math.round(e.loaded / e.total * 100));
      setRow(row, p, p + '%');
    } else {
      setRow(row, null, '正在发送…');
    }
  };
  xhr.upload.onload = () => {
    sent = true;
    setRow(row, 99, '电脑正在保存…');
    setTimeout(() => {
      if(!settled) finish(xhr.status===200 ? '已发出，另一部手机可保存' : '已发到电脑，请在电脑上看', 100);
    }, 8000);
  };
  xhr.onload = () => finish(xhr.status===200 ? '已发出，另一部手机可保存' : '电脑没收下', 100);
  xhr.onloadend = () => {
    if(xhr.status===200) finish('已发出，另一部手机可保存', 100);
  };
  xhr.onerror = () => finish(sent ? '已发到电脑，请在电脑上看' : '网络中断，请再试一次', sent ? 100 : 0);
  xhr.ontimeout = () => finish('等太久了，请再试一次', 0);
  xhr.send(body);
}
document.getElementById('pick').onchange = e => sendFiles(e.target.files);
document.getElementById('pickdir').onchange = e => sendFiles(e.target.files);
;['dragenter','dragover'].forEach(ev => drop.addEventListener(ev, e => { e.preventDefault(); drop.classList.add('over'); }));
;['dragleave','drop'].forEach(ev => drop.addEventListener(ev, e => { e.preventDefault(); drop.classList.remove('over'); }));
drop.addEventListener('drop', e => sendFiles(e.dataTransfer.files));
const inbox = document.getElementById('inbox');
const seenMsg = {};
const seenFile = {};
function prettySize(n){
  const u=['B','KB','MB','GB']; let v=Number(n)||0, i=0;
  while(v>=1024 && i<u.length-1){ v/=1024; i++; }
  return i===0 ? Math.round(v)+' '+u[i] : v.toFixed(1)+' '+u[i];
}
function kindOf(name){
  const n = String(name||'').toLowerCase();
  if(n.endsWith('.jpg')||n.endsWith('.jpeg')||n.endsWith('.png')||n.endsWith('.gif')||n.endsWith('.webp')||n.endsWith('.bmp')||n.endsWith('.heic')||n.endsWith('.heif')) return 'image';
  if(n.endsWith('.mp4')||n.endsWith('.mov')||n.endsWith('.webm')||n.endsWith('.m4v')) return 'video';
  if(n.endsWith('.mp3')||n.endsWith('.m4a')||n.endsWith('.wav')||n.endsWith('.aac')) return 'audio';
  if(n.endsWith('.pdf')) return 'pdf';
  return 'file';
}
function fileURL(f, save){
  let u = '/file/' + encodeURIComponent(f.id) + '/' + encodeURIComponent(f.name);
  if(save) u += '?save=1';
  return u;
}
function insertMedia(row, el){
  const box = row.querySelector('p');
  if(box) row.insertBefore(el, box);
  else row.appendChild(el);
}
function showImage(row, f){
  let img = row.querySelector('img.preview');
  if(!img){
    img = document.createElement('img');
    img.className = 'preview';
    img.alt = f.name;
    insertMedia(row, img);
  }
  img.src = fileURL(f);
}
function showPlayer(row, f, tag){
  let el = row.querySelector(tag + '.preview');
  if(!el){
    el = document.createElement(tag);
    el.className = 'preview';
    el.setAttribute('controls','');
    el.setAttribute('playsinline','');
    el.setAttribute('preload','metadata');
    insertMedia(row, el);
  }
  el.src = fileURL(f);
}
function saveLink(f, label, save){
  const a = document.createElement('a');
  a.className = 'btn';
  a.href = fileURL(f, save);
  a.textContent = label;
  if(save) a.setAttribute('download', f.name);
  else { a.target = '_blank'; a.rel = 'noopener'; }
  return a;
}
async function pull(){
  try{
    const r = await fetch('/api/outbox?from=' + encodeURIComponent(phoneId));
    const j = await r.json();
    (j.messages||[]).forEach(m => {
      if(seenMsg[m.id]) return;
      seenMsg[m.id] = true;
      const row = document.createElement('div');
      row.className = 'row';
      row.innerHTML = '<b>电脑说</b><span></span>';
      row.querySelector('span').textContent = m.text;
      inbox.prepend(row);
    });
    (j.files||[]).forEach(f => {
      if(seenFile[f.id]) return;
      seenFile[f.id] = true;
      const row = document.createElement('div');
      row.className = 'row';
      const who = f.phone ? '另一部手机发来的' : '电脑发来的';
      const k = kindOf(f.name);
      row.innerHTML = '<b></b><span></span><p style="text-align:center;margin-top:10px"></p>';
      row.querySelector('b').textContent = f.name + ' · ' + prettySize(f.size);
      const box = row.querySelector('p');
      if(k==='image'){
        row.querySelector('span').textContent = who + '图片。长按图片，选「保存到相册」';
        showImage(row, f);
        box.appendChild(saveLink(f, '打开大图', false));
      } else if(k==='video'){
        row.querySelector('span').textContent = who + '视频。可先播放，再点保存到手机。';
        showPlayer(row, f, 'video');
        box.appendChild(saveLink(f, '保存到手机', true));
      } else if(k==='audio'){
        row.querySelector('span').textContent = who + '音频。可先试听，再点保存到手机。';
        showPlayer(row, f, 'audio');
        box.appendChild(saveLink(f, '保存到手机', true));
      } else {
        row.querySelector('span').textContent = who + '文件。点保存；微信里可长按按钮，选「用浏览器打开」。';
        box.appendChild(saveLink(f, '保存到手机', true));
      }
      inbox.prepend(row);
    });
  }catch(e){}
}
setInterval(pull, 1000);
pull();
</script>
</body></html>`

func (n *Node) startPhoneHTTP() {
	s := n.settingsCopy()
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" && !strings.HasPrefix(r.URL.Path, "/index") {
			http.NotFound(w, r)
			return
		}
		n.notePhoneOnline(requestHost(r))
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store, no-cache, must-revalidate")
		_, _ = w.Write([]byte(phoneHTML))
	})
	mux.HandleFunc("/api/info", func(w http.ResponseWriter, r *http.Request) {
		n.notePhoneOnline(requestHost(r))
		name := n.settingsCopy().DeviceName
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_, _ = w.Write([]byte(fmt.Sprintf(`{"name":%q}`, name)))
	})
	mux.HandleFunc("/api/outbox", n.handleOutbox)
	mux.HandleFunc("/download", n.handleDownload)
	mux.HandleFunc("/file/", n.handleDownload)
	mux.HandleFunc("/upload", n.handleUpload)
	registerBoothMux(mux, n.boothHub())
	srv := &http.Server{
		Addr:              fmt.Sprintf(":%d", HTTPPort(s.Port)),
		Handler:           mux,
		ReadHeaderTimeout: 20 * time.Second,
	}
	n.mu.Lock()
	n.phoneSrv = srv
	n.mu.Unlock()
	go func() { _ = srv.ListenAndServe() }()
}

func (n *Node) handleUpload(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type, X-File-Name")
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "只接受上传", 405)
		return
	}
	n.notePhoneOnline(requestHost(r))
	rawName := r.URL.Query().Get("name")
	if rawName == "" {
		rawName = r.Header.Get("X-File-Name")
	}
	if rawName == "" {
		rawName = "未命名文件"
	}
	safe, ok := protocol.SanitizeRelativePath(rawName)
	if !ok {
		safe = protocol.SanitizeFileName(rawName)
	}
	folder := n.settingsCopy().ReceiveFolder
	_ = os.MkdirAll(folder, 0o755)
	dest := protocol.UniquePath(folder, safe)
	f, err := os.Create(dest)
	if err != nil {
		http.Error(w, "保存失败", 500)
		return
	}
	written, err := copyIdle(w, r.Body, f)
	_ = f.Close()
	if err != nil && written == 0 {
		_ = os.Remove(dest)
		http.Error(w, "保存失败", 500)
		return
	}
	n.NotePhoneFile(filepath.Base(dest), dest, written)
	n.sharePhoneUpload(dest, r.URL.Query().Get("from"))
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write([]byte(`{"ok":true,"isComplete":true}`))
}

func copyIdle(w http.ResponseWriter, src io.Reader, dst io.Writer) (int64, error) {
	rc := http.NewResponseController(w)
	buf := make([]byte, 256*1024)
	var written int64
	first := true
	for {
		wait := 4 * time.Second
		if first {
			wait = 20 * time.Second
		}
		_ = rc.SetReadDeadline(time.Now().Add(wait))
		n, err := src.Read(buf)
		if n > 0 {
			first = false
			nw, werr := dst.Write(buf[:n])
			written += int64(nw)
			if werr != nil {
				return written, werr
			}
		}
		if err == io.EOF {
			return written, nil
		}
		if err != nil {
			if ne, ok := err.(net.Error); ok && ne.Timeout() && written > 0 {
				return written, nil
			}
			return written, err
		}
	}
}

func (n *Node) ServeLocalUI(page string) (string, error) {
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write([]byte(page))
	})
	mux.HandleFunc("/api/state", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, n.Snapshot())
	})
	mux.HandleFunc("/api/select", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			ID string `json:"id"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		n.Select(body.ID)
		writeJSON(w, map[string]any{"ok": true})
	})
	mux.HandleFunc("/api/page", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Page string `json:"page"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		n.SetPage(body.Page)
		writeJSON(w, map[string]any{"ok": true})
	})
	mux.HandleFunc("/api/send-text", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Text string `json:"text"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		n.SendText(body.Text)
		writeJSON(w, map[string]any{"ok": true})
	})
	mux.HandleFunc("/api/send-files", n.handleSendFiles)
	mux.HandleFunc("/api/pick-files", func(w http.ResponseWriter, r *http.Request) {
		if !nativePickerAvailable() {
			writeJSON(w, map[string]any{"ok": true, "native": false})
			return
		}
		n.PickAndSend(0)
		writeJSON(w, map[string]any{"ok": true, "native": true})
	})
	mux.HandleFunc("/api/pick-folder", func(w http.ResponseWriter, r *http.Request) {
		if !nativePickerAvailable() {
			writeJSON(w, map[string]any{"ok": true, "native": false})
			return
		}
		n.PickAndSendFolder(0)
		writeJSON(w, map[string]any{"ok": true, "native": true})
	})
	mux.HandleFunc("/api/accept", func(w http.ResponseWriter, r *http.Request) {
		n.AcceptIncoming()
		writeJSON(w, map[string]any{"ok": true})
	})
	mux.HandleFunc("/api/reject", func(w http.ResponseWriter, r *http.Request) {
		n.RejectIncoming()
		writeJSON(w, map[string]any{"ok": true})
	})
	mux.HandleFunc("/api/dismiss-text", func(w http.ResponseWriter, r *http.Request) {
		n.DismissText()
		writeJSON(w, map[string]any{"ok": true})
	})
	mux.HandleFunc("/api/cancel", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			ID string `json:"id"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		n.Cancel(body.ID)
		writeJSON(w, map[string]any{"ok": true})
	})
	mux.HandleFunc("/api/settings", func(w http.ResponseWriter, r *http.Request) {
		var s Settings
		_ = json.NewDecoder(r.Body).Decode(&s)
		n.UpdateSettings(s)
		writeJSON(w, map[string]any{"ok": true})
	})
	mux.HandleFunc("/api/manual", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Host string `json:"host"`
			Port uint16 `json:"port"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		n.AddManual(body.Host, body.Port)
		writeJSON(w, map[string]any{"ok": true})
	})
	mux.HandleFunc("/api/refresh", func(w http.ResponseWriter, r *http.Request) {
		n.Refresh()
		writeJSON(w, map[string]any{"ok": true})
	})
	mux.HandleFunc("/api/wifi-fill", func(w http.ResponseWriter, r *http.Request) {
		name, err := n.FillStoreWifi()
		if err != nil {
			writeJSON(w, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		writeJSON(w, map[string]any{"ok": true, "ssid": name})
	})
	mux.HandleFunc("/api/firewall", func(w http.ResponseWriter, r *http.Request) {
		openFirewallSettings()
		writeJSON(w, map[string]any{"ok": true})
	})
	mux.HandleFunc("/api/open-recv", func(w http.ResponseWriter, r *http.Request) {
		n.OpenRecv()
		writeJSON(w, map[string]any{"ok": true})
	})
	mux.HandleFunc("/api/open-site", func(w http.ResponseWriter, r *http.Request) {
		OpenOfficialSite()
		writeJSON(w, map[string]any{"ok": true})
	})
	mux.HandleFunc("/api/open-path", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Path string `json:"path"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		n.OpenPath(body.Path)
		writeJSON(w, map[string]any{"ok": true})
	})
	mux.HandleFunc("/api/reveal-path", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Path string `json:"path"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		n.RevealPath(body.Path)
		writeJSON(w, map[string]any{"ok": true})
	})
	mux.HandleFunc("/api/favorite", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			ID string `json:"id"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		n.ToggleFavorite(body.ID)
		writeJSON(w, map[string]any{"ok": true})
	})
	mux.HandleFunc("/api/picking", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			On bool `json:"on"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		n.SetPicking(body.On)
		writeJSON(w, map[string]any{"ok": true})
	})
	mux.HandleFunc("/api/multi-toggle", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			ID string `json:"id"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		n.ToggleMulti(body.ID)
		writeJSON(w, map[string]any{"ok": true})
	})
	mux.HandleFunc("/api/history-clear", func(w http.ResponseWriter, r *http.Request) {
		n.ClearHistory()
		writeJSON(w, map[string]any{"ok": true})
	})
	mux.HandleFunc("/api/booth-open", func(w http.ResponseWriter, r *http.Request) {
		sess := n.OpenBooth()
		if sess == nil {
			n.mu.Lock()
			msg := n.boothErr
			n.mu.Unlock()
			if msg == "" {
				msg = "打不开门店码"
			}
			writeJSON(w, map[string]any{"ok": false, "error": msg})
			return
		}
		writeJSON(w, map[string]any{"ok": true})
	})
	mux.HandleFunc("/api/booth-close", func(w http.ResponseWriter, r *http.Request) {
		n.CloseBooth()
		writeJSON(w, map[string]any{"ok": true})
	})
	mux.HandleFunc("/api/booth-rotate", func(w http.ResponseWriter, r *http.Request) {
		n.RotateBooth()
		writeJSON(w, map[string]any{"ok": true})
	})
	mux.HandleFunc("/api/send-clipboard", func(w http.ResponseWriter, r *http.Request) {
		text := strings.TrimSpace(readClipboard())
		if text == "" {
			writeJSON(w, map[string]any{"ok": false, "error": "剪贴板是空的"})
			return
		}
		n.SendText(text)
		writeJSON(w, map[string]any{"ok": true})
	})
	mux.HandleFunc("/api/quit", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]any{"ok": true})
		go func() {
			time.Sleep(200 * time.Millisecond)
			RequestQuit()
		}()
	})
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return "", err
	}
	addr := "http://" + ln.Addr().String()
	n.mu.Lock()
	n.uiLn = ln
	n.uiAddr = addr
	n.mu.Unlock()
	go func() { _ = http.Serve(ln, mux) }()
	return addr, nil
}

func (n *Node) handleSendFiles(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseMultipartForm(512 << 20); err != nil {
		http.Error(w, "文件读不进来", 400)
		return
	}
	tmp, err := os.MkdirTemp("", "huchuan-send-*")
	if err != nil {
		http.Error(w, "临时目录失败", 500)
		return
	}
	headers := r.MultipartForm.File["files"]
	if len(headers) == 0 {
		http.Error(w, "没有可发送的文件", 400)
		return
	}
	var paths []string
	for _, hdr := range headers {
		name := hdr.Filename
		if name == "" {
			name = "未命名"
		}
		rel, ok := protocol.SanitizeRelativePath(name)
		if !ok {
			rel = protocol.SanitizeFileName(filepath.Base(name))
		}
		dest := filepath.Join(tmp, filepath.FromSlash(rel))
		_ = os.MkdirAll(filepath.Dir(dest), 0o755)
		src, err := hdr.Open()
		if err != nil {
			continue
		}
		out, err := os.Create(dest)
		if err != nil {
			src.Close()
			continue
		}
		_, err = io.Copy(out, src)
		src.Close()
		out.Close()
		if err == nil {
			paths = append(paths, dest)
		}
	}
	if len(paths) == 0 {
		http.Error(w, "没有可发送的文件", 400)
		return
	}
	ids := r.MultipartForm.Value["ids"]
	if len(ids) > 0 {
		n.SendToIDs(ids, paths)
		writeJSON(w, map[string]any{"ok": true})
		return
	}
	peer, ok := n.selectedPeer()
	if !ok {
		http.Error(w, "请先选一台设备", 400)
		return
	}
	n.SendPaths(peer, paths)
	writeJSON(w, map[string]any{"ok": true})
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(v)
}
