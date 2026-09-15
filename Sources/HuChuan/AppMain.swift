import SwiftUI
import AppKit

@main
struct HuChuanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var state: AppState

    init() {
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.runAndExit()
        }
        _state = StateObject(wrappedValue: AppState())
    }

    var body: some Scene {
        WindowGroup("互传") {
            ContentView()
                .environmentObject(state)
                .environmentObject(state.settings)
                .environmentObject(state.discovery)
                .environmentObject(state.transfers)
                .onAppear { state.start() }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 860, height: 560)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    NotificationCenter.default.post(name: .huchuanOpenSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button("互传用法") {
                    NotificationCenter.default.post(name: .huchuanOpenHelp, object: nil)
                }
            }
            CommandGroup(replacing: .newItem) {}
        }
    }
}
