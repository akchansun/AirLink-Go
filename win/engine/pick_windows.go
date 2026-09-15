//go:build windows

package engine

import (
	"path/filepath"
	"unicode/utf16"
	"unsafe"

	"golang.org/x/sys/windows"
)

const (
	ofnExplorer         = 0x00080000
	ofnFileMustExist    = 0x00001000
	ofnHideReadOnly     = 0x00000004
	ofnAllowMultiSelect = 0x00000200
	ofnNoChangeDir      = 0x00000008
	ofnPathMustExist    = 0x00000800
)

type openFileNameW struct {
	structSize       uint32
	owner            uintptr
	instance         uintptr
	filter           *uint16
	customFilter     *uint16
	maxCustFilter    uint32
	filterIndex      uint32
	file             *uint16
	maxFile          uint32
	fileTitle        *uint16
	maxFileTitle     uint32
	initialDir       *uint16
	title            *uint16
	flags            uint32
	fileOffset       uint16
	fileExtension    uint16
	defExt           *uint16
	custData         uintptr
	hook             uintptr
	templateName     *uint16
	reserved         uintptr
	dwReserved       uint32
	flagsEx          uint32
}

func nativePickerAvailable() bool { return true }

func nativePickFiles(owner uintptr) []string {
	filter := utf16DoubleNull("所有文件", "*.*")
	title, _ := windows.UTF16PtrFromString("选择要发给对方的文件，格式不限")
	buf := make([]uint16, 32768)
	ofn := openFileNameW{
		owner:       owner,
		filter:      filter,
		file:        &buf[0],
		maxFile:     uint32(len(buf)),
		title:       title,
		filterIndex: 1,
		flags:       ofnExplorer | ofnFileMustExist | ofnHideReadOnly | ofnAllowMultiSelect | ofnNoChangeDir | ofnPathMustExist,
	}
	ofn.structSize = uint32(unsafe.Sizeof(ofn))
	r, _, _ := windows.NewLazySystemDLL("comdlg32.dll").NewProc("GetOpenFileNameW").Call(uintptr(unsafe.Pointer(&ofn)))
	if r == 0 {
		return nil
	}
	return parseOpenFileBuffer(buf)
}

func utf16DoubleNull(label, pattern string) *uint16 {
	var u []uint16
	u = append(u, utf16.Encode([]rune(label))...)
	u = append(u, 0)
	u = append(u, utf16.Encode([]rune(pattern))...)
	u = append(u, 0, 0)
	return &u[0]
}

func parseOpenFileBuffer(buf []uint16) []string {
	var parts []string
	start := 0
	for i, c := range buf {
		if c != 0 {
			continue
		}
		if i == start {
			break
		}
		parts = append(parts, windows.UTF16ToString(buf[start:i]))
		start = i + 1
	}
	if len(parts) == 0 {
		return nil
	}
	if len(parts) == 1 {
		return parts
	}
	dir := parts[0]
	out := make([]string, 0, len(parts)-1)
	for _, name := range parts[1:] {
		if name == "" {
			continue
		}
		out = append(out, filepath.Join(dir, name))
	}
	return out
}
