package engine

import (
	"bytes"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

type portMap struct {
	control string
	service string
	port    uint16
}

var (
	mapMu   sync.Mutex
	lastMap *portMap
)

func isPublicIPv4(s string) bool {
	ip := net.ParseIP(s).To4()
	if ip == nil {
		return false
	}
	if ip.IsLoopback() || ip.IsLinkLocalUnicast() || ip.IsMulticast() {
		return false
	}
	if ip[0] == 10 {
		return false
	}
	if ip[0] == 172 && ip[1] >= 16 && ip[1] <= 31 {
		return false
	}
	if ip[0] == 192 && ip[1] == 168 {
		return false
	}
	if ip[0] == 100 && ip[1] >= 64 && ip[1] <= 127 {
		return false
	}
	return true
}

func openHTTPPort(port uint16, localIPs []string) (string, bool) {
	closeHTTPPort()
	for _, ip := range localIPs {
		if ip == "" || ip == "127.0.0.1" {
			continue
		}
		if host, ok := tryUPNP(ip, port); ok {
			return host, true
		}
		if host, ok := tryNATPmp(ip, port); ok {
			return host, true
		}
	}
	return "", false
}

func closeHTTPPort() {
	mapMu.Lock()
	m := lastMap
	lastMap = nil
	mapMu.Unlock()
	if m == nil {
		return
	}
	body := soapArgs(m.service, "DeletePortMapping", map[string]string{
		"NewRemoteHost":   "",
		"NewExternalPort": fmt.Sprint(m.port),
		"NewProtocol":     "TCP",
	})
	_, _ = soapCall(m.control, m.service, "DeletePortMapping", body)
}

func tryUPNP(localIP string, port uint16) (string, bool) {
	loc := ssdpLocation(localIP)
	if loc == "" {
		return "", false
	}
	ctrl, service := fetchControl(loc)
	if ctrl == "" {
		return "", false
	}
	extXML, _ := soapCall(ctrl, service, "GetExternalIPAddress", soapArgs(service, "GetExternalIPAddress", nil))
	ext := xmlTag(extXML, "NewExternalIPAddress")
	add := soapArgs(service, "AddPortMapping", map[string]string{
		"NewRemoteHost":             "",
		"NewExternalPort":           fmt.Sprint(port),
		"NewProtocol":               "TCP",
		"NewInternalPort":           fmt.Sprint(port),
		"NewInternalClient":         localIP,
		"NewEnabled":                "1",
		"NewPortMappingDescription": "huchuan-booth",
		"NewLeaseDuration":          "7200",
	})
	if _, err := soapCall(ctrl, service, "AddPortMapping", add); err != nil {
		return "", false
	}
	if !isPublicIPv4(ext) {
		return "", false
	}
	mapMu.Lock()
	lastMap = &portMap{control: ctrl, service: service, port: port}
	mapMu.Unlock()
	return fmt.Sprintf("http://%s:%d", ext, port), true
}

func ssdpLocation(localIP string) string {
	laddr := &net.UDPAddr{IP: net.ParseIP(localIP), Port: 0}
	c, err := net.ListenUDP("udp4", laddr)
	if err != nil {
		return ""
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(1400 * time.Millisecond))
	dst := &net.UDPAddr{IP: net.ParseIP("239.255.255.250"), Port: 1900}
	sts := []string{
		"urn:schemas-upnp-org:service:WANIPConnection:1",
		"urn:schemas-upnp-org:service:WANPPPConnection:1",
		"urn:schemas-upnp-org:device:InternetGatewayDevice:1",
	}
	for _, st := range sts {
		msg := "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: " + st + "\r\n\r\n"
		_, _ = c.WriteToUDP([]byte(msg), dst)
	}
	buf := make([]byte, 4096)
	n, _, err := c.ReadFromUDP(buf)
	if err != nil || n <= 0 {
		return ""
	}
	text := string(buf[:n])
	if v := httpHeader(text, "LOCATION"); v != "" {
		return v
	}
	return httpHeader(text, "Location")
}

func fetchControl(location string) (string, string) {
	client := &http.Client{Timeout: 2 * time.Second}
	resp, err := client.Get(location)
	if err != nil {
		return "", ""
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 256*1024))
	xml := string(raw)
	types := []string{
		"urn:schemas-upnp-org:service:WANIPConnection:1",
		"urn:schemas-upnp-org:service:WANIPConnection:2",
		"urn:schemas-upnp-org:service:WANPPPConnection:1",
	}
	for _, part := range strings.Split(xml, "<service") {
		typ := xmlTag(part, "serviceType")
		path := xmlTag(part, "controlURL")
		ok := false
		for _, t := range types {
			if typ == t {
				ok = true
				break
			}
		}
		if !ok || path == "" {
			continue
		}
		return absURL(path, location), typ
	}
	return "", ""
}

func soapCall(control, service, action, body string) (string, error) {
	req, err := http.NewRequest(http.MethodPost, control, strings.NewReader(body))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "text/xml; charset=\"utf-8\"")
	req.Header.Set("SOAPAction", `"`+service+"#"+action+`"`)
	client := &http.Client{Timeout: 2 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("upnp %d", resp.StatusCode)
	}
	return string(raw), nil
}

func soapArgs(service, action string, fields map[string]string) string {
	var b bytes.Buffer
	b.WriteString(`<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:`)
	b.WriteString(action)
	b.WriteString(` xmlns:u="`)
	b.WriteString(service)
	b.WriteString(`">`)
	for k, v := range fields {
		b.WriteByte('<')
		b.WriteString(k)
		b.WriteByte('>')
		b.WriteString(v)
		b.WriteString("</")
		b.WriteString(k)
		b.WriteByte('>')
	}
	b.WriteString(`</u:`)
	b.WriteString(action)
	b.WriteString(`></s:Body></s:Envelope>`)
	return b.String()
}

func tryNATPmp(localIP string, port uint16) (string, bool) {
	gw := guessGateway(localIP)
	if gw == "" {
		return "", false
	}
	c, err := net.DialTimeout("udp4", net.JoinHostPort(gw, "5351"), 600*time.Millisecond)
	if err != nil {
		return "", false
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(600 * time.Millisecond))
	if _, err := c.Write([]byte{0, 0}); err != nil {
		return "", false
	}
	buf := make([]byte, 32)
	n, err := c.Read(buf)
	if err != nil || n < 12 || buf[0] != 0 || buf[3] != 0 {
		return "", false
	}
	wan := fmt.Sprintf("%d.%d.%d.%d", buf[8], buf[9], buf[10], buf[11])
	req := []byte{0, 2, 0, 0, byte(port >> 8), byte(port), byte(port >> 8), byte(port), 0, 0, 0x1C, 0x20}
	if _, err := c.Write(req); err != nil {
		return "", false
	}
	n, err = c.Read(buf)
	if err != nil || n < 12 || buf[0] != 0 || buf[3] != 0 {
		return "", false
	}
	if !isPublicIPv4(wan) {
		return "", false
	}
	return fmt.Sprintf("http://%s:%d", wan, port), true
}

func guessGateway(ip string) string {
	p := net.ParseIP(ip).To4()
	if p == nil {
		return ""
	}
	p[3] = 1
	return p.String()
}

func httpHeader(text, key string) string {
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if len(line) >= len(key)+1 && strings.EqualFold(line[:len(key)], key) && line[len(key)] == ':' {
			return strings.TrimSpace(line[len(key)+1:])
		}
	}
	return ""
}

func xmlTag(xml, name string) string {
	names := []string{name, "s:" + name, "u:" + name}
	low := strings.ToLower(xml)
	for _, n := range names {
		open := "<" + strings.ToLower(n) + ">"
		close := "</" + strings.ToLower(n) + ">"
		a := strings.Index(low, open)
		if a < 0 {
			continue
		}
		a += len(open)
		b := strings.Index(low[a:], close)
		if b < 0 {
			continue
		}
		return strings.TrimSpace(xml[a : a+b])
	}
	return ""
}

func absURL(path, base string) string {
	if strings.HasPrefix(strings.ToLower(path), "http") {
		return path
	}
	u, err := url.Parse(base)
	if err != nil {
		return path
	}
	ref, err := url.Parse(path)
	if err != nil {
		return path
	}
	return u.ResolveReference(ref).String()
}
