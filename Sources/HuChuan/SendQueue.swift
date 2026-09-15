import Foundation
import HuChuanCore

struct QueuedSend: Equatable {
    var itemId: UUID
    var sessionId: String
    var peerId: String
    var peerName: String
    var host: String
    var port: UInt16
    var paths: [String]
    var text: String
    var title: String
    var total: UInt64
    var fileCount: Int
    var lastAttempt: Date = .distantPast
}

private struct QueuedSendDisk: Codable {
    var itemId: String
    var sessionId: String
    var peerId: String
    var peerName: String
    var host: String
    var port: UInt16
    var paths: [String]
    var text: String
    var title: String
    var total: UInt64
    var fileCount: Int
}

enum SendReachability {
    static let resumeHint = "网络中断，会自动接着传（已传过的部分会跳过）"

    static func isUnreachable(_ error: Error) -> Bool {
        let s = ((error as? AppError)?.description ?? "") + " " + error.localizedDescription + " " + String(describing: error)
        if s.contains("分块多次校验失败") || s.contains("对方还是旧版") ||
            s.contains("协议不匹配") || s.contains("对方拒绝") ||
            s.contains("连接已取消") || s.contains("已取消") {
            return false
        }
        let keys = [
            "连接超时", "连不上", "连接已断开", "等待数据超时", "等待超时", "数据通道",
            "握手失败", "对方没有回应", "Connection refused", "Could not connect",
            "couldn't connect", "Network is unreachable", "No route to host",
            "Host is down", "Socket is not connected", "Broken pipe",
            "Connection reset", "Software caused connection abort",
            "POSIXErrorCode(61)", "POSIXErrorCode(60)", "POSIXErrorCode(54)",
            "POSIXErrorCode(32)", "POSIXErrorCode(57)", "POSIXErrorCode(51)",
            "POSIXErrorCode(65)", "POSIXErrorCode(50)",
        ]
        return keys.contains { s.localizedCaseInsensitiveContains($0) }
    }
}

enum SendQueueFile {
    static func url() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let folder = dir.appendingPathComponent("互传", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("send-queue.json")
    }

    static func load() -> [QueuedSend] {
        guard let data = try? Data(contentsOf: url()),
              let list = try? JSONDecoder().decode([QueuedSendDisk].self, from: data) else {
            return []
        }
        return list.compactMap { row in
            guard let id = UUID(uuidString: row.itemId) else { return nil }
            return QueuedSend(
                itemId: id, sessionId: row.sessionId, peerId: row.peerId, peerName: row.peerName,
                host: row.host, port: row.port, paths: row.paths, text: row.text,
                title: row.title, total: row.total, fileCount: row.fileCount
            )
        }
    }

    static func save(_ items: [QueuedSend]) {
        let rows = items.map {
            QueuedSendDisk(
                itemId: $0.itemId.uuidString, sessionId: $0.sessionId, peerId: $0.peerId,
                peerName: $0.peerName, host: $0.host, port: $0.port, paths: $0.paths,
                text: $0.text, title: $0.title, total: $0.total, fileCount: $0.fileCount
            )
        }
        guard let data = try? JSONEncoder().encode(rows) else { return }
        try? data.write(to: url(), options: .atomic)
    }
}

extension TransferCenter {
    var persistSendQueue: Bool {
        settings.deviceName != "自检接收端" && !CommandLine.arguments.contains("--selftest")
    }

    func canQueue(_ peer: PeerDevice) -> Bool {
        peer.id != "phone-web" && !peer.id.isEmpty
    }

    func shouldQueue(_ peer: PeerDevice) -> Bool {
        var p = peer
        p.refreshOnline()
        return canQueue(p) && !p.online
    }

    func configureSender(deviceId: String, deviceName: String) {
        senderId = deviceId
        senderName = deviceName
    }

    func startRetryTimer() {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.flushPending()
            }
        }
    }

    func restoreQueue() {
        guard persistSendQueue else { return }
        sendQueue = SendQueueFile.load()
        for job in sendQueue {
            if items.contains(where: { $0.id == job.itemId }) { continue }
            add(TransferItem(
                id: job.itemId, sessionId: job.sessionId, direction: .send, peerName: job.peerName,
                title: job.title, total: job.total, done: 0, speed: 0, state: .waitingPeer,
                detail: SendReachability.resumeHint, fileCount: job.fileCount,
                localPath: job.paths.first
            ))
        }
    }

    func enqueue(_ job: QueuedSend) {
        if let idx = sendQueue.firstIndex(where: { $0.itemId == job.itemId }) {
            sendQueue[idx] = job
        } else {
            sendQueue.append(job)
        }
        persistQueue()
    }

    func dropQueued(itemId: UUID) {
        sendQueue.removeAll { $0.itemId == itemId }
        persistQueue()
    }

    func persistQueue() {
        guard persistSendQueue else { return }
        SendQueueFile.save(sendQueue)
    }

    func flushPending() {
        let ids = Set(sendQueue.map(\.peerId))
        for id in ids {
            guard let peer = resolvedPeer(id: id, fallback: nil) else { continue }
            var live = peer
            live.refreshOnline()
            guard live.online else { continue }
            flush(to: live)
        }
    }

    func flush(to peer: PeerDevice) {
        guard peer.id != "phone-web" else { return }
        guard sendQueue.contains(where: { $0.peerId == peer.id }) else { return }
        guard !flushingPeers.contains(peer.id) else { return }
        flushingPeers.insert(peer.id)
        Task { @MainActor in
            defer { flushingPeers.remove(peer.id) }
            while true {
                guard let job = takeReadyJob(peerId: peer.id) else { break }
                if await flags.isCancelled(job.sessionId) { continue }
                var live = resolvedPeer(id: peer.id, fallback: peer) ?? peer
                live.refreshOnline()
                if !live.online {
                    enqueue(job)
                    break
                }
                await runQueued(job, peer: live)
            }
        }
    }

    private func resolvedPeer(id: String, fallback: PeerDevice?) -> PeerDevice? {
        if let found = livePeer?(id) { return found }
        return fallback
    }

    private func takeReadyJob(peerId: String) -> QueuedSend? {
        let now = Date()
        guard let idx = sendQueue.firstIndex(where: { job in
            job.peerId == peerId && now.timeIntervalSince(job.lastAttempt) >= 20
        }) else { return nil }
        let job = sendQueue.remove(at: idx)
        persistQueue()
        return job
    }

    func runQueued(_ job: QueuedSend, peer: PeerDevice) async {
        if !job.text.isEmpty {
            await deliverText(to: peer, text: job.text, job: job)
            return
        }
        let urls = job.paths.map { URL(fileURLWithPath: $0) }
        let missing = urls.contains { !FileManager.default.fileExists(atPath: $0.path) }
        if missing || urls.isEmpty {
            fail(peerName: job.peerName, message: "文件已经不在了", itemId: job.itemId)
            return
        }
        mutate(job.itemId) { item in
            var item = item
            item.state = .waiting
            item.detail = "正在连接 \(peer.host)"
            return item
        }
        let snap = Snapshot(settings)
        let deviceId = senderId
        let deviceName = senderName
        let cancelFlags = flags
        do {
            let scanned = try await Task.detached {
                try FileScanner.collect(urls: urls)
            }.value
            let files = scanned.enumerated().map {
                FileOffer(index: $0.offset, relativePath: $0.element.relative, size: $0.element.size, modified: $0.element.modified)
            }
            try await Task.detached {
                try await TransferPipes.send(
                    peer: peer, files: files, localURLs: scanned.map(\.url),
                    sessionId: job.sessionId, itemId: job.itemId,
                    deviceId: deviceId, deviceName: deviceName, settings: snap, flags: cancelFlags,
                    onUpdate: { itemId, mutate in
                        await TransferCenter.shared?.mutate(itemId, mutate)
                    }
                )
            }.value
        } catch {
            if await flags.isCancelled(job.sessionId) { return }
            if SendReachability.isUnreachable(error) && canQueue(peer) {
                var again = job
                again.lastAttempt = Date()
                again.host = peer.host
                again.port = peer.port
                enqueue(again)
                mutate(job.itemId) { item in
                    var item = item
                    item.state = .waitingPeer
                    item.detail = SendReachability.resumeHint
                    item.speed = 0
                    return item
                }
                return
            }
            fail(peerName: job.peerName, message: (error as? AppError)?.description ?? error.localizedDescription, itemId: job.itemId)
        }
    }

    func deliverText(to peer: PeerDevice, text: String, job: QueuedSend?) async {
        let port = settings.port
        let pin = settings.pin
        let deviceId = senderId
        let deviceName = senderName
        do {
            try await Task.detached {
                let conn = NetFactory.connect(host: peer.host, port: peer.port)
                try await conn.startAndWait()
                let io = try await WireIO.open(conn, asServer: false)
                try await io.sendJSON(.hello(ControlMessage.Hello(
                    deviceId: deviceId, name: deviceName, port: port,
                    httpPort: Ports.http(port), os: "macOS", appVersion: "1.0.0",
                    pin: pin.isEmpty ? nil : pin
                )))
                _ = try await io.receiveFrame(timeout: 15)
                try await io.sendJSON(.text(ControlMessage.TextPayload(sessionId: UUID().uuidString, body: text)))
                io.cancel()
            }.value
            if let job {
                mutate(job.itemId) { item in
                    var item = item
                    item.state = .completed
                    item.detail = "已发出"
                    item.speed = 0
                    return item
                }
            }
        } catch {
            if let job, await flags.isCancelled(job.sessionId) { return }
            if SendReachability.isUnreachable(error) && canQueue(peer) {
                if var again = job {
                    again.lastAttempt = Date()
                    again.host = peer.host
                    again.port = peer.port
                    enqueue(again)
                    mutate(again.itemId) { item in
                        var item = item
                        item.state = .waitingPeer
                        item.detail = SendReachability.resumeHint
                        return item
                    }
                } else {
                    parkText(to: peer, text: text)
                }
                return
            }
            fail(peerName: peer.name, message: "文字没发出去", itemId: job?.itemId)
        }
    }

    func parkFiles(to peer: PeerDevice, scanned: [(url: URL, relative: String, size: UInt64, modified: TimeInterval)], itemId: UUID, sessionId: String) {
        let files = scanned.enumerated().map {
            FileOffer(index: $0.offset, relativePath: $0.element.relative, size: $0.element.size, modified: $0.element.modified)
        }
        let total = files.reduce(UInt64(0)) { $0 + $1.size }
        let title = files.count == 1 ? files[0].relativePath : "\(files.count) 个文件"
        if !items.contains(where: { $0.id == itemId }) {
            add(TransferItem(
                id: itemId, sessionId: sessionId, direction: .send, peerName: peer.name,
                title: title, total: total, done: 0, speed: 0, state: .waitingPeer,
                detail: SendReachability.resumeHint, fileCount: files.count,
                localPath: scanned.first?.url.path
            ))
        } else {
            mutate(itemId) { item in
                var item = item
                item.state = .waitingPeer
                item.detail = SendReachability.resumeHint
                item.speed = 0
                return item
            }
        }
        enqueue(QueuedSend(
            itemId: itemId, sessionId: sessionId, peerId: peer.id, peerName: peer.name,
            host: peer.host, port: peer.port, paths: scanned.map(\.url.path), text: "",
            title: title, total: total, fileCount: files.count
        ))
    }

    func parkText(to peer: PeerDevice, text: String) {
        let itemId = UUID()
        let sessionId = UUID().uuidString
        let title = text.count > 36 ? String(text.prefix(36)) + "…" : text
        add(TransferItem(
            id: itemId, sessionId: sessionId, direction: .send, peerName: peer.name,
            title: title, total: 0, done: 0, speed: 0, state: .waitingPeer,
            detail: SendReachability.resumeHint, fileCount: 0
        ))
        enqueue(QueuedSend(
            itemId: itemId, sessionId: sessionId, peerId: peer.id, peerName: peer.name,
            host: peer.host, port: peer.port, paths: [], text: text,
            title: title, total: 0, fileCount: 0
        ))
    }
}
