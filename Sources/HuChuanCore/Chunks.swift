import Foundation

public struct ChunkPlan: Equatable, Sendable {
    public let fileSize: UInt64
    public let chunkSize: UInt32

    public init(fileSize: UInt64, chunkSize: UInt32) {
        self.fileSize = fileSize
        self.chunkSize = max(chunkSize, 1)
    }

    public var chunkCount: Int {
        if fileSize == 0 { return 1 }
        return Int((fileSize + UInt64(chunkSize) - 1) / UInt64(chunkSize))
    }

    public func byteRange(for index: Int) -> Range<UInt64> {
        let start = UInt64(index) * UInt64(chunkSize)
        let end = min(start + UInt64(chunkSize), fileSize)
        return start..<end
    }

    public func length(for index: Int) -> Int {
        let r = byteRange(for: index)
        return Int(r.upperBound - r.lowerBound)
    }

    public static func plan(fileSize: UInt64) -> ChunkPlan {
        let size: UInt32
        if fileSize == 0 {
            size = 1
        } else if fileSize < 2_000_000 {
            size = UInt32(fileSize)
        } else if fileSize < 64_000_000 {
            size = 2 * 1024 * 1024
        } else if fileSize < 1_000_000_000 {
            size = 4 * 1024 * 1024
        } else {
            size = 8 * 1024 * 1024
        }
        return ChunkPlan(fileSize: fileSize, chunkSize: size)
    }

    public static func parallelConnections(fileSize: UInt64, configuredMax: Int) -> Int {
        let cap = max(1, min(configuredMax, 16))
        if fileSize < 8_000_000 { return 1 }
        if fileSize < 32_000_000 { return min(2, cap) }
        if fileSize < 128_000_000 { return min(4, cap) }
        return cap
    }
}

/// 紧凑位图：第 i 位为 1 表示该分块已收齐。
public struct ChunkBitmap: Equatable, Sendable {
    public private(set) var bytes: [UInt8]
    public let chunkCount: Int

    public init(chunkCount: Int) {
        self.chunkCount = max(chunkCount, 1)
        self.bytes = [UInt8](repeating: 0, count: (self.chunkCount + 7) / 8)
    }

    public init(chunkCount: Int, data: Data) {
        self.chunkCount = max(chunkCount, 1)
        let need = (self.chunkCount + 7) / 8
        var raw = [UInt8](data.prefix(need))
        if raw.count < need {
            raw.append(contentsOf: [UInt8](repeating: 0, count: need - raw.count))
        }
        self.bytes = raw
    }

    public var data: Data { Data(bytes) }

    public var base64: String { data.base64EncodedString() }

    public static func fromBase64(_ text: String, chunkCount: Int) -> ChunkBitmap {
        ChunkBitmap(chunkCount: chunkCount, data: Data(base64Encoded: text) ?? Data())
    }

    public func contains(_ index: Int) -> Bool {
        guard index >= 0, index < chunkCount else { return false }
        return bytes[index / 8] & (1 << (index % 8)) != 0
    }

    public mutating func insert(_ index: Int) {
        guard index >= 0, index < chunkCount else { return }
        bytes[index / 8] |= (1 << (index % 8))
    }

    public var receivedCount: Int {
        var n = 0
        for i in 0..<chunkCount where contains(i) { n += 1 }
        return n
    }

    public var isComplete: Bool { receivedCount == chunkCount }

    public func missingIndices() -> [Int] {
        (0..<chunkCount).filter { !contains($0) }
    }
}

public struct FileOffer: Codable, Equatable, Sendable, Identifiable {
    public var id: Int { index }
    public var index: Int
    public var relativePath: String
    public var size: UInt64
    public var modified: TimeInterval

    public init(index: Int, relativePath: String, size: UInt64, modified: TimeInterval) {
        self.index = index
        self.relativePath = relativePath
        self.size = size
        self.modified = modified
    }

    public var plan: ChunkPlan { ChunkPlan.plan(fileSize: size) }
}
