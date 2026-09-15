//go:build !linux

package engine

func HandOffToRunning() bool { return false }
