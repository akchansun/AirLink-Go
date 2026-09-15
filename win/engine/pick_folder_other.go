//go:build !windows && !linux

package engine

func nativePickFolder(owner uintptr) []string { return nil }
