import Foundation
import HuChuanCore

enum AppError: Error, LocalizedError, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case .message(let s): return s
        }
    }
    var errorDescription: String? { description }
}

final class RandomAccessFile: @unchecked Sendable {
    let path: String
    private let fd: Int32
    let size: UInt64

    init(reading path: String) throws {
        self.path = path
        fd = open(path, O_RDONLY)
        if fd < 0 { throw AppError.message("无法打开文件：\(path)") }
        var st = stat()
        if fstat(fd, &st) != 0 {
            close(fd)
            throw AppError.message("无法读取文件大小")
        }
        size = UInt64(st.st_size)
    }

    init(writing path: String, size: UInt64) throws {
        self.path = path
        let folder = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        fd = open(path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        if fd < 0 { throw AppError.message("无法创建文件：\(path)") }
        var store = fstore_t(
            fst_flags: UInt32(F_ALLOCATECONTIG),
            fst_posmode: Int32(F_PEOFPOSMODE),
            fst_offset: 0,
            fst_length: off_t(size),
            fst_bytesalloc: 0
        )
        _ = fcntl(fd, F_PREALLOCATE, &store)
        store.fst_flags = UInt32(F_ALLOCATEALL)
        _ = fcntl(fd, F_PREALLOCATE, &store)
        if ftruncate(fd, off_t(size)) != 0 {
            close(fd)
            throw AppError.message("磁盘空间不足，无法预分配 \(ByteFormat.size(size))")
        }
        self.size = size
    }

    func read(offset: UInt64, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var buffer = Data(count: count)
        let got = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return pread(fd, base, count, off_t(offset))
        }
        if got < 0 { throw AppError.message("读文件失败") }
        if got < count { buffer.removeSubrange(got..<count) }
        return buffer
    }

    func write(offset: UInt64, data: Data) throws {
        if data.isEmpty { return }
        let put = data.withUnsafeBytes { raw -> Int in
            pwrite(fd, raw.baseAddress, data.count, off_t(offset))
        }
        if put != data.count { throw AppError.message("写文件失败") }
    }

    func sync() {
        fsync(fd)
    }

    deinit {
        close(fd)
    }
}

enum FileScanner {
    static func collect(urls: [URL]) throws -> [(url: URL, relative: String, size: UInt64, modified: TimeInterval)] {
        var out: [(URL, String, UInt64, TimeInterval)] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            let path = url.path
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                let root = url.standardizedFileURL
                for case let fileURL as URL in enumerator {
                    let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
                    guard values.isRegularFile == true else { continue }
                    let rel = relativePath(fileURL, under: root)
                    guard let clean = PathGuard.sanitizeRelativePath(root.lastPathComponent + "/" + rel) else { continue }
                    let size = UInt64(values.fileSize ?? 0)
                    let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                    out.append((fileURL, clean, size, mtime))
                }
            } else {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let name = PathGuard.sanitizeFileName(url.lastPathComponent)
                let size = UInt64(values.fileSize ?? 0)
                let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                out.append((url, name, size, mtime))
            }
        }
        if out.isEmpty { throw AppError.message("没有可发送的文件") }
        if out.count > 20_000 { throw AppError.message("一次最多发送 2 万个文件，请拆开再传") }
        return out
    }

    private static func relativePath(_ file: URL, under root: URL) -> String {
        let filePath = file.standardizedFileURL.path
        let rootPath = root.path
        if filePath.hasPrefix(rootPath) {
            var rel = String(filePath.dropFirst(rootPath.count))
            if rel.hasPrefix("/") { rel.removeFirst() }
            return rel
        }
        return file.lastPathComponent
    }
}
