import Foundation
import Darwin

enum WanAddress {
    static func isPublicIPv4(_ raw: String) -> Bool {
        var addr = in_addr()
        guard raw.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else { return false }
        let n = UInt32(bigEndian: addr.s_addr)
        let a = UInt8(n >> 24), b = UInt8((n >> 16) & 0xFF)
        if a == 127 || a == 0 || a == 10 { return false }
        if a == 169 && b == 254 { return false }
        if a == 172 && (16...31).contains(b) { return false }
        if a == 192 && b == 168 { return false }
        if a == 100 && (64...127).contains(b) { return false }
        return true
    }
}

enum PortOpener {
    private static let q = DispatchQueue(label: "huchuan.portmap")
    private static var last: Mapping?

    private struct Mapping {
        var control: String
        var service: String
        var port: UInt16
    }

    static func openHTTP(port: UInt16, localIPs: [String]) async -> String? {
        closeLast()
        return await Task.detached(priority: .userInitiated) {
            for ip in localIPs where ip != "127.0.0.1" && !ip.isEmpty {
                if let wan = await mapOn(localIP: ip, port: port) {
                    return wan
                }
            }
            return nil
        }.value
    }

    static func closeLast() {
        let map: Mapping? = q.sync {
            let old = last
            last = nil
            return old
        }
        guard let map else { return }
        let body = soapArgs(map.service, "DeletePortMapping", [
            "NewRemoteHost": "",
            "NewExternalPort": "\(map.port)",
            "NewProtocol": "TCP",
        ])
        Task.detached {
            _ = try? await soap(map.control, map.service, "DeletePortMapping", body)
        }
    }

    private static func mapOn(localIP: String, port: UInt16) async -> String? {
        if let wan = await upnpMap(localIP: localIP, port: port) { return wan }
        return natpmpMap(localIP: localIP, port: port)
    }

    private static func upnpMap(localIP: String, port: UInt16) async -> String? {
        guard let loc = ssdpLocation(from: localIP) else { return nil }
        guard let found = await controlURL(from: loc) else { return nil }
        let extXML = try? await soap(found.control, found.service, "GetExternalIPAddress",
                                     soapArgs(found.service, "GetExternalIPAddress", [:]))
        let ext = extXML.flatMap { xmlTag($0, "NewExternalIPAddress") } ?? ""
        let add = soapArgs(found.service, "AddPortMapping", [
            "NewRemoteHost": "",
            "NewExternalPort": "\(port)",
            "NewProtocol": "TCP",
            "NewInternalPort": "\(port)",
            "NewInternalClient": localIP,
            "NewEnabled": "1",
            "NewPortMappingDescription": "huchuan-booth",
            "NewLeaseDuration": "7200",
        ])
        let mapped = (try? await soap(found.control, found.service, "AddPortMapping", add)) != nil
        guard mapped, WanAddress.isPublicIPv4(ext) else { return nil }
        q.sync { last = Mapping(control: found.control, service: found.service, port: port) }
        return "http://\(ext):\(port)"
    }

    private static func ssdpLocation(from localIP: String) -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var ttl: Int32 = 2
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout.size(ofValue: ttl)))
        var iface = in_addr()
        _ = localIP.withCString { inet_pton(AF_INET, $0, &iface) }
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &iface, socklen_t(MemoryLayout<in_addr>.size))
        var bindAddr = sockaddr_in()
        bindAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        bindAddr.sin_family = sa_family_t(AF_INET)
        _ = localIP.withCString { inet_pton(AF_INET, $0, &bindAddr.sin_addr) }
        _ = withUnsafePointer(to: &bindAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var dst = sockaddr_in()
        dst.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dst.sin_family = sa_family_t(AF_INET)
        dst.sin_port = UInt16(1900).bigEndian
        _ = "239.255.255.250".withCString { inet_pton(AF_INET, $0, &dst.sin_addr) }
        let searches = [
            "urn:schemas-upnp-org:service:WANIPConnection:1",
            "urn:schemas-upnp-org:service:WANPPPConnection:1",
            "urn:schemas-upnp-org:device:InternetGatewayDevice:1",
        ]
        for st in searches {
            let msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: \(st)\r\n\r\n"
            _ = msg.withCString { cstr in
                withUnsafePointer(to: &dst) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, cstr, strlen(cstr), 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
        var tv = timeval(tv_sec: 1, tv_usec: 400_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = recv(fd, &buf, buf.count, 0)
        guard n > 0, let text = String(bytes: buf.prefix(n), encoding: .utf8) else { return nil }
        return httpHeader(text, "LOCATION") ?? httpHeader(text, "Location")
    }

    private static func controlURL(from location: String) async -> (control: String, service: String)? {
        guard let url = URL(string: location) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 2)
        req.httpMethod = "GET"
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let xml = String(data: data, encoding: .utf8) else { return nil }
        let types = [
            "urn:schemas-upnp-org:service:WANIPConnection:1",
            "urn:schemas-upnp-org:service:WANIPConnection:2",
            "urn:schemas-upnp-org:service:WANPPPConnection:1",
        ]
        for part in xml.components(separatedBy: "<service") {
            let typ = xmlTag(part, "serviceType") ?? ""
            guard types.contains(typ), let path = xmlTag(part, "controlURL"), !path.isEmpty else { continue }
            return (absoluteURL(path, base: location), typ)
        }
        return nil
    }

    private static func soap(_ control: String, _ service: String, _ action: String, _ body: String) async throws -> String {
        guard let url = URL(string: control) else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 2)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"\(service)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        req.httpBody = Data(body.utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code), let text = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotParseResponse)
        }
        return text
    }

    private static func soapArgs(_ service: String, _ action: String, _ fields: [String: String]) -> String {
        let inner = fields.map { "<\($0.key)>\($0.value)</\($0.key)>" }.joined()
        return """
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        <s:Body><u:\(action) xmlns:u="\(service)">\(inner)</u:\(action)></s:Body>
        </s:Envelope>
        """
    }

    private static func natpmpMap(localIP: String, port: UInt16) -> String? {
        guard let gw = guessGateway(localIP) else { return nil }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: 0, tv_usec: 600_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var dst = sockaddr_in()
        dst.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dst.sin_family = sa_family_t(AF_INET)
        dst.sin_port = UInt16(5351).bigEndian
        _ = gw.withCString { inet_pton(AF_INET, $0, &dst.sin_addr) }
        func sendRecv(_ payload: [UInt8]) -> [UInt8]? {
            _ = payload.withUnsafeBytes { raw in
                withUnsafePointer(to: &dst) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, raw.baseAddress, payload.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            var buf = [UInt8](repeating: 0, count: 32)
            let n = recv(fd, &buf, buf.count, 0)
            guard n > 0 else { return nil }
            return Array(buf.prefix(n))
        }
        guard let ext = sendRecv([0, 0]), ext.count >= 12, ext[0] == 0, ext[3] == 0 else { return nil }
        let wan = "\(ext[8]).\(ext[9]).\(ext[10]).\(ext[11])"
        let mapReq: [UInt8] = [0, 2, 0, 0, UInt8(port >> 8), UInt8(port & 0xFF), UInt8(port >> 8), UInt8(port & 0xFF), 0, 0, 0x1C, 0x20]
        guard let mapped = sendRecv(mapReq), mapped.count >= 12, mapped[0] == 0, mapped[3] == 0 else { return nil }
        guard WanAddress.isPublicIPv4(wan) else { return nil }
        return "http://\(wan):\(port)"
    }

    private static func guessGateway(_ ip: String) -> String? {
        var addr = in_addr()
        guard ip.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else { return nil }
        var n = UInt32(bigEndian: addr.s_addr)
        n = (n & 0xFFFFFF00) | 1
        var out = in_addr(s_addr: n.bigEndian)
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &out, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buf)
    }

    private static func httpHeader(_ text: String, _ key: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let s = String(line)
            if s.lowercased().hasPrefix(key.lowercased() + ":") {
                return s.drop { $0 != ":" }.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func xmlTag(_ xml: String, _ name: String) -> String? {
        let names = [name, "s:" + name, "u:" + name]
        let lower = xml.lowercased()
        for n in names {
            let open = "<" + n.lowercased() + ">"
            let close = "</" + n.lowercased() + ">"
            guard let a = lower.range(of: open), let b = lower.range(of: close, range: a.upperBound..<lower.endIndex) else { continue }
            let startOff = lower.distance(from: lower.startIndex, to: a.upperBound)
            let endOff = lower.distance(from: lower.startIndex, to: b.lowerBound)
            let start = xml.index(xml.startIndex, offsetBy: startOff)
            let end = xml.index(xml.startIndex, offsetBy: endOff)
            return String(xml[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func absoluteURL(_ path: String, base: String) -> String {
        if path.lowercased().hasPrefix("http") { return path }
        guard let u = URL(string: base) else { return path }
        if path.hasPrefix("/") {
            return "\(u.scheme ?? "http")://\(u.host ?? "")\(u.port.map { ":\($0)" } ?? "")\(path)"
        }
        return URL(string: path, relativeTo: u)?.absoluteString ?? path
    }
}
