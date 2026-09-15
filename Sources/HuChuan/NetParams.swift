import Foundation
import Network

enum Ports {
    static let `default`: UInt16 = 41789
    static func http(_ base: UInt16) -> UInt16 { base &- 1 }
    static func udp(_ base: UInt16) -> UInt16 { base &+ 1 }
}

enum NetFactory {
    static func tcp(peerToPeer: Bool = false) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 3
        tcp.keepaliveInterval = 1
        tcp.keepaliveCount = 8
        tcp.connectionTimeout = 12
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = peerToPeer
        params.allowLocalEndpointReuse = true
        params.serviceClass = .responsiveData
        return params
    }

    static func connect(host: String, port: UInt16) -> NWConnection {
        let params = tcp(peerToPeer: false)
        if let v4 = IPv4Address(host) {
            return NWConnection(
                host: .ipv4(v4),
                port: NWEndpoint.Port(rawValue: port)!,
                using: params
            )
        }
        return NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: params
        )
    }
}

extension NWConnection {
    func startAndWait(timeout: TimeInterval = 12) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let box = SettleBox()
            self.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.finish(cont, error: nil)
                case .failed(let err):
                    box.finish(cont, error: err)
                case .cancelled:
                    box.finish(cont, error: AppError.message("连接已取消"))
                default:
                    break
                }
            }
            self.start(queue: DispatchQueue.global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                box.finish(cont, error: AppError.message("连接超时"))
            }
        }
    }

    func receiveExactly(_ count: Int, timeout: TimeInterval = 90) async throws -> Data {
        guard count > 0 else { return Data() }
        var collected = Data()
        collected.reserveCapacity(count)
        let deadline = Date().addingTimeInterval(timeout)
        while collected.count < count {
            let left = count - collected.count
            if deadline.timeIntervalSinceNow <= 0 { throw AppError.message("等待数据超时") }
            let chunk: Data = try await withCheckedThrowingContinuation { cont in
                self.receive(minimumIncompleteLength: 1, maximumLength: left) { data, _, isComplete, error in
                    if let error {
                        cont.resume(throwing: error)
                    } else if let data, !data.isEmpty {
                        cont.resume(returning: data)
                    } else if isComplete {
                        cont.resume(throwing: AppError.message("连接已断开"))
                    } else {
                        cont.resume(returning: Data())
                    }
                }
            }
            if chunk.isEmpty { throw AppError.message("连接已断开") }
            collected.append(chunk)
        }
        return collected
    }

    func sendData(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }
}

private final class SettleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func finish(_ cont: CheckedContinuation<Void, Error>, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        if let error { cont.resume(throwing: error) } else { cont.resume() }
    }
}
