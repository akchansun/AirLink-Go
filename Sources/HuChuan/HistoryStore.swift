import Foundation
import Combine

struct FavoritePeer: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var host: String
    var port: UInt16
}

struct HistoryItem: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var peerName: String
    var path: String
    var text: String
    var time: TimeInterval
    var kind: String

    var date: Date { Date(timeIntervalSince1970: time) }
    var isSend: Bool { kind == "send" }

    enum CodingKeys: String, CodingKey {
        case id, title, peerName, path, text, time, kind
    }

    init(id: String, title: String, peerName: String, path: String, text: String, time: TimeInterval, kind: String) {
        self.id = id
        self.title = title
        self.peerName = peerName
        self.path = path
        self.text = text
        self.time = time
        self.kind = kind
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        peerName = try c.decode(String.self, forKey: .peerName)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        time = try c.decode(TimeInterval.self, forKey: .time)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "recv"
    }
}

enum ReceiveMode: String, CaseIterable {
    case ask = "ask"
    case auto = "auto"
    case fav = "fav"
    case off = "off"

    var title: String {
        switch self {
        case .ask: return "每次都问我"
        case .auto: return "自动收下"
        case .fav: return "只自动收收藏的人"
        case .off: return "全部拒收"
        }
    }
}

enum DiscoverMode: String, CaseIterable {
    case everyone = "everyone"
    case favorites = "favorites"
    case off = "off"

    var title: String {
        switch self {
        case .everyone: return "所有人都能发现我"
        case .favorites: return "只让收藏的人发现"
        case .off: return "不广播，别人找不到我"
        }
    }
}

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var items: [HistoryItem] = []
    private let url: URL
    private let limit = 80

    init(fileURL: URL? = nil) {
        if let fileURL {
            url = fileURL
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
            let folder = dir.appendingPathComponent("互传", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            url = folder.appendingPathComponent("history.json")
        }
        load()
    }

    func add(title: String, peerName: String, path: String = "", text: String = "", kind: String = "recv") {
        let item = HistoryItem(
            id: UUID().uuidString, title: title, peerName: peerName,
            path: path, text: text, time: Date().timeIntervalSince1970, kind: kind
        )
        items.insert(item, at: 0)
        if items.count > limit {
            items = Array(items.prefix(limit))
        }
        save()
    }

    func clear() {
        items = []
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([HistoryItem].self, from: data) else { return }
        items = list
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
