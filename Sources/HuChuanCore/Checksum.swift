import Foundation
import CryptoKit
import zlib

public enum Checksum {
    public static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    public static func sha256(_ bytes: UnsafeRawBufferPointer) -> Data {
        let data = Data(bytes)
        return sha256(data)
    }

    public static func crc32(_ data: Data) -> UInt32 {
        if data.isEmpty { return 0 }
        return data.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: UInt8.self)
            return UInt32(zlib.crc32(0, ptr.baseAddress, UInt32(data.count)))
        }
    }

    public static func crc32(_ bytes: UnsafeRawBufferPointer) -> UInt32 {
        let ptr = bytes.bindMemory(to: UInt8.self)
        return UInt32(zlib.crc32(0, ptr.baseAddress, UInt32(bytes.count)))
    }
}
