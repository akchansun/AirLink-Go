//go:build linux

package engine

import (
	"os"
	"os/exec"
	"strings"
)

func nativePickerAvailable() bool {
	if os.Getenv("DISPLAY") == "" && os.Getenv("WAYLAND_DISPLAY") == "" {
		return false
	}
	return linuxPicker() != ""
}

func linuxPicker() string {
	for _, name := range []string{"zenity", "qarma", "kdialog"} {
		if _, err := exec.LookPath(name); err == nil {
			return name
		}
	}
	return ""
}

func nativePickFiles(owner uintptr) []string {
	_ = owner
	switch linuxPicker() {
	case "zenity", "qarma":
		return runPicker(linuxPicker(), "--file-selection", "--multiple", "--separator=\n", "--title=选择要发送的文件")
	case "kdialog":
		return runPicker("kdialog", "--getopenfilename", "--multiple", "--separate-output")
	default:
		return nil
	}
}

func nativePickFolder(owner uintptr) []string {
	_ = owner
	switch linuxPicker() {
	case "zenity", "qarma":
		return runPicker(linuxPicker(), "--file-selection", "--directory", "--title=选择要发送的文件夹")
	case "kdialog":
		return runPicker("kdialog", "--getexistingdirectory")
	default:
		return nil
	}
}

func runPicker(name string, args ...string) []string {
	cmd := exec.Command(name, args...)
	out, err := cmd.Output()
	if err != nil {
		return nil
	}
	var paths []string
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if line != "" {
			paths = append(paths, line)
		}
	}
	return paths
}
