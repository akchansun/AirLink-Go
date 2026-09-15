package engine

import (
	"encoding/json"
	"os"
	"path/filepath"
	"time"
)

type HistoryItem struct {
	ID       string  `json:"id"`
	Title    string  `json:"title"`
	PeerName string  `json:"peerName"`
	Path     string  `json:"path"`
	Text     string  `json:"text"`
	Time     float64 `json:"time"`
	Kind     string  `json:"kind"`
}

const historyLimit = 80

func historyPath() string {
	return filepath.Join(filepath.Dir(settingsPath()), "history.json")
}

func loadHistory(deviceID string) []HistoryItem {
	if deviceID == "selftest-node" {
		return nil
	}
	raw, err := os.ReadFile(historyPath())
	if err != nil {
		return nil
	}
	var list []HistoryItem
	if json.Unmarshal(raw, &list) != nil {
		return nil
	}
	return list
}

func (n *Node) addHistory(title, peerName, path, text string, kind ...string) {
	if n.settingsCopy().isSelfTest() {
		return
	}
	k := "recv"
	if len(kind) > 0 && kind[0] != "" {
		k = kind[0]
	}
	item := HistoryItem{
		ID: newUUID(), Title: title, PeerName: peerName,
		Path: path, Text: text, Time: float64(time.Now().Unix()), Kind: k,
	}
	n.mu.Lock()
	n.history = append([]HistoryItem{item}, n.history...)
	if len(n.history) > historyLimit {
		n.history = n.history[:historyLimit]
	}
	list := append([]HistoryItem(nil), n.history...)
	n.mu.Unlock()
	raw, _ := json.MarshalIndent(list, "", "  ")
	_ = os.MkdirAll(filepath.Dir(historyPath()), 0o755)
	_ = os.WriteFile(historyPath(), raw, 0o644)
}

func (n *Node) ClearHistory() {
	n.mu.Lock()
	n.history = nil
	n.mu.Unlock()
	if n.settingsCopy().isSelfTest() {
		return
	}
	_ = os.WriteFile(historyPath(), []byte("[]"), 0o644)
}
