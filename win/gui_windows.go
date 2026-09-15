//go:build windows

package main

import (
	_ "embed"
	"os"
	"path/filepath"
	"syscall"
	"unsafe"

	"github.com/jchv/go-webview2"
	"golang.org/x/sys/windows"

	"huchuan/engine"
)

//go:embed app.ico
var appIcon []byte

	const (
	gwlpWndProc     = uintptr(^uintptr(3))
	gclpHicon       = uintptr(^uintptr(13))
	gclpHiconSm     = uintptr(^uintptr(33))
	wmClose         = 0x0010
	wmSysCommand    = 0x0112
	wmCommand       = 0x0111
	wmSize          = 0x0005
	wmSetIcon       = 0x0080
	wmLButtonUp     = 0x0202
	wmRButtonUp     = 0x0205
	wmLButtonDblClk = 0x0203
	wmApp           = 0x8000
	wmTray          = wmApp + 1
	scClose         = 0xF060
	scMinimize      = 0xF020
	sizeMinimized   = 6
	swHide          = 0
	swShow          = 5
	swRestore       = 9
	swShowNA        = 8
	nimAdd          = 0
	nimModify       = 1
	nimDelete       = 2
	nifMessage      = 0x00000001
	nifIcon         = 0x00000002
	nifTip          = 0x00000004
	nifInfo         = 0x00000010
	niifInfo        = 0x00000001
	mfString        = 0
	mfGrayed        = 0x00000001
	mfDisabled      = 0x00000002
	mfSeparator     = 0x00000800
	tpmRightButton  = 0x0002
	tpmReturnCmd    = 0x0100
	menuOpen        = 1001
	menuQuit        = 1002
	menuSendBase    = 1100
	menuSendMax     = 8
	idiApplication  = 32512
	imageIcon       = 1
	iconSmall       = 0
	iconBig         = 1
	lrLoadFromFile  = 0x0010
	lrDefaultSize   = 0x0040
	flashwAll       = 3
	flashwTimerNoFG = 12
	mbIconAsterisk  = 0x00000040
)

type notifyIconData struct {
	Size            uint32
	Wnd             uintptr
	ID              uint32
	Flags           uint32
	CallbackMessage uint32
	Icon            uintptr
	Tip             [128]uint16
	State           uint32
	StateMask       uint32
	Info            [256]uint16
	Timeout         uint32
	InfoTitle       [64]uint16
	InfoFlags       uint32
	GuidItem        [16]byte
	BalloonIcon     uintptr
}

type flashwinfo struct {
	Size    uint32
	Wnd     uintptr
	Flags   uint32
	Count   uint32
	Timeout uint32
}

var (
	user32               = windows.NewLazySystemDLL("user32.dll")
	shell32              = windows.NewLazySystemDLL("shell32.dll")
	procSetWindowLongPtr = user32.NewProc("SetWindowLongPtrW")
	procCallWindowProc   = user32.NewProc("CallWindowProcW")
	procShowWindow       = user32.NewProc("ShowWindow")
	procSetForeground    = user32.NewProc("SetForegroundWindow")
	procLoadIcon         = user32.NewProc("LoadIconW")
	procLoadImage        = user32.NewProc("LoadImageW")
	procSendMessage      = user32.NewProc("SendMessageW")
	procSetClassLongPtr  = user32.NewProc("SetClassLongPtrW")
	procShellNotify      = shell32.NewProc("Shell_NotifyIconW")
	procExtractIcon      = shell32.NewProc("ExtractIconW")
	procCreatePopup      = user32.NewProc("CreatePopupMenu")
	procAppendMenu       = user32.NewProc("AppendMenuW")
	procTrackPopup       = user32.NewProc("TrackPopupMenu")
	procDestroyMenu      = user32.NewProc("DestroyMenu")
	procGetCursor        = user32.NewProc("GetCursorPos")
	procFlashWindowEx    = user32.NewProc("FlashWindowEx")
	procMessageBeep      = user32.NewProc("MessageBeep")
	oldWndProc           uintptr
	quitting             bool
	balloonShown         bool
	mainHwnd             uintptr
	trayIcon             uintptr
	trayNode             *engine.Node
	minCallback          = windows.NewCallback(closeToMinProc)
)

type point struct{ X, Y int32 }

func closeToMinProc(hwnd, msg, wp, lp uintptr) uintptr {
	if msg == wmTray {
		switch lp {
		case wmLButtonUp, wmLButtonDblClk:
			restoreWindow()
		case wmRButtonUp:
			showTrayMenu(hwnd)
		}
		return 0
	}
	if !quitting && (msg == wmClose || (msg == wmSysCommand && (wp&0xFFF0 == scClose || wp&0xFFF0 == scMinimize))) {
		hideToTray(hwnd)
		return 0
	}
	if !quitting && msg == wmSize && wp == sizeMinimized {
		hideToTray(hwnd)
		return 0
	}
	r, _, _ := procCallWindowProc.Call(oldWndProc, hwnd, msg, wp, lp)
	return r
}

func hideToTray(hwnd uintptr) {
	_, _, _ = procShowWindow.Call(hwnd, swHide)
	if !balloonShown {
		balloonShown = true
		notifyBalloon("互传还在运行", "窗口已经收到右下角，不占任务栏。点图标打开，右击选「退出互传」。")
	}
}

func restoreWindow() {
	if mainHwnd == 0 {
		return
	}
	_, _, _ = procShowWindow.Call(mainHwnd, swShow)
	_, _, _ = procShowWindow.Call(mainHwnd, swRestore)
	_, _, _ = procSetForeground.Call(mainHwnd)
}

func showTrayMenu(hwnd uintptr) {
	_, _, _ = procSetForeground.Call(hwnd)
	menu, _, _ := procCreatePopup.Call()
	if menu == 0 {
		return
	}
	appendMenu(menu, menuOpen, "打开互传")
	appendSep(menu)
	peers := []engine.Peer{}
	if trayNode != nil {
		peers = trayNode.OnlinePeers()
	}
	if len(peers) == 0 {
		appendDisabled(menu, "附近还没有在线设备")
	} else {
		if len(peers) > int(menuSendMax) {
			peers = peers[:int(menuSendMax)]
		}
		for i, p := range peers {
			appendMenu(menu, menuSendBase+uintptr(i), "发给 "+p.Name)
		}
	}
	appendSep(menu)
	appendMenu(menu, menuQuit, "退出互传")
	var pt point
	_, _, _ = procGetCursor.Call(uintptr(unsafe.Pointer(&pt)))
	cmd, _, _ := procTrackPopup.Call(menu, tpmRightButton|tpmReturnCmd, uintptr(pt.X), uintptr(pt.Y), 0, hwnd, 0)
	_, _, _ = procDestroyMenu.Call(menu)
	switch {
	case cmd == menuOpen:
		restoreWindow()
	case cmd == menuQuit:
		requestExit()
	case cmd >= menuSendBase && cmd < menuSendBase+uintptr(menuSendMax):
		idx := int(cmd - menuSendBase)
		if idx >= 0 && idx < len(peers) && trayNode != nil {
			restoreWindow()
			trayNode.Select(peers[idx].ID)
			trayNode.PickAndSend(hwnd)
		}
	}
}

func appendMenu(menu uintptr, id uintptr, text string) {
	p, _ := windows.UTF16PtrFromString(text)
	_, _, _ = procAppendMenu.Call(menu, mfString, id, uintptr(unsafe.Pointer(p)))
}

func appendSep(menu uintptr) {
	_, _, _ = procAppendMenu.Call(menu, mfSeparator, 0, 0)
}

func appendDisabled(menu uintptr, text string) {
	p, _ := windows.UTF16PtrFromString(text)
	_, _, _ = procAppendMenu.Call(menu, mfString|mfGrayed|mfDisabled, 0, uintptr(unsafe.Pointer(p)))
}

func requestExit() {
	quitting = true
	removeTray()
	engine.RequestQuit()
}

func hookWindow(hwnd uintptr) {
	if hwnd == 0 {
		return
	}
	mainHwnd = hwnd
	old, _, _ := procSetWindowLongPtr.Call(hwnd, gwlpWndProc, minCallback)
	oldWndProc = old
	applyWindowIcon(hwnd)
	addTray(hwnd)
}

func iconFile() string {
	tmp := filepath.Join(os.TempDir(), "huchuan-app.ico")
	if len(appIcon) > 0 {
		_ = os.WriteFile(tmp, appIcon, 0o644)
		return tmp
	}
	return ""
}

func loadImageFile(path string, w, h uintptr) uintptr {
	if path == "" {
		return 0
	}
	p, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return 0
	}
	hicon, _, _ := procLoadImage.Call(0, uintptr(unsafe.Pointer(p)), imageIcon, w, h, lrLoadFromFile)
	return hicon
}

func loadIcon() uintptr {
	path := iconFile()
	if h := loadImageFile(path, 32, 32); h != 0 {
		return h
	}
	if h := loadImageFile(path, 0, 0); h != 0 {
		return h
	}
	exe, _ := os.Executable()
	if exe != "" {
		p, _ := windows.UTF16PtrFromString(exe)
		h, _, _ := procExtractIcon.Call(0, uintptr(unsafe.Pointer(p)), 0)
		if h > 1 {
			return h
		}
	}
	h, _, _ := procLoadIcon.Call(0, idiApplication)
	return h
}

func applyWindowIcon(hwnd uintptr) {
	path := iconFile()
	big := loadImageFile(path, 32, 32)
	small := loadImageFile(path, 16, 16)
	if big == 0 {
		big = loadIcon()
	}
	if small == 0 {
		small = big
	}
	if big != 0 {
		trayIcon = big
		_, _, _ = procSendMessage.Call(hwnd, wmSetIcon, iconBig, big)
		_, _, _ = procSetClassLongPtr.Call(hwnd, gclpHicon, big)
	}
	if small != 0 {
		_, _, _ = procSendMessage.Call(hwnd, wmSetIcon, iconSmall, small)
		_, _, _ = procSetClassLongPtr.Call(hwnd, gclpHiconSm, small)
	}
}

func fillTip(nid *notifyIconData, tip string) {
	u, _ := windows.UTF16FromString(tip)
	n := len(u)
	if n > len(nid.Tip) {
		n = len(nid.Tip)
	}
	copy(nid.Tip[:], u[:n])
}

func fillInfo(nid *notifyIconData, title, body string) {
	u, _ := windows.UTF16FromString(body)
	n := len(u)
	if n > len(nid.Info) {
		n = len(nid.Info)
	}
	copy(nid.Info[:], u[:n])
	t, _ := windows.UTF16FromString(title)
	m := len(t)
	if m > len(nid.InfoTitle) {
		m = len(nid.InfoTitle)
	}
	copy(nid.InfoTitle[:], t[:m])
}

func addTray(hwnd uintptr) {
	trayIcon = loadIcon()
	nid := notifyIconData{
		Wnd:             hwnd,
		ID:              1,
		Flags:           nifMessage | nifIcon | nifTip,
		CallbackMessage: wmTray,
		Icon:            trayIcon,
	}
	nid.Size = uint32(unsafe.Sizeof(nid))
	fillTip(&nid, "互传 · 喜相逢科技公司")
	_, _, _ = procShellNotify.Call(nimAdd, uintptr(unsafe.Pointer(&nid)))
}

func notifyBalloon(title, body string) {
	if mainHwnd == 0 {
		return
	}
	nid := notifyIconData{
		Wnd:             mainHwnd,
		ID:              1,
		Flags:           nifMessage | nifIcon | nifTip | nifInfo,
		CallbackMessage: wmTray,
		Icon:            trayIcon,
		Timeout:         8000,
		InfoFlags:       niifInfo,
	}
	nid.Size = uint32(unsafe.Sizeof(nid))
	fillTip(&nid, "互传 · 喜相逢科技公司")
	fillInfo(&nid, title, body)
	_, _, _ = procShellNotify.Call(nimModify, uintptr(unsafe.Pointer(&nid)))
}

func flashTaskbar() {
	if mainHwnd == 0 {
		return
	}
	info := flashwinfo{
		Size:    uint32(unsafe.Sizeof(flashwinfo{})),
		Wnd:     mainHwnd,
		Flags:   flashwAll | flashwTimerNoFG,
		Count:   8,
		Timeout: 0,
	}
	_, _, _ = procFlashWindowEx.Call(uintptr(unsafe.Pointer(&info)))
}

func playAlertSound() {
	_, _, _ = procMessageBeep.Call(mbIconAsterisk)
}

func removeTray() {
	if mainHwnd == 0 {
		return
	}
	nid := notifyIconData{Wnd: mainHwnd, ID: 1}
	nid.Size = uint32(unsafe.Sizeof(nid))
	_, _, _ = procShellNotify.Call(nimDelete, uintptr(unsafe.Pointer(&nid)))
}

func fitWindowSize(wantW, wantH int) (int, int) {
	user32 := windows.NewLazySystemDLL("user32.dll")
	var r struct{ Left, Top, Right, Bottom int32 }
	_, _, _ = user32.NewProc("SystemParametersInfoW").Call(0x0030, 0, uintptr(unsafe.Pointer(&r)), 0)
	aw := int(r.Right - r.Left)
	ah := int(r.Bottom - r.Top)
	if aw < 200 || ah < 200 {
		return wantW, wantH
	}
	maxW := aw - 40
	maxH := ah - 40
	if wantW > maxW {
		wantW = maxW
	}
	if wantH > maxH {
		wantH = maxH
	}
	if wantW < 640 {
		wantW = maxW
		if wantW > 640 {
			wantW = 640
		}
	}
	if wantH < 480 {
		wantH = maxH
		if wantH > 480 {
			wantH = 480
		}
	}
	return wantW, wantH
}

func runUI(url string, n *engine.Node) {
	data := filepath.Join(os.Getenv("APPDATA"), "互传", "webview")
	_ = os.MkdirAll(data, 0o755)
	winW, winH := fitWindowSize(860, 560)
	w := webview2.NewWithOptions(webview2.WebViewOptions{
		Debug:     false,
		AutoFocus: true,
		DataPath:  data,
		WindowOptions: webview2.WindowOptions{
			Title:  "互传",
			Width:  uint(winW),
			Height: uint(winH),
			Center: true,
		},
	})
	if w == nil {
		fatalUI("打不开窗口。请先安装 Microsoft Edge，或安装微软的 WebView2 运行时后再打开互传。")
		return
	}
	defer func() {
		removeTray()
		w.Destroy()
	}()
	hwnd := uintptr(w.Window())
	hookWindow(hwnd)
	trayNode = n
	engine.SetAlertHook(func(title, body string) {
		flashTaskbar()
		playAlertSound()
		notifyBalloon(title, body)
	})
	_ = w.Bind("pickLocalFiles", func() {
		n.PickAndSend(hwnd)
	})
	_ = w.Bind("pickLocalFolder", func() {
		n.PickAndSendFolder(hwnd)
	})
	w.Init(`
		document.addEventListener('dragover', function(e){ e.preventDefault(); }, true);
		document.addEventListener('dragenter', function(e){ e.preventDefault(); }, true);
	`)
	engine.SetQuitHook(func() {
		quitting = true
		removeTray()
		w.Dispatch(func() {
			w.Terminate()
		})
	})
	w.SetSize(winW, winH, webview2.HintNone)
	w.Navigate(url)
	notifyBalloon("互传已启动", "关掉窗口会收到右下角，不占任务栏。要退出请右击图标，选「退出互传」。")
	w.Run()
}

func fatalUI(msg string) {
	u32 := syscall.NewLazyDLL("user32.dll")
	proc := u32.NewProc("MessageBoxW")
	text, _ := syscall.UTF16PtrFromString(msg)
	title, _ := syscall.UTF16PtrFromString("互传")
	proc.Call(0, uintptr(unsafe.Pointer(text)), uintptr(unsafe.Pointer(title)), 0x00000010)
}
