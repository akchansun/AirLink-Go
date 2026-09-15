import Foundation
import Network
import HuChuanCore

actor WireIO {
    private let connection: NWConnection
    private var session: SecurePipe.Session

    private init(connection: NWConnection, session: SecurePipe.Session) {
        self.connection = connection
        self.session = session
    }

    static func open(_ connection: NWConnection, asServer: Bool) async throws -> WireIO {
        let session = try await SecurePipe.handshake(on: connection, asServer: asServer)
        return WireIO(connection: connection, session: session)
    }

    func send(_ frame: WireFrame) async throws {
        let record = try SecurePipe.seal(frame.encode(), session: &session)
        try await connection.sendData(record)
    }

    func sendJSON(_ message: ControlMessage) async throws {
        let payload = try message.encodeJSON()
        try await send(WireFrame(kind: .json, payload: payload))
    }

    func sendChunk(_ packet: ChunkPacket) async throws {
        try await send(WireFrame(kind: .chunk, payload: packet.encode()))
    }

    func sendAck(_ ack: ChunkAck) async throws {
        try await send(WireFrame(kind: .chunkAck, payload: ack.encode()))
    }

    func sendPing() async throws {
        try await send(WireFrame(kind: .ping, payload: Data()))
    }

    func sendPong() async throws {
        try await send(WireFrame(kind: .pong, payload: Data()))
    }

    func receiveFrame(timeout: TimeInterval = 90) async throws -> WireFrame {
        let header = try await connection.receiveExactly(4, timeout: timeout)
        let n = Int(UInt32(header[0]) << 24 | UInt32(header[1]) << 16 | UInt32(header[2]) << 8 | UInt32(header[3]))
        guard n >= 16, n <= WireFrame.maxPayload + 64 else {
            throw AppError.message("加密数据包过大（\(n) 字节）")
        }
        let body = try await connection.receiveExactly(n, timeout: timeout)
        let plain = try SecurePipe.open(body, session: &session)
        guard plain.count >= WireFrame.headerSize else { throw WireError.truncatedHeader }
        let parsed = try WireFrame.parseHeader(Data(plain.prefix(WireFrame.headerSize)))
        let payload: Data
        if parsed.length == 0 {
            payload = Data()
        } else {
            let start = WireFrame.headerSize
            let end = start + parsed.length
            guard plain.count >= end else { throw WireError.truncatedHeader }
            payload = plain.subdata(in: start..<end)
        }
        return WireFrame(kind: parsed.kind, payload: payload)
    }

    nonisolated func cancel() {
        connection.cancel()
    }
}
