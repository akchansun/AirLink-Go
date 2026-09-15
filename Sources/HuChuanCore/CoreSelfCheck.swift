import Foundation

public enum CoreSelfCheck {
    public static func run() throws {
        let hello = ControlMessage.hello(.init(
            deviceId: "abc", name: "测试机", port: 41789, httpPort: 41788, os: "macOS", appVersion: "1.0.0"
        ))
        let json = try hello.encodeJSON()
        let frame = WireFrame(kind: .json, payload: json)
        let data = frame.encode()
        let parsed = try WireFrame.parseHeader(Data(data.prefix(WireFrame.headerSize)))
        guard parsed.kind == .json, parsed.length == json.count else { throw fail("帧头") }
        guard try ControlMessage.decodeJSON(json) == hello else { throw fail("握手编解码") }

        let payload = Data((0..<4096).map { UInt8($0 % 255) })
        let packet = ChunkPacket(fileIndex: 3, chunkIndex: 9, data: payload)
        let again = try ChunkPacket.decode(packet.encode())
        guard again.hashOk, again.data == payload else { throw fail("分块校验") }
        var bad = packet.encode()
        bad[20] ^= 0xFF
        guard try ChunkPacket.decode(bad).hashOk == false else { throw fail("损坏检测") }
        guard Checksum.sha256(Data()).count == 32 else { throw fail("SHA-256") }

        var bits = ChunkBitmap(chunkCount: 10)
        for i in 0..<10 { bits.insert(i) }
        guard bits.isComplete else { throw fail("位图") }
        guard ChunkPlan.plan(fileSize: 800_000).chunkCount == 1 else { throw fail("小文件分块") }
        guard ChunkPlan.plan(fileSize: 2_000_000_000).chunkSize == 8 * 1024 * 1024 else { throw fail("大文件分块") }
        guard PathGuard.sanitizeRelativePath("../etc/passwd") == nil else { throw fail("路径穿越") }
        guard PathGuard.sanitizeRelativePath("相册/夕阳.JPG") == "相册/夕阳.JPG" else { throw fail("中文路径") }
        let ack = try ChunkAck.decode(ChunkAck(fileIndex: 1, chunkIndex: 2, ok: true).encode())
        guard ack.ok, ack.chunkIndex == 2 else { throw fail("确认包") }

        let disc = DiscoveryPacket(id: "id1", name: "客厅电脑", port: 41789, httpPort: 41788, os: "macOS")
        guard DiscoveryPacket.decode(disc.encode()) == disc else { throw fail("发现包") }
        guard ByteFormat.size(1536) == "1.5 KB" else { throw fail("大小显示") }
        guard PathGuard.sanitizeFileName("a/b:c") == "a_b_c" else { throw fail("文件名清理") }
        guard MeetCode.of("b-id", "a-id") == MeetCode.of("a-id", "b-id") else { throw fail("见面码") }
        guard MeetCode.of("a-id", "b-id").count == 4 else { throw fail("见面码位数") }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nested = PathGuard.uniquePath(in: tmp, relative: "相册/夕阳.JPG")
        guard nested.lastPathComponent == "夕阳.JPG" else { throw fail("子目录保存路径") }
        try? FileManager.default.removeItem(at: tmp)
    }

    private static func fail(_ s: String) -> WireError { .protocolViolation("协议自检失败：\(s)") }
}
