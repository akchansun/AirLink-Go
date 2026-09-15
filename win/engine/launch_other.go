//go:build !windows && !linux

package engine

func SetLaunchAtLogin(on bool) {}

func LaunchAtLoginEnabled() bool { return false }
