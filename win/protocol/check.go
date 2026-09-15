package protocol

import "fmt"

func SelfCheck() error {
	hello := Envelope{
		T: "hello", DeviceID: "abc", Name: "测试机", Port: 41789,
		HTTPPort: 41788, OS: "macOS", AppVersion: "1.0.0",
	}
	json := MarshalEnv(hello)
	frame := EncodeFrame(KindJSON, json)
	kind, n, err := ParseHeader(frame[:HeaderSize])
	if err != nil || kind != KindJSON || n != len(json) {
		return fail("帧头")
	}
	back, err := UnmarshalEnv(json)
	if err != nil || back.T != "hello" || back.Name != "测试机" {
		return fail("握手编解码")
	}

	payload := make([]byte, 4096)
	for i := range payload {
		payload[i] = byte(i % 255)
	}
	packet := NewChunk(3, 9, payload)
	again, err := DecodeChunk(packet.Encode())
	if err != nil || !again.HashOk() || len(again.Data) != len(payload) {
		return fail("分块校验")
	}
	bad := packet.Encode()
	bad[20] ^= 0xFF
	decoded, err := DecodeChunk(bad)
	if err != nil || decoded.HashOk() {
		return fail("损坏检测")
	}

	bits := NewBitmap(10)
	for i := 0; i < 10; i++ {
		bits.Insert(i)
	}
	if !bits.IsComplete() {
		return fail("位图")
	}
	if Plan(800_000).ChunkCount() != 1 {
		return fail("小文件分块")
	}
	if Plan(2_000_000_000).ChunkSize != 8*1024*1024 {
		return fail("大文件分块")
	}
	if _, ok := SanitizeRelativePath("../etc/passwd"); ok {
		return fail("路径穿越")
	}
	if p, ok := SanitizeRelativePath("相册/夕阳.JPG"); !ok || p != "相册/夕阳.JPG" {
		return fail("中文路径")
	}
	ack, err := DecodeAck(ChunkAck{FileIndex: 1, ChunkIndex: 2, OK: true}.Encode())
	if err != nil || !ack.OK || ack.ChunkIndex != 2 {
		return fail("确认包")
	}
	disc := DiscoveryPacket{V: 1, ID: "id1", Name: "客厅电脑", Port: 41789, HTTPPort: 41788, OS: "macOS"}
	raw, _ := jsonMarshal(disc)
	var againDisc DiscoveryPacket
	if err := jsonUnmarshal(raw, &againDisc); err != nil || againDisc != disc {
		return fail("发现包")
	}
	if FormatSize(1536) != "1.5 KB" {
		return fail("大小显示")
	}
	if SanitizeFileName("a/b:c") != "a_b_c" {
		return fail("文件名清理")
	}
	if MeetCode("b-id", "a-id") != MeetCode("a-id", "b-id") {
		return fail("见面码")
	}
	if len(MeetCode("a-id", "b-id")) != 4 {
		return fail("见面码位数")
	}
	if CRC32(nil) != 0 {
		return fail("空校验")
	}
	if len(SHA256(nil)) != 32 {
		return fail("SHA-256")
	}
	return nil
}

func fail(s string) error { return fmt.Errorf("协议自检失败：%s", s) }
