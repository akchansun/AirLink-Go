//go:build windows

package engine

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

func firewallMarker() string {
	return filepath.Join(appLogDir(), "firewall.ok")
}

func firewallReady() bool {
	_, err := os.Stat(firewallMarker())
	return err == nil
}

func markFirewallReady() {
	_ = os.WriteFile(firewallMarker(), []byte("ok"), 0o644)
}

func allowFirewall(port uint16) {
	if port == 0 {
		port = DefaultPort
	}
	exe, err := os.Executable()
	if err != nil || exe == "" {
		return
	}
	if tryNetsh(exe, port) {
		markFirewallReady()
		return
	}
	if firewallReady() {
		return
	}
	messageBox("互传需要通过防火墙，另一台电脑才能发现这台电脑。\n\n接下来会弹出「用户帐户控制」，请点「是」。\n没有这一步，就永远找不到对方。")
	if elevateNetsh(exe, port) {
		markFirewallReady()
	}
}

func tryNetsh(exe string, port uint16) bool {
	ok := true
	for _, args := range netshArgs(exe, port) {
		cmd := exec.Command("netsh", args...)
		cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
		if cmd.Run() != nil {
			ok = false
		}
	}
	return ok
}

func netshArgs(exe string, port uint16) [][]string {
	return [][]string{
		{"advfirewall", "firewall", "add", "rule",
			"name=HuChuanIn", "dir=in", "action=allow", "program=" + exe,
			"enable=yes", "profile=any"},
		{"advfirewall", "firewall", "add", "rule",
			"name=HuChuanOut", "dir=out", "action=allow", "program=" + exe,
			"enable=yes", "profile=any"},
		{"advfirewall", "firewall", "add", "rule",
			"name=HuChuanTCP", "dir=in", "action=allow", "protocol=TCP",
			fmt.Sprintf("localport=%d", port), "enable=yes", "profile=any"},
		{"advfirewall", "firewall", "add", "rule",
			"name=HuChuanUDP", "dir=in", "action=allow", "protocol=UDP",
			fmt.Sprintf("localport=%d", UDPPort(port)), "enable=yes", "profile=any"},
		{"advfirewall", "firewall", "add", "rule",
			"name=HuChuanHTTP", "dir=in", "action=allow", "protocol=TCP",
			fmt.Sprintf("localport=%d", HTTPPort(port)), "enable=yes", "profile=any"},
		{"advfirewall", "firewall", "add", "rule",
			"name=HuChuanMDNS", "dir=in", "action=allow", "protocol=UDP",
			"localport=5353", "enable=yes", "profile=any"},
	}
}

func elevateNetsh(exe string, port uint16) bool {
	script := fmt.Sprintf(
		`netsh advfirewall firewall delete rule name=HuChuanIn & `+
			`netsh advfirewall firewall add rule name=HuChuanIn dir=in action=allow program="%s" enable=yes profile=any & `+
			`netsh advfirewall firewall add rule name=HuChuanOut dir=out action=allow program="%s" enable=yes profile=any & `+
			`netsh advfirewall firewall add rule name=HuChuanTCP dir=in action=allow protocol=TCP localport=%d enable=yes profile=any & `+
			`netsh advfirewall firewall add rule name=HuChuanUDP dir=in action=allow protocol=UDP localport=%d enable=yes profile=any & `+
			`netsh advfirewall firewall add rule name=HuChuanHTTP dir=in action=allow protocol=TCP localport=%d enable=yes profile=any & `+
			`netsh advfirewall firewall add rule name=HuChuanMDNS dir=in action=allow protocol=UDP localport=5353 enable=yes profile=any`,
		exe, exe, port, UDPPort(port), HTTPPort(port),
	)
	verb, _ := windows.UTF16PtrFromString("runas")
	file, _ := windows.UTF16PtrFromString("cmd.exe")
	params, _ := windows.UTF16PtrFromString("/C " + script)
	cwd, _ := windows.UTF16PtrFromString(filepath.Dir(exe))
	const swHide = 0
	ret, _, _ := windows.NewLazySystemDLL("shell32.dll").NewProc("ShellExecuteW").Call(
		0,
		uintptr(unsafe.Pointer(verb)),
		uintptr(unsafe.Pointer(file)),
		uintptr(unsafe.Pointer(params)),
		uintptr(unsafe.Pointer(cwd)),
		swHide,
	)
	return ret > 32
}

func openFirewallSettings() {
	_ = exec.Command("control", "firewall.cpl").Start()
}

func messageBox(text string) {
	t, _ := windows.UTF16PtrFromString(text)
	title, _ := windows.UTF16PtrFromString("互传")
	user32 := windows.NewLazySystemDLL("user32.dll")
	user32.NewProc("MessageBoxW").Call(0, uintptr(unsafe.Pointer(t)), uintptr(unsafe.Pointer(title)), 0x00000040)
}
