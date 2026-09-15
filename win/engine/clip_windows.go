//go:build windows

package engine

import (
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

const (
	cfUnicodeText = 13
	gmemMoveable  = 0x0002
)

func copyTextOS(s string) {
	if s == "" {
		return
	}
	u32 := windows.NewLazySystemDLL("user32.dll")
	k32 := windows.NewLazySystemDLL("kernel32.dll")
	open := u32.NewProc("OpenClipboard")
	empty := u32.NewProc("EmptyClipboard")
	set := u32.NewProc("SetClipboardData")
	close := u32.NewProc("CloseClipboard")
	globalAlloc := k32.NewProc("GlobalAlloc")
	globalLock := k32.NewProc("GlobalLock")
	globalUnlock := k32.NewProc("GlobalUnlock")
	r, _, _ := open.Call(0)
	if r == 0 {
		return
	}
	defer close.Call()
	_, _, _ = empty.Call()
	u16, err := syscall.UTF16FromString(s)
	if err != nil {
		return
	}
	size := uintptr(len(u16) * 2)
	h, _, _ := globalAlloc.Call(gmemMoveable, size)
	if h == 0 {
		return
	}
	ptr, _, _ := globalLock.Call(h)
	if ptr == 0 {
		return
	}
	copy(unsafe.Slice((*uint16)(unsafe.Pointer(ptr)), len(u16)), u16)
	_, _, _ = globalUnlock.Call(h)
	r, _, _ = set.Call(cfUnicodeText, h)
	if r == 0 {
		k32.NewProc("GlobalFree").Call(h)
	}
}
