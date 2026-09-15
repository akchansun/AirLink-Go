import Foundation

public enum FrameKind: UInt8, Sendable {
    case json = 1
    case chunk = 2
    case chunkAck = 3
    case ping = 4
    case pong = 5
}

public struct WireFrame: Equatable, Sendable {
    public static let magic: [UInt8] = [0x48, 0x55, 0x43, 0x48] // HUCH
    public static let version: UInt8 = 1
    public static let headerSize = 10
    public static let maxPayload = 16 * 1024 * 1024

    public var kind: FrameKind
    public var payload: Data

    public init(kind: FrameKind, payload: Data) {
        self.kind = kind
        self.payload = payload
    }

    public func encode() -> Data {
        var out = Data(capacity: Self.headerSize + payload.count)
        out.append(contentsOf: Self.magic)
        out.append(Self.version)
        out.append(kind.rawValue)
        var be = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    public static func parseHeader(_ header: Data) throws -> (kind: FrameKind, length: Int) {
        guard header.count == headerSize else { throw WireError.truncatedHeader }
        let bytes = [UInt8](header)
        guard bytes[0] == magic[0], bytes[1] == magic[1], bytes[2] == magic[2], bytes[3] == magic[3] else {
            throw WireError.badMagic
        }
        guard bytes[4] == version else { throw WireError.unsupportedVersion(bytes[4]) }
        guard let kind = FrameKind(rawValue: bytes[5]) else { throw WireError.unknownKind(bytes[5]) }
        let length = Int(UInt32(bytes[6]) << 24 | UInt32(bytes[7]) << 16 | UInt32(bytes[8]) << 8 | UInt32(bytes[9]))
        guard length >= 0, length <= maxPayload else { throw WireError.payloadTooLarge(length) }
        return (kind, length)
    }
}

public struct ChunkPacket: Equatable, Sendable {
    public static let hashSize = 32
    public static let headerSize = 8 + hashSize

    public var fileIndex: UInt32
    public var chunkIndex: UInt32
    public var sha256: Data
    public var data: Data

    public init(fileIndex: UInt32, chunkIndex: UInt32, data: Data, sha256: Data? = nil) {
        self.fileIndex = fileIndex
        self.chunkIndex = chunkIndex
        self.data = data
        self.sha256 = sha256 ?? Checksum.sha256(data)
    }

    public func encode() -> Data {
        var out = Data(capacity: Self.headerSize + data.count)
        func append(_ v: UInt32) {
            var be = v.bigEndian
            withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
        }
        append(fileIndex)
        append(chunkIndex)
        let hash = sha256.prefix(Self.hashSize)
        out.append(hash)
        if hash.count < Self.hashSize {
            out.append(Data(count: Self.hashSize - hash.count))
        }
        out.append(data)
        return out
    }

    public static func decode(_ payload: Data) throws -> ChunkPacket {
        guard payload.count >= headerSize else { throw WireError.truncatedChunk }
        let bytes = [UInt8](payload.prefix(8))
        func u32(_ i: Int) -> UInt32 {
            UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16 | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3])
        }
        return ChunkPacket(
            fileIndex: u32(0),
            chunkIndex: u32(4),
            data: payload.suffix(from: headerSize),
            sha256: payload.subdata(in: 8..<headerSize)
        )
    }

    public var hashOk: Bool { Checksum.sha256(data) == sha256 }
    public var crcOk: Bool { hashOk }
}

public struct ChunkAck: Equatable, Sendable {
    public var fileIndex: UInt32
    public var chunkIndex: UInt32
    public var ok: Bool

    public init(fileIndex: UInt32, chunkIndex: UInt32, ok: Bool) {
        self.fileIndex = fileIndex
        self.chunkIndex = chunkIndex
        self.ok = ok
    }

    public func encode() -> Data {
        var out = Data(capacity: 9)
        func append(_ v: UInt32) {
            var be = v.bigEndian
            withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
        }
        append(fileIndex)
        append(chunkIndex)
        out.append(ok ? 1 : 0)
        return out
    }

    public static func decode(_ payload: Data) throws -> ChunkAck {
        guard payload.count >= 9 else { throw WireError.truncatedAck }
        let bytes = [UInt8](payload)
        func u32(_ i: Int) -> UInt32 {
            UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16 | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3])
        }
        return ChunkAck(fileIndex: u32(0), chunkIndex: u32(4), ok: bytes[8] != 0)
    }
}

public enum WireError: Error, Equatable, CustomStringConvertible {
    case truncatedHeader
    case badMagic
    case unsupportedVersion(UInt8)
    case unknownKind(UInt8)
    case payloadTooLarge(Int)
    case truncatedChunk
    case truncatedAck
    case disconnected
    case timeout
    case protocolViolation(String)

    public var description: String {
        switch self {
        case .truncatedHeader: return "数据头不完整"
        case .badMagic: return "协议不匹配，对方可能不是互传"
        case .unsupportedVersion(let v): return "协议版本不支持（\(v)）"
        case .unknownKind(let k): return "未知数据包类型（\(k)）"
        case .payloadTooLarge(let n): return "数据包过大（\(n) 字节）"
        case .truncatedChunk: return "分块数据不完整"
        case .truncatedAck: return "确认包不完整"
        case .disconnected: return "连接已断开"
        case .timeout: return "等待超时"
        case .protocolViolation(let s): return s
        }
    }
}
