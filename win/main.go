package main

import (
	_ "embed"
	"fmt"
	"os"
	"time"

	"huchuan/engine"
)

//go:embed ui/index.html
var uiPage string

func main() {
	if len(os.Args) > 1 && os.Args[1] == "--relay" {
		addr := ":8088"
		if len(os.Args) > 2 {
			addr = os.Args[2]
		}
		if err := engine.RunStoreRelay(addr); err != nil {
			fmt.Fprintln(os.Stderr, "中转启动失败：", err)
			os.Exit(1)
		}
		return
	}

	if len(os.Args) > 1 && os.Args[1] == "--selftest" {
		if err := engine.RunSelfTest(); err != nil {
			fmt.Fprintln(os.Stderr, "自检失败：", err)
			os.Exit(1)
		}
		return
	}

	engine.KillOtherHuChuan()
	time.Sleep(400 * time.Millisecond)
	if !engine.ClaimInstance() {
		if engine.HandOffToRunning() {
			return
		}
		engine.KillOtherHuChuan()
		time.Sleep(400 * time.Millisecond)
		if !engine.ClaimInstance() {
			fatalUI("已经有一份互传在运行。请打开已有窗口，或先退出后再打开。")
			os.Exit(1)
		}
	}
	defer engine.ReleaseInstance()

	s := engine.LoadSettings()
	if p := flagPort(); p > 0 {
		s.Port = p
	}
	n := engine.NewNode(s)
	err := n.Start()
	if err != nil {
		engine.KillOtherHuChuan()
		time.Sleep(500 * time.Millisecond)
		n = engine.NewNode(s)
		err = n.Start()
	}
	if err != nil {
		fatalUI("启动失败。端口被占用。请先退出已打开的互传后再打开。")
		os.Exit(1)
	}
	addr, err := n.ServeLocalUI(uiPage)
	if err != nil {
		fatalUI("界面启动失败。")
		os.Exit(1)
	}
	engine.WriteUIAddr(addr)
	runUI(addr, n)
	n.Stop()
}

func flagPort() uint16 {
	for i, a := range os.Args {
		if a == "--port" && i+1 < len(os.Args) {
			var p int
			fmt.Sscanf(os.Args[i+1], "%d", &p)
			if p > 0 && p < 65535 {
				return uint16(p)
			}
		}
	}
	return 0
}
