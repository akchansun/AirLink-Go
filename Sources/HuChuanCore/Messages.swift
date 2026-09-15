import Foundation

public enum ControlMessage: Equatable, Sendable {
    case hello(Hello)
    case helloOk(Hello)
    case offer(Offer)
    case offerReply(OfferReply)
    case reject(Reject)
    case join(Join)
    case finish(Finish)
    case cancel(Cancel)
    case text(TextPayload)

    public struct Hello: Codable, Equatable, Sendable {
        public var deviceId: String
        public var name: String
        public var port: UInt16
        public var httpPort: UInt16
        public var os: String
        public var appVersion: String
        public var pin: String?

        public init(deviceId: String, name: String, port: UInt16, httpPort: UInt16, os: String, appVersion: String, pin: String? = nil) {
            self.deviceId = deviceId
            self.name = name
            self.port = port
            self.httpPort = httpPort
            self.os = os
            self.appVersion = appVersion
            self.pin = pin
        }
    }

    public struct Offer: Codable, Equatable, Sendable {
        public var sessionId: String
        public var token: String
        public var files: [FileOffer]

        public init(sessionId: String, token: String, files: [FileOffer]) {
            self.sessionId = sessionId
            self.token = token
            self.files = files
        }
    }

    public struct OfferReply: Codable, Equatable, Sendable {
        public var sessionId: String
        public var accepted: Bool
        public var saveNames: [String]
        public var resumeBits: [String]

        public init(sessionId: String, accepted: Bool, saveNames: [String], resumeBits: [String]) {
            self.sessionId = sessionId
            self.accepted = accepted
            self.saveNames = saveNames
            self.resumeBits = resumeBits
        }
    }

    public struct Reject: Codable, Equatable, Sendable {
        public var sessionId: String
        public var reason: String
        public init(sessionId: String, reason: String) {
            self.sessionId = sessionId
            self.reason = reason
        }
    }

    public struct Join: Codable, Equatable, Sendable {
        public var sessionId: String
        public var token: String
        public var workerId: Int
        public init(sessionId: String, token: String, workerId: Int) {
            self.sessionId = sessionId
            self.token = token
            self.workerId = workerId
        }
    }

    public struct Finish: Codable, Equatable, Sendable {
        public var sessionId: String
        public init(sessionId: String) { self.sessionId = sessionId }
    }

    public struct Cancel: Codable, Equatable, Sendable {
        public var sessionId: String
        public var reason: String
        public init(sessionId: String, reason: String) {
            self.sessionId = sessionId
            self.reason = reason
        }
    }

    public struct TextPayload: Codable, Equatable, Sendable {
        public var sessionId: String
        public var body: String
        public init(sessionId: String, body: String) {
            self.sessionId = sessionId
            self.body = body
        }
    }

    private struct Envelope: Codable {
        var t: String
        var deviceId: String? = nil
        var name: String? = nil
        var port: UInt16? = nil
        var httpPort: UInt16? = nil
        var os: String? = nil
        var appVersion: String? = nil
        var pin: String? = nil
        var sessionId: String? = nil
        var token: String? = nil
        var files: [FileOffer]? = nil
        var accepted: Bool? = nil
        var saveNames: [String]? = nil
        var resumeBits: [String]? = nil
        var reason: String? = nil
        var workerId: Int? = nil
        var body: String? = nil
    }

    public func encodeJSON() throws -> Data {
        let env: Envelope
        switch self {
        case .hello(let h), .helloOk(let h):
            env = Envelope(
                t: helloTag, deviceId: h.deviceId, name: h.name, port: h.port, httpPort: h.httpPort,
                os: h.os, appVersion: h.appVersion, pin: h.pin
            )
        case .offer(let o):
            env = Envelope(t: "offer", sessionId: o.sessionId, token: o.token, files: o.files)
        case .offerReply(let r):
            env = Envelope(t: "offerReply", sessionId: r.sessionId, accepted: r.accepted, saveNames: r.saveNames, resumeBits: r.resumeBits)
        case .reject(let r):
            env = Envelope(t: "reject", sessionId: r.sessionId, reason: r.reason)
        case .join(let j):
            env = Envelope(t: "join", sessionId: j.sessionId, token: j.token, workerId: j.workerId)
        case .finish(let f):
            env = Envelope(t: "finish", sessionId: f.sessionId)
        case .cancel(let c):
            env = Envelope(t: "cancel", sessionId: c.sessionId, reason: c.reason)
        case .text(let t):
            env = Envelope(t: "text", sessionId: t.sessionId, body: t.body)
        }
        return try JSONEncoder().encode(env)
    }

    private var helloTag: String {
        if case .helloOk = self { return "helloOk" }
        return "hello"
    }

    public static func decodeJSON(_ data: Data) throws -> ControlMessage {
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        switch env.t {
        case "hello", "helloOk":
            guard let id = env.deviceId, let name = env.name, let port = env.port, let http = env.httpPort else {
                throw WireError.protocolViolation("握手信息不完整")
            }
            let hello = Hello(
                deviceId: id, name: name, port: port, httpPort: http,
                os: env.os ?? "unknown", appVersion: env.appVersion ?? "0", pin: env.pin
            )
            return env.t == "helloOk" ? .helloOk(hello) : .hello(hello)
        case "offer":
            guard let sid = env.sessionId, let token = env.token, let files = env.files else {
                throw WireError.protocolViolation("发送请求不完整")
            }
            return .offer(Offer(sessionId: sid, token: token, files: files))
        case "offerReply":
            guard let sid = env.sessionId else { throw WireError.protocolViolation("回复缺少会话") }
            return .offerReply(OfferReply(
                sessionId: sid,
                accepted: env.accepted ?? false,
                saveNames: env.saveNames ?? [],
                resumeBits: env.resumeBits ?? []
            ))
        case "reject":
            return .reject(Reject(sessionId: env.sessionId ?? "", reason: env.reason ?? "已拒绝"))
        case "join":
            guard let sid = env.sessionId, let token = env.token else {
                throw WireError.protocolViolation("数据通道信息不完整")
            }
            return .join(Join(sessionId: sid, token: token, workerId: env.workerId ?? 0))
        case "finish":
            return .finish(Finish(sessionId: env.sessionId ?? ""))
        case "cancel":
            return .cancel(Cancel(sessionId: env.sessionId ?? "", reason: env.reason ?? "已取消"))
        case "text":
            return .text(TextPayload(sessionId: env.sessionId ?? "", body: env.body ?? ""))
        default:
            throw WireError.protocolViolation("未知消息：\(env.t)")
        }
    }
}

public struct DiscoveryPacket: Codable, Equatable, Sendable {
    public var v: Int
    public var id: String
    public var name: String
    public var port: UInt16
    public var httpPort: UInt16
    public var os: String
    public var reply: Bool?
    public var phoneClaim: String?

    public init(v: Int = 1, id: String, name: String, port: UInt16, httpPort: UInt16, os: String, reply: Bool = false, phoneClaim: String? = nil) {
        self.v = v
        self.id = id
        self.name = name
        self.port = port
        self.httpPort = httpPort
        self.os = os
        self.reply = reply ? true : nil
        self.phoneClaim = phoneClaim
    }

    public func encode() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    public static func decode(_ data: Data) -> DiscoveryPacket? {
        try? JSONDecoder().decode(DiscoveryPacket.self, from: data)
    }
}
