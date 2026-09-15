package engine

import (
	"os"
	"path/filepath"
	"strings"
)

func WriteUIAddr(addr string) {
	if addr == "" {
		return
	}
	_ = os.MkdirAll(appLogDir(), 0o755)
	_ = os.WriteFile(uiAddrPath(), []byte(addr+"\n"), 0o644)
}

func ReadUIAddr() string {
	raw, err := os.ReadFile(uiAddrPath())
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(raw))
}

func uiAddrPath() string {
	return filepath.Join(appLogDir(), "ui.url")
}
