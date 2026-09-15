//go:build !windows

package engine

import (
	"os/exec"
	"runtime"
	"strings"
)

func copyTextOS(s string) {
	if s == "" {
		return
	}
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.Command("pbcopy")
	default:
		if path, err := exec.LookPath("wl-copy"); err == nil {
			cmd = exec.Command(path)
		} else if path, err := exec.LookPath("xclip"); err == nil {
			cmd = exec.Command(path, "-selection", "clipboard")
		} else {
			return
		}
	}
	cmd.Stdin = strings.NewReader(s)
	_ = cmd.Run()
}
