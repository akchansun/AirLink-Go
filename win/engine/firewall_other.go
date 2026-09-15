//go:build !windows

package engine

func allowFirewall(port uint16) {}

func openFirewallSettings() {}
