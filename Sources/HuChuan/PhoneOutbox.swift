import Foundation
import HuChuanCore

struct PhoneJob {
    let sessionId: String
    let title: String
    let size: UInt64
    let count: Int
    let localPath: String
}

struct PhoneOutFile {
    let id: String
    let sessionId: String
    let name: String
    let path: URL
    let size: UInt64
    let tempZip: Bool
    var fromId: String = ""
}

final class PhoneOutbox: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [PhoneOutFile] = []
    private var texts: [(id: String, text: String)] = []
    private var notified = Set<String>()

    func enqueue(urls: [URL]) throws -> PhoneJob {
        let scanned = try FileScanner.collect(urls: urls)
        let sessionId = UUID().uuidString
        if scanned.count == 1 {
            let one = scanned[0]
            let item = PhoneOutFile(
                id: UUID().uuidString, sessionId: sessionId,
                name: (one.relative as NSString).lastPathComponent,
                path: one.url, size: one.size, tempZip: false
            )
            lock.lock(); files.append(item); lock.unlock()
            return PhoneJob(sessionId: sessionId, title: item.name, size: one.size, count: 1, localPath: one.url.path)
        }
        let zipURL = try Self.makeZip(scanned)
        let size = UInt64((try? zipURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let name = "互传文件.zip"
        let item = PhoneOutFile(
            id: UUID().uuidString, sessionId: sessionId,
            name: name, path: zipURL, size: size, tempZip: true
        )
        lock.lock(); files.append(item); lock.unlock()
        return PhoneJob(sessionId: sessionId, title: "\(scanned.count) 个文件", size: size, count: scanned.count, localPath: zipURL.path)
    }

    func enqueueSaved(url: URL, from: String) {
        let size = UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let item = PhoneOutFile(
            id: UUID().uuidString, sessionId: "",
            name: url.lastPathComponent, path: url, size: size, tempZip: false, fromId: from
        )
        lock.lock()
        files.append(item)
        let dropped: [PhoneOutFile]
        if files.count > 40 {
            dropped = Array(files.prefix(files.count - 40))
            files = Array(files.suffix(40))
        } else {
            dropped = []
        }
        lock.unlock()
        for old in dropped where old.tempZip {
            try? FileManager.default.removeItem(at: old.path)
        }
    }

    func enqueueText(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        lock.lock()
        texts.append((UUID().uuidString, t))
        if texts.count > 50 { texts.removeFirst(texts.count - 50) }
        lock.unlock()
    }

    func snapshot(excluding from: String = "") -> (files: [PhoneOutFile], texts: [(id: String, text: String)]) {
        lock.lock(); defer { lock.unlock() }
        if from.isEmpty {
            return (files, texts)
        }
        return (files.filter { $0.fromId != from }, texts)
    }

    func file(id: String) -> PhoneOutFile? {
        lock.lock(); defer { lock.unlock() }
        return files.first(where: { $0.id == id })
    }

    func markDownloaded(_ id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let item = files.first(where: { $0.id == id }) else { return nil }
        if !item.fromId.isEmpty { return nil }
        if notified.contains(id) { return nil }
        notified.insert(id)
        return item.sessionId
    }

    func cancel(session: String) {
        lock.lock()
        let removed = files.filter { $0.sessionId == session }
        files.removeAll { $0.sessionId == session }
        lock.unlock()
        for item in removed where item.tempZip {
            try? FileManager.default.removeItem(at: item.path)
        }
    }

    private static func makeZip(_ files: [(url: URL, relative: String, size: UInt64, modified: TimeInterval)]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("huchuan-out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for file in files {
            let dest = PathGuard.uniquePath(in: root, relative: file.relative)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try FileManager.default.linkItem(at: file.url, to: dest)
            } catch {
                try FileManager.default.copyItem(at: file.url, to: dest)
            }
        }
        let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent("互传文件-\(UUID().uuidString.prefix(8)).zip")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proc.arguments = ["-q", "-r", zipURL.path, "."]
        proc.currentDirectoryURL = root
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            throw AppError.message("打包到手机失败")
        }
        return zipURL
    }
}
