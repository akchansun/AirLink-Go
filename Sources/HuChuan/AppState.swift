import Foundation
import Combine
import AppKit
import SwiftUI
import UserNotifications

enum AppDialog: String, Equatable {
    case settings
    case manual
    case phone
    case store
    case textComposer
    case incoming
    case incomingText
    case help
}

enum MainPage: Equatable {
    case welcome
    case chat
    case settings
    case phone
    case store
    case addIP
    case history
    case help
}

struct ChatLine: Identifiable, Equatable {
    let id: UUID
    var peerId: String
    var peerName: String
    var outgoing: Bool
    var text: String
    var time: Date

    init(id: UUID = UUID(), peerId: String, peerName: String, outgoing: Bool, text: String, time: Date = Date()) {
        self.id = id
        self.peerId = peerId
        self.peerName = peerName
        self.outgoing = outgoing
        self.text = text
        self.time = time
    }
}

@MainActor
final class AppState: ObservableObject {
    let settings: SettingsStore
    let discovery: DiscoveryService
    let transfers: TransferCenter
    let http: HTTPGateway
    let history: HistoryStore
    let store: StoreBooth
    @Published var showSettings = false
    @Published var showManual = false
    @Published var showPhone = false
    @Published var showTextComposer = false
    @Published var dialog: AppDialog?
    @Published var page: MainPage = .welcome
    @Published var textDraft = ""
    @Published var selectedPeer: PeerDevice?
    @Published var multiIDs: Set<String> = []
    @Published var pickingMany = false
    @Published var messages: [ChatLine] = []
    @Published var manualHost = ""
    @Published var manualPort = "41789"
    private var bag = Set<AnyCancellable>()
    private var waitingForPhone = false

    init() {
        let settings = SettingsStore()
        self.settings = settings
        let transfers = TransferCenter(settings: settings)
        transfers.attachShared()
        self.transfers = transfers
        self.discovery = DiscoveryService(settings: settings) { conn in
            transfers.handleInbound(conn)
        }
        transfers.onDiscovered = { [discovery = self.discovery] peer in
            discovery.upsert(peer)
        }
        self.http = HTTPGateway(settings: settings)
        self.history = HistoryStore()
        self.store = StoreBooth(hub: http.booth, settings: settings, discovery: discovery)
        transfers.history = history
        settings.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        discovery.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        transfers.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        history.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
    }

    func start() {
        TrayBridge.state = self
        transfers.configureSender(deviceId: discovery.deviceId, deviceName: settings.deviceName)
        transfers.livePeer = { [weak self] id in
            self?.discovery.peers.first(where: { $0.id == id })
        }
        discovery.onPeerCameOnline = { [weak self] peer in
            self?.transfers.flush(to: peer)
        }
        discovery.onPhoneClaimed = { [weak self] ip in
            self?.dropPhone(claimedIP: ip)
        }
        discovery.start()
        transfers.restoreQueue()
        transfers.flushPending()
        transfers.startRetryTimer()
        http.onFileSaved = { [weak self] dest in
            Task { @MainActor in
                self?.rememberPhoneFile(at: dest)
            }
        }
        http.onBoothSaved = { [weak self] dest in
            Task { @MainActor in
                self?.rememberStoreFile(at: dest)
            }
        }
        store.onFileSaved = { [weak self] dest in
            self?.rememberStoreFile(at: dest)
        }
        http.onPhonePing = { [weak self] host, pair in
            if pair {
                self?.notePhoneOnline(host: host)
            } else {
                self?.touchPhone(host: host)
            }
        }
        http.onPhoneDownloaded = { [weak self] sessionId in
            self?.transfers.mark(sessionId: sessionId, state: .completed, detail: "手机已保存")
            if let idx = self?.transfers.items.firstIndex(where: { $0.sessionId == sessionId }) {
                self?.transfers.items[idx].done = self?.transfers.items[idx].total ?? 0
            }
            self?.transfers.notify("已发到手机", self?.transfers.items.first(where: { $0.sessionId == sessionId })?.title ?? "文件")
        }
        transfers.onCancelSession = { [weak self] sid in
            self?.http.outbox.cancel(session: sid)
        }
        http.start()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func pickAndSend(to peer: PeerDevice) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "发送"
        panel.message = "选择要发给「\(peer.name)」的文件或文件夹"
        if panel.runModal() == .OK {
            sendFiles(to: peer, urls: panel.urls)
        }
    }

    func sendDropped(to peer: PeerDevice, providers: [NSItemProvider]) {
        Task {
            var urls: [URL] = []
            for p in providers {
                if let url = try? await p.loadItem(forTypeIdentifier: "public.file-url") as? URL {
                    urls.append(url)
                } else if let data = try? await p.loadItem(forTypeIdentifier: "public.file-url") as? Data,
                          let s = String(data: data, encoding: .utf8),
                          let url = URL(string: s) {
                    urls.append(url)
                }
            }
            if !urls.isEmpty {
                sendFiles(to: peer, urls: urls)
            }
        }
    }

    func sendDroppedMany(providers: [NSItemProvider]) {
        Task {
            var urls: [URL] = []
            for p in providers {
                if let url = try? await p.loadItem(forTypeIdentifier: "public.file-url") as? URL {
                    urls.append(url)
                } else if let data = try? await p.loadItem(forTypeIdentifier: "public.file-url") as? Data,
                          let s = String(data: data, encoding: .utf8),
                          let url = URL(string: s) {
                    urls.append(url)
                }
            }
            if !urls.isEmpty {
                sendToMany(urls: urls)
            }
        }
    }

    func sendFiles(to peer: PeerDevice, urls: [URL]) {
        if peer.id == "phone-web" {
            sendToPhone(urls: urls)
            return
        }
        transfers.send(to: peer, urls: urls, deviceId: discovery.deviceId, deviceName: settings.deviceName)
    }

    func sendToPhone(urls: [URL]) {
        ensurePhonePeer()
        Task.detached { [http, transfers] in
            do {
                let job = try http.outbox.enqueue(urls: urls)
                await MainActor.run {
                    transfers.add(TransferItem(
                        id: UUID(), sessionId: job.sessionId, direction: .send, peerName: "手机网页",
                        title: job.title, total: job.size, done: 0, speed: 0, state: .waitingPhone,
                        detail: "手机打开网页后点「保存到手机」", fileCount: job.count, localPath: job.localPath
                    ))
                }
            } catch {
                await MainActor.run {
                    transfers.fail(peerName: "手机网页", message: (error as? AppError)?.description ?? "发给手机失败")
                }
            }
        }
    }

    func ensurePhonePeer(host: String = "") {
        let existing = discovery.peers.first(where: { $0.id == "phone-web" })
        var shown = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if shown.isEmpty || shown == "127.0.0.1" || shown == "::1" || shown == "localhost" {
            if let old = existing?.host, old != "网页", old != "手机" {
                shown = old
            } else if shown.isEmpty {
                shown = "手机"
            }
        }
        let peer = PeerDevice(
            id: "phone-web",
            name: "手机网页",
            host: shown,
            port: settings.port,
            httpPort: Ports.http(settings.port),
            os: "手机",
            lastSeen: Date(),
            via: "手机网页"
        )
        discovery.upsert(peer)
    }

    func phoneIsLive() -> Bool {
        guard let peer = discovery.peers.first(where: { $0.id == "phone-web" }) else { return false }
        return Date().timeIntervalSince(peer.lastSeen) < 12
    }

    func notePhoneOnline(host: String) {
        let ip = PhoneIP.normalize(host)
        if ip != "127.0.0.1" && ip != "::1" && ip != "localhost" && ip != "手机",
           discovery.peers.contains(where: { $0.id != "phone-web" && PhoneIP.normalize($0.host) == ip }) {
            return
        }
        let first = !phoneIsLive()
        ensurePhonePeer(host: ip)
        if waitingForPhone || page == .welcome {
            waitingForPhone = false
            if let peer = discovery.peers.first(where: { $0.id == "phone-web" }) {
                if first {
                    if !messages.contains(where: { $0.peerId == "phone-web" && $0.text.contains("已连通") }) {
                        messages.append(ChatLine(peerId: "phone-web", peerName: "手机网页", outgoing: false, text: "手机已连通，可以发文件或说话了"))
                    }
                    if ip != "127.0.0.1" && ip != "::1" && ip != "localhost" && ip != "手机" {
                        transfers.notify("手机已连通", "可以给手机发文件了")
                    }
                }
                openChat(peer)
            }
        }
        if ip != "127.0.0.1" && ip != "::1" && ip != "localhost" && ip != "手机" {
            discovery.broadcastPhoneClaim(ip)
        }
    }

    func touchPhone(host: String) {
        guard discovery.peers.contains(where: { $0.id == "phone-web" }) else { return }
        ensurePhonePeer(host: host)
    }

    func dropPhone(claimedIP: String) {
        let ip = PhoneIP.normalize(claimedIP)
        guard !ip.isEmpty, ip != "手机" else { return }
        guard let peer = discovery.peers.first(where: { $0.id == "phone-web" }) else { return }
        guard PhoneIP.normalize(peer.host) == ip else { return }
        discovery.removePhonePeer()
        if selectedPeer?.id == "phone-web" {
            selectedPeer = nil
            if page == .chat {
                page = .welcome
            }
        }
    }

    func addManual() {
        let host = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        let port = UInt16(manualPort) ?? Ports.default
        discovery.addManual(host: host, port: port)
        if let peer = discovery.peers.first(where: { $0.host == host && $0.port == port }) {
            openChat(peer)
        }
        dialog = nil
        showManual = false
        manualHost = ""
    }

    func openChat(_ peer: PeerDevice) {
        selectedPeer = peer
        page = .chat
        dialog = nil
    }

    func sendComposer() {
        let text = textDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let peer = selectedPeer, !text.isEmpty else { return }
        if peer.id == "phone-web" {
            http.outbox.enqueueText(text)
            messages.append(ChatLine(peerId: peer.id, peerName: peer.name, outgoing: true, text: text))
            textDraft = ""
            ensurePhonePeer()
            return
        }
        transfers.sendText(to: peer, text: text, deviceId: discovery.deviceId, deviceName: settings.deviceName)
        messages.append(ChatLine(peerId: peer.id, peerName: peer.name, outgoing: true, text: text))
        textDraft = ""
    }

    func rememberIncomingText(_ item: IncomingText) {
        let peerId = discovery.peers.first(where: { $0.name == item.peerName })?.id ?? item.peerName
        messages.append(ChatLine(peerId: peerId, peerName: item.peerName, outgoing: false, text: item.body))
        if settings.autoCopyText {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.body, forType: .string)
        }
        if let peer = discovery.peers.first(where: { $0.name == item.peerName }) {
            selectedPeer = peer
            page = .chat
        }
    }

    func sendClipboard(to peer: PeerDevice) {
        let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return }
        textDraft = text
        sendComposer()
    }

    func rememberStoreFile(at dest: URL) {
        let size = UInt64((try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        transfers.add(TransferItem(
            id: UUID(), sessionId: UUID().uuidString, direction: .receive, peerName: "门店码",
            title: dest.lastPathComponent, total: size, done: size, speed: 0, state: .completed,
            detail: "门店码投递", fileCount: 1, localPath: dest.path
        ))
        transfers.notify("门店码收到文件", dest.lastPathComponent)
        history.add(title: dest.lastPathComponent, peerName: "门店码", path: dest.path, kind: "recv")
        store.noteIncoming(dest)
    }

    func rememberPhoneFile(at dest: URL) {
        notePhoneOnline(host: discovery.peers.first(where: { $0.id == "phone-web" })?.host ?? "手机")
        let size = UInt64((try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        transfers.add(TransferItem(
            id: UUID(), sessionId: UUID().uuidString, direction: .receive, peerName: "手机网页",
            title: dest.lastPathComponent, total: size, done: size, speed: 0, state: .completed,
            detail: "已保存", fileCount: 1, localPath: dest.path
        ))
        if let peer = discovery.peers.first(where: { $0.id == "phone-web" }) {
            openChat(peer)
        }
        transfers.notify("手机发来文件", dest.lastPathComponent)
        history.add(title: dest.lastPathComponent, peerName: "手机网页", path: dest.path, kind: "recv")
    }

    func toggleFavorite(_ peer: PeerDevice) {
        settings.toggleFavorite(peer)
        discovery.mergeFavorites()
    }

    func pickAndSendMany() {
        let names = discovery.peers.filter { multiIDs.contains($0.id) }.map(\.name)
        guard !names.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "发送"
        panel.message = "发给：\(names.joined(separator: "、"))"
        if panel.runModal() == .OK {
            sendToMany(urls: panel.urls)
        }
    }

    func sendToMany(urls: [URL]) {
        let targets = discovery.peers.filter { multiIDs.contains($0.id) }
        for peer in targets {
            sendFiles(to: peer, urls: urls)
        }
        pickingMany = false
        multiIDs.removeAll()
        if let first = targets.first {
            openChat(first)
        }
    }

    func pasteToCurrent() {
        let pb = NSPasteboard.general
        let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        let files = urls.filter { $0.isFileURL }
        if !files.isEmpty {
            if pickingMany && !multiIDs.isEmpty {
                sendToMany(urls: files)
            } else if let peer = selectedPeer {
                sendFiles(to: peer, urls: files)
            }
            return
        }
        if NSApp.keyWindow?.firstResponder is NSTextView {
            return
        }
        if let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            if selectedPeer != nil {
                textDraft = text
                sendComposer()
            }
        }
    }

    func openDialog(_ value: AppDialog) {
        dialog = value
        switch value {
        case .settings: page = .settings
        case .phone:
            page = .phone
            waitingForPhone = !phoneIsLive()
        case .store:
            page = .store
            if store.session == nil { store.open() }
        case .manual: page = .addIP
        case .help: page = .help
        case .textComposer:
            page = .chat
        case .incoming, .incomingText:
            break
        }
    }

    func closeDialog() {
        if dialog == .incoming {
            transfers.rejectIncoming()
        }
        if dialog == .incomingText {
            transfers.incomingText = nil
        }
        dialog = nil
        showSettings = false
        showManual = false
        showPhone = false
        showTextComposer = false
    }

    var phoneURL: String {
        let ip = discovery.localIPs.first ?? "本机IP"
        return "http://\(ip):\(Ports.http(settings.port))"
    }

    func copyPhoneURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(phoneURL, forType: .string)
    }
}

enum PhoneIP {
    static func normalize(_ raw: String) -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let pct = host.firstIndex(of: "%") {
            host = String(host[..<pct])
        }
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if host.hasPrefix("::ffff:") {
            host = String(host.dropFirst(7))
        }
        return host.isEmpty ? "手机" : host
    }
}

@MainActor
enum TrayBridge {
    static weak var state: AppState?
}
