package engine

import (
	"fmt"
	"net"
	"sync"
	"time"

	"huchuan/protocol"
)

type Wire struct {
	c    net.Conn
	dead error
	mu   sync.Mutex
}

func NewWire(c net.Conn, asServer bool) *Wire {
	sc, err := openSecure(c, asServer)
	if err != nil {
		_ = c.Close()
		return &Wire{dead: err}
	}
	return &Wire{c: sc}
}

func (w *Wire) Close() {
	if w != nil && w.c != nil {
		_ = w.c.Close()
	}
}

func (w *Wire) Send(kind byte, payload []byte) error {
	if w == nil {
		return errMsg("连接已断开")
	}
	if w.dead != nil {
		return w.dead
	}
	if w.c == nil {
		return errMsg("连接已断开")
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	_ = w.c.SetWriteDeadline(time.Now().Add(30 * time.Second))
	_, err := w.c.Write(protocol.EncodeFrame(kind, payload))
	return err
}

func (w *Wire) SendJSON(env protocol.Envelope) error {
	return w.Send(protocol.KindJSON, protocol.MarshalEnv(env))
}

func (w *Wire) SendChunk(p protocol.ChunkPacket) error {
	return w.Send(protocol.KindChunk, p.Encode())
}

func (w *Wire) SendAck(a protocol.ChunkAck) error {
	return w.Send(protocol.KindChunkAck, a.Encode())
}

func (w *Wire) SendPong() error { return w.Send(protocol.KindPong, nil) }

func (w *Wire) Recv(timeout time.Duration) (protocol.Frame, error) {
	if w == nil {
		return protocol.Frame{}, errMsg("连接已断开")
	}
	if w.dead != nil {
		return protocol.Frame{}, w.dead
	}
	if w.c == nil {
		return protocol.Frame{}, errMsg("连接已断开")
	}
	_ = w.c.SetReadDeadline(time.Now().Add(timeout))
	return protocol.ReadFrame(w.c)
}

func (w *Wire) RecvJSON(timeout time.Duration) (protocol.Envelope, error) {
	f, err := w.Recv(timeout)
	if err != nil {
		return protocol.Envelope{}, err
	}
	if f.Kind != protocol.KindJSON {
		return protocol.Envelope{}, fmt.Errorf("对方协议不对")
	}
	return protocol.UnmarshalEnv(f.Payload)
}
