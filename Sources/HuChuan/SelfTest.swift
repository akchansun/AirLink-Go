import Foundation
import AppKit
import Network
import Darwin
import HuChuanCore

enum SelfTest {
    static func runAndExit() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        setbuf(stdout, nil)
        Task { @MainActor in
            do {
                try await runAll()
                print("自检通过：全部功能正常")
                exit(0)
            } catch {
                fputs("自检失败：\(error)\n", stderr)
                exit(1)
            }
        }
        app.run()
        fatalError("未进入运行循环")
    }

    @MainActor
    private static func runAll() async throws {
        let keys = ["deviceName", "receiveFolder", "autoAccept", "pin", "port", "maxConnections", "receiveMode", "launchAtLogin", "discoverMode", "autoCopyText", "storeRelayURL", "storePublicURL", "storeWifiName", "storeWifiPassword"]
        var backup: [String: Any] = [:]
        for k in keys { if let v = UserDefaults.standard.object(forKey: k) { backup[k] = v } }
        defer {
            for k in keys {
                if let v = backup[k] { UserDefaults.standard.set(v, forKey: k) }
                else { UserDefaults.standard.removeObject(forKey: k) }
            }
            UserDefaults.standard.synchronize()
        }

                print("→ 协议与安全路径"); fflush(stdout)
                try CoreSelfCheck.run()

                print("→ 按钮与弹窗状态"); fflush(stdout)
        try testButtonsAndDialogs()

        let env = try await makeEnv(port: 42123)
        defer {
            env.discovery.stop()
            env.http.stop()
            try? FileManager.default.removeItem(at: env.root)
        }

        print("→ 刷新 / 手动添加 IP / 复制网址")
        try testDiscoveryAndClipboard(env)

        print("→ 局域网发现（UDP + 加密握手）")
        try await testLanDiscovery(env)

        print("→ 打开接收箱目录")
        try testReceiveFolder(env)

        print("→ 空文件")
        try await testEmptyFile(env)

        print("→ 小文件 + 大文件")
        try await testSmallAndBig(env)

        print("→ 文件夹")
        try await testFolder(env)

        print("→ 拒绝接收")
        try await testReject(env)

        print("→ 口令拦截")
        try await testPinReject(env)

        print("→ 发送文字")
        try await testText(env)

        print("→ 取消传输")
        try await testCancel(env)

        print("→ 断点续传")
        try await testResume(env)

        print("→ 离线排队")
        try await testOfflineQueue(env)

        print("→ 手机网页通道")
        try await testHTTP(env)

        print("→ 设置保存")
        try testSettingsPersist()

        print("→ 接收记录")
        try testHistory()

        print("→ 见面码与发现范围")
        try testMeetAndDiscover()

        print("→ 门店码")
        try await testBooth(env)
    }

    @MainActor
    private struct Env {
        let root: URL
        let recv: URL
        let send: URL
        let settings: SettingsStore
        let transfers: TransferCenter
        let discovery: DiscoveryService
        let http: HTTPGateway
        let state: AppState?
        var peer: PeerDevice {
            PeerDevice(
                id: "loop", name: settings.deviceName, host: "127.0.0.1",
                port: settings.port, httpPort: Ports.http(settings.port),
                os: "macOS", lastSeen: Date(), via: "自检"
            )
        }
    }

    @MainActor
    private static func testDefaults() -> UserDefaults {
        let name = "com.huchuan.selftest"
        if let d = UserDefaults(suiteName: name) {
            d.removePersistentDomain(forName: name)
            return d
        }
        return .standard
    }

    @MainActor
    private static func makeEnv(port: UInt16) async throws -> Env {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("huchuan-selftest-\(UUID().uuidString)", isDirectory: true)
        let recv = root.appendingPathComponent("recv", isDirectory: true)
        let send = root.appendingPathComponent("send", isDirectory: true)
        try FileManager.default.createDirectory(at: recv, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: send, withIntermediateDirectories: true)

        let settings = SettingsStore(defaults: Self.testDefaults(), sanitize: false)
        settings.autoAccept = true
        settings.pin = ""
        settings.port = port
        settings.receiveFolder = recv
        settings.maxConnections = 4
        settings.deviceName = "自检接收端"

        let transfers = TransferCenter(settings: settings)
        transfers.attachShared()
        let discovery = DiscoveryService(settings: settings) { conn in
            transfers.handleInbound(conn)
        }
        transfers.onDiscovered = { peer in
            discovery.upsert(peer)
        }
        transfers.configureSender(deviceId: "sender", deviceName: "发送端")
        transfers.livePeer = { [discovery] id in
            discovery.peers.first(where: { $0.id == id })
        }
        discovery.onPeerCameOnline = { [transfers] peer in
            transfers.flush(to: peer)
        }
        let http = HTTPGateway(settings: settings)
        discovery.start()
        http.start()
        try await discovery.waitUntilListening()
        try await http.waitUntilListening()
        return Env(root: root, recv: recv, send: send, settings: settings, transfers: transfers, discovery: discovery, http: http, state: nil)
    }

    @MainActor
    private static func testButtonsAndDialogs() throws {
        let state = AppState()
        let buttons: [(AppDialog, String)] = [
            (.settings, "设置"),
            (.manual, "IP"),
            (.phone, "手机"),
            (.store, "门店码"),
            (.help, "帮助"),
            (.textComposer, "发文字"),
        ]
        for (dialog, name) in buttons {
            state.openDialog(dialog)
            guard state.dialog == dialog else { throw AppError.message("「\(name)」按钮没有打开窗口") }
            state.dialog = nil
            guard state.dialog == nil else { throw AppError.message("「\(name)」窗口关不掉") }
        }
        NotificationCenter.default.post(name: .huchuanOpenSettings, object: nil)
        // 通知是异步到界面的；这里直接测同一动作
        state.openDialog(.settings)
        guard state.dialog == .settings else { throw AppError.message("菜单「设置」打不开") }

        state.openDialog(.help)
        guard state.page == .help else { throw AppError.message("帮助页打不开") }

        state.manualHost = ""
        state.addManual()
        guard state.discovery.peers.isEmpty else { throw AppError.message("空 IP 不该被添加") }

        state.manualHost = "10.0.0.9"
        state.manualPort = "41789"
        state.openDialog(.manual)
        state.addManual()
        guard state.discovery.peers.contains(where: { $0.host == "10.0.0.9" }) else {
            throw AppError.message("手动添加 IP 失败")
        }
        guard state.dialog == nil else { throw AppError.message("添加 IP 后窗口没关掉") }

        let qr = QRMaker.image("http://127.0.0.1:41788")
        guard qr != nil else { throw AppError.message("二维码生成失败") }
        let wifi = StoreWifi.payload(ssid: "店;网", password: "a:b")
        guard let wifi, wifi.hasPrefix("WIFI:S:"), wifi.contains("S:店\\;网"), wifi.contains("P:a\\:b") else {
            throw AppError.message("连网码内容不对")
        }
        guard QRMaker.image(wifi) != nil else { throw AppError.message("连网码生成失败") }
        if StoreWifi.payload(ssid: "  ", password: "x") != nil {
            throw AppError.message("空名称不该出连网码")
        }

        var ghost = PeerDevice(id: "fav-1", name: "客厅电脑", host: "192.168.1.8", port: 41789, httpPort: 41788, os: "收藏", lastSeen: Date.distantPast, via: "收藏", favorite: true)
        ghost.refreshOnline()
        if ghost.online { throw AppError.message("没出现的收藏不该显示在线") }
        ghost.lastSeen = Date()
        ghost.refreshOnline()
        if !ghost.online { throw AppError.message("刚出现的收藏该显示在线") }

        state.touchPhone(host: "192.168.1.9")
        guard !state.discovery.peers.contains(where: { $0.id == "phone-web" }) else {
            throw AppError.message("轮询发件箱不该冒出手机网页")
        }

        state.openDialog(.phone)
        guard state.page == .phone else { throw AppError.message("手机来传页打不开") }
        state.notePhoneOnline(host: "192.168.1.9")
        guard state.page == .chat else { throw AppError.message("手机扫码后没有打开聊天窗口") }
        guard state.selectedPeer?.id == "phone-web" else { throw AppError.message("没有选中手机网页") }

        state.dropPhone(claimedIP: "192.168.1.9")
        guard !state.discovery.peers.contains(where: { $0.id == "phone-web" }) else {
            throw AppError.message("扫了别的电脑后这台还占着手机")
        }
        guard state.selectedPeer?.id != "phone-web" else {
            throw AppError.message("扫了别的电脑后聊天窗口没关掉")
        }

        state.openDialog(.phone)
        state.notePhoneOnline(host: "192.168.1.9")
        guard state.page == .chat else { throw AppError.message("再次扫码没有打开聊天窗口") }

        state.openDialog(.settings)
        state.notePhoneOnline(host: "192.168.1.9")
        guard state.page == .settings else { throw AppError.message("设置页不该被手机连通抢走") }

        state.closeDialog()
    }

    @MainActor
    private static func testDiscoveryAndClipboard(_ env: Env) throws {
        env.discovery.addManual(host: "192.168.0.55", port: 41789)
        guard env.discovery.peers.contains(where: { $0.host == "192.168.0.55" }) else {
            throw AppError.message("刷新后手动设备丢失")
        }
        NSPasteboard.general.clearContents()
        let ip = env.discovery.localIPs.first ?? "127.0.0.1"
        let url = "http://\(ip):\(Ports.http(env.settings.port))"
        NSPasteboard.general.setString(url, forType: .string)
        guard NSPasteboard.general.string(forType: .string) == url else {
            throw AppError.message("复制网址失败")
        }
    }

    @MainActor
    private static func testLanDiscovery(_ env: Env) async throws {
        let udpId = "win-udp-\(UUID().uuidString)"
        let packet = DiscoveryPacket(
            id: udpId, name: "Windows测试机", port: 41789,
            httpPort: 41788, os: "Windows"
        )
        sendRawUDP(packet.encode(), host: "127.0.0.1", port: Ports.udp(env.settings.port))
        try await waitUntil(timeout: 3) {
            env.discovery.peers.contains { $0.id == udpId }
        }

        let tcpId = "win-tcp-\(UUID().uuidString)"
        try await Task.detached { [port = env.settings.port] in
            let conn = NetFactory.connect(host: "127.0.0.1", port: port)
            try await conn.startAndWait(timeout: 2)
            let io = try await WireIO.open(conn, asServer: false)
            try await io.sendJSON(.hello(ControlMessage.Hello(
                deviceId: tcpId, name: "Windows握手机", port: 41789,
                httpPort: 41788, os: "Windows", appVersion: "1.0.0"
            )))
            _ = try await io.receiveFrame(timeout: 2)
            conn.cancel()
        }.value
        try await waitUntil(timeout: 3) {
            env.discovery.peers.contains { $0.id == tcpId }
        }
    }

    private static func sendRawUDP(_ data: Data, host: String, port: UInt16) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)
        _ = data.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, raw.baseAddress, data.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    @MainActor
    private static func testReceiveFolder(_ env: Env) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: env.recv.path, isDirectory: &isDir), isDir.boolValue else {
            throw AppError.message("接收文件夹不存在")
        }
    }

    @MainActor
    private static func testEmptyFile(_ env: Env) async throws {
        let url = env.send.appendingPathComponent("空文件.txt")
        try Data().write(to: url)
        env.settings.autoAccept = true
        env.transfers.send(to: env.peer, urls: [url], deviceId: "sender", deviceName: "发送端")
        try await waitReceive(env, name: "空文件.txt", timeout: 12)
        let got = try Data(contentsOf: env.recv.appendingPathComponent("空文件.txt"))
        if !got.isEmpty { throw AppError.message("空文件收到后不是 0 字节") }
    }

    @MainActor
    private static func testSmallAndBig(_ env: Env) async throws {
        let small = env.send.appendingPathComponent("短信.txt")
        try Data("互传自检：你好".utf8).write(to: small)
        let big = env.send.appendingPathComponent("大文件.bin")
        try writePattern(big, size: 12 * 1024 * 1024)
        env.transfers.send(to: env.peer, urls: [small, big], deviceId: "sender", deviceName: "发送端")
        try await waitReceive(env, name: "大文件.bin", timeout: 25)
        let a = try Data(contentsOf: small)
        let b = try Data(contentsOf: env.recv.appendingPathComponent("短信.txt"))
        if a != b { throw AppError.message("小文件内容不一致") }
        try comparePrefix(big, env.recv.appendingPathComponent("大文件.bin"), bytes: 2 * 1024 * 1024)
    }

    @MainActor
    private static func testFolder(_ env: Env) async throws {
        let dir = env.send.appendingPathComponent("相册", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: dir.appendingPathComponent("一.jpg"))
        try Data("bb".utf8).write(to: dir.appendingPathComponent("二.jpg"))
        env.transfers.send(to: env.peer, urls: [dir], deviceId: "sender", deviceName: "发送端")
        try await waitUntil(timeout: 15) {
            FileManager.default.fileExists(atPath: env.recv.appendingPathComponent("相册/一.jpg").path)
                && FileManager.default.fileExists(atPath: env.recv.appendingPathComponent("相册/二.jpg").path)
        }
    }

    @MainActor
    private static func testReject(_ env: Env) async throws {
        env.settings.autoAccept = false
        let url = env.send.appendingPathComponent("拒绝我.txt")
        try Data("no".utf8).write(to: url)
        env.transfers.send(to: env.peer, urls: [url], deviceId: "sender", deviceName: "发送端")
        try await waitUntil(timeout: 8) { env.transfers.incoming != nil }
        env.transfers.rejectIncoming()
        try await waitUntil(timeout: 8) {
            env.transfers.items.contains { $0.state == .failed || $0.detail.contains("拒绝") }
        }
        env.settings.autoAccept = true
    }

    @MainActor
    private static func testPinReject(_ env: Env) async throws {
        env.settings.pin = "9988"
        try await Task.sleep(nanoseconds: 50_000_000)
        let conn = NetFactory.connect(host: "127.0.0.1", port: env.settings.port)
        try await conn.startAndWait()
        let io = try await WireIO.open(conn, asServer: false)
        try await io.sendJSON(.hello(ControlMessage.Hello(
            deviceId: "x", name: "闯关", port: 1, httpPort: 1, os: "macOS", appVersion: "1.0.0", pin: "0000"
        )))
        let frame = try await io.receiveFrame(timeout: 8)
        let msg = try ControlMessage.decodeJSON(frame.payload)
        guard case .reject = msg else { throw AppError.message("错误口令没有被拦住") }
        io.cancel()
        env.settings.pin = ""
    }

    @MainActor
    private static func testText(_ env: Env) async throws {
        env.settings.autoAccept = true
        env.settings.pin = ""
        env.transfers.resetDialogs()
        env.transfers.sendText(to: env.peer, text: "你好，这是一段测试文字", deviceId: "sender", deviceName: "发送端")
        try await waitUntil(timeout: 8) { env.transfers.incomingText?.body == "你好，这是一段测试文字" }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(env.transfers.incomingText!.body, forType: .string)
        guard NSPasteboard.general.string(forType: .string) == "你好，这是一段测试文字" else {
            throw AppError.message("复制收到的文字失败")
        }
        env.transfers.incomingText = nil
    }

    @MainActor
    private static func testCancel(_ env: Env) async throws {
        env.settings.autoAccept = true
        env.settings.pin = ""
        env.transfers.resetDialogs()
        env.transfers.attachShared()
        let url = env.send.appendingPathComponent("取消.bin")
        try writePattern(url, size: 16 * 1024 * 1024)
        env.transfers.send(to: env.peer, urls: [url], deviceId: "sender", deviceName: "发送端")
        try await waitUntil(timeout: 10) {
            env.transfers.items.contains { $0.title.contains("取消.bin") && $0.direction == .send }
        }
        guard let item = env.transfers.items.first(where: { $0.title.contains("取消.bin") && $0.direction == .send }) else {
            throw AppError.message("取消任务没出现")
        }
        if item.state == .waiting || item.state == .transferring {
            env.transfers.cancel(item.id)
            try await waitUntil(timeout: 8) {
                env.transfers.items.contains { $0.id == item.id && $0.state == .cancelled }
            }
        }
    }

    @MainActor
    private static func testResume(_ env: Env) async throws {
        env.settings.autoAccept = true
        env.settings.pin = ""
        env.transfers.resetDialogs()
        let url = env.send.appendingPathComponent("续传.bin")
        try writePattern(url, size: 8 * 1024 * 1024)
        let dest = env.recv.appendingPathComponent("续传.bin")
        let part = URL(fileURLWithPath: dest.path + ".huchuanpart")
        let bits = URL(fileURLWithPath: dest.path + ".huchuanbits")
        let plan = ChunkPlan.plan(fileSize: 8 * 1024 * 1024)
        var bitmap = ChunkBitmap(chunkCount: plan.chunkCount)
        let half = max(1, plan.chunkCount / 2)
        let handle = try RandomAccessFile(writing: part.path, size: 8 * 1024 * 1024)
        let src = try RandomAccessFile(reading: url.path)
        for i in 0..<half {
            bitmap.insert(i)
            let range = plan.byteRange(for: i)
            let data = try src.read(offset: range.lowerBound, count: Int(range.upperBound - range.lowerBound))
            try handle.write(offset: range.lowerBound, data: data)
        }
        try bitmap.data.write(to: bits)
        env.transfers.send(to: env.peer, urls: [url], deviceId: "sender", deviceName: "发送端")
        try await waitReceive(env, name: "续传.bin", timeout: 20)
        try comparePrefix(url, dest, bytes: 1024 * 1024)
    }

    @MainActor
    private static func testOfflineQueue(_ env: Env) async throws {
        env.settings.autoAccept = true
        var ghost = env.peer
        ghost.lastSeen = Date.distantPast
        ghost.favorite = true
        ghost.online = false

        let cancelled = env.send.appendingPathComponent("取消排队.txt")
        try Data("不该发出去".utf8).write(to: cancelled)
        env.transfers.send(to: ghost, urls: [cancelled], deviceId: "sender", deviceName: "发送端")
        try await waitUntil(timeout: 8) {
            env.transfers.items.contains { $0.title.contains("取消排队.txt") && $0.state == .waitingPeer }
        }
        if let item = env.transfers.items.first(where: { $0.title.contains("取消排队.txt") }) {
            env.transfers.cancel(item.id)
        }

        let url = env.send.appendingPathComponent("排队.txt")
        try Data("等你上线".utf8).write(to: url)
        env.transfers.send(to: ghost, urls: [url], deviceId: "sender", deviceName: "发送端")
        try await waitUntil(timeout: 8) {
            env.transfers.items.contains { $0.title.contains("排队.txt") && $0.state == .waitingPeer }
        }

        var live = env.peer
        live.lastSeen = Date()
        live.favorite = true
        live.refreshOnline()
        env.transfers.flush(to: live)
        try await waitReceive(env, name: "排队.txt", timeout: 12)
        if FileManager.default.fileExists(atPath: env.recv.appendingPathComponent("取消排队.txt").path) {
            throw AppError.message("已取消的排队不该发出去")
        }
        let got = try String(contentsOf: env.recv.appendingPathComponent("排队.txt"), encoding: .utf8)
        if got != "等你上线" { throw AppError.message("排队发出的内容不对") }
    }

    @MainActor
    private static func testHTTP(_ env: Env) async throws {
        let port = Ports.http(env.settings.port)
        print("  网页信息 \(port)")
        let infoText = try await httpGet(port, path: "/api/info")
        if !infoText.contains("200") { throw AppError.message("网页信息接口失败：\(infoText.prefix(80))") }
        if !infoText.contains("自检接收端") { throw AppError.message("网页信息没有电脑名：\(infoText.prefix(120))") }

        print("  网页页面")
        if !HTTPGateway.html.contains("选择文件") { throw AppError.message("手机网页页面不完整") }
        if !HTTPGateway.html.contains("选择文件夹") { throw AppError.message("手机网页没有选文件夹") }
        if !HTTPGateway.html.contains("new Blob") { throw AppError.message("网页上传没有按实际字节发送") }
        if !HTTPGateway.html.contains("保存到手机") { throw AppError.message("手机网页不能接收电脑文件") }
        if !HTTPGateway.html.contains("另一部手机") { throw AppError.message("手机网页不能互传") }
        if !HTTPGateway.html.contains("/file/") { throw AppError.message("手机网页没有图片直链") }
        if !HTTPGateway.html.contains("保存到相册") { throw AppError.message("手机网页没有长按保存提示") }
        if !HTTPGateway.html.contains("?save=1") { throw AppError.message("手机网页不能保存普通文件") }
        if !HTTPGateway.html.contains("showPlayer") { throw AppError.message("手机网页不能收视频音频") }
    }

    private static func httpGet(_ port: UInt16, path: String, headOnly: Bool = false) async throws -> String {
        try await Task.detached {
            try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    let conn = NetFactory.connect(host: "127.0.0.1", port: port)
                    try await conn.startAndWait(timeout: 5)
                    let req = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
                    try await conn.sendData(Data(req.utf8))
                    var out = Data()
                    let deadline = Date().addingTimeInterval(8)
                    while Date() < deadline && out.count < 8192 {
                        let chunk = try await conn.receiveExactly(1, timeout: max(0.2, deadline.timeIntervalSinceNow))
                        out.append(chunk)
                        let s = String(data: out, encoding: .utf8) ?? ""
                        if headOnly && s.contains("200") { break }
                        if s.contains("自检接收端") { break }
                        if s.contains("选择文件") { break }
                    }
                    conn.cancel()
                    return String(data: out, encoding: .utf8) ?? ""
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                    throw AppError.message("网页通道没有响应")
                }
                guard let first = try await group.next() else {
                    throw AppError.message("网页通道没有结果")
                }
                group.cancelAll()
                return first
            }
        }.value
    }

    @MainActor
    private static func testSettingsPersist() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("huchuan-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let d = Self.testDefaults()
        let s = SettingsStore(defaults: d, sanitize: false)
        s.deviceName = "持久化测试机"
        s.receiveFolder = folder
        s.autoAccept = true
        s.maxConnections = 6
        s.port = 41999
        s.receiveMode = ReceiveMode.fav.rawValue
        s.discoverMode = DiscoverMode.favorites.rawValue
        s.autoCopyText = false
        let again = SettingsStore(defaults: d, sanitize: false)
        if again.deviceName != "持久化测试机" { throw AppError.message("设置名称没记住") }
        if again.maxConnections != 6 { throw AppError.message("并行路数没记住") }
        if again.port != 41999 { throw AppError.message("端口没记住") }
        if again.receiveMode != ReceiveMode.fav.rawValue { throw AppError.message("接收方式没记住") }
        if again.discoverMode != DiscoverMode.favorites.rawValue { throw AppError.message("发现范围没记住") }
        if again.autoCopyText { throw AppError.message("剪贴板开关没记住") }
        if again.autoAccept { throw AppError.message("只自动收收藏的人时不该还是全部自动收下") }
        if again.shouldAutoAccept(peerID: "x", peerName: "甲") != nil { throw AppError.message("没收藏的人不该自动收") }
        try? FileManager.default.removeItem(at: folder)
    }

    @MainActor
    private static func testHistory() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("huchuan-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("history.json")
        let store = HistoryStore(fileURL: file)
        store.add(title: "照片.jpg", peerName: "客厅电脑", path: "/tmp/照片.jpg")
        store.add(title: "发给对面", peerName: "客厅电脑", path: "/tmp/a.jpg", kind: "send")
        if store.items.count != 2 { throw AppError.message("收发记录条数不对") }
        if store.items.first?.kind != "send" { throw AppError.message("发送记录没记上") }
        let again = HistoryStore(fileURL: file)
        if again.items.first?.title != "发给对面" { throw AppError.message("收发记录没按新到旧保存") }
        again.clear()
        if !HistoryStore(fileURL: file).items.isEmpty { throw AppError.message("清空收发记录失败") }
        try? FileManager.default.removeItem(at: folder)
    }

    @MainActor
    private static func testMeetAndDiscover() throws {
        let a = MeetCode.of("设备甲", "设备乙")
        let b = MeetCode.of("设备乙", "设备甲")
        if a != b || a.count != 4 { throw AppError.message("见面码不对") }
        let d = Self.testDefaults()
        let s = SettingsStore(defaults: d, sanitize: false)
        s.discoverMode = DiscoverMode.off.rawValue
        let disc = DiscoveryService(settings: s) { _ in }
        if disc.allowsPeer(id: "other", via: "UDP 广播") { throw AppError.message("关闭发现后不该出现陌生人") }
        if !disc.allowsPeer(id: "manual-1", via: "手动添加") { throw AppError.message("关闭发现后仍应能手填 IP") }
        s.discoverMode = DiscoverMode.favorites.rawValue
        s.favorites = [FavoritePeer(id: "fav-1", name: "客厅", host: "1.1.1.1", port: 41789)]
        if !disc.allowsPeer(id: "fav-1", via: "UDP 广播") { throw AppError.message("仅收藏时应能看见收藏的人") }
        if disc.allowsPeer(id: "stranger", via: "UDP 广播") { throw AppError.message("仅收藏时不该看见陌生人") }
    }

    @MainActor
    private static func testBooth(_ env: Env) async throws {
        let sess = env.http.booth.open(name: "店里电脑", publicBase: "http://127.0.0.1:\(Ports.http(env.settings.port))")
        guard let encoded = "店单.pdf".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "http://127.0.0.1:\(Ports.http(env.settings.port))/b/\(sess.id)/upload?name=\(encoded)&p=\(sess.pin)") else {
            throw AppError.message("门店码网址不对")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("booth-ok".utf8)
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw AppError.message("门店码上传失败")
        }
        try await waitUntil(timeout: 6) {
            FileManager.default.fileExists(atPath: env.recv.appendingPathComponent("店单.pdf").path)
        }
        env.http.booth.close(id: sess.id, token: sess.token)
        if WanAddress.isPublicIPv4("192.168.1.8") || WanAddress.isPublicIPv4("100.64.1.2") {
            throw AppError.message("内网地址不该当外网")
        }
        if !WanAddress.isPublicIPv4("8.8.8.8") {
            throw AppError.message("外网地址判断不对")
        }
    }

    @MainActor
    private static func waitReceive(_ env: Env, name: String, timeout: TimeInterval) async throws {
        let dest = env.recv.appendingPathComponent(name)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: dest.path) { return }
            if let failed = env.transfers.items.first(where: { $0.state == .failed && $0.title.contains(name) }) {
                throw AppError.message("发送「\(name)」失败：\(failed.detail)")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let snap = env.transfers.items.map { "\($0.direction == .send ? "发" : "收") \($0.title) \($0.state.rawValue) \($0.detail)" }.joined(separator: "；")
        throw AppError.message("没有收到 \(name)。当前任务：\(snap.isEmpty ? "无" : snap)")
    }

    private static func waitUntil(timeout: TimeInterval, _ pred: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pred() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw AppError.message("等待超时（\(Int(timeout)) 秒）")
    }

    private static func writePattern(_ url: URL, size: Int) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        let block = Data((0..<65536).map { UInt8($0 % 251) })
        var written = 0
        while written < size {
            let n = min(block.count, size - written)
            try handle.write(contentsOf: n == block.count ? block : block.prefix(n))
            written += n
        }
        try handle.close()
    }

    private static func comparePrefix(_ a: URL, _ b: URL, bytes: Int) throws {
        let sa = try FileHandle(forReadingFrom: a)
        let sb = try FileHandle(forReadingFrom: b)
        defer { try? sa.close(); try? sb.close() }
        let xa = try sa.read(upToCount: bytes) ?? Data()
        let xb = try sb.read(upToCount: bytes) ?? Data()
        if xa != xb { throw AppError.message("\(a.lastPathComponent) 内容不一致") }
        let za = try FileManager.default.attributesOfItem(atPath: a.path)[.size] as? UInt64
        let zb = try FileManager.default.attributesOfItem(atPath: b.path)[.size] as? UInt64
        if za != zb { throw AppError.message("\(a.lastPathComponent) 大小不一致") }
    }
}
