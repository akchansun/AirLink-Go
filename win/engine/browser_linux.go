//go:build linux

package engine

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

var chromeNames = []string{
	"google-chrome-stable",
	"google-chrome",
	"chromium-browser",
	"chromium",
	"microsoft-edge-stable",
	"microsoft-edge",
	"browser",
	"uos-browser",
	"qaxbrowser-safe",
	"qaxbrowser",
	"vivaldi-stable",
	"vivaldi",
	"brave-browser",
}

func OpenLocalUI(url string) {
	if url == "" {
		return
	}
	bin, kind := findLinuxBrowser()
	if bin == "" {
		fmt.Fprintln(os.Stderr, "找不到浏览器。请手动打开：", url)
		return
	}
	profile := filepath.Join(appLogDir(), "browser-profile")
	_ = os.MkdirAll(profile, 0o755)
	var cmd *exec.Cmd
	switch kind {
	case "chrome":
		cmd = exec.Command(bin,
			"--app="+url,
			"--window-size=860,560",
			"--class=Huchuan",
			"--user-data-dir="+profile,
			"--no-first-run",
			"--no-default-browser-check",
		)
	case "firefox":
		cmd = exec.Command(bin, "--new-window", "--class=Huchuan", url)
	default:
		cmd = exec.Command(bin, url)
	}
	cmd.Stdout = nil
	cmd.Stderr = nil
	if err := cmd.Start(); err != nil {
		cmd = exec.Command(bin, url)
		if err := cmd.Start(); err != nil {
			fmt.Fprintln(os.Stderr, "打不开窗口，请手动打开：", url)
			return
		}
	}
	go func() { _ = cmd.Wait() }()
}

func findLinuxBrowser() (string, string) {
	for _, name := range chromeNames {
		if p, err := exec.LookPath(name); err == nil {
			return p, "chrome"
		}
	}
	if p, err := exec.LookPath("firefox"); err == nil {
		return p, "firefox"
	}
	if p, err := exec.LookPath("xdg-open"); err == nil {
		return p, "xdg"
	}
	return "", ""
}

func linuxConfigDir() string {
	if xdg := strings.TrimSpace(os.Getenv("XDG_CONFIG_HOME")); xdg != "" {
		return filepath.Join(xdg, "huchuan")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "huchuan")
}
