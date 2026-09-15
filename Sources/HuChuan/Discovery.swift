import Foundation
import Network
import Combine
import Darwin
import HuChuanCore

struct PeerDevice: Identifiable, Equatable, Hashable, Sendable {
    var id: String
    var name: String
    var host: String
    var port: UInt16
    var httpPort: UInt16
    var os: String
    var lastSeen: Date
    var via: String
    var favorite: Bool = false
    var online: Bool = false

    mutating func refreshOnline() {
        let limit: TimeInterval = id == "phone-web" ? 12 : 45
        online = Date().timeIntervalSince(lastSeen) <= limit
    }

    var isStale: Bool { Date().timeIntervalSince(lastSeen) > 45 }

    var initial: String {
        let s = name.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "?" : String(s.prefix(1))
    }
}

@MainActor
final class DiscoveryService: ObservableObject {
    @Published private(set) var peers: [PeerDevice] = []
    @Published private(set) var localIPs: [String] = []
    @Published var statusText = "正在寻找附近设备…"
    @Published private(set) var isListening = false
    @Published private(set) var recvCount = 0
    var onPhoneClaimed: ((String) -> Void)?
    var onPeerCameOnline: ((PeerDevice) -> Void)?

    private var bonjour: BonjourWatch?
    private var listener: NWListener?
    private var udpListen: DispatchSourceRead?
    private var udpFD: Int32 = -1
    private var timer: Timer?
    private var settings: SettingsStore
    private var lastUnicast: [String: Date] = [:]
    private var lastPhoneClaim: Date?
    private var scanBusy = false
    private var tickN = 0
    private let onInbound: (NWConnection) -> Void
    let deviceId: String

    init(settings: SettingsStore, onInbound: @escaping (NWConnection) -> Void) {
        self.settings = settings
        self.onInbound = onInbound
        if let saved = UserDefaults.standard.string(forKey: "deviceId"), !saved.isEmpty {
            deviceId = saved
        } else {
            let fresh = UUID().uuidString
            UserDefaults.standard.set(fresh, forKey: "deviceId")
            deviceId = fresh
        }
    }

    func start() {
        stop()
        isListening = false
        scanBusy = false
        recvCount = 0
        refreshLocalIPs()
        startListener()
        startBrowser()
        startUDP()
        mergeFavorites()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.broadcast()
                self?.prune()
                self?.tickN += 1
                if (self?.tickN ?? 0) % 3 == 0 {
                    self?.scanLAN()
                }
            }
        }
        broadcast()
        updateSeekStatus()
    }

    func stop() {
        isListening = false
        scanBusy = false
        timer?.invalidate()
        timer = nil
        bonjour?.stop()
        bonjour = nil
        listener?.cancel()
        listener = nil
        udpListen?.cancel()
        udpListen = nil
        if udpFD >= 0 { close(udpFD); udpFD = -1 }
    }

    func refresh() {
        refreshLocalIPs()
        broadcast()
        prune()
        mergeFavorites()
        if !isListening { start() }
    }

    func mergeFavorites() {
        for fav in settings.favorites where fav.id != "phone-web" {
            if let idx = peers.firstIndex(where: { $0.id == fav.id }) {
                peers[idx].favorite = true
                continue
            }
            upsert(PeerDevice(
                id: fav.id, name: fav.name, host: fav.host, port: fav.port,
                httpPort: Ports.http(fav.port), os: "收藏", lastSeen: Date.distantPast,
                via: "收藏", favorite: true, online: false
            ))
        }
        for i in peers.indices {
            peers[i].favorite = settings.isFavorite(peers[i].id)
        }
        peers.sort {
            if $0.favorite != $1.favorite { return $0.favorite }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func waitUntilListening(timeout: TimeInterval = 4) async throws {
        if isListening { return }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isListening { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw AppError.message("没有成功监听端口 \(settings.port)")
    }

    func refreshLocalIPs() {
        localIPs = Self.ipv4Addresses()
    }

    var hello: ControlMessage.Hello {
        ControlMessage.Hello(
            deviceId: deviceId,
            name: settings.deviceName,
            port: settings.port,
            httpPort: Ports.http(settings.port),
            os: "macOS",
            appVersion: "1.0.0"
        )
    }

    private func startListener() {
        do {
            let params = NetFactory.tcp(peerToPeer: false)
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: settings.port)!)
            let txt = NWTXTRecord([
                "id": deviceId,
                "name": settings.deviceName,
                "http": String(Ports.http(settings.port)),
                "os": "macOS",
            ])
            listener.service = NWListener.Service(name: settings.deviceName, type: "_huchuan._tcp", domain: "local.", txtRecord: txt)
            listener.newConnectionHandler = { [onInbound] conn in
                Task { @MainActor in
                    onInbound(conn)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isListening = true
                    case .failed(let err):
                        self?.isListening = false
                        self?.statusText = "端口 \(self?.settings.port ?? 0) 被占用：\(err.localizedDescription)"
                    default:
                        break
                    }
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
        } catch {
            statusText = "无法监听端口 \(settings.port)，请在设置里换一个"
        }
    }

    private func startBrowser() {
        if CommandLine.arguments.contains("--selftest") { return }
        if settings.discoverMode != DiscoverMode.everyone.rawValue { return }
        let watch = BonjourWatch { [weak self] peer in
            Task { @MainActor in
                self?.upsert(peer)
            }
        }
        watch.start()
        bonjour = watch
    }

    private func startUDP() {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Ports.udp(settings.port).bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bindOk = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if bindOk != 0 {
            close(fd)
            return
        }
        var mreq = ip_mreq()
        inet_pton(AF_INET, "239.255.41.89", &mreq.imr_multiaddr)
        mreq.imr_interface = in_addr(s_addr: INADDR_ANY)
        setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size))
        for ip in localIPs {
            var per = ip_mreq()
            inet_pton(AF_INET, "239.255.41.89", &per.imr_multiaddr)
            inet_pton(AF_INET, ip, &per.imr_interface)
            setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &per, socklen_t(MemoryLayout<ip_mreq>.size))
        }
        var ttl: Int32 = 2
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout.size(ofValue: ttl)))
        var loop: Int32 = 0
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_LOOP, &loop, socklen_t(MemoryLayout.size(ofValue: loop)))
        udpFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .utility))
        src.setEventHandler { [weak self] in
            var buf = [UInt8](repeating: 0, count: 2048)
            var sender = sockaddr_in()
            var senderLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &sender) { ptr -> Int in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(fd, &buf, buf.count, 0, sa, &senderLen)
                }
            }
            guard n > 0 else { return }
            let data = Data(buf.prefix(n))
            guard let packet = DiscoveryPacket.decode(data) else { return }
            var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var addr = sender.sin_addr
            inet_ntop(AF_INET, &addr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
            let ip = String(cString: ipBuf)
            Task { @MainActor in
                self?.handleUDP(packet, host: ip)
            }
        }
        src.resume()
        udpListen = src
    }

    private func handleUDP(_ packet: DiscoveryPacket, host: String) {
        if let claim = packet.phoneClaim, !claim.isEmpty, packet.id != deviceId {
            onPhoneClaimed?(claim)
        }
        recvCount += 1
        if packet.id == deviceId || Self.isOwnIPv4(host, local: localIPs) {
            updateSeekStatus()
            return
        }
        if !allowsPeer(id: packet.id, via: "UDP 广播") {
            return
        }
        upsert(PeerDevice(
            id: packet.id,
            name: packet.name,
            host: host,
            port: packet.port,
            httpPort: packet.httpPort,
            os: packet.os,
            lastSeen: Date(),
            via: "UDP 广播"
        ))
        if packet.reply != true {
            maybeUnicastReply(to: host)
        }
    }

    func allowsPeer(id: String, via: String) -> Bool {
        if id == "phone-web" || id.hasPrefix("manual-") || via == "手动添加" || via == "收藏" {
            return true
        }
        switch DiscoverMode(rawValue: settings.discoverMode) ?? .everyone {
        case .off:
            return false
        case .favorites:
            return settings.isFavorite(id)
        case .everyone:
            return true
        }
    }

    private func maybeUnicastReply(to host: String) {
        if host.isEmpty || host == "127.0.0.1" { return }
        if localIPs.contains(host) { return }
        let now = Date()
        if let last = lastUnicast[host], now.timeIntervalSince(last) < 2 { return }
        lastUnicast[host] = now
        let packet = DiscoveryPacket(
            id: deviceId,
            name: settings.deviceName,
            port: settings.port,
            httpPort: Ports.http(settings.port),
            os: "macOS",
            reply: true
        )
        sendUDP(packet.encode(), to: host)
    }

    private func broadcast() {
        refreshLocalIPs()
        let mode = DiscoverMode(rawValue: settings.discoverMode) ?? .everyone
        if mode == .off { return }
        let packet = DiscoveryPacket(
            id: deviceId,
            name: settings.deviceName,
            port: settings.port,
            httpPort: Ports.http(settings.port),
            os: "macOS"
        )
        let data = packet.encode()
        if mode == .favorites {
            for fav in settings.favorites where !fav.host.isEmpty {
                sendUDP(data, to: fav.host)
            }
            return
        }
        sendUDP(data, to: "255.255.255.255")
        sendUDP(data, to: "239.255.41.89")
        for ip in localIPs {
            if let bcast = Self.guessBroadcast(ip) {
                sendUDP(data, to: bcast)
            }
        }
    }

    func broadcastPhoneClaim(_ ip: String) {
        let now = Date()
        if let last = lastPhoneClaim, now.timeIntervalSince(last) < 1.5 { return }
        lastPhoneClaim = now
        let packet = DiscoveryPacket(
            id: deviceId,
            name: settings.deviceName,
            port: settings.port,
            httpPort: Ports.http(settings.port),
            os: "macOS",
            reply: true,
            phoneClaim: ip
        )
        let data = packet.encode()
        sendUDP(data, to: "255.255.255.255")
        sendUDP(data, to: "239.255.41.89")
        for local in localIPs {
            if let bcast = Self.guessBroadcast(local) {
                sendUDP(data, to: bcast)
            }
        }
    }

    func removePhonePeer() {
        peers.removeAll { $0.id == "phone-web" }
        updateSeekStatus()
    }

    private func sendUDP(_ data: Data, to ip: String) {
        sendUDPOnce(data, to: ip, from: nil)
        for local in localIPs {
            sendUDPOnce(data, to: ip, from: local)
        }
    }

    private func sendUDPOnce(_ data: Data, to ip: String, from src: String?) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var ttl: Int32 = 2
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout.size(ofValue: ttl)))
        if let src {
            var local = sockaddr_in()
            local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            local.sin_family = sa_family_t(AF_INET)
            local.sin_port = 0
            inet_pton(AF_INET, src, &local.sin_addr)
            _ = withUnsafePointer(to: &local) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            var ifaddr = in_addr()
            inet_pton(AF_INET, src, &ifaddr)
            setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &ifaddr, socklen_t(MemoryLayout<in_addr>.size))
        }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Ports.udp(settings.port).bigEndian
        inet_pton(AF_INET, ip, &addr.sin_addr)
        _ = data.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, raw.baseAddress, data.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    func upsert(_ peer: PeerDevice) {
        if !allowsPeer(id: peer.id, via: peer.via) { return }
        if peer.id != "phone-web" {
            if peer.id == deviceId { return }
            if Self.isOwnIPv4(peer.host, local: localIPs) { return }
            if peer.host.isEmpty { return }
        }
        var cameOnline: PeerDevice?
        if let idx = peers.firstIndex(where: { $0.id == peer.id || ($0.host == peer.host && $0.port == peer.port) }) {
            var merged = peers[idx]
            let wasOnline = merged.online
            merged.name = peer.name
            merged.host = peer.host
            merged.port = peer.port
            merged.httpPort = peer.httpPort
            merged.os = peer.os
            merged.lastSeen = peer.lastSeen
            merged.via = peer.via
            if !peer.id.hasPrefix("bonjour-") { merged.id = peer.id }
            merged.favorite = settings.isFavorite(merged.id)
            merged.refreshOnline()
            peers[idx] = merged
            if !wasOnline && merged.online && merged.id != "phone-web" {
                cameOnline = merged
            }
        } else {
            var incoming = peer
            incoming.favorite = settings.isFavorite(peer.id)
            incoming.refreshOnline()
            peers.append(incoming)
            if incoming.online && incoming.id != "phone-web" {
                cameOnline = incoming
            }
        }
        peers.sort {
            if $0.favorite != $1.favorite { return $0.favorite }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        updateSeekStatus()
        if let live = cameOnline {
            onPeerCameOnline?(live)
        }
    }

    private func updateSeekStatus() {
        let mode = DiscoverMode(rawValue: settings.discoverMode) ?? .everyone
        if mode == .off {
            statusText = "已关闭发现，别人找不到这台电脑"
            return
        }
        if mode == .favorites {
            statusText = peers.isEmpty ? "只让收藏的人发现我" : "收藏范围内 \(peers.count) 台设备"
            return
        }
        if peers.isEmpty {
            statusText = "正在寻找附近设备…（收到 \(recvCount) 个发现包）端口 \(settings.port)"
        } else {
            statusText = "发现 \(peers.count) 台设备"
        }
    }

    func addManual(host: String, port: UInt16) {
        let clean = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        upsert(PeerDevice(
            id: "manual-\(clean)-\(port)",
            name: clean,
            host: clean,
            port: port,
            httpPort: Ports.http(port),
            os: "手动",
            lastSeen: Date().addingTimeInterval(3600),
            via: "手动添加"
        ))
    }

    private func prune() {
        let before = peers.count
        peers.removeAll { $0.isStale && !$0.id.hasPrefix("manual-") && !$0.favorite && !settings.isFavorite($0.id) }
        refreshPresence()
        if peers.isEmpty && before != 0 {
            updateSeekStatus()
        }
    }

    private func refreshPresence() {
        for i in peers.indices {
            var p = peers[i]
            p.refreshOnline()
            if p.online != peers[i].online {
                peers[i] = p
            }
        }
    }

    static func ipv4Addresses() -> [String] {
        let preferred = collectIPv4(skipVirtual: true)
        if !preferred.isEmpty { return preferred }
        return collectIPv4(skipVirtual: false)
    }

    private static func collectIPv4(skipVirtual: Bool) -> [String] {
        var scored: [(Int, String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let flags = Int32(p.pointee.ifa_flags)
            let name = String(cString: p.pointee.ifa_name)
            if flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
               !(skipVirtual && skipIface(name)),
               let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                let ip = String(cString: host)
                if !ip.hasPrefix("169.254") && !ip.hasPrefix("127.") {
                    scored.append((lanScore(ip), ip))
                }
            }
            ptr = p.pointee.ifa_next
        }
        let unique = Dictionary(scored.map { ($0.1, $0.0) }, uniquingKeysWith: { max($0, $1) })
        return unique.keys.sorted { (unique[$0] ?? 0) > (unique[$1] ?? 0) }
    }

    static func skipIface(_ name: String) -> Bool {
        let n = name.lowercased()
        for p in ["lo", "awdl", "llw", "utun", "bridge", "gif", "stf", "p2p", "ap", "vmenet", "anpi", "ipsec", "ppp", "zt", "wg", "tun"] {
            if n == p || n.hasPrefix(p) { return true }
        }
        return false
    }

    static func lanScore(_ ip: String) -> Int {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return 0 }
        if parts[0] == 192 && parts[1] == 168 { return 300 }
        if parts[0] == 10 { return 200 }
        if parts[0] == 172 && parts[1] >= 16 && parts[1] <= 31 { return 150 }
        return 40
    }

    static func isOwnIPv4(_ host: String, local: [String]) -> Bool {
        if host.isEmpty || host == "0.0.0.0" { return true }
        return local.contains(host)
    }

    private static func guessBroadcast(_ ip: String) -> String? {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return nil }
        return "\(parts[0]).\(parts[1]).\(parts[2]).255"
    }

    private func scanLAN() {
        if CommandLine.arguments.contains("--selftest") { return }
        let mode = DiscoverMode(rawValue: settings.discoverMode) ?? .everyone
        if mode == .off { return }
        if scanBusy { return }
        scanBusy = true
        let ips = localIPs
        let port = settings.port
        let name = settings.deviceName
        let pin = settings.pin
        let myId = deviceId
        let packet = DiscoveryPacket(
            id: deviceId, name: name, port: port,
            httpPort: Ports.http(port), os: "macOS"
        ).encode()
        let hosts: [String]
        if mode == .favorites {
            hosts = settings.favorites.map(\.host).filter { !$0.isEmpty }
        } else {
            hosts = Self.subnetHosts(from: ips)
        }
        let own = Set(ips)
        for host in hosts {
            sendUDP(packet, to: host)
        }
        Task.detached { [weak self] in
            let captured = self
            await Self.probeHosts(hosts, port: port, deviceId: myId, name: name, pin: pin, own: own) { peer in
                await MainActor.run { captured?.upsert(peer) }
            }
            await MainActor.run { captured?.scanBusy = false }
        }
    }

    private static func subnetHosts(from ips: [String]) -> [String] {
        let own = Set(ips)
        var seen = Set<String>()
        var hosts: [String] = []
        for ip in ips {
            let parts = ip.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 4 else { continue }
            for i in 1...254 {
                let host = "\(parts[0]).\(parts[1]).\(parts[2]).\(i)"
                if own.contains(host) || seen.contains(host) { continue }
                seen.insert(host)
                hosts.append(host)
            }
        }
        return hosts
    }

    private static func probeHosts(
        _ hosts: [String], port: UInt16, deviceId: String, name: String, pin: String, own: Set<String>,
        onPeer: @escaping @Sendable (PeerDevice) async -> Void
    ) async {
        let chunk = 24
        var i = 0
        while i < hosts.count {
            let end = min(i + chunk, hosts.count)
            await withTaskGroup(of: PeerDevice?.self) { group in
                for host in hosts[i..<end] {
                    group.addTask {
                        await probeOne(host: host, port: port, deviceId: deviceId, name: name, pin: pin, own: own)
                    }
                }
                for await peer in group {
                    if let peer { await onPeer(peer) }
                }
            }
            i = end
        }
    }

    private static func probeOne(host: String, port: UInt16, deviceId: String, name: String, pin: String, own: Set<String>) async -> PeerDevice? {
        if own.contains(host) { return nil }
        let conn = NetFactory.connect(host: host, port: port)
        do {
            try await conn.startAndWait(timeout: 0.4)
            let io = try await WireIO.open(conn, asServer: false)
            try await io.sendJSON(.hello(ControlMessage.Hello(
                deviceId: deviceId, name: name, port: port,
                httpPort: Ports.http(port), os: "macOS", appVersion: "1.0.0",
                pin: pin.isEmpty ? nil : pin
            )))
            let frame = try await io.receiveFrame(timeout: 1.0)
            conn.cancel()
            guard frame.kind == .json else { return nil }
            let msg = try ControlMessage.decodeJSON(frame.payload)
            switch msg {
            case .helloOk(let h):
                if h.deviceId == deviceId { return nil }
                if own.contains(host) { return nil }
                return PeerDevice(
                    id: h.deviceId, name: h.name, host: host, port: port,
                    httpPort: Ports.http(port), os: h.os, lastSeen: Date(), via: "局域网扫描"
                )
            case .reject:
                return PeerDevice(
                    id: "tcp-\(host)", name: host, host: host, port: port,
                    httpPort: Ports.http(port), os: "电脑", lastSeen: Date(), via: "局域网扫描"
                )
            default:
                return nil
            }
        } catch {
            conn.cancel()
            return nil
        }
    }
}
