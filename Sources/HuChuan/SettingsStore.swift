import Foundation
import Combine
import AppKit

@MainActor
final class SettingsStore: ObservableObject {
    private let defaults: UserDefaults

    @Published var deviceName: String {
        didSet { defaults.set(deviceName, forKey: "deviceName") }
    }
    @Published var receiveFolder: URL {
        didSet { defaults.set(receiveFolder.path, forKey: "receiveFolder") }
    }
    @Published var autoAccept: Bool {
        didSet {
            defaults.set(autoAccept, forKey: "autoAccept")
            if autoAccept && receiveMode != ReceiveMode.auto.rawValue {
                receiveMode = ReceiveMode.auto.rawValue
            }
            if !autoAccept && receiveMode == ReceiveMode.auto.rawValue {
                receiveMode = ReceiveMode.ask.rawValue
            }
        }
    }
    @Published var receiveMode: String {
        didSet {
            defaults.set(receiveMode, forKey: "receiveMode")
            let auto = receiveMode == ReceiveMode.auto.rawValue
            if autoAccept != auto {
                autoAccept = auto
            }
        }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: "launchAtLogin")
            LaunchAtLogin.setEnabled(launchAtLogin)
        }
    }
    @Published var favorites: [FavoritePeer] {
        didSet { saveFavorites() }
    }
    @Published var pin: String {
        didSet { defaults.set(pin, forKey: "pin") }
    }
    @Published var port: UInt16 {
        didSet { defaults.set(Int(port), forKey: "port") }
    }
    @Published var maxConnections: Int {
        didSet { defaults.set(maxConnections, forKey: "maxConnections") }
    }
    @Published var discoverMode: String {
        didSet { defaults.set(discoverMode, forKey: "discoverMode") }
    }
    @Published var autoCopyText: Bool {
        didSet { defaults.set(autoCopyText, forKey: "autoCopyText") }
    }
    @Published var storeRelayURL: String {
        didSet { defaults.set(storeRelayURL, forKey: "storeRelayURL") }
    }
    @Published var storePublicURL: String {
        didSet { defaults.set(storePublicURL, forKey: "storePublicURL") }
    }
    @Published var storeWifiName: String {
        didSet { defaults.set(storeWifiName, forKey: "storeWifiName") }
    }
    @Published var storeWifiPassword: String {
        didSet { defaults.set(storeWifiPassword, forKey: "storeWifiPassword") }
    }

    init(defaults: UserDefaults = .standard, sanitize: Bool = true) {
        self.defaults = defaults
        let host = Host.current().localizedName ?? NSUserName()
        deviceName = defaults.string(forKey: "deviceName") ?? "\(host) 的互传"
        if let path = defaults.string(forKey: "receiveFolder") {
            receiveFolder = URL(fileURLWithPath: path)
        } else {
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
            receiveFolder = downloads.appendingPathComponent("互传", isDirectory: true)
        }
        let accept = defaults.bool(forKey: "autoAccept")
        autoAccept = accept
        if let mode = defaults.string(forKey: "receiveMode"), ReceiveMode(rawValue: mode) != nil {
            receiveMode = mode
        } else {
            receiveMode = accept ? ReceiveMode.auto.rawValue : ReceiveMode.ask.rawValue
        }
        launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        if let data = defaults.data(forKey: "favorites"),
           let list = try? JSONDecoder().decode([FavoritePeer].self, from: data) {
            favorites = list
        } else {
            favorites = []
        }
        pin = defaults.string(forKey: "pin") ?? ""
        let storedPort = defaults.integer(forKey: "port")
        port = storedPort > 0 ? UInt16(storedPort) : Ports.default
        let storedConn = defaults.integer(forKey: "maxConnections")
        maxConnections = storedConn > 0 ? storedConn : 8
        if let mode = defaults.string(forKey: "discoverMode"), DiscoverMode(rawValue: mode) != nil {
            discoverMode = mode
        } else {
            discoverMode = DiscoverMode.everyone.rawValue
        }
        if defaults.object(forKey: "autoCopyText") == nil {
            autoCopyText = true
        } else {
            autoCopyText = defaults.bool(forKey: "autoCopyText")
        }
        storeRelayURL = defaults.string(forKey: "storeRelayURL") ?? ""
        storePublicURL = defaults.string(forKey: "storePublicURL") ?? ""
        storeWifiName = defaults.string(forKey: "storeWifiName") ?? ""
        storeWifiPassword = defaults.string(forKey: "storeWifiPassword") ?? ""
        try? FileManager.default.createDirectory(at: receiveFolder, withIntermediateDirectories: true)
        if sanitize {
            let testNames: Set<String> = ["自检接收端", "持久化测试机"]
            let testPorts: Set<UInt16> = [42123, 41999, 42131, 42141, 42171, 42181]
            if testNames.contains(deviceName) {
                deviceName = "\(host) 的互传"
            }
            if testPorts.contains(port) {
                port = Ports.default
            }
        }
    }

    func pickReceiveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择收到文件后的保存位置"
        if panel.runModal() == .OK, let url = panel.url {
            receiveFolder = url
        }
    }

    func isFavorite(_ id: String) -> Bool {
        favorites.contains(where: { $0.id == id })
    }

    func toggleFavorite(_ peer: PeerDevice) {
        if let idx = favorites.firstIndex(where: { $0.id == peer.id }) {
            favorites.remove(at: idx)
        } else if peer.id != "phone-web" {
            favorites.append(FavoritePeer(id: peer.id, name: peer.name, host: peer.host, port: peer.port))
        }
    }

    func shouldAutoAccept(peerID: String, peerName: String) -> Bool? {
        switch ReceiveMode(rawValue: receiveMode) ?? .ask {
        case .auto: return true
        case .off: return false
        case .fav:
            return favorites.contains(where: { $0.id == peerID || $0.name == peerName }) ? true : nil
        case .ask: return nil
        }
    }

    private func saveFavorites() {
        if let data = try? JSONEncoder().encode(favorites) {
            defaults.set(data, forKey: "favorites")
        }
    }
}
