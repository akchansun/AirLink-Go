//go:build darwin

package main

import (
	"fmt"
	"os"
	"os/exec"
	"time"

	"huchuan/engine"
)

func runUI(url string, n *engine.Node) {
	_ = n
	chrome := "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
	if st, err := os.Stat(chrome); err == nil && !st.IsDir() {
		cmd := exec.Command(chrome, "--app="+url, "--window-size=860,560")
		if err := cmd.Start(); err == nil {
			_ = cmd.Wait()
			return
		}
	}
	_ = exec.Command("open", url).Start()
	fmt.Println("请在浏览器打开：", url)
	time.Sleep(3600 * time.Hour)
}

func fatalUI(msg string) {
	fmt.Fprintln(os.Stderr, msg)
}
