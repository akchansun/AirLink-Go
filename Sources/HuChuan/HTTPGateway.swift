import Foundation
import Network
import AppKit
import HuChuanCore

final class HTTPGateway: @unchecked Sendable {
    private var listener: NWListener?
    private let settings: SettingsStore
    private let queue = DispatchQueue(label: "huchuan.http")
    private let lock = NSLock()
    private var cachedName = "互传"
    private var cachedFolder = URL(fileURLWithPath: NSHomeDirectory())
    private(set) var lastSavedPath: String?
    private(set) var isListening = false
    var onFileSaved: ((URL) -> Void)?
    var onPhonePing: ((String, Bool) -> Void)?
    var onPhoneDownloaded: ((String) -> Void)?
    let outbox = PhoneOutbox()
    let booth = BoothHub()
    private var idleWork: [ObjectIdentifier: DispatchWorkItem] = [:]
    private var finishedConns: Set<ObjectIdentifier> = []
    private var uploadFrom: [String: String] = [:]
    private var boothUpload: [String: String] = [:]
    var onBoothSaved: ((URL) -> Void)?

    init(settings: SettingsStore) {
        self.settings = settings
        booth.receiveFolder = { [weak self] in
            guard let self else { return URL(fileURLWithPath: NSHomeDirectory()) }
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.cachedFolder
        }
    }

    @MainActor
    func start() {
        stop()
        lock.lock()
        cachedName = settings.deviceName
        cachedFolder = settings.receiveFolder
        lock.unlock()
        let port = Ports.http(settings.port)
        do {
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            listener.newConnectionHandler = { [weak self] conn in
                self?.serve(conn)
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state { self?.isListening = true }
                if case .failed = state { self?.isListening = false }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            NSLog("网页通道启动失败：\(error.localizedDescription)")
        }
    }

    func stop() {
        isListening = false
        listener?.cancel()
        listener = nil
    }

    func waitUntilListening(timeout: TimeInterval = 4) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isListening { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw AppError.message("网页通道没有启动")
    }

    private func serve(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveHeader(conn, buffer: Data())
    }

    private func pingPhone(_ conn: NWConnection, pair: Bool) {
        let host = clientHost(conn)
        DispatchQueue.main.async { [weak self] in self?.onPhonePing?(host, pair) }
    }

    private func clientHost(_ conn: NWConnection) -> String {
        let endpoint = conn.currentPath?.remoteEndpoint ?? conn.endpoint
        guard case .hostPort(let host, _) = endpoint else { return "手机" }
        var raw = "\(host)"
        if let pct = raw.firstIndex(of: "%") {
            raw = String(raw[..<pct])
        }
        if raw.hasPrefix("::ffff:") {
            raw = String(raw.dropFirst(7))
        }
        return PhoneIP.normalize(raw)
    }

    private func receiveHeader(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if error != nil || (complete && data == nil) {
                conn.cancel()
                return
            }
            var buf = buffer
            if let data { buf.append(data) }
            guard let range = buf.range(of: Data("\r\n\r\n".utf8)) else {
                if buf.count > 1024 * 1024 { conn.cancel(); return }
                self.receiveHeader(conn, buffer: buf)
                return
            }
            let headerData = buf.subdata(in: 0..<range.lowerBound)
            let extra = buf.subdata(in: range.upperBound..<buf.count)
            let headerText = String(data: headerData, encoding: .utf8) ?? ""
            self.handle(conn: conn, header: headerText, leftover: extra)
        }
    }

    private func handle(conn: NWConnection, header: String, leftover: Data) {
        let lines = header.split(whereSeparator: { $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let first = lines.first else { conn.cancel(); return }
        let parts = first.split(separator: " ")
        let method = parts.first.map(String.init) ?? "GET"
        let path = parts.count > 1 ? String(parts[1]) : "/"
        let route = path.split(separator: "?").first.map(String.init) ?? path
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[k] = v
            }
        }
        if method == "OPTIONS" {
            reply(conn, status: "204 No Content", contentType: "text/plain; charset=utf-8", body: Data())
            return
        }
        if method == "GET" && (route == "/" || route.hasPrefix("/index")) {
            pingPhone(conn, pair: true)
            reply(conn, status: "200 OK", contentType: "text/html; charset=utf-8", body: Data(Self.html.utf8))
            return
        }
        if method == "GET" && path.split(separator: "?").first == "/api/outbox" {
            pingPhone(conn, pair: false)
            let from = (Self.queryValue(path, key: "from") ?? "").removingPercentEncoding ?? Self.queryValue(path, key: "from") ?? ""
            reply(conn, status: "200 OK", contentType: "application/json; charset=utf-8", body: Data(outboxJSON(excluding: from).utf8))
            return
        }
        if (method == "GET" || method == "HEAD") && (route == "/download" || route.hasPrefix("/file/")) {
            var id = Self.queryValue(path, key: "id") ?? ""
            if id.isEmpty, route.hasPrefix("/file/") {
                let rest = String(route.dropFirst("/file/".count))
                id = rest.split(separator: "/").first.map(String.init) ?? ""
            }
            id = id.removingPercentEncoding ?? id
            guard let item = outbox.file(id: id) else {
                reply(conn, status: "404 Not Found", contentType: "text/plain; charset=utf-8", body: Data("找不到文件".utf8))
                return
            }
            let attach = Self.queryValue(path, key: "save") == "1"
            replyFile(conn: conn, item: item, headOnly: method == "HEAD", attach: attach)
            return
        }
        if method == "GET" && route == "/api/info" {
            pingPhone(conn, pair: true)
            lock.lock()
            let name = cachedName
            lock.unlock()
            let json = "{\"name\":\"\(Self.escape(name))\"}"
            reply(conn, status: "200 OK", contentType: "application/json; charset=utf-8", body: Data(json.utf8))
            return
        }
        if method == "POST" && path.split(separator: "?").first == "/upload" {
            pingPhone(conn, pair: true)
            let fromQuery = Self.queryValue(path, key: "name")
            let rawName = fromQuery ?? headers["x-file-name"] ?? "未命名文件"
            let decoded = rawName.removingPercentEncoding ?? rawName
            let safe = PathGuard.sanitizeRelativePath(decoded) ?? PathGuard.sanitizeFileName(decoded)
            lock.lock()
            let folder = cachedFolder
            lock.unlock()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let dest = PathGuard.uniquePath(in: folder, relative: safe)
            lock.lock()
            uploadFrom[dest.path] = (Self.queryValue(path, key: "from") ?? "").removingPercentEncoding ?? Self.queryValue(path, key: "from") ?? ""
            lock.unlock()
            let chunked = (headers["transfer-encoding"] ?? "").lowercased().contains("chunked")
            let expectContinue = (headers["expect"] ?? "").lowercased().contains("100-continue")
            let length = headers["content-length"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            let begin = { [weak self] in
                guard let self else { return }
                if chunked {
                    self.receiveChunked(conn: conn, leftover: leftover, dest: dest)
                } else if let length {
                    self.receiveBody(conn: conn, leftover: leftover, remaining: max(0, length - leftover.count), dest: dest, first: leftover)
                } else {
                    self.receiveUntilClose(conn: conn, dest: dest, first: leftover)
                }
            }
            if expectContinue && leftover.isEmpty {
                sendContinue(conn)
            }
            begin()
            return
        }
        if handleBooth(conn: conn, method: method, path: path, route: route, headers: headers, leftover: leftover) {
            return
        }
        reply(conn, status: "404 Not Found", contentType: "text/plain; charset=utf-8", body: Data("找不到页面".utf8))
    }

    private func handleBooth(conn: NWConnection, method: String, path: String, route: String, headers: [String: String], leftover: Data) -> Bool {
        if method == "GET" && route.hasPrefix("/b/") {
            let rest = String(route.dropFirst(3))
            let parts = rest.split(separator: "/").map(String.init)
            if parts.count == 1 {
                reply(conn, status: "200 OK", contentType: "text/html; charset=utf-8", body: Data(BoothHub.pageHTML.utf8))
                return true
            }
        }
        if method == "POST" && route.hasPrefix("/b/") && route.hasSuffix("/upload") {
            let rest = String(route.dropFirst(3).dropLast("/upload".count))
            let id = rest.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let pin = Self.queryValue(path, key: "p") ?? ""
            guard booth.info(id: id, pin: pin) != nil else {
                reply(conn, status: "400 Bad Request", contentType: "text/plain; charset=utf-8", body: Data("这个码已经作废".utf8))
                return true
            }
            let fromQuery = Self.queryValue(path, key: "name")
            let rawName = fromQuery ?? headers["x-file-name"] ?? "未命名文件"
            let decoded = rawName.removingPercentEncoding ?? rawName
            let safe = PathGuard.sanitizeRelativePath(decoded) ?? PathGuard.sanitizeFileName(decoded)
            lock.lock()
            let folder = cachedFolder
            lock.unlock()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let dest = PathGuard.uniquePath(in: folder, relative: safe)
            lock.lock()
            boothUpload[dest.path] = id
            lock.unlock()
            let chunked = (headers["transfer-encoding"] ?? "").lowercased().contains("chunked")
            let expectContinue = (headers["expect"] ?? "").lowercased().contains("100-continue")
            let length = headers["content-length"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            let begin = { [weak self] in
                guard let self else { return }
                if chunked {
                    self.receiveChunked(conn: conn, leftover: leftover, dest: dest)
                } else if let length {
                    self.receiveBody(conn: conn, leftover: leftover, remaining: max(0, length - leftover.count), dest: dest, first: leftover)
                } else {
                    self.receiveUntilClose(conn: conn, dest: dest, first: leftover)
                }
            }
            if expectContinue && leftover.isEmpty {
                sendContinue(conn)
            }
            begin()
            return true
        }
        if method == "GET" && route.hasPrefix("/api/booth/") {
            let rest = String(route.dropFirst("/api/booth/".count))
            let parts = rest.split(separator: "/").map(String.init)
            if parts.count >= 2 && parts[1] == "info" {
                let pin = Self.queryValue(path, key: "p") ?? ""
                if let name = booth.info(id: parts[0], pin: pin) {
                    reply(conn, status: "200 OK", contentType: "application/json; charset=utf-8", body: Data("{\"ok\":true,\"name\":\"\(Self.escape(name))\"}".utf8))
                } else {
                    reply(conn, status: "200 OK", contentType: "application/json; charset=utf-8", body: Data("{\"ok\":false,\"error\":\"这个码已经作废\"}".utf8))
                }
                return true
            }
        }
        if method == "POST" && route == "/api/booth/open" {
            lock.lock()
            let name = cachedName
            lock.unlock()
            // 店铺电脑自己开门走 StoreBooth，这里留给远程中转；本机网页不需要
            reply(conn, status: "404 Not Found", contentType: "text/plain; charset=utf-8", body: Data("请在电脑上点门店码".utf8))
            _ = name
            return true
        }
        return false
    }

    private func sendContinue(_ conn: NWConnection) {
        let data = Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)
        conn.send(content: data, completion: .contentProcessed { _ in })
    }

    private func connID(_ conn: NWConnection) -> ObjectIdentifier { ObjectIdentifier(conn) }

    private func armIdle(conn: NWConnection, handle: FileHandle, dest: URL, seconds: Double) {
        let id = connID(conn)
        idleWork[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.completeUpload(conn: conn, handle: handle, dest: dest)
        }
        idleWork[id] = work
        queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func completeUpload(conn: NWConnection, handle: FileHandle?, dest: URL) {
        let id = connID(conn)
        idleWork[id]?.cancel()
        idleWork[id] = nil
        guard !finishedConns.contains(id) else { return }
        finishedConns.insert(id)
        try? handle?.synchronize()
        try? handle?.close()
        finishUpload(conn: conn, dest: dest)
    }

    private func failUpload(conn: NWConnection, handle: FileHandle?, dest: URL) {
        let id = connID(conn)
        idleWork[id]?.cancel()
        idleWork[id] = nil
        try? handle?.close()
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.intValue ?? 0
        if size > 0 {
            completeUpload(conn: conn, handle: nil, dest: dest)
            return
        }
        try? FileManager.default.removeItem(at: dest)
        finishedConns.insert(id)
        conn.cancel()
    }

    private func receiveUntilClose(conn: NWConnection, dest: URL, first: Data) {
        do {
            FileManager.default.createFile(atPath: dest.path, contents: nil)
            lastSavedPath = dest.path
            let handle = try FileHandle(forWritingTo: dest)
            if !first.isEmpty { try handle.write(contentsOf: first) }
            armIdle(conn: conn, handle: handle, dest: dest, seconds: first.isEmpty ? 20 : 4)
            readUntilClose(conn: conn, handle: handle, dest: dest)
        } catch {
            reply(conn, status: "500 Internal Server Error", contentType: "text/plain; charset=utf-8", body: Data("保存失败".utf8))
        }
    }

    private func readUntilClose(conn: NWConnection, handle: FileHandle, dest: URL) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if self.finishedConns.contains(self.connID(conn)) { return }
            if let error {
                self.failUpload(conn: conn, handle: handle, dest: dest)
                _ = error
                return
            }
            do {
                if let data, !data.isEmpty { try handle.write(contentsOf: data) }
                if complete {
                    self.completeUpload(conn: conn, handle: handle, dest: dest)
                    return
                }
                self.armIdle(conn: conn, handle: handle, dest: dest, seconds: 4)
                self.readUntilClose(conn: conn, handle: handle, dest: dest)
            } catch {
                self.failUpload(conn: conn, handle: handle, dest: dest)
            }
        }
    }

    private func receiveBody(conn: NWConnection, leftover: Data, remaining: Int, dest: URL, first: Data) {
        do {
            FileManager.default.createFile(atPath: dest.path, contents: nil)
            lastSavedPath = dest.path
            let handle = try FileHandle(forWritingTo: dest)
            if !first.isEmpty { try handle.write(contentsOf: first) }
            if remaining <= 0 {
                completeUpload(conn: conn, handle: handle, dest: dest)
                return
            }
            armIdle(conn: conn, handle: handle, dest: dest, seconds: leftover.isEmpty ? 20 : 4)
            readMore(conn: conn, handle: handle, remaining: remaining, dest: dest)
        } catch {
            reply(conn, status: "500 Internal Server Error", contentType: "text/plain; charset=utf-8", body: Data("保存失败".utf8))
        }
    }

    private func readMore(conn: NWConnection, handle: FileHandle, remaining: Int, dest: URL) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: min(max(remaining, 1), 256 * 1024)) { [weak self] data, _, complete, error in
            guard let self else { return }
            if self.finishedConns.contains(self.connID(conn)) { return }
            if let error {
                self.failUpload(conn: conn, handle: handle, dest: dest)
                _ = error
                return
            }
            let chunk = data ?? Data()
            do {
                if !chunk.isEmpty { try handle.write(contentsOf: chunk) }
                let left = remaining - chunk.count
                if left <= 0 || complete {
                    self.completeUpload(conn: conn, handle: handle, dest: dest)
                    return
                }
                self.armIdle(conn: conn, handle: handle, dest: dest, seconds: 4)
                self.readMore(conn: conn, handle: handle, remaining: left, dest: dest)
            } catch {
                self.failUpload(conn: conn, handle: handle, dest: dest)
            }
        }
    }

    private func receiveChunked(conn: NWConnection, leftover: Data, dest: URL) {
        do {
            FileManager.default.createFile(atPath: dest.path, contents: nil)
            lastSavedPath = dest.path
            let handle = try FileHandle(forWritingTo: dest)
            armIdle(conn: conn, handle: handle, dest: dest, seconds: leftover.isEmpty ? 20 : 4)
            parseChunked(conn: conn, handle: handle, dest: dest, buffer: leftover)
        } catch {
            reply(conn, status: "500 Internal Server Error", contentType: "text/plain; charset=utf-8", body: Data("保存失败".utf8))
        }
    }

    private func parseChunked(conn: NWConnection, handle: FileHandle, dest: URL, buffer: Data) {
        if finishedConns.contains(connID(conn)) { return }
        var buf = buffer
        while true {
            guard let lineEnd = buf.range(of: Data("\r\n".utf8)) else { break }
            let line = String(data: buf.subdata(in: 0..<lineEnd.lowerBound), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let hex = line.split(separator: ";", maxSplits: 1).first.map(String.init) ?? line
            guard let size = Int(hex, radix: 16) else {
                failUpload(conn: conn, handle: handle, dest: dest)
                return
            }
            if size == 0 {
                completeUpload(conn: conn, handle: handle, dest: dest)
                return
            }
            let dataStart = lineEnd.upperBound
            let need = dataStart + size + 2
            if buf.count < need { break }
            let payload = buf.subdata(in: dataStart..<(dataStart + size))
            do {
                try handle.write(contentsOf: payload)
            } catch {
                failUpload(conn: conn, handle: handle, dest: dest)
                return
            }
            buf.removeSubrange(0..<need)
        }
        let pending = buf
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if self.finishedConns.contains(self.connID(conn)) { return }
            if let error {
                self.failUpload(conn: conn, handle: handle, dest: dest)
                _ = error
                return
            }
            var next = pending
            if let data, !data.isEmpty { next.append(data) }
            if complete && (data == nil || data?.isEmpty == true) && next == pending {
                self.completeUpload(conn: conn, handle: handle, dest: dest)
                return
            }
            self.armIdle(conn: conn, handle: handle, dest: dest, seconds: 4)
            self.parseChunked(conn: conn, handle: handle, dest: dest, buffer: next)
        }
    }

    private func finishUpload(conn: NWConnection, dest: URL) {
        lastSavedPath = dest.path
        lock.lock()
        let from = uploadFrom.removeValue(forKey: dest.path) ?? ""
        let boothId = boothUpload.removeValue(forKey: dest.path)
        lock.unlock()
        if let boothId {
            booth.noteLocalFile(id: boothId, url: dest)
            let saved = dest
            if let hook = onBoothSaved {
                DispatchQueue.main.async { hook(saved) }
            } else if let hook = onFileSaved {
                DispatchQueue.main.async { hook(saved) }
            }
            reply(conn, status: "200 OK", contentType: "application/json", body: Data("{\"ok\":true,\"isComplete\":true}".utf8))
            return
        }
        outbox.enqueueSaved(url: dest, from: from)
        let saved = dest
        if let hook = onFileSaved {
            DispatchQueue.main.async { hook(saved) }
        }
        reply(conn, status: "200 OK", contentType: "application/json", body: Data("{\"ok\":true,\"isComplete\":true}".utf8))
    }

    private func reply(_ conn: NWConnection, status: String, contentType: String, body: Data) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        head += "Cache-Control: no-store, no-cache, must-revalidate\r\n"
        head += "Pragma: no-cache\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        head += "Access-Control-Allow-Headers: Content-Type, X-File-Name\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        conn.send(content: data, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.queue.asyncAfter(deadline: .now() + 0.8) {
                conn.cancel()
                if let self {
                    let id = self.connID(conn)
                    self.idleWork[id]?.cancel()
                    self.idleWork[id] = nil
                    self.finishedConns.remove(id)
                }
            }
        })
    }

    private func outboxJSON(excluding from: String = "") -> String {
        let snap = outbox.snapshot(excluding: from)
        var files = "["
        for (i, f) in snap.files.enumerated() {
            if i > 0 { files += "," }
            let phone = f.fromId.isEmpty ? "false" : "true"
            files += "{\"id\":\"\(Self.escape(f.id))\",\"name\":\"\(Self.escape(f.name))\",\"size\":\(f.size),\"phone\":\(phone)}"
        }
        files += "]"
        var msgs = "["
        for (i, m) in snap.texts.enumerated() {
            if i > 0 { msgs += "," }
            msgs += "{\"id\":\"\(Self.escape(m.id))\",\"text\":\"\(Self.escape(m.text))\"}"
        }
        msgs += "]"
        return "{\"files\":\(files),\"messages\":\(msgs)}"
    }

    private func replyFile(conn: NWConnection, item: PhoneOutFile, headOnly: Bool, attach: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: item.path) else {
            reply(conn, status: "404 Not Found", contentType: "text/plain; charset=utf-8", body: Data("找不到文件".utf8))
            return
        }
        let size = UInt64((try? FileManager.default.attributesOfItem(atPath: item.path.path)[.size] as? NSNumber)?.uint64Value ?? item.size)
        try? handle.seek(toOffset: 0)
        let mime = Self.mimeType(for: item.name)
        let inline = !attach && Self.isInline(mime)
        let encoded = item.name.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? item.name
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: \(mime)\r\n"
        head += "Content-Length: \(size)\r\n"
        head += "Content-Disposition: \(inline ? "inline" : "attachment"); filename*=UTF-8''\(encoded)\r\n"
        head += "Cache-Control: no-store, no-cache, must-revalidate\r\n"
        head += "Pragma: no-cache\r\n"
        head += "Connection: close\r\n"
        head += "Access-Control-Allow-Origin: *\r\n\r\n"
        if headOnly {
            try? handle.close()
            conn.send(content: Data(head.utf8), contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { _ in
                conn.cancel()
            })
            return
        }
        conn.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] _ in
            self?.streamFile(conn: conn, handle: handle, left: size, sessionId: item.sessionId, downloadId: item.id)
        })
    }

    private static func mimeType(for name: String) -> String {
        switch URL(fileURLWithPath: name).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic", "heif": return "image/heic"
        case "bmp": return "image/bmp"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "webm": return "video/webm"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "wav": return "audio/wav"
        case "aac": return "audio/aac"
        case "pdf": return "application/pdf"
        case "zip": return "application/zip"
        case "rar": return "application/vnd.rar"
        case "7z": return "application/x-7z-compressed"
        case "doc": return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls": return "application/vnd.ms-excel"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "ppt": return "application/vnd.ms-powerpoint"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "txt", "csv": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }

    private static func isInline(_ mime: String) -> Bool {
        mime.hasPrefix("image/") || mime.hasPrefix("video/") || mime.hasPrefix("audio/") || mime == "application/pdf"
    }

    private func streamFile(conn: NWConnection, handle: FileHandle, left: UInt64, sessionId: String, downloadId: String) {
        if left == 0 {
            try? handle.close()
            if let sid = outbox.markDownloaded(downloadId) {
                DispatchQueue.main.async { [weak self] in self?.onPhoneDownloaded?(sid) }
            }
            conn.send(content: nil, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { _ in
                conn.cancel()
            })
            return
        }
        let chunk = min(left, 256 * 1024)
        let data = (try? handle.read(upToCount: Int(chunk))) ?? Data()
        if data.isEmpty {
            streamFile(conn: conn, handle: handle, left: 0, sessionId: sessionId, downloadId: downloadId)
            return
        }
        conn.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil {
                try? handle.close()
                conn.cancel()
                return
            }
            self?.streamFile(conn: conn, handle: handle, left: left - UInt64(data.count), sessionId: sessionId, downloadId: downloadId)
        })
    }

    private static func queryValue(_ path: String, key: String) -> String? {
        guard let q = path.split(separator: "?", maxSplits: 1).dropFirst().first else { return nil }
        for part in q.split(separator: "&") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == key { return String(kv[1]) }
        }
        return nil
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static let html = """
    <!doctype html>
    <html lang="zh-CN">
    <head>
    <meta charset="utf-8"/>
    <meta name="viewport" content="width=device-width,initial-scale=1"/>
    <meta http-equiv="Cache-Control" content="no-store"/>
    <title>互传</title>
    <style>
      :root { --bg:#f6f1ea; --ink:#1a1814; --accent:#3d7a6a; --hot:#c4502a; --card:#fffdf8; }
      * { box-sizing:border-box; }
      body { margin:0; font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif; background:var(--bg); color:var(--ink); }
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
    function sendFiles(files){
      [...files].forEach(file => upload(file));
    }
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
      xhr.open('POST', '/upload?name=' + encodeURIComponent(name) + '&from=' + encodeURIComponent(phoneId));
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
    </body></html>
    """
}
