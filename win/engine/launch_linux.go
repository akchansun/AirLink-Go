//go:build linux

package engine

import (
	"os"
	"path/filepath"
	"strings"
)

func SetLaunchAtLogin(on bool) {
	path := autostartDesktopPath()
	if !on {
		_ = os.Remove(path)
		return
	}
	body := linuxDesktopBody()
	if body == "" {
		return
	}
	_ = os.MkdirAll(filepath.Dir(path), 0o755)
	_ = os.WriteFile(path, []byte(body), 0o644)
}

func LaunchAtLoginEnabled() bool {
	_, err := os.Stat(autostartDesktopPath())
	return err == nil
}

func InstallDesktopShortcut() {
	body := linuxDesktopBody()
	if body == "" {
		return
	}
	appPath := filepath.Join(linuxDataHome(), "applications", "huchuan.desktop")
	_ = os.MkdirAll(filepath.Dir(appPath), 0o755)
	_ = os.WriteFile(appPath, []byte(body), 0o644)
	if icon := linuxIconPath(); icon != "" {
		dest := filepath.Join(linuxDataHome(), "icons", "hicolor", "256x256", "apps", "huchuan.png")
		_ = os.MkdirAll(filepath.Dir(dest), 0o755)
		if raw, err := os.ReadFile(icon); err == nil {
			_ = os.WriteFile(dest, raw, 0o644)
		}
	}
	if LaunchAtLoginEnabled() {
		SetLaunchAtLogin(true)
	}
}

func linuxDesktopBody() string {
	exe := linuxExecutable()
	if exe == "" {
		return ""
	}
	icon := linuxIconPath()
	if icon == "" {
		icon = "huchuan"
	}
	return "[Desktop Entry]\n" +
		"Type=Application\n" +
		"Version=1.0\n" +
		"Name=互传\n" +
		"Comment=局域网文件互传，同一网络里传文件和文字\n" +
		"Exec=\"" + exe + "\"\n" +
		"Icon=" + icon + "\n" +
		"Terminal=false\n" +
		"Categories=Network;FileTransfer;Utility;\n" +
		"StartupNotify=true\n" +
		"StartupWMClass=Huchuan\n"
}

func linuxExecutable() string {
	exe, err := os.Executable()
	if err != nil || exe == "" {
		return ""
	}
	if real, err := filepath.EvalSymlinks(exe); err == nil && real != "" {
		return real
	}
	return exe
}

func linuxIconPath() string {
	exe := linuxExecutable()
	if exe == "" {
		return ""
	}
	p := filepath.Join(filepath.Dir(exe), "icon.png")
	if st, err := os.Stat(p); err == nil && !st.IsDir() {
		return p
	}
	return ""
}

func autostartDesktopPath() string {
	if xdg := strings.TrimSpace(os.Getenv("XDG_CONFIG_HOME")); xdg != "" {
		return filepath.Join(xdg, "autostart", "huchuan.desktop")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "autostart", "huchuan.desktop")
}

func linuxDataHome() string {
	if xdg := strings.TrimSpace(os.Getenv("XDG_DATA_HOME")); xdg != "" {
		return xdg
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".local", "share")
}
