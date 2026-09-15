//go:build windows

package engine

import (
	"os"

	"golang.org/x/sys/windows/registry"
)

func SetLaunchAtLogin(on bool) {
	exe, err := os.Executable()
	if err != nil || exe == "" {
		return
	}
	k, err := registry.OpenKey(registry.CURRENT_USER, `Software\Microsoft\Windows\CurrentVersion\Run`, registry.SET_VALUE)
	if err != nil {
		k, err = registry.OpenKey(registry.CURRENT_USER, `Software\Microsoft\Windows\CurrentVersion\Run`, registry.ALL_ACCESS)
		if err != nil {
			return
		}
	}
	defer k.Close()
	if on {
		_ = k.SetStringValue("互传", `"`+exe+`"`)
		return
	}
	_ = k.DeleteValue("互传")
}

func LaunchAtLoginEnabled() bool {
	k, err := registry.OpenKey(registry.CURRENT_USER, `Software\Microsoft\Windows\CurrentVersion\Run`, registry.QUERY_VALUE)
	if err != nil {
		return false
	}
	defer k.Close()
	_, _, err = k.GetStringValue("互传")
	return err == nil
}
