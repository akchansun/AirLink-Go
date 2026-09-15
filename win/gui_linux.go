//go:build linux

package main

import (
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"huchuan/engine"
)

func runUI(url string, n *engine.Node) {
	_ = n
	engine.InstallDesktopShortcut()
	engine.OpenLocalUI(url)
	wait := make(chan os.Signal, 1)
	signal.Notify(wait, syscall.SIGINT, syscall.SIGTERM)
	<-wait
}

func fatalUI(msg string) {
	fmt.Fprintln(os.Stderr, msg)
}
