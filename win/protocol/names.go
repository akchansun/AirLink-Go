package protocol

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"unicode/utf8"
)

func MeetCode(a, b string) string {
	pair := a + "|" + b
	if b < a {
		pair = b + "|" + a
	}
	var h uint32 = 2166136261
	for i := 0; i < len(pair); i++ {
		h ^= uint32(pair[i])
		h *= 16777619
	}
	return fmt.Sprintf("%04d", h%10000)
}

func SanitizeFileName(raw string) string {
	s := strings.TrimSpace(raw)
	var b strings.Builder
	for _, r := range s {
		switch r {
		case '/', '\\', ':', '*', '?', '"', '<', '>', '|', '\n', '\r', '\t':
			b.WriteByte('_')
		default:
			b.WriteRune(r)
		}
	}
	s = b.String()
	if s == "." || s == ".." {
		s = "_"
	}
	if s == "" {
		s = "未命名"
	}
	if utf8.RuneCountInString(s) > 180 {
		rs := []rune(s)
		s = string(rs[:180])
	}
	return s
}

func SanitizeRelativePath(raw string) (string, bool) {
	unified := strings.ReplaceAll(raw, "\\", "/")
	parts := strings.Split(unified, "/")
	var clean []string
	for _, part := range parts {
		if part == "" || part == "." {
			continue
		}
		if part == ".." {
			return "", false
		}
		if strings.HasPrefix(part, ".") && (part == ".DS_Store" || part == "Thumbs.db") {
			return "", false
		}
		trimmed := SanitizeFileName(part)
		if trimmed == "" {
			return "", false
		}
		clean = append(clean, trimmed)
	}
	if len(clean) == 0 {
		return "", false
	}
	return strings.Join(clean, "/"), true
}

func UniquePath(directory, relative string) string {
	dest := filepath.Join(directory, filepath.FromSlash(relative))
	_ = os.MkdirAll(filepath.Dir(dest), 0o755)
	if _, err := os.Stat(dest); os.IsNotExist(err) {
		return dest
	}
	ext := filepath.Ext(dest)
	base := strings.TrimSuffix(filepath.Base(dest), ext)
	parent := filepath.Dir(dest)
	for i := 1; i <= 9999; i++ {
		var name string
		if ext == "" {
			name = fmt.Sprintf("%s (%d)", base, i)
		} else {
			name = fmt.Sprintf("%s (%d)%s", base, i, ext)
		}
		candidate := filepath.Join(parent, name)
		if _, err := os.Stat(candidate); os.IsNotExist(err) {
			return candidate
		}
	}
	return filepath.Join(parent, fmt.Sprintf("%s-%s%s", base, randomID(), ext))
}

func randomID() string {
	return fmt.Sprintf("%d", os.Getpid())
}

func FormatSize(n uint64) string {
	return formatBytes(float64(n), false)
}

func FormatSpeed(bytesPerSecond float64) string {
	if bytesPerSecond < 1 {
		return "0 B/s"
	}
	return formatBytes(bytesPerSecond, false) + "/s"
}

func FormatETA(remaining uint64, speed float64) string {
	if speed <= 1 {
		return "计算中"
	}
	seconds := float64(remaining) / speed
	if seconds < 60 {
		return fmt.Sprintf("还剩 %d 秒", int(seconds))
	}
	if seconds < 3600 {
		return fmt.Sprintf("还剩 %d 分 %d 秒", int(seconds/60), int(seconds)%60)
	}
	h := int(seconds / 3600)
	m := int(seconds) % 3600 / 60
	return fmt.Sprintf("还剩 %d 小时 %d 分", h, m)
}

func formatBytes(value float64, _ bool) string {
	units := []string{"B", "KB", "MB", "GB", "TB"}
	idx := 0
	for value >= 1024 && idx < len(units)-1 {
		value /= 1024
		idx++
	}
	if idx == 0 {
		return fmt.Sprintf("%d %s", int(value), units[idx])
	}
	return fmt.Sprintf("%.1f %s", value, units[idx])
}
