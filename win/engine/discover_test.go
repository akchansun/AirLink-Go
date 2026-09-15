package engine

import (
	"encoding/json"
	"net"
	"path/filepath"
	"testing"
	"time"

	"huchuan/protocol"
)

func TestRankIPv4PrefersHomeLAN(t *testing.T) {
	got := rankIPv4([]string{"10.8.0.2", "192.168.1.8", "172.16.0.5"})
	if len(got) == 0 || got[0] != "192.168.1.8" {
		t.Fatalf("家用网段应排在最前，实际 %v", got)
	}
}

func TestDiscoverUDPAndHello(t *testing.T) {
	root := t.TempDir()
	n := NewNode(Settings{
		DeviceName:     "发现接收端",
		ReceiveFolder:  filepath.Join(root, "recv"),
		AutoAccept:     true,
		Port:           42141,
		MaxConnections: 2,
		DeviceID:       "discover-recv",
	})
	if err := n.Start(); err != nil {
		t.Fatal(err)
	}
	defer n.Stop()
	if err := n.WaitListening(3 * time.Second); err != nil {
		t.Fatal(err)
	}
	time.Sleep(150 * time.Millisecond)

	pkt := protocol.DiscoveryPacket{
		V: 1, ID: "win-udp-peer", Name: "Windows测试机",
		Port: 41789, HTTPPort: 41788, OS: "Windows",
	}
	data, _ := json.Marshal(pkt)
	dst := &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: int(UDPPort(42141))}
	c, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 0})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := c.WriteToUDP(data, dst); err != nil {
		t.Fatal(err)
	}
	c.Close()

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if _, ok := n.PeerByID("win-udp-peer"); ok {
			break
		}
		time.Sleep(40 * time.Millisecond)
	}
	if _, ok := n.PeerByID("win-udp-peer"); !ok {
		t.Fatal("UDP 发现包没有变成设备")
	}

	conn, err := dialTCP("127.0.0.1", 42141, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	io := NewWire(conn, false)
	hello := protocol.Envelope{
		T: "hello", DeviceID: "win-tcp-peer", Name: "Windows握手机",
		Port: 41789, HTTPPort: 41788, OS: "Windows", AppVersion: AppVersion,
	}
	if err := io.SendJSON(hello); err != nil {
		t.Fatal(err)
	}
	if _, err := io.RecvJSON(2 * time.Second); err != nil {
		t.Fatal(err)
	}
	conn.Close()

	deadline = time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if _, ok := n.PeerByID("win-tcp-peer"); ok {
			return
		}
		time.Sleep(40 * time.Millisecond)
	}
	t.Fatal("TCP 握手后没有把对方记进设备列表")
}
