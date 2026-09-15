package engine

import (
	"os/exec"
	"runtime"
	"strings"
	"sync"
	"time"
	"unicode"
)

func WifiQRPayload(ssid, password string) string {
	name := strings.TrimSpace(ssid)
	if name == "" {
		return ""
	}
	pass := strings.TrimSpace(password)
	if pass == "" {
		return "WIFI:S:" + wifiEscape(name) + ";T:nopass;;"
	}
	return "WIFI:S:" + wifiEscape(name) + ";T:WPA;P:" + wifiEscape(pass) + ";;"
}

func wifiEscape(s string) string {
	var b strings.Builder
	for _, r := range s {
		if strings.ContainsRune(`\;,"`, r) || r == ':' {
			b.WriteByte('\\')
		}
		b.WriteRune(r)
	}
	return b.String()
}

var (
	ssidMu    sync.Mutex
	ssidCache string
	ssidAt    time.Time
)

func RefreshSSID() string {
	ssidMu.Lock()
	ssidAt = time.Time{}
	ssidMu.Unlock()
	return CurrentSSID()
}

func (n *Node) FillStoreWifi() (string, error) {
	name := strings.TrimSpace(RefreshSSID())
	if name == "" {
		return "", errMsg("没读到当前 Wi-Fi 名称，请自己填。电脑如果用的网线，就没有 Wi-Fi 名称。")
	}
	s := n.settingsCopy()
	s.StoreWifiName = name
	n.UpdateSettings(s)
	return name, nil
}

func CurrentSSID() string {
	ssidMu.Lock()
	defer ssidMu.Unlock()
	if !ssidAt.IsZero() && time.Since(ssidAt) < 10*time.Second {
		return ssidCache
	}
	name := detectSSID()
	ssidAt = time.Now()
	ssidCache = name
	return name
}

func detectSSID() string {
	switch runtime.GOOS {
	case "windows":
		return parseNetshSSID(runHidden("netsh", "wlan", "show", "interfaces"))
	case "darwin":
		dev := wifiDeviceDarwin()
		if dev == "" {
			dev = "en0"
		}
		return parseAirportSSID(runHidden("/usr/sbin/networksetup", "-getairportnetwork", dev))
	default:
		if s := strings.TrimSpace(runHidden("iwgetid", "-r")); s != "" {
			return s
		}
		return parseNmcliSSID(runHidden("nmcli", "-t", "-f", "active,ssid", "dev", "wifi"))
	}
}

func wifiDeviceDarwin() string {
	raw := runHidden("/usr/sbin/networksetup", "-listallhardwareports")
	lines := strings.Split(raw, "\n")
	for i, line := range lines {
		if strings.Contains(line, "Wi-Fi") || strings.Contains(line, "AirPort") {
			if i+1 < len(lines) && strings.Contains(lines[i+1], "Device:") {
				return strings.TrimSpace(strings.TrimPrefix(lines[i+1], "Device:"))
			}
		}
	}
	return ""
}

func parseAirportSSID(raw string) string {
	line := strings.TrimSpace(raw)
	if line == "" || strings.Contains(line, "not associated") {
		return ""
	}
	_, rest, ok := strings.Cut(line, ": ")
	if !ok {
		return ""
	}
	return strings.TrimSpace(rest)
}

func parseNetshSSID(raw string) string {
	for _, line := range strings.Split(raw, "\n") {
		trim := strings.TrimSpace(line)
		if trim == "" || strings.Contains(strings.ToUpper(trim), "BSSID") {
			continue
		}
		key, val, ok := strings.Cut(trim, ":")
		if !ok {
			continue
		}
		k := strings.TrimSpace(key)
		if strings.EqualFold(k, "SSID") || strings.Contains(k, "SSID") {
			name := strings.TrimSpace(val)
			if name != "" && !strings.EqualFold(name, "BSSID") {
				return name
			}
		}
	}
	return ""
}

func parseNmcliSSID(raw string) string {
	for _, line := range strings.Split(raw, "\n") {
		parts := strings.SplitN(strings.TrimSpace(line), ":", 2)
		if len(parts) == 2 && (parts[0] == "yes" || parts[0] == "是") {
			return strings.TrimSpace(parts[1])
		}
	}
	return ""
}

func runHidden(name string, args ...string) string {
	cmd := exec.Command(name, args...)
	hideConsole(cmd)
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	s := string(out)
	if !utf8Printable(s) {
		return ""
	}
	return s
}

func utf8Printable(s string) bool {
	for _, r := range s {
		if r == unicode.ReplacementChar {
			return false
		}
	}
	return true
}
