package engine

import (
	"encoding/json"
	"fmt"
	"net"
	"sync"
	"time"

	"huchuan/protocol"
)

func (n *Node) shouldScan() bool {
	s := n.settingsCopy()
	if s.DeviceID == "selftest-node" {
		return false
	}
	return s.DiscoverMode != "off"
}

func (n *Node) udpLanSweep() {
	if !n.shouldScan() {
		return
	}
	if !n.scanMu.TryLock() {
		return
	}
	defer n.scanMu.Unlock()
	s := n.settingsCopy()
	hosts := n.scanHosts(s)
	if len(hosts) == 0 {
		return
	}
	pkt := protocol.DiscoveryPacket{
		V: 1, ID: s.DeviceID, Name: s.DeviceName,
		Port: s.Port, HTTPPort: HTTPPort(s.Port), OS: OSName(),
	}
	data, _ := json.Marshal(pkt)
	udp := UDPPort(s.Port)
	n.mu.Lock()
	uc := n.udpConn
	n.mu.Unlock()
	if uc == nil {
		return
	}
	for _, host := range hosts {
		_, _ = uc.WriteToUDP(data, &net.UDPAddr{IP: net.ParseIP(host), Port: int(udp)})
	}
}

func (n *Node) tcpLanSweep() {
	if !n.shouldScan() {
		return
	}
	if !n.tcpScanMu.TryLock() {
		return
	}
	defer n.tcpScanMu.Unlock()
	s := n.settingsCopy()
	hosts := n.scanHosts(s)
	if len(hosts) == 0 {
		return
	}
	sem := make(chan struct{}, 24)
	var wg sync.WaitGroup
	for _, host := range hosts {
		wg.Add(1)
		sem <- struct{}{}
		host := host
		go func() {
			defer func() { <-sem; wg.Done() }()
			n.tcpProbe(host, s)
		}()
	}
	wg.Wait()
}

func (n *Node) scanHosts(s Settings) []string {
	if s.DiscoverMode == "favorites" {
		var hosts []string
		seen := map[string]bool{}
		for _, fav := range s.Favorites {
			if fav.Host == "" || seen[fav.Host] {
				continue
			}
			seen[fav.Host] = true
			hosts = append(hosts, fav.Host)
		}
		return hosts
	}
	return n.subnetHosts()
}

func (n *Node) subnetHosts() []string {
	own := map[string]bool{}
	for _, ip := range allOwnIPv4() {
		own[ip] = true
	}
	seeds := rankIPv4(localIPv4())
	if len(seeds) == 0 {
		seeds = rankIPv4(allOwnIPv4())
	}
	seen := map[string]bool{}
	var hosts []string
	for _, ip := range seeds {
		parsed := net.ParseIP(ip).To4()
		if parsed == nil {
			continue
		}
		for i := 1; i <= 254; i++ {
			host := fmt.Sprintf("%d.%d.%d.%d", parsed[0], parsed[1], parsed[2], i)
			if own[host] || seen[host] {
				continue
			}
			seen[host] = true
			hosts = append(hosts, host)
		}
	}
	return hosts
}

func (n *Node) tcpProbe(host string, s Settings) {
	if isOwnHost(host) {
		return
	}
	conn, err := dialTCP(host, s.Port, 400*time.Millisecond)
	if err != nil {
		return
	}
	defer conn.Close()
	io := NewWire(conn, false)
	hello := protocol.Envelope{
		T: "hello", DeviceID: s.DeviceID, Name: s.DeviceName, Port: s.Port,
		HTTPPort: HTTPPort(s.Port), OS: OSName(), AppVersion: AppVersion,
	}
	if s.Pin != "" {
		p := s.Pin
		hello.Pin = &p
	}
	if err := io.SendJSON(hello); err != nil {
		return
	}
	msg, err := io.RecvJSON(time.Second)
	if err != nil {
		return
	}
	name := host
	id := "tcp-" + host
	osname := "电脑"
	if msg.T == "helloOk" {
		if msg.Name != "" {
			name = msg.Name
		}
		if msg.DeviceID != "" {
			id = msg.DeviceID
		}
		if msg.OS != "" {
			osname = msg.OS
		}
	} else if msg.T != "reject" {
		return
	}
	if id == s.DeviceID {
		return
	}
	if isOwnHost(host) {
		return
	}
	n.upsert(Peer{
		ID: id, Name: name, Host: host, Port: s.Port,
		HTTPPort: HTTPPort(s.Port), OS: osname, Via: "局域网扫描",
		LastSeen: time.Now(),
	})
}
