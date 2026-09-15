//go:build !windows && !linux

package engine

func KillOtherHuChuan() int { return 0 }
func ClaimInstance() bool   { return true }
func ReleaseInstance()      {}
