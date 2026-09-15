package engine

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"sort"
	"strings"
	"time"

	"huchuan/protocol"
)

func skipIface(name string) bool {
	n := strings.ToLower(strings.TrimSpace(name))
	if n == "lo" || strings.HasPrefix(n, "lo0") || strings.HasPrefix(n, "loopback") {
		return true
	}
	for _, p := range []string{
		"vethernet", "wsl", "vmware", "virtualbox", "hyper-v",
		"bluetooth", "docker", "br-", "awdl", "llw", "utun",
		"isatap", "teredo",
	} {
		if strings.Contains(n, p) {
			return true
		}
	}
	return false
}

func localIPv4() []string {
	var out []string
	ifs, err := net.Interfaces()
	if err != nil {
		return out
	}
	for _, ifi := range ifs {
		if ifi.Flags&net.FlagUp == 0 || ifi.Flags&net.FlagLoopback != 0 {
			continue
		}
		if skipIface(ifi.Name) {
			continue
		}
		addrs, err := ifi.Addrs()
		if err != nil {
			continue
		}
		for _, a := range addrs {
			ipn, ok := a.(*net.IPNet)
			if !ok || ipn.IP == nil {
				continue
			}
			ip := ipn.IP.To4()
			if ip == nil || ip.IsLoopback() {
				continue
			}
			if ip[0] == 169 && ip[1] == 254 {
				continue
			}
			out = append(out, ip.String())
		}
	}
	if len(out) == 0 {
		out = allOwnIPv4()
	}
	return uniqueStrings(out)
}

func allOwnIPv4() []string {
	var out []string
	ifs, err := net.Interfaces()
	if err != nil {
		return uniqueStrings(allIPv4Fallback())
	}
	for _, ifi := range ifs {
		if ifi.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := ifi.Addrs()
		if err != nil {
			continue
		}
		for _, a := range addrs {
			ipn, ok := a.(*net.IPNet)
			if !ok || ipn.IP == nil {
				continue
			}
			ip := ipn.IP.To4()
			if ip == nil || ip.IsLoopback() {
				continue
			}
			if ip[0] == 169 && ip[1] == 254 {
				continue
			}
			out = append(out, ip.String())
		}
	}
	if len(out) == 0 {
		out = allIPv4Fallback()
	}
	return uniqueStrings(out)
}

func isOwnHost(host string) bool {
	if host == "" || host == "0.0.0.0" {
		return true
	}
	for _, ip := range allOwnIPv4() {
		if ip == host {
			return true
		}
	}
	return false
}

func rankIPv4(in []string) []string {
	type scored struct {
		score int
		ip    string
	}
	var items []scored
	seen := map[string]bool{}
	for _, ip := range in {
		if seen[ip] || ip == "" || strings.HasPrefix(ip, "127.") {
			continue
		}
		seen[ip] = true
		items = append(items, scored{score: lanScore(ip), ip: ip})
	}
	sort.SliceStable(items, func(i, j int) bool { return items[i].score > items[j].score })
	out := make([]string, len(items))
	for i, it := range items {
		out[i] = it.ip
	}
	return out
}

func lanScore(ip string) int {
	parsed := net.ParseIP(ip).To4()
	if parsed == nil {
		return 0
	}
	if parsed[0] == 192 && parsed[1] == 168 {
		return 300
	}
	if parsed[0] == 10 {
		return 200
	}
	if parsed[0] == 172 && parsed[1] >= 16 && parsed[1] <= 31 {
		return 150
	}
	return 40
}

func allIPv4Fallback() []string {
	var out []string
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return out
	}
	for _, a := range addrs {
		ipn, ok := a.(*net.IPNet)
		if !ok || ipn.IP == nil || ipn.IP.IsLoopback() {
			continue
		}
		ip := ipn.IP.To4()
		if ip == nil || (ip[0] == 169 && ip[1] == 254) {
			continue
		}
		out = append(out, ip.String())
	}
	return out
}

func uniqueStrings(in []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, s := range in {
		if seen[s] {
			continue
		}
		seen[s] = true
		out = append(out, s)
	}
	return out
}

func v4String(ip net.IP) string {
	if ip == nil {
		return ""
	}
	if v4 := ip.To4(); v4 != nil {
		return v4.String()
	}
	return ip.String()
}

func (n *Node) listenUDP() error {
	s := n.settingsCopy()
	port := UDPPort(s.Port)
	lc := net.ListenConfig{Control: controlUDPSocket}
	pc, err := lc.ListenPacket(context.Background(), "udp4", fmt.Sprintf("0.0.0.0:%d", port))
	if err != nil {
		n.log.Println("UDP 发现端口打不开：", err)
		n.setStatus(fmt.Sprintf("发现端口 %d 打不开：%v", port, err))
		return err
	}
	uc := pc.(*net.UDPConn)
	n.mu.Lock()
	n.udpConn = uc
	n.mu.Unlock()
	for _, ip := range localIPv4() {
		joinMulticastOn(uc, net.ParseIP(ip))
	}
	joinMulticastOn(uc, net.IPv4zero)
	go n.udpLoop(uc)
	return nil
}

func (n *Node) broadcast() {
	s := n.settingsCopy()
	n.refreshIPs()
	if s.DiscoverMode == "off" {
		return
	}
	pkt := protocol.DiscoveryPacket{
		V: 1, ID: s.DeviceID, Name: s.DeviceName,
		Port: s.Port, HTTPPort: HTTPPort(s.Port), OS: OSName(),
	}
	data, _ := json.Marshal(pkt)
	udp := UDPPort(s.Port)
	if s.DiscoverMode == "favorites" {
		for _, fav := range s.Favorites {
			if fav.Host != "" {
				n.sendDiscover(data, fav.Host, udp)
			}
		}
		return
	}
	n.sendDiscover(data, "255.255.255.255", udp)
	n.sendDiscover(data, multicastGroup, udp)
	n.mu.Lock()
	ips := append([]string(nil), n.localIPs...)
	n.mu.Unlock()
	for _, ip := range ips {
		if b := guessBroadcast(ip); b != "" {
			n.sendDiscover(data, b, udp)
		}
	}
}

func (n *Node) sendDiscover(data []byte, ip string, port uint16) {
	dst := net.ParseIP(ip)
	if dst == nil {
		return
	}
	raddr := &net.UDPAddr{IP: dst, Port: int(port)}
	n.mu.Lock()
	uc := n.udpConn
	n.mu.Unlock()
	if uc != nil {
		if _, err := uc.WriteToUDP(data, raddr); err != nil {
			n.log.Println("发现包发送失败", ip, err)
		}
	}
	for _, src := range localIPv4() {
		laddr := &net.UDPAddr{IP: net.ParseIP(src), Port: 0}
		c, err := net.ListenUDP("udp4", laddr)
		if err != nil {
			continue
		}
		_ = setBroadcastConn(c)
		_, _ = c.WriteToUDP(data, raddr)
		c.Close()
	}
}

func (n *Node) udpLoop(uc *net.UDPConn) {
	buf := make([]byte, 2048)
	for {
		nr, addr, err := uc.ReadFromUDP(buf)
		if err != nil {
			return
		}
		var pkt protocol.DiscoveryPacket
		if json.Unmarshal(buf[:nr], &pkt) != nil {
			continue
		}
		if pkt.ID == "" || pkt.Port == 0 {
			continue
		}
		host := v4String(addr.IP)
		n.handleUDP(pkt, host)
	}
}

func (n *Node) handleUDP(pkt protocol.DiscoveryPacket, host string) {
	s := n.settingsCopy()
	if pkt.ID == s.DeviceID || pkt.ID == "" || isOwnHost(host) {
		n.mu.Lock()
		n.echoCount++
		n.mu.Unlock()
		n.refreshStatus()
		return
	}
	if pkt.PhoneClaim != "" {
		n.dropPhoneClaimed(pkt.PhoneClaim)
	}
	n.mu.Lock()
	n.recvCount++
	n.mu.Unlock()
	if !n.allowPeer(pkt.ID, "UDP 广播") {
		return
	}
	n.upsert(Peer{
		ID: pkt.ID, Name: pkt.Name, Host: host, Port: pkt.Port,
		HTTPPort: pkt.HTTPPort, OS: pkt.OS, Via: "UDP 广播", LastSeen: time.Now(),
	})
	if !pkt.Reply {
		n.unicastReply(host)
	}
}

func (n *Node) unicastReply(host string) {
	n.mu.Lock()
	if last, ok := n.lastUni[host]; ok && time.Since(last) < 2*time.Second {
		n.mu.Unlock()
		return
	}
	n.lastUni[host] = time.Now()
	n.mu.Unlock()
	s := n.settingsCopy()
	pkt := protocol.DiscoveryPacket{
		V: 1, ID: s.DeviceID, Name: s.DeviceName,
		Port: s.Port, HTTPPort: HTTPPort(s.Port), OS: OSName(), Reply: true,
	}
	data, _ := json.Marshal(pkt)
	n.sendDiscover(data, host, UDPPort(s.Port))
}
