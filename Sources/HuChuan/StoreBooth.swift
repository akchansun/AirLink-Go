import Foundation
import Combine
import AppKit
import HuChuanCore

struct StoreFile: Identifiable, Equatable {
    var id: String
    var name: String
    var size: Int64
    var path: String
    var at: TimeInterval
}

struct StoreSession: Equatable {
    var id: String
    var pin: String
    var token: String
    var name: String
    var url: String
    var remote: Bool
    var expires: TimeInterval
    var files: [StoreFile]
}

final class BoothHub: @unchecked Sendable {
    static let ttl: TimeInterval = 2 * 3600
    static let maxFiles = 200
    static let maxBytes: Int64 = 2 * 1024 * 1024 * 1024
    static let maxOne: Int64 = 400 * 1024 * 1024

    private let lock = NSLock()
    private var items: [String: Live] = [:]
    var receiveFolder: () -> URL = { URL(fileURLWithPath: NSHomeDirectory()) }
    var onSaved: ((URL) -> Void)?

    private struct Live {
        var session: StoreSession
        var bytes: Int64
        var dir: URL
        var closed: Bool
    }

    func open(name: String, publicBase: String) -> StoreSession {
        sweep()
        let id = Self.randHex(5)
        let pin = String(format: "%04d", Int.random(in: 0...9999))
        let token = Self.randHex(12)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("huchuan-booth-\(id)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = Self.trimSlash(publicBase)
        let url = "\(base)/b/\(id)?p=\(pin)"
        let sess = StoreSession(id: id, pin: pin, token: token, name: name, url: url, remote: false, expires: Date().timeIntervalSince1970 + Self.ttl, files: [])
        lock.lock()
        items[id] = Live(session: sess, bytes: 0, dir: dir, closed: false)
        lock.unlock()
        return sess
    }

    func adopt(_ sess: StoreSession) {
        sweep()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("huchuan-booth-\(sess.id)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        lock.lock()
        items[sess.id] = Live(session: sess, bytes: 0, dir: dir, closed: false)
        lock.unlock()
    }

    func close(id: String, token: String) {
        lock.lock()
        guard var live = items[id], token.isEmpty || live.session.token == token else {
            lock.unlock()
            return
        }
        live.closed = true
        let dir = live.dir
        items[id] = nil
        lock.unlock()
        try? FileManager.default.removeItem(at: dir)
    }

    func info(id: String, pin: String) -> String? {
        sweep()
        lock.lock()
        defer { lock.unlock() }
        guard let live = items[id], !live.closed else { return nil }
        if !pin.isEmpty && pin != live.session.pin { return nil }
        if Date().timeIntervalSince1970 > live.session.expires { return nil }
        return live.session.name
    }

    func snapshot(id: String, token: String) -> StoreSession? {
        sweep()
        lock.lock()
        defer { lock.unlock() }
        guard let live = items[id], !live.closed else { return nil }
        if !token.isEmpty && live.session.token != token { return nil }
        return live.session
    }

    func saveUpload(id: String, pin: String, name: String, data: Data) throws -> URL {
        sweep()
        lock.lock()
        guard var live = items[id], !live.closed else {
            lock.unlock()
            throw AppError.message("这次投递已经结束，请让店员换一个码")
        }
        if !pin.isEmpty && pin != live.session.pin {
            lock.unlock()
            throw AppError.message("口令不对")
        }
        if Date().timeIntervalSince1970 > live.session.expires {
            lock.unlock()
            throw AppError.message("这个码过期了，请让店员换一个")
        }
        if live.session.files.count >= Self.maxFiles {
            lock.unlock()
            throw AppError.message("这次收得太多了，请让店员换一个码")
        }
        if live.bytes + Int64(data.count) > Self.maxBytes {
            lock.unlock()
            throw AppError.message("这次体积太大了，请让店员换一个码")
        }
        lock.unlock()
        if data.count > Int(Self.maxOne) {
            throw AppError.message("单个文件太大")
        }
        let safe = PathGuard.sanitizeRelativePath(name) ?? PathGuard.sanitizeFileName(name)
        let folder = receiveFolder()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = PathGuard.uniquePath(in: folder, relative: safe)
        try data.write(to: dest, options: .atomic)
        let file = StoreFile(id: UUID().uuidString, name: dest.lastPathComponent, size: Int64(data.count), path: dest.path, at: Date().timeIntervalSince1970)
        lock.lock()
        live = items[id] ?? live
        live.session.files.append(file)
        live.bytes += Int64(data.count)
        items[id] = live
        lock.unlock()
        onSaved?(dest)
        return dest
    }

    func noteLocalFile(id: String, url: URL) {
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let file = StoreFile(id: UUID().uuidString, name: url.lastPathComponent, size: size, path: url.path, at: Date().timeIntervalSince1970)
        lock.lock()
        if var live = items[id] {
            live.session.files.append(file)
            live.bytes += size
            items[id] = live
        }
        lock.unlock()
    }

    private func sweep() {
        let now = Date().timeIntervalSince1970
        lock.lock()
        for (id, live) in items {
            if live.closed || now > live.session.expires {
                try? FileManager.default.removeItem(at: live.dir)
                items[id] = nil
            }
        }
        lock.unlock()
    }

    static func randHex(_ n: Int) -> String {
        let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return String(raw.prefix(n * 2))
    }

    static func trimSlash(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix("/") { t.removeLast() }
        return t
    }

    static let pageHTML = #"""
<!doctype html>
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
</body></html>
"""#
}

@MainActor
final class StoreBooth: ObservableObject {
    @Published var session: StoreSession?
    @Published var errorText = ""
    @Published var reachHint = ""
    @Published var probing = false
    private var probeToken = UUID()
    let hub: BoothHub
    private var settings: SettingsStore
    private var discovery: DiscoveryService
    private var poll: Task<Void, Never>?
    var onFileSaved: ((URL) -> Void)?

    init(hub: BoothHub, settings: SettingsStore, discovery: DiscoveryService) {
        self.hub = hub
        self.settings = settings
        self.discovery = discovery
        hub.receiveFolder = { settings.receiveFolder }
        hub.onSaved = { [weak self] url in
            DispatchQueue.main.async { self?.onFileSaved?(url) }
        }
    }

    func noteIncoming(_ url: URL) {
        if session?.files.contains(where: { $0.path == url.path || $0.name == url.lastPathComponent }) == true {
            return
        }
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let file = StoreFile(id: UUID().uuidString, name: url.lastPathComponent, size: size, path: url.path, at: Date().timeIntervalSince1970)
        session?.files.append(file)
    }

    func open() {
        errorText = ""
        probing = false
        let relay = settings.storeRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !relay.isEmpty {
            reachHint = "码给顾客扫。文件直达本机，不走中转的流量。"
            Task { await openRemote(relay) }
            return
        }
        let manual = settings.storePublicURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manual.isEmpty {
            session = hub.open(name: settings.deviceName, publicBase: BoothHub.trimSlash(manual))
            reachHint = "按设置里填的外网地址亮码。"
            return
        }
        let ip = discovery.localIPs.first ?? "127.0.0.1"
        let lan = "http://\(ip):\(Ports.http(settings.port))"
        session = hub.open(name: settings.deviceName, publicBase: BoothHub.trimSlash(lan))
        reachHint = "请让顾客关掉流量，连店里 Wi-Fi 再扫。"
        guard shouldProbeWan else { return }
        let token = UUID()
        probeToken = token
        probing = true
        reachHint = "正在试着让顾客用流量也能扫…"
        let port = Ports.http(settings.port)
        let ips = discovery.localIPs
        let sessId = session?.id
        let pin = session?.pin
        Task { @MainActor in
            let wan = await PortOpener.openHTTP(port: port, localIPs: ips)
            guard probeToken == token, session?.id == sessId, let pin, var sess = session else { return }
            probing = false
            if let wan {
                sess.url = "\(BoothHub.trimSlash(wan))/b/\(sess.id)?p=\(pin)"
                session = sess
                reachHint = "顾客可以用手机流量扫，不用连店里网。若打不开，让他连店里 Wi-Fi。"
            } else {
                reachHint = "请让顾客关掉流量，连店里 Wi-Fi 再扫。不用改设置。"
            }
        }
    }

    private var shouldProbeWan: Bool {
        !CommandLine.arguments.contains("--selftest") && settings.deviceName != "自检接收端"
    }

    func close() {
        poll?.cancel()
        poll = nil
        probeToken = UUID()
        probing = false
        PortOpener.closeLast()
        if let sess = session {
            hub.close(id: sess.id, token: sess.token)
            if sess.remote {
                Task { await closeRemote(sess) }
            }
        }
        session = nil
        errorText = ""
        reachHint = ""
    }

    func rotate() {
        close()
        open()
    }

    private func openRemote(_ base: String) async {
        let trimmed = BoothHub.trimSlash(base)
        guard let url = URL(string: trimmed + "/api/booth/open") else {
            errorText = "中转网址不对"
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["name": settings.deviceName])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = obj["id"] as? String, !id.isEmpty else {
                errorText = "中转没有收下开门请求"
                return
            }
            let sess = StoreSession(
                id: id,
                pin: obj["pin"] as? String ?? "",
                token: obj["token"] as? String ?? "",
                name: obj["name"] as? String ?? settings.deviceName,
                url: obj["url"] as? String ?? "",
                remote: true,
                expires: (obj["expires"] as? Double) ?? (Date().timeIntervalSince1970 + BoothHub.ttl),
                files: []
            )
            session = sess
            errorText = ""
            hub.adopt(sess)
            startDirect(base: trimmed, sess: sess)
        } catch {
            errorText = "连不上中转。先让顾客连店里 Wi-Fi 扫，或找人看设置里的高级项。"
        }
    }

    private func closeRemote(_ sess: StoreSession) async {
        let base = BoothHub.trimSlash(settings.storeRelayURL)
        guard let url = URL(string: "\(base)/api/booth/\(sess.id)/close?token=\(sess.token)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: req)
    }

    private func startDirect(base: String, sess: StoreSession) {
        poll?.cancel()
        let port = Ports.http(settings.port)
        let ips = discovery.localIPs
        let lan = "http://\(ips.first ?? "127.0.0.1"):\(port)"
        let manual = settings.storePublicURL.trimmingCharacters(in: .whitespacesAndNewlines)
        poll = Task { [weak self] in
            guard let self else { return }
            var wan = BoothHub.trimSlash(manual)
            await self.announce(base: base, sess: sess, lan: lan, wan: wan)
            if wan.isEmpty, self.shouldProbeWan {
                await MainActor.run {
                    self.probing = true
                    self.reachHint = "正在试着让顾客用流量也能转到本机…"
                }
                let found = await PortOpener.openHTTP(port: port, localIPs: ips)
                let alive = await MainActor.run { self.session?.id == sess.id }
                guard alive else { return }
                await MainActor.run { self.probing = false }
                if let found {
                    wan = BoothHub.trimSlash(found)
                    await MainActor.run {
                        self.reachHint = "顾客用流量扫码后会转到本机。若打不开，让他连店里 Wi-Fi。"
                    }
                    await self.announce(base: base, sess: sess, lan: lan, wan: wan)
                } else {
                    await MainActor.run {
                        self.reachHint = "请让顾客关掉流量，连店里 Wi-Fi 再扫。中转只指路，文件不经过服务器。"
                    }
                }
            }
            while !Task.isCancelled {
                let alive = await MainActor.run { self.session?.id == sess.id }
                guard alive else { return }
                await self.announce(base: base, sess: sess, lan: lan, wan: wan)
                try? await Task.sleep(nanoseconds: 25_000_000_000)
            }
        }
    }

    private func announce(base: String, sess: StoreSession, lan: String, wan: String) async {
        guard let url = URL(string: "\(base)/api/booth/\(sess.id)/announce") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "token": sess.token,
            "lan": lan,
            "wan": wan,
        ])
        _ = try? await URLSession.shared.data(for: req)
    }
}
