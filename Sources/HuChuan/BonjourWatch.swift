import Foundation
import Darwin

final class BonjourWatch: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var resolving: [NetService] = []
    private let onPeer: (PeerDevice) -> Void

    init(onPeer: @escaping (PeerDevice) -> Void) {
        self.onPeer = onPeer
        super.init()
        browser.delegate = self
        browser.includesPeerToPeer = true
    }

    func start() {
        browser.searchForServices(ofType: "_huchuan._tcp.", inDomain: "local.")
    }

    func stop() {
        browser.stop()
        for service in resolving { service.stop() }
        resolving.removeAll()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        service.resolve(withTimeout: 6)
        resolving.append(service)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        resolving.removeAll { $0.name == service.name && $0.type == service.type && $0.domain == service.domain }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        let port = UInt16(clamping: sender.port)
        guard port > 0 else { return }
        var txtId = ""
        var txtName = sender.name
        var httpPort = Ports.http(port)
        var osName = "电脑"
        if let data = sender.txtRecordData() {
            let dict = NetService.dictionary(fromTXTRecord: data)
            if let raw = dict["id"], let value = String(data: raw, encoding: .utf8), !value.isEmpty {
                txtId = value
            }
            if let raw = dict["name"], let value = String(data: raw, encoding: .utf8), !value.isEmpty {
                txtName = value
            }
            if let raw = dict["http"], let value = String(data: raw, encoding: .utf8), let n = UInt16(value) {
                httpPort = n
            }
            if let raw = dict["os"], let value = String(data: raw, encoding: .utf8), !value.isEmpty {
                osName = value
            }
        }
        for addr in sender.addresses ?? [] {
            guard let ip = ipv4(from: addr) else { continue }
            let id = txtId.isEmpty ? "bonjour-\(ip)-\(port)" : txtId
            let peer = PeerDevice(
                id: id, name: txtName, host: ip, port: port,
                httpPort: httpPort, os: osName, lastSeen: Date(), via: "局域网名字"
            )
            DispatchQueue.main.async { [onPeer] in
                onPeer(peer)
            }
        }
    }

    private func ipv4(from data: Data) -> String? {
        data.withUnsafeBytes { raw -> String? in
            guard raw.count >= MemoryLayout<sockaddr>.size else { return nil }
            let family = raw.load(as: sockaddr.self).sa_family
            guard family == sa_family_t(AF_INET) else { return nil }
            var addr = raw.load(as: sockaddr_in.self)
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addr.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
            let ip = String(cString: buf)
            if ip.hasPrefix("127.") || ip.hasPrefix("169.254") || ip.isEmpty { return nil }
            return ip
        }
    }
}
