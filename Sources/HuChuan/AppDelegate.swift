import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var fitted = false
    private let trayMenu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        setupTray()
        NotificationCenter.default.addObserver(self, selector: #selector(hookWindows), name: NSWindow.didBecomeKeyNotification, object: nil)
        DispatchQueue.main.async { self.hookWindows() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    @objc func showMainWindow() {
        NSApp.unhide(nil)
        if NSApp.windows.isEmpty { return }
        for win in NSApp.windows where win.canBecomeMain {
            win.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openHelp() {
        showMainWindow()
        NotificationCenter.default.post(name: .huchuanOpenHelp, object: nil)
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func hookWindows() {
        for win in NSApp.windows where win.canBecomeMain {
            win.isReleasedWhenClosed = false
            win.minSize = NSSize(width: 720, height: 500)
            if !fitted {
                fitMainWindow(win)
            }
            if let close = win.standardWindowButton(.closeButton) {
                close.target = self
                close.action = #selector(hideToTray(_:))
            }
        }
        fitted = true
    }

    private func fitMainWindow(_ win: NSWindow) {
        let vis = (win.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let w = min(CGFloat(860), max(vis.width - 40, 640))
        let h = min(CGFloat(560), max(vis.height - 40, 480))
        var f = win.frame
        f.size = NSSize(width: w, height: h)
        f.origin.x = vis.midX - w / 2
        f.origin.y = vis.midY - h / 2
        if f.minX < vis.minX { f.origin.x = vis.minX + 20 }
        if f.minY < vis.minY { f.origin.y = vis.minY + 20 }
        win.setFrame(f, display: true)
    }

    @objc private func hideToTray(_ sender: Any?) {
        NSApp.hide(nil)
    }

    private func setupTray() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = item.button {
            btn.image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: "互传")
            btn.image?.isTemplate = true
            btn.toolTip = "互传"
        }
        trayMenu.delegate = self
        item.menu = trayMenu
        statusItem = item
        menuNeedsUpdate(trayMenu)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let open = NSMenuItem(title: "打开互传", action: #selector(showMainWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let help = NSMenuItem(title: "用法说明", action: #selector(openHelp), keyEquivalent: "")
        help.target = self
        menu.addItem(help)
        menu.addItem(NSMenuItem.separator())
        let peers: [(String, String)] = MainActor.assumeIsolated {
            (TrayBridge.state?.discovery.peers.filter { $0.online && $0.id != "phone-web" } ?? [])
                .prefix(8)
                .map { ($0.id, $0.name) }
        }
        if peers.isEmpty {
            let empty = NSMenuItem(title: "附近还没有在线设备", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for peer in peers {
                let item = NSMenuItem(title: "发给 \(peer.1)", action: #selector(sendToPeer(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = peer.0
                menu.addItem(item)
            }
        }
        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "退出互传", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func sendToPeer(_ sender: NSMenuItem) {
        let id = sender.representedObject as? String
        showMainWindow()
        Task { @MainActor in
            guard let id, let state = TrayBridge.state,
                  let peer = state.discovery.peers.first(where: { $0.id == id }) else { return }
            state.openChat(peer)
            state.pickAndSend(to: peer)
        }
    }
}
