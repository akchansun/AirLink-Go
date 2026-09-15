import SwiftUI
import AppKit

enum Brand {
    static let app = "互传"
    static let company = "喜相逢科技公司"
    static let site = URL(string: "https://www.ak129.cn/")!

    static func openSite() {
        NSWorkspace.shared.open(site)
    }
}

struct BrandMark: View {
    var compact: Bool = false

    var body: some View {
        Button(action: Brand.openSite) {
            Text(Brand.company)
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(Palette.muted)
        }
        .buttonStyle(.plain)
        .help("打开官网 www.ak129.cn")
        .onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

enum Palette {
    static let paper = Color(red: 0.97, green: 0.95, blue: 0.92)
    static let sidebar = Color(red: 0.93, green: 0.90, blue: 0.85)
    static let ink = Color(red: 0.12, green: 0.10, blue: 0.08)
    static let muted = Color(red: 0.42, green: 0.38, blue: 0.34)
    static let celadon = Color(red: 0.22, green: 0.47, blue: 0.40)
    static let celadonSoft = Color(red: 0.82, green: 0.90, blue: 0.86)
    static let cinnabar = Color(red: 0.75, green: 0.32, blue: 0.18)
    static let card = Color(red: 1.0, green: 0.99, blue: 0.97)
    static let line = Color(red: 0.82, green: 0.77, blue: 0.70)
    static let bubbleOut = Color(red: 0.22, green: 0.47, blue: 0.40)
    static let bubbleIn = Color.white
    static let chatBg = Color(red: 0.96, green: 0.94, blue: 0.90)
}

func peerColor(_ id: String) -> Color {
    var hash: UInt64 = 5381
    for b in id.utf8 { hash = hash &* 33 &+ UInt64(b) }
    let hues: [Color] = [
        Palette.celadon,
        Palette.cinnabar,
        Color(red: 0.40, green: 0.34, blue: 0.58),
        Color(red: 0.18, green: 0.40, blue: 0.55),
        Color(red: 0.58, green: 0.40, blue: 0.20),
        Color(red: 0.26, green: 0.44, blue: 0.32),
    ]
    return hues[Int(hash % UInt64(hues.count))]
}

struct AvatarView: View {
    let name: String
    let id: String
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Circle().fill(peerColor(id))
            Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)))
                .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}
