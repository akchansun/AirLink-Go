import Foundation
import CryptoKit
import Network
import HuChuanCore

enum SecurePipe {
    static let handshakeSize = 38
    private static let magic: [UInt8] = [0x48, 0x43, 0x53, 0x4B] // HCSK
    private static let version: UInt8 = 1
    private static let salt = Data("huchuan-secure-v1".utf8)

    struct Session {
        var writeKey: SymmetricKey
        var readKey: SymmetricKey
        var writeCounter: UInt64 = 1
        var readCounter: UInt64 = 1
    }

    static func handshake(on connection: NWConnection, asServer: Bool) async throws -> Session {
        let priv = Curve25519.KeyAgreement.PrivateKey()
        var mine = Data(capacity: handshakeSize)
        mine.append(contentsOf: magic)
        mine.append(version)
        mine.append(0)
        mine.append(priv.publicKey.rawRepresentation)
        guard mine.count == handshakeSize else { throw AppError.message("加密握手长度不对") }

        let mineCopy = mine
        async let writeDone: Void = connection.sendData(mineCopy)
        async let peer = connection.receiveExactly(handshakeSize, timeout: 12)
        try await writeDone
        let theirs = try await peer
        let bytes = [UInt8](theirs)
        if bytes.count >= 4, bytes[0] == 0x48, bytes[1] == 0x55, bytes[2] == 0x43, bytes[3] == 0x48 {
            throw AppError.message("对方还是旧版互传，请两边都升级后再传")
        }
        guard bytes.count == handshakeSize,
              bytes[0] == magic[0], bytes[1] == magic[1], bytes[2] == magic[2], bytes[3] == magic[3] else {
            throw AppError.message("对方不是加密版互传")
        }
        guard bytes[4] == version else {
            throw AppError.message("加密协议版本不支持")
        }
        let pubData = theirs.subdata(in: 6..<38)
        let peerPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: pubData)
        let shared = try priv.sharedSecretFromKeyAgreement(with: peerPub)
        let c2s = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: salt, sharedInfo: Data("c2s".utf8), outputByteCount: 32
        )
        let s2c = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: salt, sharedInfo: Data("s2c".utf8), outputByteCount: 32
        )
        if asServer {
            return Session(writeKey: s2c, readKey: c2s)
        }
        return Session(writeKey: c2s, readKey: s2c)
    }

    static func seal(_ plain: Data, session: inout Session) throws -> Data {
        let nonce = nonceData(session.writeCounter)
        session.writeCounter += 1
        let box = try AES.GCM.seal(plain, using: session.writeKey, nonce: AES.GCM.Nonce(data: nonce))
        let body = box.ciphertext + box.tag
        var out = Data(capacity: 4 + body.count)
        var be = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }

    static func open(_ recordBody: Data, session: inout Session) throws -> Data {
        guard recordBody.count >= 16 else { throw AppError.message("加密数据不完整") }
        let nonce = nonceData(session.readCounter)
        session.readCounter += 1
        let cipher = recordBody.prefix(recordBody.count - 16)
        let tag = recordBody.suffix(16)
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonce),
            ciphertext: cipher,
            tag: tag
        )
        return try AES.GCM.open(box, using: session.readKey)
    }

    private static func nonceData(_ counter: UInt64) -> Data {
        var out = Data(count: 12)
        var be = counter.bigEndian
        withUnsafeBytes(of: &be) { raw in
            out.replaceSubrange(4..<12, with: raw)
        }
        return out
    }
}
