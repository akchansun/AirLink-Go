package protocol

import "encoding/base64"

type ChunkPlan struct {
	FileSize  uint64
	ChunkSize uint32
}

func Plan(fileSize uint64) ChunkPlan {
	var size uint32
	switch {
	case fileSize == 0:
		size = 1
	case fileSize < 2_000_000:
		size = uint32(fileSize)
	case fileSize < 64_000_000:
		size = 2 * 1024 * 1024
	case fileSize < 1_000_000_000:
		size = 4 * 1024 * 1024
	default:
		size = 8 * 1024 * 1024
	}
	return ChunkPlan{FileSize: fileSize, ChunkSize: size}
}

func (p ChunkPlan) ChunkCount() int {
	if p.FileSize == 0 {
		return 1
	}
	cs := uint64(p.ChunkSize)
	if cs == 0 {
		cs = 1
	}
	return int((p.FileSize + cs - 1) / cs)
}

func (p ChunkPlan) ByteRange(index int) (start, end uint64) {
	cs := uint64(p.ChunkSize)
	if cs == 0 {
		cs = 1
	}
	start = uint64(index) * cs
	end = start + cs
	if end > p.FileSize {
		end = p.FileSize
	}
	return
}

func (p ChunkPlan) Length(index int) int {
	s, e := p.ByteRange(index)
	return int(e - s)
}

func ParallelConnections(fileSize uint64, configuredMax int) int {
	capn := configuredMax
	if capn < 1 {
		capn = 1
	}
	if capn > 16 {
		capn = 16
	}
	switch {
	case fileSize < 8_000_000:
		return 1
	case fileSize < 32_000_000:
		if capn < 2 {
			return capn
		}
		return 2
	case fileSize < 128_000_000:
		if capn < 4 {
			return capn
		}
		return 4
	default:
		return capn
	}
}

type ChunkBitmap struct {
	bytes      []byte
	chunkCount int
}

func NewBitmap(chunkCount int) ChunkBitmap {
	if chunkCount < 1 {
		chunkCount = 1
	}
	return ChunkBitmap{bytes: make([]byte, (chunkCount+7)/8), chunkCount: chunkCount}
}

func BitmapFromData(chunkCount int, data []byte) ChunkBitmap {
	b := NewBitmap(chunkCount)
	n := len(b.bytes)
	if len(data) < n {
		copy(b.bytes, data)
	} else {
		copy(b.bytes, data[:n])
	}
	return b
}

func BitmapFromBase64(text string, chunkCount int) ChunkBitmap {
	raw, err := base64.StdEncoding.DecodeString(text)
	if err != nil {
		return NewBitmap(chunkCount)
	}
	return BitmapFromData(chunkCount, raw)
}

func (b ChunkBitmap) Data() []byte { return append([]byte(nil), b.bytes...) }

func (b ChunkBitmap) Base64() string { return base64.StdEncoding.EncodeToString(b.bytes) }

func (b ChunkBitmap) Contains(index int) bool {
	if index < 0 || index >= b.chunkCount {
		return false
	}
	return b.bytes[index/8]&(1<<uint(index%8)) != 0
}

func (b *ChunkBitmap) Insert(index int) {
	if index < 0 || index >= b.chunkCount {
		return
	}
	b.bytes[index/8] |= 1 << uint(index%8)
}

func (b ChunkBitmap) ReceivedCount() int {
	n := 0
	for i := 0; i < b.chunkCount; i++ {
		if b.Contains(i) {
			n++
		}
	}
	return n
}

func (b ChunkBitmap) IsComplete() bool { return b.ReceivedCount() == b.chunkCount }
