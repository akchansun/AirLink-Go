//go:build windows

package engine

import (
	"unsafe"

	"golang.org/x/sys/windows"
)

const (
	bifReturnOnlyFSDirs = 0x00000001
	bifNewDialogStyle   = 0x00000040
	coInitApartment     = 0x00000002
)

type browseInfoW struct {
	hwndOwner      uintptr
	pidlRoot       uintptr
	pszDisplayName *uint16
	lpszTitle      *uint16
	ulFlags        uint32
	lpfn           uintptr
	lParam         uintptr
	iImage         int32
}

func nativePickFolder(owner uintptr) []string {
	ole32 := windows.NewLazySystemDLL("ole32.dll")
	shell32 := windows.NewLazySystemDLL("shell32.dll")
	_, _, _ = ole32.NewProc("CoInitializeEx").Call(0, coInitApartment)
	display := make([]uint16, 260)
	title, _ := windows.UTF16PtrFromString("选择要发给对方的文件夹")
	bi := browseInfoW{
		hwndOwner:      owner,
		pszDisplayName: &display[0],
		lpszTitle:      title,
		ulFlags:        bifReturnOnlyFSDirs | bifNewDialogStyle,
	}
	pidl, _, _ := shell32.NewProc("SHBrowseForFolderW").Call(uintptr(unsafe.Pointer(&bi)))
	if pidl == 0 {
		return nil
	}
	defer ole32.NewProc("CoTaskMemFree").Call(pidl)
	buf := make([]uint16, 32768)
	ok, _, _ := shell32.NewProc("SHGetPathFromIDListW").Call(pidl, uintptr(unsafe.Pointer(&buf[0])))
	if ok == 0 {
		return nil
	}
	p := windows.UTF16ToString(buf)
	if p == "" {
		return nil
	}
	return []string{p}
}
