package protocol

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"hash/crc32"
	"io"
)

const (
	Magic0, Magic1, Magic2, Magic3 = 0x48, 0x55, 0x43, 0x48 // HUCH
	Version                        = 1
	HeaderSize                     = 10
	MaxPayload                     = 16 * 1024 * 1024
	KindJSON                       = 1
	KindChunk                      = 2
	KindChunkAck                   = 3
	KindPing                       = 4
	KindPong                       = 5
	ChunkHeaderSize                = 40
	ChunkHashSize                  = 32
)

type Frame struct {
	Kind    byte
	Payload []byte
}

func EncodeFrame(kind byte, payload []byte) []byte {
	out := make([]byte, HeaderSize+len(payload))
	out[0], out[1], out[2], out[3] = Magic0, Magic1, Magic2, Magic3
	out[4] = Version
	out[5] = kind
	binary.BigEndian.PutUint32(out[6:10], uint32(len(payload)))
	copy(out[10:], payload)
	return out
}

func ParseHeader(h []byte) (kind byte, length int, err error) {
	if len(h) != HeaderSize {
		return 0, 0, errors.New("数据头不完整")
	}
	if h[0] != Magic0 || h[1] != Magic1 || h[2] != Magic2 || h[3] != Magic3 {
		return 0, 0, errors.New("协议不匹配，对方可能不是互传")
	}
	if h[4] != Version {
		return 0, 0, fmt.Errorf("协议版本不支持（%d）", h[4])
	}
	kind = h[5]
	if kind < KindJSON || kind > KindPong {
		return 0, 0, fmt.Errorf("未知数据包类型（%d）", kind)
	}
	n := int(binary.BigEndian.Uint32(h[6:10]))
	if n < 0 || n > MaxPayload {
		return 0, 0, fmt.Errorf("数据包过大（%d 字节）", n)
	}
	return kind, n, nil
}

func ReadFrame(r io.Reader) (Frame, error) {
	var hdr [HeaderSize]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		return Frame{}, err
	}
	kind, n, err := ParseHeader(hdr[:])
	if err != nil {
		return Frame{}, err
	}
	var payload []byte
	if n > 0 {
		payload = make([]byte, n)
		if _, err := io.ReadFull(r, payload); err != nil {
			return Frame{}, err
		}
	}
	return Frame{Kind: kind, Payload: payload}, nil
}

func SHA256(data []byte) []byte {
	sum := sha256.Sum256(data)
	out := make([]byte, ChunkHashSize)
	copy(out, sum[:])
	return out
}

func CRC32(data []byte) uint32 {
	if len(data) == 0 {
		return 0
	}
	return crc32.ChecksumIEEE(data)
}

type ChunkPacket struct {
	FileIndex  uint32
	ChunkIndex uint32
	Hash       []byte
	Data       []byte
}

func (c ChunkPacket) Encode() []byte {
	out := make([]byte, ChunkHeaderSize+len(c.Data))
	binary.BigEndian.PutUint32(out[0:4], c.FileIndex)
	binary.BigEndian.PutUint32(out[4:8], c.ChunkIndex)
	sum := c.Hash
	if len(sum) != ChunkHashSize {
		sum = SHA256(c.Data)
	}
	copy(out[8:ChunkHeaderSize], sum)
	copy(out[ChunkHeaderSize:], c.Data)
	return out
}

func NewChunk(fileIndex, chunkIndex uint32, data []byte) ChunkPacket {
	return ChunkPacket{FileIndex: fileIndex, ChunkIndex: chunkIndex, Hash: SHA256(data), Data: data}
}

func DecodeChunk(p []byte) (ChunkPacket, error) {
	if len(p) < ChunkHeaderSize {
		return ChunkPacket{}, errors.New("分块数据不完整")
	}
	h := make([]byte, ChunkHashSize)
	copy(h, p[8:ChunkHeaderSize])
	data := append([]byte(nil), p[ChunkHeaderSize:]...)
	return ChunkPacket{
		FileIndex:  binary.BigEndian.Uint32(p[0:4]),
		ChunkIndex: binary.BigEndian.Uint32(p[4:8]),
		Hash:       h,
		Data:       data,
	}, nil
}

func (c ChunkPacket) HashOk() bool {
	return bytes.Equal(c.Hash, SHA256(c.Data))
}

func (c ChunkPacket) CRCOk() bool { return c.HashOk() }

type ChunkAck struct {
	FileIndex  uint32
	ChunkIndex uint32
	OK         bool
}

func (a ChunkAck) Encode() []byte {
	out := make([]byte, 9)
	binary.BigEndian.PutUint32(out[0:4], a.FileIndex)
	binary.BigEndian.PutUint32(out[4:8], a.ChunkIndex)
	if a.OK {
		out[8] = 1
	}
	return out
}

func DecodeAck(p []byte) (ChunkAck, error) {
	if len(p) < 9 {
		return ChunkAck{}, errors.New("确认包不完整")
	}
	return ChunkAck{
		FileIndex:  binary.BigEndian.Uint32(p[0:4]),
		ChunkIndex: binary.BigEndian.Uint32(p[4:8]),
		OK:         p[8] != 0,
	}, nil
}

type Envelope struct {
	T          string      `json:"t"`
	DeviceID   string      `json:"deviceId,omitempty"`
	Name       string      `json:"name,omitempty"`
	Port       uint16      `json:"port,omitempty"`
	HTTPPort   uint16      `json:"httpPort,omitempty"`
	OS         string      `json:"os,omitempty"`
	AppVersion string      `json:"appVersion,omitempty"`
	Pin        *string     `json:"pin,omitempty"`
	SessionID  string      `json:"sessionId,omitempty"`
	Token      string      `json:"token,omitempty"`
	Files      []FileOffer `json:"files,omitempty"`
	Accepted   *bool       `json:"accepted,omitempty"`
	SaveNames  []string    `json:"saveNames,omitempty"`
	ResumeBits []string    `json:"resumeBits,omitempty"`
	Reason     string      `json:"reason,omitempty"`
	WorkerID   int         `json:"workerId,omitempty"`
	Body       string      `json:"body,omitempty"`
}

type FileOffer struct {
	Index        int     `json:"index"`
	RelativePath string  `json:"relativePath"`
	Size         uint64  `json:"size"`
	Modified     float64 `json:"modified"`
}

type DiscoveryPacket struct {
	V        int    `json:"v"`
	ID       string `json:"id"`
	Name     string `json:"name"`
	Port     uint16 `json:"port"`
	HTTPPort uint16 `json:"httpPort"`
	OS       string `json:"os"`
	Reply    bool   `json:"reply,omitempty"`
	PhoneClaim string `json:"phoneClaim,omitempty"`
}

func MarshalEnv(e Envelope) []byte {
	b, _ := json.Marshal(e)
	return b
}

func UnmarshalEnv(b []byte) (Envelope, error) {
	var e Envelope
	err := json.Unmarshal(b, &e)
	return e, err
}
