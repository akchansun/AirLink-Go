//go:build windows

package engine

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

const mutexName = "Local\\HuChuanSingleInstance"

var instanceMutex windows.Handle

func KillOtherHuChuan() int {
	self := uint32(os.Getpid())
	selfName := strings.ToLower(filepath.Base(os.Args[0]))
	if selfName == "" {
		selfName = "互传.exe"
	}
	if !strings.HasSuffix(selfName, ".exe") {
		selfName += ".exe"
	}

	snap, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return killByTaskkill(self)
	}
	defer windows.CloseHandle(snap)

	var entry windows.ProcessEntry32
	entry.Size = uint32(unsafe.Sizeof(entry))
	if err := windows.Process32First(snap, &entry); err != nil {
		return killByTaskkill(self)
	}
	killed := 0
	for {
		name := strings.ToLower(windows.UTF16ToString(entry.ExeFile[:]))
		pid := entry.ProcessID
		if pid != self && (name == selfName || name == "互传.exe" || name == "huchuan.exe") {
			if terminateTree(pid) {
				killed++
			}
		}
		if err := windows.Process32Next(snap, &entry); err != nil {
			break
		}
	}
	return killed
}

func terminateTree(pid uint32) bool {
	cmd := exec.Command("taskkill", "/F", "/PID", strconv.Itoa(int(pid)), "/T")
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	if cmd.Run() == nil {
		return true
	}
	h, err := windows.OpenProcess(windows.PROCESS_TERMINATE, false, pid)
	if err != nil {
		return false
	}
	defer windows.CloseHandle(h)
	return windows.TerminateProcess(h, 1) == nil
}

func killByTaskkill(self uint32) int {
	out, _ := exec.Command("tasklist", "/FO", "CSV", "/NH").Output()
	killed := 0
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		low := strings.ToLower(line)
		if !strings.Contains(low, "互传.exe") && !strings.Contains(low, "huchuan.exe") {
			continue
		}
		parts := strings.Split(line, ",")
		if len(parts) < 2 {
			continue
		}
		pidStr := strings.Trim(parts[1], "\" ")
		pid, err := strconv.Atoi(pidStr)
		if err != nil || uint32(pid) == self {
			continue
		}
		if terminateTree(uint32(pid)) {
			killed++
		}
	}
	return killed
}

func ClaimInstance() bool {
	name, err := windows.UTF16PtrFromString(mutexName)
	if err != nil {
		return true
	}
	h, err := windows.CreateMutex(nil, false, name)
	if h == 0 {
		return true
	}
	if err == windows.ERROR_ALREADY_EXISTS {
		_ = windows.CloseHandle(h)
		return false
	}
	instanceMutex = h
	return true
}

func ReleaseInstance() {
	if instanceMutex != 0 {
		_ = windows.CloseHandle(instanceMutex)
		instanceMutex = 0
	}
}
