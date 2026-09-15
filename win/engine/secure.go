package engine

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"sync"
	"time"
)

const (
	secureMagic     = "HCSK"
	secureVersion   = 1
	secureHandshake = 38
)

var secureSalt = []byte("huchuan-secure-v1")

type secureConn struct {
	net.Conn
	writeAEAD cipher.AEAD
	readAEAD  cipher.AEAD
	writeN    uint64
	readN     uint64
	buf       []byte
	mu        sync.Mutex
	readMu    sync.Mutex
}

func openSecure(c net.Conn, asServer bool) (net.Conn, error) {
	priv, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	mine := make([]byte, secureHandshake)
	copy(mine[0:4], secureMagic)
	mine[4] = secureVersion
	copy(mine[6:38], priv.PublicKey().Bytes())

	peer := make([]byte, secureHandshake)
	errc := make(chan error, 2)
	go func() {
		_ = c.SetWriteDeadline(time.Now().Add(12 * time.Second))
		_, err := c.Write(mine)
		errc <- err
	}()
	go func() {
		_ = c.SetReadDeadline(time.Now().Add(12 * time.Second))
		_, err := io.ReadFull(c, peer)
		errc <- err
	}()
	if err := <-errc; err != nil {
		return nil, err
	}
	if err := <-errc; err != nil {
		return nil, err
	}
	if string(peer[0:4]) == "HUCH" {
		return nil, errMsg("对方还是旧版互传，请两边都升级后再传")
	}
	if string(peer[0:4]) != secureMagic {
		return nil, errMsg("对方不是加密版互传")
	}
	if peer[4] != secureVersion {
		return nil, errMsg("加密协议版本不支持")
	}
	pub, err := ecdh.X25519().NewPublicKey(peer[6:38])
	if err != nil {
		return nil, errMsg("对方密钥无效")
	}
	shared, err := priv.ECDH(pub)
	if err != nil {
		return nil, err
	}
	c2s, err := hkdf.Key(sha256.New, shared, secureSalt, "c2s", 32)
	if err != nil {
		return nil, err
	}
	s2c, err := hkdf.Key(sha256.New, shared, secureSalt, "s2c", 32)
	if err != nil {
		return nil, err
	}
	var writeKey, readKey []byte
	if asServer {
		writeKey, readKey = s2c, c2s
	} else {
		writeKey, readKey = c2s, s2c
	}
	wa, err := aeadFrom(writeKey)
	if err != nil {
		return nil, err
	}
	ra, err := aeadFrom(readKey)
	if err != nil {
		return nil, err
	}
	_ = c.SetDeadline(time.Time{})
	return &secureConn{Conn: c, writeAEAD: wa, readAEAD: ra, writeN: 1, readN: 1}, nil
}

func aeadFrom(key []byte) (cipher.AEAD, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

func nonceFor(n uint64) []byte {
	out := make([]byte, 12)
	binary.BigEndian.PutUint64(out[4:], n)
	return out
}

func (s *secureConn) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	n := s.writeN
	s.writeN++
	sealed := s.writeAEAD.Seal(nil, nonceFor(n), p, nil)
	hdr := make([]byte, 4)
	binary.BigEndian.PutUint32(hdr, uint32(len(sealed)))
	if _, err := s.Conn.Write(append(hdr, sealed...)); err != nil {
		return 0, err
	}
	return len(p), nil
}

func (s *secureConn) Read(p []byte) (int, error) {
	s.readMu.Lock()
	defer s.readMu.Unlock()
	if len(s.buf) == 0 {
		plain, err := s.readRecord()
		if err != nil {
			return 0, err
		}
		s.buf = plain
	}
	n := copy(p, s.buf)
	s.buf = s.buf[n:]
	return n, nil
}

func (s *secureConn) readRecord() ([]byte, error) {
	var hdr [4]byte
	if _, err := io.ReadFull(s.Conn, hdr[:]); err != nil {
		return nil, err
	}
	n := int(binary.BigEndian.Uint32(hdr[:]))
	if n < 16 || n > 16*1024*1024+64 {
		return nil, fmt.Errorf("加密数据包过大（%d 字节）", n)
	}
	body := make([]byte, n)
	if _, err := io.ReadFull(s.Conn, body); err != nil {
		return nil, err
	}
	ctr := s.readN
	s.readN++
	plain, err := s.readAEAD.Open(nil, nonceFor(ctr), body, nil)
	if err != nil {
		return nil, errMsg("文件在路上被改过，已停止接收")
	}
	return plain, nil
}

func testSecureRoundTrip() error {
	c1, c2 := net.Pipe()
	defer c1.Close()
	defer c2.Close()
	errc := make(chan error, 2)
	go func() {
		s, err := openSecure(c1, true)
		if err != nil {
			errc <- err
			return
		}
		buf := make([]byte, 16)
		if _, err := io.ReadFull(s, buf); err != nil {
			errc <- err
			return
		}
		if string(buf) != "hello-from-peer!" {
			errc <- errMsg("解密内容不对")
			return
		}
		_, err = s.Write([]byte("back-at-you!!!!"))
		errc <- err
	}()
	s, err := openSecure(c2, false)
	if err != nil {
		return err
	}
	if _, err := s.Write([]byte("hello-from-peer!")); err != nil {
		return err
	}
	buf := make([]byte, 15)
	if _, err := io.ReadFull(s, buf); err != nil {
		return err
	}
	if string(buf) != "back-at-you!!!!" {
		return errMsg("加密回程内容不对")
	}
	return <-errc
}
