//go:build windows

package engine

import (
	"unsafe"

	"golang.org/x/sys/windows"
)

func readClipboardOS() string {
	u32 := windows.NewLazySystemDLL("user32.dll")
	k32 := windows.NewLazySystemDLL("kernel32.dll")
	open := u32.NewProc("OpenClipboard")
	get := u32.NewProc("GetClipboardData")
	close := u32.NewProc("CloseClipboard")
	lock := k32.NewProc("GlobalLock")
	unlock := k32.NewProc("GlobalUnlock")
	r, _, _ := open.Call(0)
	if r == 0 {
		return ""
	}
	defer close.Call()
	h, _, _ := get.Call(cfUnicodeText)
	if h == 0 {
		return ""
	}
	ptr, _, _ := lock.Call(h)
	if ptr == 0 {
		return ""
	}
	defer unlock.Call(h)
	return windows.UTF16PtrToString((*uint16)(unsafe.Pointer(ptr)))
}
