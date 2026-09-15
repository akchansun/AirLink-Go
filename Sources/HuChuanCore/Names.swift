import Foundation

public enum PathGuard {
    public static func sanitizeRelativePath(_ raw: String) -> String? {
        let unified = raw.replacingOccurrences(of: "\\", with: "/")
        let parts = unified.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return nil }
        var clean: [String] = []
        for part in parts {
            if part.isEmpty || part == "." { continue }
            if part == ".." { return nil }
            if part.hasPrefix(".") && (part == ".DS_Store" || part == "Thumbs.db") { return nil }
            let trimmed = sanitizeFileName(part)
            if trimmed.isEmpty { return nil }
            clean.append(trimmed)
        }
        guard !clean.isEmpty else { return nil }
        return clean.joined(separator: "/")
    }

    public static func sanitizeFileName(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        s = s.components(separatedBy: banned).joined(separator: "_")
        if s == "." || s == ".." { s = "_" }
        if s.isEmpty { s = "未命名" }
        if s.count > 180 { s = String(s.prefix(180)) }
        return s
    }

    public static func uniquePath(in directory: URL, relative: String) -> URL {
        var dest = directory
        for part in relative.split(separator: "/") where !part.isEmpty {
            dest.appendPathComponent(String(part))
        }
        let folder = dest.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: dest.path) {
            return dest
        }
        let ext = dest.pathExtension
        let base = dest.deletingPathExtension().lastPathComponent
        let parent = dest.deletingLastPathComponent()
        for i in 1...9999 {
            let name = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            let candidate = parent.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return parent.appendingPathComponent("\(base)-\(UUID().uuidString).\(ext)")
    }
}

public enum MeetCode {
    public static func of(_ a: String, _ b: String) -> String {
        let pair = [a, b].sorted().joined(separator: "|")
        var hash: UInt32 = 2_166_132_261
        for byte in pair.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return String(format: "%04d", Int(hash % 10_000))
    }
}

public enum ByteFormat {
    public static func size(_ n: UInt64) -> String {
        Double(n).asBytes
    }

    public static func speed(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond < 1 { return "0 B/s" }
        return bytesPerSecond.asBytes + "/s"
    }

    public static func eta(remaining: UInt64, speed: Double) -> String {
        guard speed > 1 else { return "计算中" }
        let seconds = Double(remaining) / speed
        if seconds < 60 { return "还剩 \(Int(seconds)) 秒" }
        if seconds < 3600 { return "还剩 \(Int(seconds / 60)) 分 \(Int(seconds) % 60) 秒" }
        let h = Int(seconds / 3600)
        let m = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)
        return "还剩 \(h) 小时 \(m) 分"
    }
}

private extension Double {
    var asBytes: String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = self
        var idx = 0
        while value >= 1024 && idx < units.count - 1 {
            value /= 1024
            idx += 1
        }
        if idx == 0 { return "\(Int(value)) \(units[idx])" }
        return String(format: "%.1f %@", value, units[idx])
    }
}
