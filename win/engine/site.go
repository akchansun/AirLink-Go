package engine

import (
	"os/exec"
	"runtime"
)

const OfficialSite = "https://www.ak129.cn/"

func OpenOfficialSite() {
	switch runtime.GOOS {
	case "windows":
		_ = exec.Command("cmd", "/C", "start", "", OfficialSite).Start()
	case "darwin":
		_ = exec.Command("open", OfficialSite).Start()
	default:
		_ = exec.Command("xdg-open", OfficialSite).Start()
	}
}
