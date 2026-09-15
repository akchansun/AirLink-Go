import SwiftUI
import UniformTypeIdentifiers
import AppKit
import CoreImage
import HuChuanCore

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var transfers: TransferCenter

    var body: some View {
        HStack(spacing: 0) {
            SidebarPane()
                .frame(width: 292)
            Rectangle()
                .fill(Palette.line)
                .frame(width: 1)
            detailPane
        }
        .preferredColorScheme(.light)
        .tint(Palette.celadon)
        .foregroundStyle(Palette.ink)
        .frame(minWidth: 720, minHeight: 500)
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            if state.pickingMany, !state.multiIDs.isEmpty {
                state.sendDroppedMany(providers: providers)
                return true
            }
            guard let peer = state.selectedPeer, state.page == .chat else { return false }
            state.sendDropped(to: peer, providers: providers)
            return true
        }
        .onPasteCommand(of: [.fileURL, .utf8PlainText]) { _ in
            state.pasteToCurrent()
        }
        .onChange(of: transfers.incoming?.id) { _, new in
            if new != nil { state.dialog = .incoming }
            else if state.dialog == .incoming { state.dialog = nil }
        }
        .onChange(of: transfers.incomingText?.id) { _, _ in
            if let item = transfers.incomingText {
                state.rememberIncomingText(item)
                transfers.incomingText = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .huchuanOpenSettings)) { _ in
            state.openDialog(.settings)
        }
        .onReceive(NotificationCenter.default.publisher(for: .huchuanOpenHelp)) { _ in
            state.openDialog(.help)
        }
        .overlay {
            if state.dialog == .incoming {
                IncomingOverlay()
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        switch state.page {
        case .settings:
            SettingsPane()
        case .phone:
            PhonePane()
        case .store:
            StorePane()
        case .addIP:
            AddIPPane()
        case .history:
            HistoryPane()
        case .help:
            HelpPane()
        case .chat:
            if state.selectedPeer != nil {
                ChatPane()
            } else {
                WelcomePane()
            }
        case .welcome:
            WelcomePane()
        }
    }
}

struct SidebarPane: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var discovery: DiscoveryService

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("互传")
                        .font(.system(size: 22, weight: .semibold, design: .serif))
                        .tracking(4)
                        .foregroundStyle(Palette.ink)
                    BrandMark(compact: true)
                }
                Spacer()
                Button {
                    discovery.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.celadon)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("刷新附近设备")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(settings.deviceName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(discovery.localIPs.isEmpty ? "还没有局域网地址" : discovery.localIPs.joined(separator: "  ") + " · 端口 \(settings.port)")
                    .font(.caption.monospaced())
                    .foregroundStyle(Palette.muted)
                    .textSelection(.enabled)
                Text(discovery.statusText)
                    .font(.caption2)
                    .foregroundStyle(Palette.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            HStack {
                Text("附近的人")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.muted)
                Spacer()
                Button(state.pickingMany ? "取消多选" : "发给多台") {
                    state.pickingMany.toggle()
                    if !state.pickingMany { state.multiIDs.removeAll() }
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .foregroundStyle(Palette.celadon)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)

            if discovery.peers.isEmpty {
                VStack(spacing: 8) {
                    Text("还没发现设备")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Palette.ink)
                    Text("两台电脑连同一 Wi-Fi。请看上面的地址，用 192.168 开头的那个，不要填 VPN。也可以点「添加 IP」。")
                        .font(.caption)
                        .foregroundStyle(Palette.muted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(discovery.peers) { peer in
                            DeviceRow(
                                peer: peer,
                                selected: state.page == .chat && state.selectedPeer?.id == peer.id,
                                preview: preview(for: peer),
                                favorite: state.settings.isFavorite(peer.id),
                                checked: state.multiIDs.contains(peer.id),
                                picking: state.pickingMany
                            )
                            .onTapGesture {
                                if state.pickingMany {
                                    if state.multiIDs.contains(peer.id) { state.multiIDs.remove(peer.id) }
                                    else { state.multiIDs.insert(peer.id) }
                                } else {
                                    state.openChat(peer)
                                }
                            }
                            .contextMenu {
                                Button(state.settings.isFavorite(peer.id) ? "取消收藏" : "收藏") {
                                    state.toggleFavorite(peer)
                                }
                                Button("打开聊天") { state.openChat(peer) }
                            }
                            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                                state.openChat(peer)
                                state.sendDropped(to: peer, providers: providers)
                                return true
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }
                if state.pickingMany {
                    Button {
                        state.pickAndSendMany()
                    } label: {
                        Text(state.multiIDs.isEmpty ? "先勾选要发的电脑" : "发文件给已勾选的 \(state.multiIDs.count) 台")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(state.multiIDs.isEmpty ? Palette.muted : Palette.celadon, in: RoundedRectangle(cornerRadius: 10))
                    .disabled(state.multiIDs.isEmpty)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }

            Rectangle().fill(Palette.line).frame(height: 1)

            VStack(spacing: 4) {
                SidebarNav(icon: "gearshape", title: "设置", selected: state.page == .settings) {
                    state.openDialog(.settings)
                }
                SidebarNav(icon: "iphone", title: "手机来传", selected: state.page == .phone) {
                    state.openDialog(.phone)
                }
                SidebarNav(icon: "qrcode", title: "门店码", selected: state.page == .store) {
                    state.openDialog(.store)
                }
                SidebarNav(icon: "plus.circle", title: "添加 IP", selected: state.page == .addIP) {
                    state.openDialog(.manual)
                }
                SidebarNav(icon: "clock", title: "收发记录", selected: state.page == .history) {
                    state.page = .history
                    state.dialog = nil
                }
                SidebarNav(icon: "questionmark.circle", title: "帮助", selected: state.page == .help) {
                    state.openDialog(.help)
                }
                SidebarNav(icon: "folder", title: "打开接收箱", selected: false) {
                    state.transfers.openReceived()
                }
            }
            .padding(10)
        }
        .background(Palette.sidebar)
    }

    private func preview(for peer: PeerDevice) -> String {
        if let line = state.messages.last(where: { $0.peerId == peer.id || $0.peerName == peer.name }) {
            return line.text
        }
        if let item = state.transfers.items.first(where: { $0.peerName == peer.name }) {
            return item.title
        }
        return peer.host
    }
}

struct SidebarNav: View {
    let icon: String
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 18)
                Text(title)
                Spacer()
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(selected ? Palette.celadon : Palette.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(selected ? Palette.celadonSoft : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct DeviceRow: View {
    let peer: PeerDevice
    let selected: Bool
    let preview: String
    var favorite: Bool = false
    var checked: Bool = false
    var picking: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            if picking {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(checked ? Palette.celadon : Palette.muted)
            }
            AvatarView(name: peer.name, id: peer.id, size: 42)
                .opacity(peer.online ? 1 : 0.5)
                .overlay(alignment: .bottomTrailing) {
                        Circle()
                            .fill(peer.online ? Palette.celadon : Palette.muted.opacity(0.55))
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(selected || checked ? Palette.celadonSoft : Palette.sidebar, lineWidth: 2))
                }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(peer.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(peer.online ? Palette.ink : Palette.muted)
                        .lineLimit(1)
                    if favorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.cinnabar)
                    }
                }
                Text((peer.online ? "在线" : "离线") + "  ·  " + preview)
                    .font(.caption)
                    .foregroundStyle(peer.online ? Palette.celadon : Palette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(selected || checked ? Palette.celadonSoft : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
    }
}

struct WelcomePane: View {
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().stroke(Palette.celadon.opacity(0.18), lineWidth: 1).frame(width: 120, height: 120)
                Circle().stroke(Palette.celadon.opacity(0.28), lineWidth: 1).frame(width: 80, height: 80)
                Circle().fill(Palette.celadon).frame(width: 16, height: 16)
            }
            Text("选左边一个人，就能发文件或说话")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Palette.ink)
            Text("和聊天软件一样：左边是附近设备，右边拖文件进去，或打字发送。手机扫码连通后，右边会自动出现聊天窗口。")
                .font(.callout)
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            BrandMark()
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.chatBg)
    }
}

struct ChatPane: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var transfers: TransferCenter
    @EnvironmentObject var discovery: DiscoveryService
    @State private var dropping = false

    var peer: PeerDevice {
        discovery.peers.first(where: { $0.id == state.selectedPeer?.id }) ?? state.selectedPeer!
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                AvatarView(name: peer.name, id: peer.id, size: 36)
                    .overlay(alignment: .bottomTrailing) {
                        Circle()
                            .fill(peer.online ? Palette.celadon : Palette.muted.opacity(0.55))
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(Palette.card, lineWidth: 2))
                    }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(peer.name)
                            .font(.headline)
                            .foregroundStyle(Palette.ink)
                        Text(peer.online ? "在线" : "离线")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(peer.online ? Palette.celadon : Palette.muted)
                    }
                    Text("\(peer.host)  ·  \(peer.via)")
                        .font(.caption)
                        .foregroundStyle(Palette.muted)
                    if peer.id != "phone-web" {
                        Text("见面码 \(MeetCode.of(discovery.deviceId, peer.id))（两边应一样）")
                            .font(.caption)
                            .foregroundStyle(Palette.celadon)
                    }
                }
                Spacer()
                if peer.id != "phone-web" {
                    Button {
                        state.toggleFavorite(peer)
                    } label: {
                        Image(systemName: state.settings.isFavorite(peer.id) ? "star.fill" : "star")
                            .foregroundStyle(state.settings.isFavorite(peer.id) ? Palette.cinnabar : Palette.muted)
                    }
                    .buttonStyle(.plain)
                    .help(state.settings.isFavorite(peer.id) ? "取消收藏" : "收藏后离线也留着，并可设为自动接收")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Palette.card)
            .overlay(alignment: .bottom) { Palette.line.frame(height: 1) }

            ZStack {
                Palette.chatBg
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(chatItems) { item in
                                ChatItemView(item: item)
                                    .id(item.id)
                            }
                        }
                        .padding(20)
                    }
                    .onChange(of: chatItems.count) { _, _ in
                        if let last = chatItems.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
                if dropping {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Palette.celadon, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        .background(Palette.celadonSoft.opacity(0.45), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .padding(16)
                        .overlay {
                            Text("松手发给 \(peer.name)")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Palette.celadon)
                        }
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                state.sendDropped(to: peer, providers: providers)
                return true
            }

            composer
        }
        .background(Palette.chatBg)
    }

    private var chatItems: [DisplayItem] {
        var rows: [DisplayItem] = []
        for line in state.messages where line.peerId == peer.id || line.peerName == peer.name {
            rows.append(DisplayItem(id: line.id.uuidString, date: line.time, kind: .text(line)))
        }
        for item in transfers.items.reversed() where item.peerName == peer.name {
            rows.append(DisplayItem(id: item.id.uuidString, date: Date(), kind: .file(item)))
        }
        return rows
    }

    private var composer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    state.pickAndSend(to: peer)
                } label: {
                    Label("发文件/文件夹", systemImage: "paperclip")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Palette.paper, in: Capsule())
                }
                .buttonStyle(.plain)
                if peer.id != "phone-web" {
                    Button {
                        state.sendClipboard(to: peer)
                    } label: {
                        Label("发剪贴板", systemImage: "clipboard")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Palette.ink)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Palette.paper, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("把当前复制的文字发过去，对方可自动进剪贴板")
                }
                Text(peer.id == "phone-web" ? "发到手机网页，手机上点「保存到手机」" : "也可以把文件或文件夹拖到上面的对话里")
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
                Spacer()
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("和 \(peer.name) 说点什么…", text: $state.textDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1...5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.line, lineWidth: 1))
                    .onSubmit { state.sendComposer() }
                Button {
                    state.sendComposer()
                } label: {
                    Text("发送")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(state.textDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Palette.muted : Palette.celadon, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(state.textDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .background(Palette.card)
        .overlay(alignment: .top) { Palette.line.frame(height: 1) }
    }
}

struct DisplayItem: Identifiable {
    let id: String
    let date: Date
    enum Kind {
        case text(ChatLine)
        case file(TransferItem)
    }
    let kind: Kind
}

struct ChatItemView: View {
    let item: DisplayItem
    @EnvironmentObject var state: AppState

    var body: some View {
        switch item.kind {
        case .text(let line):
            TextBubble(line: line)
        case .file(let file):
            FileBubble(item: file)
        }
    }
}

struct TextBubble: View {
    let line: ChatLine

    var body: some View {
        HStack {
            if line.outgoing { Spacer(minLength: 80) }
            Text(linkedText)
                .font(.body)
                .foregroundStyle(line.outgoing ? Color.white : Palette.ink)
                .tint(line.outgoing ? Color.white : Palette.celadon)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(line.outgoing ? Palette.bubbleOut : Palette.bubbleIn, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(line.outgoing ? Color.clear : Palette.line, lineWidth: 1)
                )
                .textSelection(.enabled)
            if !line.outgoing { Spacer(minLength: 80) }
        }
    }

    private var linkedText: AttributedString {
        var result = AttributedString(line.text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return result
        }
        let s = line.text
        detector.enumerateMatches(in: s, options: [], range: NSRange(location: 0, length: (s as NSString).length)) { match, _, _ in
            guard let match, let url = match.url,
                  let strRange = Range(match.range, in: s),
                  let attrRange = Range(strRange, in: result) else { return }
            result[attrRange].link = url
            result[attrRange].underlineStyle = .single
        }
        return result
    }
}

struct FileBubble: View {
    let item: TransferItem
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack {
            if item.direction == .send { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: item.direction == .send ? "arrow.up.doc.fill" : "arrow.down.doc.fill")
                        .foregroundStyle(item.direction == .send ? Palette.cinnabar : Palette.celadon)
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(2)
                    Spacer()
                    Text(item.state.rawValue)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(statusColor)
                }
                if item.total > 0 {
                    ProgressView(value: item.progress)
                        .tint(Palette.celadon)
                    HStack {
                        Text("\(ByteFormat.size(item.done)) / \(ByteFormat.size(item.total))")
                        Spacer()
                        Text(item.detail)
                    }
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
                } else if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(Palette.muted)
                }
                if item.state == .transferring || item.state == .waiting || item.state == .waitingPeer || item.state == .waitingPhone {
                    Button("取消") { state.transfers.cancel(item.id) }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Palette.cinnabar)
                }
                if item.state == .completed {
                    HStack(spacing: 14) {
                        if let path = item.localPath, !path.isEmpty {
                            Button("打开") { state.transfers.openLocal(path) }
                            Button("打开所在位置") { state.transfers.revealLocal(path) }
                        } else {
                            Button("打开接收箱") { state.transfers.openReceived() }
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Palette.celadon)
                }
            }
            .padding(12)
            .frame(maxWidth: 420, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.line, lineWidth: 1))
            if item.direction == .receive { Spacer(minLength: 60) }
        }
    }

    private var statusColor: Color {
        switch item.state {
        case .completed: return Palette.celadon
        case .failed, .cancelled: return Palette.cinnabar
        default: return Palette.muted
        }
    }
}

struct SettingsPane: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var state: AppState
    @State private var portText = ""
    @State private var wifiHint = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("设置")
                    .font(.system(size: 28, weight: .semibold, design: .serif))
                    .foregroundStyle(Palette.ink)

                settingsCard("这台电脑叫什么") {
                    TextField("例如 客厅的电脑", text: $settings.deviceName)
                        .textFieldStyle(.plain)
                        .foregroundStyle(Palette.ink)
                        .padding(10)
                        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 10))
                }

                settingsCard("收到的文件放哪里") {
                    Text(settings.receiveFolder.path)
                        .font(.callout)
                        .foregroundStyle(Palette.ink)
                        .textSelection(.enabled)
                    Button("更换文件夹") { settings.pickReceiveFolder() }
                        .buttonStyle(SolidButton(color: Palette.celadon))
                }

                settingsCard("接收方式") {
                    Picker("别人发来时", selection: $settings.receiveMode) {
                        ForEach(ReceiveMode.allCases, id: \.rawValue) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .foregroundStyle(Palette.ink)
                    Text("收藏的人可在左侧名单上右键添加。选「只自动收收藏的人」时，其他人发来仍会先问你。")
                        .font(.caption)
                        .foregroundStyle(Palette.muted)
                    HStack {
                        Text("口令（可空）")
                            .foregroundStyle(Palette.ink)
                        SecureField("对方要填一样的口令", text: $settings.pin)
                            .textFieldStyle(.plain)
                            .foregroundStyle(Palette.ink)
                            .padding(8)
                            .background(Palette.paper, in: RoundedRectangle(cornerRadius: 8))
                    }
                }

                settingsCard("谁能发现我") {
                    Picker("发现范围", selection: $settings.discoverMode) {
                        ForEach(DiscoverMode.allCases, id: \.rawValue) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .foregroundStyle(Palette.ink)
                    Text("「不广播」后，别人自动找不到你，仍可用添加 IP 互传。")
                        .font(.caption)
                        .foregroundStyle(Palette.muted)
                }

                settingsCard("文字") {
                    Toggle("收到文字后自动复制到剪贴板", isOn: $settings.autoCopyText)
                        .foregroundStyle(Palette.ink)
                        .toggleStyle(.switch)
                    Text("适合发验证码、网盘链接。聊天里也可点「发剪贴板」。")
                        .font(.caption)
                        .foregroundStyle(Palette.muted)
                }

                settingsCard("门店码（打印店）") {
                    Text("柜台点「门店码」就会亮。填了下面的 Wi-Fi，亮码页会多一个连网码。连网码请用手机自带相机扫，不要用微信。")
                        .font(.caption)
                        .foregroundStyle(Palette.muted)
                    TextField("店里 Wi-Fi 名称", text: $settings.storeWifiName)
                        .textFieldStyle(.plain)
                        .foregroundStyle(Palette.ink)
                        .padding(10)
                        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 10))
                    SecureField("店里 Wi-Fi 密码，没有密码就空着", text: $settings.storeWifiPassword)
                        .textFieldStyle(.plain)
                        .foregroundStyle(Palette.ink)
                        .padding(10)
                        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 10))
                    Button("填入正在用的 Wi-Fi") {
                        Task { await fillCurrentWifi() }
                    }
                    .buttonStyle(SolidButton(color: Palette.celadon))
                    if !wifiHint.isEmpty {
                        Text(wifiHint)
                            .font(.caption)
                            .foregroundStyle(wifiHint.contains("已填入") ? Palette.celadon : Palette.cinnabar)
                    }
                    Text("连网码只显示在店里电脑上，不会发到中转。")
                        .font(.caption)
                        .foregroundStyle(Palette.muted)
                    DisclosureGroup("高级（一般不用填）") {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("中转网址，可空", text: $settings.storeRelayURL)
                                .textFieldStyle(.plain)
                                .foregroundStyle(Palette.ink)
                                .padding(10)
                                .background(Palette.paper, in: RoundedRectangle(cornerRadius: 10))
                            TextField("外网地址，可空", text: $settings.storePublicURL)
                                .textFieldStyle(.plain)
                                .foregroundStyle(Palette.ink)
                                .padding(10)
                                .background(Palette.paper, in: RoundedRectangle(cornerRadius: 10))
                            Text("中转只给顾客指路，文件直达店里电脑，不走服务器流量。店里电脑要一直亮着码。只有会弄电脑的人才填。")
                                .font(.caption)
                                .foregroundStyle(Palette.muted)
                        }
                        .padding(.top, 8)
                    }
                    .foregroundStyle(Palette.ink)
                }

                settingsCard("开机与驻留") {
                    Toggle("开机后自动打开互传", isOn: $settings.launchAtLogin)
                        .foregroundStyle(Palette.ink)
                        .toggleStyle(.switch)
                    Text("关掉窗口后，互传会留在菜单栏。点菜单栏图标或程序坞图标可再打开。要退出请选「退出互传」。")
                        .font(.caption)
                        .foregroundStyle(Palette.muted)
                }

                settingsCard("传输") {
                    HStack {
                        Text("端口")
                            .foregroundStyle(Palette.ink)
                        TextField("41789", text: $portText)
                            .textFieldStyle(.plain)
                            .foregroundStyle(Palette.ink)
                            .frame(width: 80)
                            .padding(8)
                            .background(Palette.paper, in: RoundedRectangle(cornerRadius: 8))
                            .onChange(of: portText) { _, value in
                                if let v = UInt16(value), v >= 1024 { settings.port = v }
                            }
                    }
                    Stepper(value: $settings.maxConnections, in: 1...16) {
                        Text("大文件走 \(settings.maxConnections) 路一起传")
                            .foregroundStyle(Palette.ink)
                    }
                    Text("改了名字或端口后点保存。Wi-Fi 一般 4～8 路就够快。电脑之间传文件已加密，每块用 SHA-256 核对。旧版互传连不上。")
                        .font(.caption)
                        .foregroundStyle(Palette.muted)
                }

                Button("保存并开始寻找设备") {
                    if let v = UInt16(portText), v >= 1024 { settings.port = v }
                    state.discovery.start()
                    state.http.start()
                    state.page = state.selectedPeer == nil ? .welcome : .chat
                    state.dialog = nil
                }
                .buttonStyle(SolidButton(color: Palette.cinnabar))

                VStack(alignment: .leading, spacing: 4) {
                    Text("互传 1.0.0")
                    BrandMark()
                }
                .padding(.top, 12)
            }
            .padding(32)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.paper)
        .onAppear {
            portText = String(settings.port)
            let on = LaunchAtLogin.isEnabled
            if settings.launchAtLogin != on {
                settings.launchAtLogin = on
            }
        }
    }

    private func fillCurrentWifi() async {
        if let name = await StoreWifi.fillCurrentSSID() {
            settings.storeWifiName = name
            wifiHint = "已填入「\(name)」。密码还要自己填。"
        } else {
            wifiHint = "没读到当前网络名称。请自己填，或到系统设置 → 隐私与安全性 → 定位服务里允许互传。"
        }
    }

    private func settingsCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.muted)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.line, lineWidth: 1))
    }
}

struct PhonePane: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    Text("手机和电脑互相传")
                        .font(.system(size: 26, weight: .semibold, design: .serif))
                        .foregroundStyle(Palette.ink)
                    Text("扫码打开网页就能传，不用装 App")
                        .font(.subheadline)
                        .foregroundStyle(Palette.muted)
                }
                .multilineTextAlignment(.center)
                .padding(.bottom, 22)

                VStack(alignment: .leading, spacing: 16) {
                    phoneStep(1, title: "电脑和手机", body: "手机连同一 Wi-Fi，扫下面的码打开网页，页面一直开着。")
                    phoneStep(2, title: "两部手机互传", body: "都扫这台电脑的码。一部发出去，另一部点「保存到手机」。电脑上也会留一份。")
                }
                .frame(maxWidth: 420, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 26)

                if let img = QRMaker.image(state.phoneURL) {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: 200, height: 200)
                        .padding(18)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.line, lineWidth: 1))
                        .padding(.bottom, 14)
                }
                Text(state.phoneURL)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Palette.ink)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: 420)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line, lineWidth: 1))
                Button("复制网址") { state.copyPhoneURL() }
                    .buttonStyle(SolidButton(color: Palette.celadon))
                    .padding(.top, 16)
                BrandMark()
                    .padding(.top, 20)
            }
            .padding(.horizontal, 32)
            .padding(.top, 36)
            .padding(.bottom, 28)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.paper)
    }

    private func phoneStep(_ n: Int, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.celadon)
                .frame(width: 22, height: 22)
                .background(Palette.celadonSoft, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                Text(body)
                    .font(.callout)
                    .foregroundStyle(Palette.muted)
                    .lineSpacing(5)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct StorePane: View {
    @EnvironmentObject var state: AppState
    @State private var wifiHint = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    Text("门店码")
                        .font(.system(size: 26, weight: .semibold, design: .serif))
                        .foregroundStyle(Palette.ink)
                    Text("柜台亮码，顾客扫了把文件投到这台电脑。连网码请用手机自带相机扫，不要用微信。连上后再用微信扫传文件码。")
                        .font(.subheadline)
                        .foregroundStyle(Palette.muted)
                }
                .multilineTextAlignment(.center)
                .padding(.bottom, 18)

                if !state.store.reachHint.isEmpty {
                    Text(state.store.reachHint)
                        .font(.callout)
                        .foregroundStyle(state.store.reachHint.contains("可以用手机流量") ? Palette.celadon : Palette.ink)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 16)
                        .frame(maxWidth: 420)
                }

                if !state.store.errorText.isEmpty {
                    Text(state.store.errorText)
                        .font(.callout)
                        .foregroundStyle(Palette.cinnabar)
                        .padding(.bottom, 12)
                }

                if let sess = state.store.session {
                    let wifiText = StoreWifi.payload(ssid: state.settings.storeWifiName, password: state.settings.storeWifiPassword)
                    HStack(alignment: .top, spacing: 28) {
                        if let wifiText, let wifiImg = QRMaker.image(wifiText) {
                            storeQRCard(
                                title: "1. 连网码",
                                caption: "店里网：\(state.settings.storeWifiName)",
                                alert: "请用手机自带「相机」扫，不要用微信。微信会显示一串英文，连不上网。",
                                image: wifiImg
                            )
                        }
                        if let img = QRMaker.image(sess.url) {
                            storeQRCard(
                                title: wifiText == nil ? "门店码" : "2. 传文件码",
                                caption: wifiText == nil ? "扫了把文件发到这台电脑" : "连上店里网后，可用微信扫",
                                image: img
                            )
                        }
                    }
                    .padding(.bottom, 14)
                    if wifiText == nil {
                        VStack(spacing: 10) {
                            Text("想让顾客扫一下就连上网，先填店里 Wi-Fi 名称。")
                                .font(.caption)
                                .foregroundStyle(Palette.muted)
                            Button("填入正在用的 Wi-Fi") {
                                Task { await fillCurrentWifi() }
                            }
                            .buttonStyle(SolidButton(color: Palette.celadon))
                            if !wifiHint.isEmpty {
                                Text(wifiHint)
                                    .font(.caption)
                                    .foregroundStyle(wifiHint.contains("已填入") ? Palette.celadon : Palette.cinnabar)
                            }
                        }
                        .padding(.bottom, 10)
                    }
                    Text(sess.url)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Palette.ink)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: 420)
                        .background(Palette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line, lineWidth: 1))
                    Text("口令 \(sess.pin)  ·  两小时后作废")
                        .font(.caption)
                        .foregroundStyle(Palette.muted)
                        .padding(.top, 8)
                    HStack(spacing: 12) {
                        Button("换一个码") { state.store.rotate() }
                            .buttonStyle(SolidButton(color: Palette.celadon))
                        Button("结束本次") { state.store.close() }
                            .buttonStyle(SolidButton(color: Palette.muted))
                    }
                    .padding(.top, 16)
                    if !sess.files.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("这次收到 \(sess.files.count) 个文件")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Palette.ink)
                            ForEach(sess.files.suffix(8).reversed()) { f in
                                Text(f.name)
                                    .font(.callout)
                                    .foregroundStyle(Palette.ink)
                            }
                        }
                        .frame(maxWidth: 420, alignment: .leading)
                        .padding(.top, 20)
                    }
                } else {
                    VStack(spacing: 12) {
                        Button("填入正在用的 Wi-Fi") {
                            Task { await fillCurrentWifi() }
                        }
                        .buttonStyle(SolidButton(color: Palette.celadon))
                        if !wifiHint.isEmpty {
                            Text(wifiHint)
                                .font(.caption)
                                .foregroundStyle(wifiHint.contains("已填入") ? Palette.celadon : Palette.cinnabar)
                        }
                        Button("亮码开始收文件") { state.store.open() }
                            .buttonStyle(SolidButton(color: Palette.cinnabar))
                    }
                    .padding(.top, 12)
                }
                BrandMark()
                    .padding(.top, 20)
            }
            .padding(.horizontal, 32)
            .padding(.top, 36)
            .padding(.bottom, 28)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.paper)
        .onAppear {
            if state.store.session == nil {
                state.store.open()
            }
        }
    }

    private func storeQRCard(title: String, caption: String, alert: String? = nil, image: NSImage) -> some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.ink)
            Image(nsImage: image)
                .resizable()
                .interpolation(.none)
                .frame(width: 180, height: 180)
                .padding(16)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.line, lineWidth: 1))
            Text(caption)
                .font(.caption)
                .foregroundStyle(Palette.muted)
            if let alert {
                Text(alert)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.cinnabar)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 220)
            }
        }
    }

    private func fillCurrentWifi() async {
        if let name = await StoreWifi.fillCurrentSSID() {
            state.settings.storeWifiName = name
            wifiHint = "已填入「\(name)」。密码请到设置里填。"
        } else {
            wifiHint = "没读到当前网络名称。请到设置里自己填，或在系统设置 → 隐私与安全性 → 定位服务里允许互传。"
        }
    }
}

struct AddIPPane: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("用 IP 添加对方")
                .font(.system(size: 26, weight: .semibold, design: .serif))
                .foregroundStyle(Palette.ink)
            Text("对方窗口左边能看到自己的 IP。路由器如果拦了自动发现，填这个最稳。")
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            TextField("例如 192.168.1.32", text: $state.manualHost)
                .textFieldStyle(.plain)
                .foregroundStyle(Palette.ink)
                .padding(10)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line, lineWidth: 1))
            TextField("端口，默认 41789", text: $state.manualPort)
                .textFieldStyle(.plain)
                .foregroundStyle(Palette.ink)
                .padding(10)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line, lineWidth: 1))
            Button("添加到左侧名单") { state.addManual() }
                .buttonStyle(SolidButton(color: Palette.celadon))
                .disabled(state.manualHost.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(36)
        .frame(maxWidth: 520, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.paper)
    }
}

struct HistoryPane: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("收发记录")
                    .font(.system(size: 26, weight: .semibold, design: .serif))
                    .foregroundStyle(Palette.ink)
                Spacer()
                if !state.history.items.isEmpty {
                    Button("清空记录") { state.history.clear() }
                        .buttonStyle(.plain)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Palette.cinnabar)
                }
            }
            if state.history.items.isEmpty {
                Text("还没有收过或发过文件。记录最多保留 80 条。")
                    .foregroundStyle(Palette.muted)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(state.history.items) { item in
                            historyRow(item)
                        }
                    }
                }
            }
        }
        .padding(32)
        .frame(maxWidth: 720, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.paper)
    }

    private func historyRow(_ item: HistoryItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.isSend ? "发出" : "收到")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(item.isSend ? Palette.muted : Palette.celadon)
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                Text("\(item.peerName)  ·  \(item.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 8)
            if !item.path.isEmpty {
                Button("打开") { state.transfers.openLocal(item.path) }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Palette.celadon)
                Button("打开位置") { state.transfers.revealLocal(item.path) }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Palette.celadon)
            }
        }
        .padding(14)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line, lineWidth: 1))
    }
}

struct HelpPane: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("用法说明")
                    .font(.system(size: 28, weight: .semibold, design: .serif))
                    .foregroundStyle(Palette.ink)
                Text("互传主要在同一局域网里用。电脑之间传文件已加密。打印店可用门店码：先让顾客连店里 Wi-Fi 再扫最稳。")
                    .font(.callout)
                    .foregroundStyle(Palette.muted)
                    .lineSpacing(5)
                    .padding(.bottom, 4)

                helpCard("电脑和电脑") {
                    Text("两边连同一个 Wi-Fi，都打开互传。左边点对方，把文件拖进去，或点「发文件/文件夹」。也可以打字发消息。")
                    Text("第一次见面看聊天标题下的四位见面码，两边应一样，避免连错邻居电脑。")
                    Text("名单里找不到时，看窗口左边自己的地址，用 192.168 开头的那个，不要填 VPN。点「添加 IP」填对方的地址。")
                }
                helpCard("手机和电脑") {
                    Text("电脑点左侧「手机来传」，手机扫码打开网页，页面一直开着。")
                    Text("手机发给电脑：在网页上选文件即可。电脑发给手机：电脑左边点「手机网页」，发文件或文字，手机上点「保存到手机」。")
                }
                helpCard("门店码") {
                    Text("打印店、图文店：柜台点「门店码」亮码。顾客用微信或相机扫，把文件投到店里电脑，不用加好友。")
                    Text("连网码请用手机自带相机扫，不要用微信。微信扫出会显示一串英文，连不上网。连上后再扫传文件码。也可在设置里填店里 Wi-Fi：亮码页会多一个连网码。")
                    Text("若用自己的中转：只给顾客指路，文件直达店里电脑，不走服务器流量。店里电脑要一直亮着码。码两小时作废，也可换码、结束。文件进接收箱。")
                }
                helpCard("手机和手机") {
                    Text("没有单独的手机 App。两部手机都连同一个 Wi-Fi，都扫同一台电脑的码，网页不要关。")
                    Text("一部手机选文件发出去，另一部手机下面会出现「另一部手机发来的文件」，点「保存到手机」。电脑接收箱里也会留一份。")
                    Text("必须有一台电脑开着互传当中转。关掉电脑或关掉网页，就传不成。")
                }
                helpCard("常用技巧") {
                    Text("关掉窗口不会退出：Mac 留在菜单栏，Windows 收到右下角。菜单里可直接「发给」在线设备。要退出请选「退出互传」。")
                    Text("设置里可开机自启，也可选择每次都问、自动收下、只自动收收藏的人，或全部拒收。谁能发现我可选所有人、仅收藏、关闭。")
                    Text("发给离线的电脑，等对方上线会自动发出。传到一半断了或换了 Wi-Fi，会自动接着传，已传过的部分会跳过。每块文件用 SHA-256 核对，传坏了会重传这一块。")
                    Text("点「发给多台」可一次发给好几台。聊天里粘贴文件会发出去；点「发剪贴板」可把验证码发到对面。")
                    Text("电脑互传全程加密，每块用 SHA-256 核对。两边都要是本版本，旧版会提示升级。")
                }
                helpCard("官网") {
                    Text("互传免费，不用注册。想看定时播音、彩店积分、英语教培等其他软件，请打开官网。")
                    Button("打开官网 www.ak129.cn") { Brand.openSite() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.celadon)
                }
                BrandMark()
                    .padding(.top, 8)
            }
            .padding(32)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.paper)
    }

    private func helpCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.celadon)
            content()
                .font(.callout)
                .foregroundStyle(Palette.ink)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.line, lineWidth: 1))
    }
}

struct IncomingOverlay: View {
    @EnvironmentObject var transfers: TransferCenter

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            Group {
                if let offer = transfers.incoming {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("\(offer.peerName) 要发给你")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(Palette.ink)
                        Text("共 \(offer.files.count) 个文件，\(ByteFormat.size(offer.total))")
                            .foregroundStyle(Palette.muted)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(offer.files) { file in
                                    HStack {
                                        Text(file.relativePath).foregroundStyle(Palette.ink)
                                        Spacer()
                                        Text(ByteFormat.size(file.size)).foregroundStyle(Palette.muted)
                                    }
                                    .font(.callout)
                                }
                            }
                        }
                        .frame(maxHeight: 180)
                        HStack {
                            Button("拒绝") { transfers.rejectIncoming() }
                                .buttonStyle(SolidButton(color: Palette.muted))
                            Spacer()
                            Button("接收") { transfers.acceptIncoming() }
                                .buttonStyle(SolidButton(color: Palette.celadon))
                                .keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding(24)
                    .frame(width: 460)
                }
            }
            .background(Palette.card)
            .foregroundStyle(Palette.ink)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
        }
        .preferredColorScheme(.light)
    }
}

struct SolidButton: ButtonStyle {
    var color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(color.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
    }
}

enum QRMaker {
    static func image(_ text: String) -> NSImage? {
        let data = text.data(using: .isoLatin1) ?? text.data(using: .utf8)
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}

extension Notification.Name {
    static let huchuanOpenSettings = Notification.Name("huchuanOpenSettings")
    static let huchuanOpenHelp = Notification.Name("huchuanOpenHelp")
}
