import Foundation
import Network
import Combine
import AppKit
import UserNotifications
import HuChuanCore

enum TransferState: String, Sendable {
    case waiting = "等待对方同意"
    case waitingPeer = "等待对方上线"
    case waitingPhone = "等手机来收"
    case transferring = "传输中"
    case paused = "已暂停"
    case completed = "已完成"
    case failed = "失败"
    case cancelled = "已取消"
}

struct TransferItem: Identifiable, Equatable, Sendable {
    let id: UUID
    var sessionId: String
    var direction: Direction
    var peerName: String
    var title: String
    var total: UInt64
    var done: UInt64
    var speed: Double
    var state: TransferState
    var detail: String
    var fileCount: Int
    var localPath: String? = nil

    enum Direction: Equatable, Sendable { case send, receive }

    var progress: Double { total == 0 ? 0 : min(1, Double(done) / Double(total)) }
}

struct IncomingOffer: Identifiable {
    let id: String
    let peerName: String
    let files: [FileOffer]
    var total: UInt64 { files.reduce(0) { $0 + $1.size } }
}

struct IncomingText: Identifiable {
    let id = UUID()
    let peerName: String
    let body: String
}

final class RecvHub: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: RecvSession] = [:]

    func put(_ session: RecvSession) {
        lock.lock(); map[session.id] = session; lock.unlock()
    }

    func get(_ id: String) -> RecvSession? {
        lock.lock(); defer { lock.unlock() }
        return map[id]
    }

    func remove(_ id: String) {
        lock.lock(); map[id] = nil; lock.unlock()
    }
}

actor CancelFlags {
    private var ids: Set<String> = []
    func cancel(_ id: String) { ids.insert(id) }
    func isCancelled(_ id: String) -> Bool { ids.contains(id) }
}

@MainActor
final class TransferCenter: ObservableObject {
    @Published var items: [TransferItem] = []
    @Published var incoming: IncomingOffer?
    @Published var incomingText: IncomingText?

    let settings: SettingsStore
    let hub = RecvHub()
    let flags = CancelFlags()
    var history: HistoryStore?
    private var offerWaiter: CheckedContinuation<Bool, Never>?

    var onDiscovered: (@MainActor (PeerDevice) -> Void)?
    var onCancelSession: ((String) -> Void)?
    var livePeer: ((String) -> PeerDevice?)?
    var senderId = ""
    var senderName = ""
    var sendQueue: [QueuedSend] = []
    var flushingPeers: Set<String> = []
    var retryTimer: Timer?

    init(settings: SettingsStore) {
        self.settings = settings
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func handleInbound(_ raw: NWConnection) {
        let settingsSnap = Snapshot(settings)
        Task.detached { [hub, flags] in
            do {
                try await raw.startAndWait()
                let io = try await WireIO.open(raw, asServer: true)
                let frame = try await io.receiveFrame(timeout: 20)
                guard frame.kind == .json else { io.cancel(); return }
                let msg = try ControlMessage.decodeJSON(frame.payload)
                switch msg {
                case .hello(let hello):
                    let myId = UserDefaults.standard.string(forKey: "deviceId") ?? ""
                    if let ip = remoteIPv4(raw),
                       !hello.deviceId.isEmpty,
                       hello.deviceId != "local",
                       hello.deviceId != myId {
                        let port = hello.port == 0 ? settingsSnap.port : hello.port
                        let httpPort = hello.httpPort == 0 ? Ports.http(port) : hello.httpPort
                        let peer = PeerDevice(
                            id: hello.deviceId, name: hello.name, host: ip, port: port,
                            httpPort: httpPort, os: hello.os.isEmpty ? "电脑" : hello.os,
                            lastSeen: Date(), via: "对方连过来"
                        )
                        await MainActor.run { TransferCenter.shared?.onDiscovered?(peer) }
                    }
                    try await TransferPipes.receiverControl(
                        io: io, hello: hello, settings: settingsSnap, hub: hub,
                        ask: { offer, name in
                            await TransferCenter.sharedDecision(offer: offer, peerName: name, peerID: hello.deviceId)
                        },
                        onPrepared: { item in
                            await TransferCenter.shared?.add(item)
                        },
                        onProgress: { sessionId, added, speed in
                            await TransferCenter.shared?.bump(sessionId: sessionId, added: added, speed: speed)
                        },
                        onFinish: { sessionId in
                            await TransferCenter.shared?.finalize(sessionId: sessionId)
                        },
                        onCancel: { sessionId, reason in
                            await TransferCenter.shared?.mark(sessionId: sessionId, state: .cancelled, detail: reason)
                        },
                        onText: { name, body in
                            await TransferCenter.shared?.showText(name: name, body: body)
                        }
                    )
                case .join(let join):
                    try await TransferPipes.receiverWorker(
                        io: io, join: join, hub: hub,
                        onProgress: { sessionId, added, speed in
                            await TransferCenter.shared?.bump(sessionId: sessionId, added: added, speed: speed)
                        }
                    )
                default:
                    io.cancel()
                }
            } catch {
                raw.cancel()
            }
            _ = flags
        }
    }

    func attachShared() { TransferCenter.shared = self }

    static weak var shared: TransferCenter?

    func send(to peer: PeerDevice, urls: [URL], deviceId: String, deviceName: String) {
        configureSender(deviceId: deviceId, deviceName: deviceName)
        let snap = Snapshot(settings)
        Task.detached { [flags, hub] in
            do {
                let scanned = try FileScanner.collect(urls: urls)
                await TransferCenter.shared?.beginFileSend(peer: peer, scanned: scanned, settings: snap, flags: flags)
            } catch {
                await TransferCenter.shared?.fail(peerName: peer.name, message: (error as? AppError)?.description ?? error.localizedDescription)
            }
            _ = hub
        }
    }

    func beginFileSend(
        peer: PeerDevice,
        scanned: [(url: URL, relative: String, size: UInt64, modified: TimeInterval)],
        settings snap: Snapshot,
        flags: CancelFlags
    ) {
        var live = livePeer?(peer.id) ?? peer
        if peer.favorite { live.favorite = true }
        live.refreshOnline()
        let files = scanned.enumerated().map {
            FileOffer(index: $0.offset, relativePath: $0.element.relative, size: $0.element.size, modified: $0.element.modified)
        }
        let total = files.reduce(UInt64(0)) { $0 + $1.size }
        let sessionId = UUID().uuidString
        let itemId = UUID()
        if shouldQueue(live) {
            parkFiles(to: live, scanned: scanned, itemId: itemId, sessionId: sessionId)
            return
        }
        let deviceId = senderId
        let deviceName = senderName
        add(TransferItem(
            id: itemId, sessionId: sessionId, direction: .send, peerName: live.name,
            title: files.count == 1 ? files[0].relativePath : "\(files.count) 个文件",
            total: total, done: 0, speed: 0, state: .waiting,
            detail: "正在连接 \(live.host)", fileCount: files.count,
            localPath: scanned.first?.url.path
        ))
        let target = live
        Task.detached {
            do {
                try await TransferPipes.send(
                    peer: target, files: files, localURLs: scanned.map(\.url),
                    sessionId: sessionId, itemId: itemId,
                    deviceId: deviceId, deviceName: deviceName, settings: snap, flags: flags,
                    onUpdate: { itemId, mutate in
                        await TransferCenter.shared?.mutate(itemId, mutate)
                    }
                )
                await TransferCenter.shared?.noteSendDone(itemId)
            } catch {
                if await flags.isCancelled(sessionId) { return }
                await TransferCenter.shared?.handleSendFailure(
                    peer: target, scanned: scanned, itemId: itemId, sessionId: sessionId, error: error
                )
            }
        }
    }

    func handleSendFailure(
        peer: PeerDevice, scanned: [(url: URL, relative: String, size: UInt64, modified: TimeInterval)],
        itemId: UUID, sessionId: String, error: Error
    ) {
        if SendReachability.isUnreachable(error) && canQueue(peer) {
            parkFiles(to: peer, scanned: scanned, itemId: itemId, sessionId: sessionId)
            return
        }
        fail(peerName: peer.name, message: (error as? AppError)?.description ?? error.localizedDescription, itemId: itemId)
    }

    func sendText(to peer: PeerDevice, text: String, deviceId: String, deviceName: String) {
        configureSender(deviceId: deviceId, deviceName: deviceName)
        var live = livePeer?(peer.id) ?? peer
        if peer.favorite { live.favorite = true }
        live.refreshOnline()
        if shouldQueue(live) {
            parkText(to: live, text: text)
            return
        }
        Task { await deliverText(to: live, text: text, job: nil) }
    }

    func acceptIncoming() {
        incoming = nil
        offerWaiter?.resume(returning: true)
        offerWaiter = nil
    }

    func rejectIncoming() {
        incoming = nil
        offerWaiter?.resume(returning: false)
        offerWaiter = nil
    }

    func resetDialogs() {
        incoming = nil
        incomingText = nil
        offerWaiter?.resume(returning: false)
        offerWaiter = nil
    }

    func cancel(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        dropQueued(itemId: id)
        Task { await flags.cancel(item.sessionId) }
        onCancelSession?(item.sessionId)
        hub.get(item.sessionId)?.cancelled = true
        mutate(id) { item in
            var item = item
            item.state = .cancelled
            item.detail = "已取消"
            item.speed = 0
            return item
        }
    }

    func openReceived() {
        NSWorkspace.shared.open(settings.receiveFolder)
    }

    func add(_ item: TransferItem) {
        items.insert(item, at: 0)
    }

    func mutate(_ id: UUID, _ body: @Sendable (TransferItem) -> TransferItem) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx] = body(items[idx])
    }

    func bump(sessionId: String, added: UInt64, speed: Double) {
        guard let idx = items.firstIndex(where: { $0.sessionId == sessionId }) else { return }
        items[idx].done = min(items[idx].total, items[idx].done + added)
        items[idx].speed = speed
        items[idx].state = .transferring
        let remain = items[idx].total - items[idx].done
        items[idx].detail = "\(ByteFormat.speed(speed)) · \(ByteFormat.eta(remaining: remain, speed: speed))"
    }

    func mark(sessionId: String, state: TransferState, detail: String) {
        guard let idx = items.firstIndex(where: { $0.sessionId == sessionId }) else { return }
        items[idx].state = state
        items[idx].detail = detail
        items[idx].speed = 0
    }

    func finalize(sessionId: String) {
        guard let session = hub.get(sessionId) else { return }
        session.syncAll()
        for i in session.files.indices {
            session.files[i].sync()
            let part = session.partURLs[i]
            let final = session.finalURLs[i]
            try? FileManager.default.removeItem(at: final)
            try? FileManager.default.moveItem(at: part, to: final)
            try? FileManager.default.removeItem(at: session.bitsURLs[i])
        }
        mark(sessionId: sessionId, state: .completed, detail: "已保存到接收文件夹")
        if let idx = items.firstIndex(where: { $0.sessionId == sessionId }) {
            items[idx].done = items[idx].total
            items[idx].localPath = session.finalURLs.first?.path
        }
        hub.remove(sessionId)
        if let item = items.first(where: { $0.sessionId == sessionId }) {
            history?.add(title: item.title, peerName: item.peerName, path: item.localPath ?? "", kind: "recv")
            notify("接收完成", item.title)
        }
    }

    func noteSendDone(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), item.state == .completed else { return }
        history?.add(title: item.title, peerName: item.peerName, path: item.localPath ?? "", kind: "send")
    }

    func fail(peerName: String, message: String, itemId: UUID? = nil) {
        if let itemId, let idx = items.firstIndex(where: { $0.id == itemId }) {
            items[idx].state = .failed
            items[idx].detail = message
            items[idx].speed = 0
            return
        }
        if let idx = items.firstIndex(where: {
            $0.peerName == peerName && ($0.state == .waiting || $0.state == .waitingPeer || $0.state == .transferring)
        }) {
            items[idx].state = .failed
            items[idx].detail = message
            items[idx].speed = 0
        } else {
            items.insert(TransferItem(
                id: UUID(), sessionId: UUID().uuidString, direction: .send, peerName: peerName,
                title: "发送失败", total: 0, done: 0, speed: 0, state: .failed, detail: message, fileCount: 0
            ), at: 0)
        }
    }

    func showText(name: String, body: String) {
        incomingText = IncomingText(peerName: name, body: body)
        history?.add(title: body, peerName: name, text: body, kind: "recv")
        notify("来自 \(name) 的文字", body)
    }

    static func sharedDecision(offer: ControlMessage.Offer, peerName: String, peerID: String) async -> Bool {
        guard let shared else { return false }
        return await shared.decide(offer: offer, peerName: peerName, peerID: peerID)
    }

    func decide(offer: ControlMessage.Offer, peerName: String, peerID: String) async -> Bool {
        if let auto = settings.shouldAutoAccept(peerID: peerID, peerName: peerName) {
            return auto
        }
        notify("\(peerName) 要发文件过来", "共 \(offer.files.count) 个，\(ByteFormat.size(offer.files.reduce(0) { $0 + $1.size }))")
        return await withCheckedContinuation { cont in
            if let old = offerWaiter { old.resume(returning: false) }
            incoming = IncomingOffer(id: offer.sessionId, peerName: peerName, files: offer.files)
            offerWaiter = cont
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
                guard let self, self.incoming?.id == offer.sessionId else { return }
                self.rejectIncoming()
            }
        }
    }

    func openLocal(_ path: String) {
        let safe = safeOpenPath(path)
        if safe.isEmpty {
            openReceived()
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: safe))
    }

    func revealLocal(_ path: String) {
        let safe = safeOpenPath(path)
        if safe.isEmpty {
            openReceived()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: safe)])
    }

    private func safeOpenPath(_ path: String) -> String {
        let p = (path as NSString).standardizingPath
        guard !p.isEmpty else { return "" }
        let recv = (settings.receiveFolder.path as NSString).standardizingPath
        if !recv.isEmpty && (p == recv || p.hasPrefix(recv + "/")) {
            return p
        }
        if items.contains(where: { item in
            guard let local = item.localPath else { return false }
            return (local as NSString).standardizingPath == p
        }) {
            return p
        }
        return ""
    }

    func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let ping = NSSound(named: NSSound.Name("Ping")) {
            ping.play()
        } else {
            NSSound.beep()
        }
        if NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        } else {
            content.sound = UNNotificationSound.default
            NSApp.requestUserAttention(.criticalRequest)
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

}

private func remoteIPv4(_ conn: NWConnection) -> String? {
    func fromEndpoint(_ endpoint: NWEndpoint?) -> String? {
        guard let endpoint else { return nil }
        guard case .hostPort(let host, _) = endpoint else { return nil }
        let raw: String
        switch host {
        case .ipv4(let addr):
            raw = "\(addr)"
        case .name(let name, _):
            raw = name
        default:
            raw = "\(host)"
        }
        let ip = raw.split(separator: "%").first.map(String.init) ?? raw
        if ip == "::1" || ip == "localhost" { return nil }
        let parts = ip.split(separator: ".")
        guard parts.count == 4, parts.allSatisfy({ Int($0) != nil }) else { return nil }
        return ip
    }
    return fromEndpoint(conn.currentPath?.remoteEndpoint) ?? fromEndpoint(conn.endpoint)
}

struct Snapshot: Sendable {
    var deviceName: String
    var receiveFolder: URL
    var autoAccept: Bool
    var pin: String
    var port: UInt16
    var maxConnections: Int

    @MainActor
    init(_ s: SettingsStore) {
        deviceName = s.deviceName
        receiveFolder = s.receiveFolder
        autoAccept = s.autoAccept
        pin = s.pin
        port = s.port
        maxConnections = s.maxConnections
    }
}

enum TransferPipes {
    static func send(
        peer: PeerDevice, files: [FileOffer], localURLs: [URL],
        sessionId: String, itemId: UUID,
        deviceId: String, deviceName: String, settings: Snapshot, flags: CancelFlags,
        onUpdate: @escaping @Sendable (UUID, @Sendable (TransferItem) -> TransferItem) async -> Void
    ) async throws {
        let conn = NetFactory.connect(host: peer.host, port: peer.port)
        try await conn.startAndWait()
        let control = try await WireIO.open(conn, asServer: false)
        try await control.sendJSON(.hello(ControlMessage.Hello(
            deviceId: deviceId, name: deviceName, port: settings.port,
            httpPort: Ports.http(settings.port), os: "macOS", appVersion: "1.0.0",
            pin: settings.pin.isEmpty ? nil : settings.pin
        )))
        let helloFrame = try await control.receiveFrame(timeout: 15)
        guard helloFrame.kind == .json else { throw AppError.message("对方协议不对") }
        let helloMsg = try ControlMessage.decodeJSON(helloFrame.payload)
        if case .reject(let r) = helloMsg { throw AppError.message(r.reason) }
        guard case .helloOk = helloMsg else { throw AppError.message("握手失败") }

        let token = UUID().uuidString
        try await control.sendJSON(.offer(ControlMessage.Offer(sessionId: sessionId, token: token, files: files)))
        await onUpdate(itemId) { item in
            var item = item
            item.detail = "等待 \(peer.name) 同意"
            return item
        }

        let replyFrame = try await control.receiveFrame(timeout: 125)
        let replyMsg = try ControlMessage.decodeJSON(replyFrame.payload)
        if case .reject(let r) = replyMsg { throw AppError.message(r.reason) }
        guard case .offerReply(let reply) = replyMsg, reply.accepted else {
            throw AppError.message("对方拒绝接收")
        }

        var bitmaps: [ChunkBitmap] = []
        for (i, file) in files.enumerated() {
            let b64 = i < reply.resumeBits.count ? reply.resumeBits[i] : ""
            bitmaps.append(ChunkBitmap.fromBase64(b64, chunkCount: file.plan.chunkCount))
        }
        let already: UInt64 = zip(files, bitmaps).reduce(UInt64(0)) { sum, pair in
            let (file, bits) = pair
            var n: UInt64 = 0
            for idx in 0..<file.plan.chunkCount where bits.contains(idx) {
                n += UInt64(file.plan.length(for: idx))
            }
            return sum + n
        }
        await onUpdate(itemId) { item in
            var item = item
            item.state = .transferring
            item.done = already
            item.detail = already > 0 ? "断点续传中" : "正在发送"
            return item
        }

        let handles = try localURLs.map { try RandomAccessFile(reading: $0.path) }
        let queue = WorkQueue()
        for (i, file) in files.enumerated() {
            for c in 0..<file.plan.chunkCount where !bitmaps[i].contains(c) {
                await queue.add(i, c)
            }
        }
        if await queue.count == 0 {
            try await control.sendJSON(.finish(ControlMessage.Finish(sessionId: sessionId)))
            await onUpdate(itemId) { item in
                var item = item
                item.state = .completed
                item.done = item.total
                item.speed = 0
                item.detail = "已完成（无需重传）"
                return item
            }
            control.cancel()
            return
        }

        let biggest = files.map(\.size).max() ?? 0
        let workers = ChunkPlan.parallelConnections(fileSize: biggest, configuredMax: settings.maxConnections)
        await onUpdate(itemId) { item in
            var item = item
            item.detail = "\(workers) 路并行发送"
            return item
        }
        let meter = SpeedMeter()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for w in 0..<workers {
                group.addTask {
                    try await runSendWorker(
                        host: peer.host, port: peer.port, sessionId: sessionId, token: token,
                        workerId: w, files: files, handles: handles, queue: queue,
                        flags: flags, meter: meter, itemId: itemId, onUpdate: onUpdate
                    )
                }
            }
            try await group.waitForAll()
        }

        if await flags.isCancelled(sessionId) {
            try? await control.sendJSON(.cancel(ControlMessage.Cancel(sessionId: sessionId, reason: "发送方取消")))
            control.cancel()
            return
        }
        try await control.sendJSON(.finish(ControlMessage.Finish(sessionId: sessionId)))
        await onUpdate(itemId) { item in
            var item = item
            item.state = .completed
            item.done = item.total
            item.speed = 0
            item.detail = "已送达"
            return item
        }
        control.cancel()
    }

    private static func runSendWorker(
        host: String, port: UInt16, sessionId: String, token: String,
        workerId: Int, files: [FileOffer], handles: [RandomAccessFile],
        queue: WorkQueue, flags: CancelFlags, meter: SpeedMeter, itemId: UUID,
        onUpdate: @escaping @Sendable (UUID, @Sendable (TransferItem) -> TransferItem) async -> Void
    ) async throws {
        let conn = NetFactory.connect(host: host, port: port)
        try await conn.startAndWait()
        let io = try await WireIO.open(conn, asServer: false)
        try await io.sendJSON(.join(ControlMessage.Join(sessionId: sessionId, token: token, workerId: workerId)))
        while let job = await queue.next() {
            if await flags.isCancelled(sessionId) { break }
            let file = files[job.file]
            let range = file.plan.byteRange(for: job.chunk)
            var attempt = 0
            while true {
                attempt += 1
                let data = try handles[job.file].read(offset: range.lowerBound, count: Int(range.upperBound - range.lowerBound))
                try await io.sendChunk(ChunkPacket(fileIndex: UInt32(job.file), chunkIndex: UInt32(job.chunk), data: data))
                let ackFrame = try await io.receiveFrame(timeout: 45)
                guard ackFrame.kind == .chunkAck else { throw AppError.message("数据通道异常") }
                if try ChunkAck.decode(ackFrame.payload).ok {
                    let spd = await meter.add(UInt64(data.count))
                    await onUpdate(itemId) { item in
                        var item = item
                        item.done = min(item.total, item.done + UInt64(data.count))
                        item.speed = spd
                        item.state = .transferring
                        item.detail = "\(ByteFormat.speed(spd)) · \(ByteFormat.eta(remaining: item.total - item.done, speed: spd))"
                        return item
                    }
                    break
                }
                if attempt >= 4 { throw AppError.message("分块多次校验失败：\(file.relativePath)") }
            }
        }
        io.cancel()
    }

    static func receiverControl(
        io: WireIO, hello: ControlMessage.Hello, settings: Snapshot, hub: RecvHub,
        ask: @escaping @Sendable (ControlMessage.Offer, String) async -> Bool,
        onPrepared: @escaping @Sendable (TransferItem) async -> Void,
        onProgress: @escaping @Sendable (String, UInt64, Double) async -> Void,
        onFinish: @escaping @Sendable (String) async -> Void,
        onCancel: @escaping @Sendable (String, String) async -> Void,
        onText: @escaping @Sendable (String, String) async -> Void
    ) async throws {
        if !settings.pin.isEmpty && hello.pin != settings.pin {
            try await io.sendJSON(.reject(ControlMessage.Reject(sessionId: "", reason: "口令不对")))
            io.cancel()
            return
        }
        try await io.sendJSON(.helloOk(ControlMessage.Hello(
            deviceId: UserDefaults.standard.string(forKey: "deviceId") ?? "mac",
            name: settings.deviceName, port: settings.port,
            httpPort: Ports.http(settings.port), os: "macOS", appVersion: "1.0.0"
        )))
        while true {
            let frame = try await io.receiveFrame(timeout: 180)
            switch frame.kind {
            case .ping:
                try await io.sendPong()
            case .json:
                let msg = try ControlMessage.decodeJSON(frame.payload)
                switch msg {
                case .offer(let offer):
                    let accepted = await ask(offer, hello.name)
                    if !accepted {
                        try await io.sendJSON(.reject(ControlMessage.Reject(sessionId: offer.sessionId, reason: "用户拒绝")))
                        io.cancel()
                        return
                    }
                    let session = try prepareRecv(offer: offer, token: offer.token, settings: settings, peerName: hello.name)
                    hub.put(session)
                    await onPrepared(TransferItem(
                        id: UUID(), sessionId: offer.sessionId, direction: .receive, peerName: hello.name,
                        title: offer.files.count == 1 ? (session.saveNames.first ?? "文件") : "\(offer.files.count) 个文件",
                        total: offer.files.reduce(0) { $0 + $1.size }, done: session.already,
                        speed: 0, state: .transferring,
                        detail: session.already > 0 ? "接着上次继续收" : "正在接收",
                        fileCount: offer.files.count,
                        localPath: session.finalURLs.first?.path
                    ))
                    try await io.sendJSON(.offerReply(ControlMessage.OfferReply(
                        sessionId: offer.sessionId, accepted: true,
                        saveNames: session.saveNames, resumeBits: session.bitmaps.map(\.base64)
                    )))
                case .text(let t):
                    await onText(hello.name, t.body)
                case .finish(let f):
                    await onFinish(f.sessionId)
                    io.cancel()
                    return
                case .cancel(let c):
                    hub.get(c.sessionId)?.cancelled = true
                    await onCancel(c.sessionId, c.reason)
                    io.cancel()
                    return
                default:
                    break
                }
            default:
                break
            }
        }
    }

    static func receiverWorker(
        io: WireIO, join: ControlMessage.Join, hub: RecvHub,
        onProgress: @escaping @Sendable (String, UInt64, Double) async -> Void
    ) async throws {
        guard let session = hub.get(join.sessionId), session.token == join.token else {
            io.cancel()
            return
        }
        let meter = SpeedMeter()
        while !session.cancelled {
            let frame = try await io.receiveFrame(timeout: 60)
            switch frame.kind {
            case .chunk:
                let packet = try ChunkPacket.decode(frame.payload)
                let ok = packet.hashOk
                if ok {
                    let idx = Int(packet.fileIndex)
                    guard session.files.indices.contains(idx) else { throw AppError.message("文件序号不对") }
                    let range = session.plans[idx].byteRange(for: Int(packet.chunkIndex))
                    try session.files[idx].write(offset: range.lowerBound, data: packet.data)
                    session.mark(file: idx, chunk: Int(packet.chunkIndex))
                    let spd = await meter.add(UInt64(packet.data.count))
                    await onProgress(join.sessionId, UInt64(packet.data.count), spd)
                }
                try await io.sendAck(ChunkAck(fileIndex: packet.fileIndex, chunkIndex: packet.chunkIndex, ok: ok))
            case .ping:
                try await io.sendPong()
            default:
                io.cancel()
                return
            }
        }
        io.cancel()
    }

    static func prepareRecv(offer: ControlMessage.Offer, token: String, settings: Snapshot, peerName: String) throws -> RecvSession {
        try FileManager.default.createDirectory(at: settings.receiveFolder, withIntermediateDirectories: true)
        var saveNames: [String] = []
        var handles: [RandomAccessFile] = []
        var bitmaps: [ChunkBitmap] = []
        var plans: [ChunkPlan] = []
        var bitsURLs: [URL] = []
        var partURLs: [URL] = []
        var finalURLs: [URL] = []
        var already: UInt64 = 0

        for file in offer.files {
            guard let rel = PathGuard.sanitizeRelativePath(file.relativePath) else {
                throw AppError.message("文件名不合法：\(file.relativePath)")
            }
            let plan = file.plan
            plans.append(plan)
            let final = PathGuard.uniquePath(in: settings.receiveFolder, relative: rel)
            let part = URL(fileURLWithPath: final.path + ".huchuanpart")
            let bits = URL(fileURLWithPath: final.path + ".huchuanbits")
            var bitmap = ChunkBitmap(chunkCount: plan.chunkCount)
            if FileManager.default.fileExists(atPath: part.path),
               let attrs = try? FileManager.default.attributesOfItem(atPath: part.path),
               let sz = attrs[.size] as? UInt64, sz == file.size,
               let data = try? Data(contentsOf: bits) {
                bitmap = ChunkBitmap(chunkCount: plan.chunkCount, data: data)
                for i in 0..<plan.chunkCount where bitmap.contains(i) {
                    already += UInt64(plan.length(for: i))
                }
            }
            handles.append(try RandomAccessFile(writing: part.path, size: file.size))
            bitmaps.append(bitmap)
            bitsURLs.append(bits)
            partURLs.append(part)
            finalURLs.append(final)
            saveNames.append(final.lastPathComponent)
        }
        return RecvSession(
            id: offer.sessionId, token: token, files: handles, plans: plans,
            bitmaps: bitmaps, bitsURLs: bitsURLs, partURLs: partURLs, finalURLs: finalURLs,
            saveNames: saveNames, already: already
        )
    }
}

final class RecvSession: @unchecked Sendable {
    let id: String
    let token: String
    let files: [RandomAccessFile]
    let plans: [ChunkPlan]
    var bitmaps: [ChunkBitmap]
    let bitsURLs: [URL]
    let partURLs: [URL]
    let finalURLs: [URL]
    let saveNames: [String]
    let already: UInt64
    var cancelled = false
    private let lock = NSLock()
    private var persistCounter = 0

    init(id: String, token: String, files: [RandomAccessFile], plans: [ChunkPlan], bitmaps: [ChunkBitmap], bitsURLs: [URL], partURLs: [URL], finalURLs: [URL], saveNames: [String], already: UInt64 = 0) {
        self.id = id
        self.token = token
        self.files = files
        self.plans = plans
        self.bitmaps = bitmaps
        self.bitsURLs = bitsURLs
        self.partURLs = partURLs
        self.finalURLs = finalURLs
        self.saveNames = saveNames
        self.already = already
    }

    func mark(file: Int, chunk: Int) {
        lock.lock()
        bitmaps[file].insert(chunk)
        persistCounter += 1
        let shouldSave = persistCounter % 8 == 0
        let data = bitmaps[file].data
        let url = bitsURLs[file]
        lock.unlock()
        if shouldSave { try? data.write(to: url) }
    }

    func syncAll() {
        lock.lock()
        let pairs = zip(bitmaps, bitsURLs).map { ($0.0.data, $0.1) }
        lock.unlock()
        for (data, url) in pairs { try? data.write(to: url) }
    }
}

actor WorkQueue {
    private var jobs: [(file: Int, chunk: Int)] = []
    private var i = 0
    func add(_ file: Int, _ chunk: Int) { jobs.append((file, chunk)) }
    func next() -> (file: Int, chunk: Int)? {
        guard i < jobs.count else { return nil }
        defer { i += 1 }
        return jobs[i]
    }
    var count: Int { jobs.count }
}

actor SpeedMeter {
    private var windowStart = Date()
    private var windowBytes: UInt64 = 0
    private var ema: Double = 0

    func add(_ n: UInt64) -> Double {
        windowBytes += n
        let dt = Date().timeIntervalSince(windowStart)
        if dt >= 0.35 {
            let inst = Double(windowBytes) / max(dt, 0.001)
            ema = ema == 0 ? inst : ema * 0.65 + inst * 0.35
            windowBytes = 0
            windowStart = Date()
        }
        return ema
    }
}
