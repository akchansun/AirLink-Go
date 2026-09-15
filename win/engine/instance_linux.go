//go:build linux

package engine

import (
	"os"
	"path/filepath"

	"golang.org/x/sys/unix"
)

var lockFile *os.File

func KillOtherHuChuan() int { return 0 }

func ClaimInstance() bool {
	dir := linuxConfigDir()
	_ = os.MkdirAll(dir, 0o755)
	f, err := os.OpenFile(filepath.Join(dir, "instance.lock"), os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return true
	}
	if err := unix.Flock(int(f.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		_ = f.Close()
		return false
	}
	lockFile = f
	return true
}

func ReleaseInstance() {
	if lockFile == nil {
		return
	}
	_ = unix.Flock(int(lockFile.Fd()), unix.LOCK_UN)
	_ = lockFile.Close()
	lockFile = nil
}

func HandOffToRunning() bool {
	url := ReadUIAddr()
	if url == "" {
		return false
	}
	OpenLocalUI(url)
	return true
}
