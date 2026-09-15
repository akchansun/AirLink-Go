//go:build !windows

package engine

import "os/exec"

func hideConsole(cmd *exec.Cmd) {}
