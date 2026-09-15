package engine

import (
	"context"
	"strconv"
	"strings"
	"time"

	"github.com/grandcat/zeroconf"
)

type mdnsService interface {
	Shutdown()
}

func (n *Node) startMDNS() {
	s := n.settingsCopy()
	if s.DeviceID == "selftest-node" {
		return
	}
	if s.DiscoverMode != "everyone" {
		return
	}
	txt := []string{
		"id=" + s.DeviceID,
		"name=" + s.DeviceName,
		"http=" + strconv.Itoa(int(HTTPPort(s.Port))),
		"os=" + OSName(),
	}
	instance := mdnsInstance(s.DeviceName, s.DeviceID)
	server, err := zeroconf.Register(instance, "_huchuan._tcp", "local.", int(s.Port), txt, nil)
	if err != nil {
		n.log.Println("局域网名字广播失败：", err)
		server, err = zeroconf.Register("HuChuan-"+shortID(s.DeviceID), "_huchuan._tcp", "local.", int(s.Port), txt, nil)
		if err != nil {
			n.log.Println("局域网名字广播仍失败：", err)
		}
	}
	if server != nil {
		n.mu.Lock()
		n.mdnsServer = server
		n.mu.Unlock()
	}

	resolver, err := zeroconf.NewResolver(nil)
	if err != nil {
		n.log.Println("局域网名字查找失败：", err)
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	n.mu.Lock()
	n.mdnsCancel = cancel
	n.mu.Unlock()
	entries := make(chan *zeroconf.ServiceEntry, 16)
	go func() {
		for e := range entries {
			n.handleMDNS(e)
		}
	}()
	go func() {
		if err := resolver.Browse(ctx, "_huchuan._tcp", "local.", entries); err != nil {
			n.log.Println("局域网名字查找：", err)
		}
	}()
}

func (n *Node) handleMDNS(e *zeroconf.ServiceEntry) {
	if e == nil || e.Port <= 0 {
		return
	}
	id := txtValue(e.Text, "id")
	name := txtValue(e.Text, "name")
	if name == "" {
		name = e.Instance
	}
	osname := txtValue(e.Text, "os")
	if osname == "" {
		osname = "电脑"
	}
	httpPort := uint16(0)
	if v := txtValue(e.Text, "http"); v != "" {
		if parsed, err := strconv.Atoi(v); err == nil && parsed > 0 && parsed < 65536 {
			httpPort = uint16(parsed)
		}
	}
	s := n.settingsCopy()
	if id != "" && id == s.DeviceID {
		return
	}
	port := uint16(e.Port)
	if httpPort == 0 {
		httpPort = HTTPPort(port)
	}
	var hosts []string
	for _, ip := range e.AddrIPv4 {
		if ip == nil {
			continue
		}
		v4 := ip.To4()
		if v4 == nil || v4.IsLoopback() || v4.IsLinkLocalUnicast() {
			continue
		}
		hosts = append(hosts, v4.String())
	}
	if len(hosts) == 0 {
		return
	}
	for _, host := range hosts {
		if isOwnHost(host) {
			continue
		}
		peerID := id
		if peerID == "" {
			peerID = "bonjour-" + host + "-" + strconv.Itoa(int(port))
		}
		n.upsert(Peer{
			ID: peerID, Name: name, Host: host, Port: port,
			HTTPPort: httpPort, OS: osname, Via: "局域网名字", LastSeen: time.Now(),
		})
	}
}

func txtValue(txt []string, key string) string {
	prefix := key + "="
	for _, t := range txt {
		if strings.HasPrefix(t, prefix) {
			return strings.TrimPrefix(t, prefix)
		}
	}
	return ""
}

func mdnsInstance(name, id string) string {
	var b strings.Builder
	for _, r := range name {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '-':
			b.WriteRune(r)
		case r == ' ' || r == '_':
			b.WriteByte('-')
		}
	}
	s := strings.Trim(b.String(), "-")
	if s == "" {
		s = "HuChuan-" + shortID(id)
	}
	if len(s) > 60 {
		s = s[:60]
	}
	return s
}

func shortID(id string) string {
	cleaned := strings.ReplaceAll(id, "-", "")
	if len(cleaned) >= 8 {
		return cleaned[:8]
	}
	if cleaned != "" {
		return cleaned
	}
	return "pc"
}
