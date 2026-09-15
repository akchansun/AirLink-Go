//go:build !windows && !linux

package engine

func nativePickerAvailable() bool { return false }

func nativePickFiles(owner uintptr) []string { return nil }
