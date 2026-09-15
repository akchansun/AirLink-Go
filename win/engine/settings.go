package engine

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"time"
)

const (
	DefaultPort  = 41789
	AppVersion   = "1.0.0"
	MaxFilesOnce = 20000
)

func HTTPPort(base uint16) uint16 { return base - 1 }
func UDPPort(base uint16) uint16  { return base + 1 }

func OSName() string {
	switch runtime.GOOS {
	case "windows":
		return "Windows"
	case "darwin":
		return "macOS"
	default:
		return "Linux"
	}
}

type Settings struct {
	DeviceName        string         `json:"deviceName"`
	ReceiveFolder     string         `json:"receiveFolder"`
	AutoAccept        bool           `json:"autoAccept"`
	ReceiveMode       string         `json:"receiveMode"`
	LaunchAtLogin     bool           `json:"launchAtLogin"`
	Favorites         []FavoritePeer `json:"favorites"`
	Pin               string         `json:"pin"`
	Port              uint16         `json:"port"`
	MaxConnections    int            `json:"maxConnections"`
	DeviceID          string         `json:"deviceId"`
	DiscoverMode      string         `json:"discoverMode"`
	AutoCopyText      bool           `json:"autoCopyText"`
	StoreRelayURL     string         `json:"storeRelayURL"`
	StorePublicURL    string         `json:"storePublicURL"`
	StoreWifiName     string         `json:"storeWifiName"`
	StoreWifiPassword string         `json:"storeWifiPassword"`
}

type FavoritePeer struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Host string `json:"host"`
	Port uint16 `json:"port"`
}

func settingsPath() string {
	home, _ := os.UserHomeDir()
	switch runtime.GOOS {
	case "windows":
		base := os.Getenv("APPDATA")
		if base == "" {
			base = filepath.Join(home, "AppData", "Roaming")
		}
		return filepath.Join(base, "互传", "settings.json")
	case "linux":
		base := os.Getenv("XDG_CONFIG_HOME")
		if base == "" {
			base = filepath.Join(home, ".config")
		}
		return filepath.Join(base, "huchuan", "settings.json")
	default:
		return filepath.Join(home, "Library", "Application Support", "HuchuanWin", "settings.json")
	}
}

func defaultReceiveFolder() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Downloads", "互传")
}

func defaultDeviceName() string {
	host, _ := os.Hostname()
	if host == "" {
		host = "电脑"
	}
	return host + " 的互传"
}

func LoadSettings() Settings {
	s := Settings{
		DeviceName:     defaultDeviceName(),
		ReceiveFolder:  defaultReceiveFolder(),
		Port:           DefaultPort,
		MaxConnections: 8,
		DiscoverMode:   "everyone",
		AutoCopyText:   true,
	}
	raw, err := os.ReadFile(settingsPath())
	if err == nil {
		var blob map[string]json.RawMessage
		_ = json.Unmarshal(raw, &blob)
		_ = json.Unmarshal(raw, &s)
		if _, ok := blob["autoCopyText"]; !ok {
			s.AutoCopyText = true
		}
	}
	if s.Port == 0 {
		s.Port = DefaultPort
	}
	if s.MaxConnections <= 0 {
		s.MaxConnections = 8
	}
	if s.DeviceName == "" {
		s.DeviceName = defaultDeviceName()
	}
	if s.ReceiveFolder == "" {
		s.ReceiveFolder = defaultReceiveFolder()
	}
	if s.DeviceID == "" {
		s.DeviceID = newUUID()
	}
	if s.Favorites == nil {
		s.Favorites = []FavoritePeer{}
	}
	switch s.DiscoverMode {
	case "everyone", "favorites", "off":
	default:
		s.DiscoverMode = "everyone"
	}
	s.NormalizeReceiveMode()
	_ = os.MkdirAll(s.ReceiveFolder, 0o755)
	s.Save()
	return s
}

func (s *Settings) NormalizeReceiveMode() {
	switch s.ReceiveMode {
	case "ask", "auto", "fav", "off":
	default:
		if s.AutoAccept {
			s.ReceiveMode = "auto"
		} else {
			s.ReceiveMode = "ask"
		}
	}
	s.AutoAccept = s.ReceiveMode == "auto"
}

func (s Settings) IsFavorite(id string) bool {
	for _, f := range s.Favorites {
		if f.ID == id {
			return true
		}
	}
	return false
}

func (s Settings) ShouldAutoAccept(peerID, peerName string) *bool {
	mode := s.ReceiveMode
	if mode == "" {
		if s.AutoAccept {
			mode = "auto"
		} else {
			mode = "ask"
		}
	}
	switch mode {
	case "auto":
		v := true
		return &v
	case "off":
		v := false
		return &v
	case "fav":
		for _, f := range s.Favorites {
			if f.ID == peerID || f.Name == peerName {
				v := true
				return &v
			}
		}
		return nil
	default:
		return nil
	}
}

func (s Settings) isSelfTest() bool {
	return s.DeviceID == "selftest-node"
}

func (s Settings) Save() {
	path := settingsPath()
	_ = os.MkdirAll(filepath.Dir(path), 0o755)
	raw, _ := json.MarshalIndent(s, "", "  ")
	_ = os.WriteFile(path, raw, 0o644)
}

func newUUID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		n := time.Now().UnixNano()
		for i := 0; i < 16; i++ {
			b[i] = byte(n >> (8 * (i % 8)))
			n = n*1103515245 + 12345
		}
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:])
}

type logMu struct {
	mu sync.Mutex
	f  *os.File
}

func appLogDir() string {
	return filepath.Dir(settingsPath())
}

func openLog() *logMu {
	_ = os.MkdirAll(appLogDir(), 0o755)
	f, err := os.OpenFile(filepath.Join(appLogDir(), "互传.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return &logMu{}
	}
	return &logMu{f: f}
}

func (l *logMu) Println(a ...any) {
	if l == nil || l.f == nil {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	fmt.Fprint(l.f, time.Now().Format("2006-01-02 15:04:05 "), fmt.Sprintln(a...))
}

func dialTCP(host string, port uint16, timeout time.Duration) (net.Conn, error) {
	d := net.Dialer{Timeout: timeout}
	conn, err := d.Dial("tcp4", net.JoinHostPort(host, fmt.Sprintf("%d", port)))
	if err != nil {
		return nil, err
	}
	if tc, ok := conn.(*net.TCPConn); ok {
		_ = tc.SetNoDelay(true)
		_ = tc.SetKeepAlive(true)
		_ = tc.SetKeepAlivePeriod(3 * time.Second)
	}
	return conn, nil
}

func guessBroadcast(ip string) string {
	parsed := net.ParseIP(ip).To4()
	if parsed == nil {
		return ""
	}
	parsed[3] = 255
	return parsed.String()
}
