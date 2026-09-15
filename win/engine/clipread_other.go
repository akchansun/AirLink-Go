//go:build !windows

package engine

import (
	"os/exec"
	"runtime"
	"strings"
)

func readClipboardOS() string {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.Command("pbpaste")
	default:
		if path, err := exec.LookPath("wl-paste"); err == nil {
			cmd = exec.Command(path)
		} else if path, err := exec.LookPath("xclip"); err == nil {
			cmd = exec.Command(path, "-selection", "clipboard", "-o")
		} else {
			return ""
		}
	}
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	return strings.TrimRight(string(out), "\n")
}
