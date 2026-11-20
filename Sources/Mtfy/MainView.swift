import AppKit
import SwiftUI

extension Color {
    static let brand = Color(red: 0.24, green: 0.72, blue: 0.61)
}

// MARK: - Topic colors

enum TopicColor {
    static let palette: [(name: String, hex: String)] = [
        ("Teal", "3DB89C"), ("Blue", "4A90E2"), ("Indigo", "6E6AE8"), ("Purple", "A35BD9"),
        ("Pink", "E05A9B"), ("Red", "E5534B"), ("Orange", "F0883E"), ("Yellow", "D4B030"),
        ("Green", "57B847"), ("Gray", "8B949E"),
    ]

    /// A stable pick from the palette (FNV-1a of the name; Swift's hashValue changes per launch).
    static func automatic(for topic: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in topic.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return palette[Int(hash % UInt32(palette.count))].hex
    }

    static func color(hex: String) -> Color { Color(nsColor: nsColor(hex: hex)) }

    static func nsColor(hex: String) -> NSColor {
        guard hex.wholeMatch(of: /[0-9A-Fa-f]{6}/) != nil, let v = UInt32(hex, radix: 16) else { return NSColor(.brand) }
        return NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// A dot and the name drawn in the color itself. Menus ignore SwiftUI text colors but show
    /// non-template images as-is, so this is how the menu previews each color.
    static func menuImage(_ name: String, hex: String) -> NSImage {
        let color = nsColor(hex: hex)
        let font = NSFont.menuFont(ofSize: 0)
        let text = NSAttributedString(string: name, attributes: [.font: font, .foregroundColor: color])
        let textSize = text.size()
        let dot: CGFloat = 10, gap: CGFloat = 6
        let size = NSSize(width: dot + gap + ceil(textSize.width), height: ceil(max(textSize.height, dot)))
        let image = NSImage(size: size, flipped: false) { _ in
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 0, y: (size.height - dot) / 2, width: dot, height: dot)).fill()
            text.draw(at: NSPoint(x: dot + gap, y: (size.height - textSize.height) / 2))
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = name
        return image
    }

    static func hex(from color: Color) -> String? {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        let v = [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) }
        return String(format: "%02X%02X%02X", v[0], v[1], v[2])
    }
}

extension Store {
    func topicColor(_ ref: TopicRef) -> Color {
        TopicColor.color(hex: config.settings(for: ref).color ?? TopicColor.automatic(for: ref.topic))
    }
}

// MARK: - Text scale (⌘+ / ⌘−)

/// SwiftUI on macOS has no Dynamic Type, so the main window sizes its text from this scale.
private struct TextScaleKey: EnvironmentKey {
    static let defaultValue: Double = 1
}

extension EnvironmentValues {
    var textScale: Double {
        get { self[TextScaleKey.self] }
        set { self[TextScaleKey.self] = newValue }
    }
}

enum TextStyle {
    case body, callout, caption, caption2

    /// macOS default point sizes for these styles.
    var size: Double {
        switch self {
        case .body: 13
        case .callout: 12
        case .caption: 10
        case .caption2: 10
        }
    }
}

private struct ScaledFont: ViewModifier {
    @Environment(\.textScale) private var scale
    let style: TextStyle
    let weight: Font.Weight

    func body(content: Content) -> some View {
        content.font(.system(size: style.size * scale, weight: weight))
    }
}

extension View {
    func scaledFont(_ style: TextStyle, weight: Font.Weight = .regular) -> some View {
        modifier(ScaledFont(style: style, weight: weight))
    }
}

struct MainView: View {
    @ObservedObject var store: Store

    var body: some View {
        NavigationSplitView {
            Sidebar(store: store)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 320)
        } detail: {
            let scope = store.selection ?? .all
            MessageList(store: store, scope: scope)
                .id(scope)
        }
        .tint(.brand)
        .environment(\.textScale, store.textScale)
        .frame(minWidth: 760, minHeight: 440)
        .sheet(item: $store.sheet) { sheet in
            switch sheet {
            case .settings: SettingsView(store: store)
            case .addTopic: AddTopicSheet(store: store)
            case .compose(let topic): ComposeSheet(store: store, topic: topic)
            case .edit(let id):
                if let msg = store.messages.first(where: { $0.id == id }) {
                    ComposeSheet(store: store, topic: msg.ref, editing: msg)
                }
            case .scheduled: ScheduledSheet(store: store)
            case .topicSettings(let ref): TopicSettingsSheet(store: store, ref: ref)
            }
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @ObservedObject var store: Store
    @State private var topicToRemove: TopicRef?

    var body: some View {
        // Redrawn every minute so a timed mute's icon goes away when it ends.
        TimelineView(.everyMinute) { _ in list }
            .safeAreaInset(edge: .bottom, spacing: 0) { footer }
            .confirmationDialog("Unsubscribe from “\(topicToRemove.map(store.fullName) ?? "")”?",
                                isPresented: Binding(get: { topicToRemove != nil }, set: { if !$0 { topicToRemove = nil } })) {
                Button("Unsubscribe", role: .destructive) {
                    if let t = topicToRemove { store.removeTopic(t) }
                }
            } message: {
                Text("Its saved notifications will be deleted.")
            }
    }

    private var list: some View {
        let counts = store.topicCounts()
        return List(selection: $store.selection) {
            SidebarRow(title: "All Notifications", symbol: "tray.full", tint: nil,
                       total: store.messages.count, unread: store.unreadCount(in: .all))
                .tag(SidebarItem.all)

            // With more than one server, each gets its own section.
            if store.config.servers.count > 1 {
                ForEach(store.config.servers) { server in
                    let subs = store.config.subscriptions.filter { $0.server == server.id }
                    if !subs.isEmpty {
                        Section(server.label) { rows(subs, counts) }
                    }
                }
            } else {
                Section("Topics") { rows(store.config.subscriptions, counts) }
            }
        }
        .listStyle(.sidebar)
    }

    private func rows(_ subs: [Subscription], _ counts: [TopicRef: (total: Int, unread: Int)]) -> some View {
        ForEach(subs, id: \.ref) { sub in
            let ref = sub.ref
            let c = counts[ref] ?? (0, 0)
            SidebarRow(title: store.displayName(ref), symbol: sub.settings.isMuted() ? "bell.slash" : "number",
                       tint: store.topicColor(ref), total: c.total, unread: c.unread)
                .tag(SidebarItem.topic(ref))
                .help(muteHelp(sub.settings) ?? "")
                .contextMenu {
                    Button("Mark All as Read") { store.markAllRead(in: .topic(ref)) }
                    Button("New Message…") { store.sheet = .compose(topic: ref) }
                    Button("Topic Settings…") { store.sheet = .topicSettings(ref) }
                    Menu("Mute") {
                        ForEach(MuteChoice.timed, id: \.self) { choice in
                            Button(choice.label) { setMute(choice, for: ref) }
                        }
                        Button("Until I Turn It Back On") { setMute(.always, for: ref) }
                        if sub.settings.isMuted() {
                            Divider()
                            Button("Unmute") { setMute(.off, for: ref) }
                        }
                    }
                    Menu("Color") {
                        colorItem("Automatic", hex: nil, ref: ref)
                        Divider()
                        ForEach(TopicColor.palette, id: \.hex) { entry in
                            colorItem(entry.name, hex: entry.hex, ref: ref)
                        }
                    }
                    Divider()
                    Button("Unsubscribe…", role: .destructive) { topicToRemove = ref }
                }
        }
    }

    private func muteHelp(_ settings: TopicSettings) -> String? {
        if settings.muted { return "Muted" }
        guard let until = settings.mutedUntil, settings.isMuted() else { return nil }
        return "Muted until " + Date(timeIntervalSince1970: TimeInterval(until)).formatted(date: .omitted, time: .shortened)
    }

    private func setMute(_ choice: MuteChoice, for ref: TopicRef) {
        var settings = store.config.settings(for: ref)
        choice.apply(to: &settings)
        store.setSettings(settings, for: ref)
    }

    private var selectedTopic: TopicRef? {
        if case .topic(let t) = store.selection { return t }
        return nil
    }

    /// A checkmarked menu entry previewing the color in its own name.
    private func colorItem(_ name: String, hex: String?, ref: TopicRef) -> some View {
        let current = store.config.settings(for: ref).color
        return Toggle(isOn: Binding(get: { current?.uppercased() == hex?.uppercased() },
                                    set: { _ in setColor(hex, for: ref) })) {
            Image(nsImage: TopicColor.menuImage(name, hex: hex ?? TopicColor.automatic(for: ref.topic)))
        }
    }

    private func setColor(_ hex: String?, for ref: TopicRef) {
        var settings = store.config.settings(for: ref)
        settings.color = hex
        store.setSettings(settings, for: ref)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Button { store.sheet = .addTopic } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add Topic")
                Button { topicToRemove = selectedTopic } label: { Image(systemName: "minus") }
                    .accessibilityLabel("Unsubscribe from Topic")
                    .disabled(selectedTopic == nil)
                Spacer()
                ConnectionBadge(store: store)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

/// Mute options, shared by the sidebar menu and the topic settings sheet.
enum MuteChoice: Hashable {
    case off, always
    case hours(Int)

    static let timed: [MuteChoice] = [.hours(1), .hours(8), .hours(24)]

    var label: String {
        switch self {
        case .off: "Off"
        case .always: "Until turned back on"
        case .hours(24): "For 1 day"
        case .hours(1): "For 1 hour"
        case .hours(let h): "For \(h) hours"
        }
    }

    func apply(to settings: inout TopicSettings) {
        switch self {
        case .off:
            settings.muted = false
            settings.mutedUntil = nil
        case .always:
            settings.muted = true
            settings.mutedUntil = nil
        case .hours(let h):
            settings.muted = false
            settings.mutedUntil = Int(Date().timeIntervalSince1970) + h * 3600
        }
    }
}

/// Sidebar entry with a count: unread in an accent pill, otherwise the total in grey.
private struct SidebarRow: View {
    let title: String
    let symbol: String
    let tint: Color?
    let total: Int
    let unread: Int

    var body: some View {
        HStack {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(tint ?? Color.secondary)
                    .fontWeight(tint == nil ? .regular : .bold)
            }
            .scaledFont(.body, weight: unread > 0 ? .semibold : .regular)
            Spacer(minLength: 6)
            if unread > 0 {
                Text("\(unread)")
                    .scaledFont(.caption, weight: .bold)
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(Color.brand, in: Capsule())
            } else if total > 0 {
                Text("\(total)")
                    .scaledFont(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ConnectionBadge: View {
    @ObservedObject var store: Store

    private var color: Color {
        switch store.state {
        case .connected: .clear
        case .connecting: .yellow
        case .failed: .red
        case .idle: .gray
        }
    }

    /// Only shown when something is wrong; a healthy connection needs no indicator.
    var body: some View {
        if store.state != .connected, !store.config.subscriptions.isEmpty {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(store.statusText)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Problems

extension Store {
    func perform(_ action: Problem.Action) {
        switch action {
        case .retry:
            onRetry?()
        case .openSettings:
            sheet = .settings
        case .openNotificationSettings:
            let id = Bundle.main.bundleIdentifier ?? ""
            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
                NSWorkspace.shared.open(url)
            }
        case .reveal(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

private struct ProblemBar: View {
    @ObservedObject var store: Store
    let problem: Problem

    private var color: Color { problem.kind == .historyFailed ? .orange : .red }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(color)
                    .scaledFont(.body)
                VStack(alignment: .leading, spacing: 2) {
                    Text(problem.title).scaledFont(.callout, weight: .semibold)
                    Text(problem.detail)
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                if let action = problem.action {
                    Button(action.title) { store.perform(action) }
                        .controlSize(.small)
                }
                Button { store.dismiss(problem) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(color.opacity(0.14))
            Divider()
        }
    }
}

// MARK: - Message list

private struct MessageList: View {
    @ObservedObject var store: Store
    let scope: SidebarItem

    @State private var selected = Set<String>()
    @State private var filter = MessageFilter.all

    private var title: String {
        if case .topic(let ref) = scope { return store.fullName(ref) }
        return "All Notifications"
    }

    var body: some View {
        // Selected messages stay listed even once they no longer match the filter: selecting
        // marks a message read, which would otherwise make it vanish from the Unread view.
        let search = store.searchText
        let items = store.messages(in: scope, matching: search).filter { selected.contains($0.id) || filter.includes($0) }
        let visibleIDs = Set(items.map(\.id))
        let unread = store.unreadCount(in: scope)
        let total = store.messages(in: scope).count

        // The bars are pinned to the top; the list or empty state fills the rest. (As a safe-area
        // inset they'd follow a short empty state into the middle of the window.)
        VStack(spacing: 0) {
            ForEach(store.problems) { ProblemBar(store: store, problem: $0) }
            filterBar
            Group {
                if items.isEmpty {
                    emptyView
                } else {
                    messageList(items)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(title)
        .navigationSubtitle(unread > 0 ? "\(unread) unread" : "\(total) notifications")
        // Only newly selected messages; pruning the selection mustn't undo "Mark as Unread".
        .onChange(of: selected) { old, new in store.setRead(new.subtracting(old), true) }
        .onChange(of: visibleIDs) { _, ids in selected.formIntersection(ids) }  // never act on hidden messages
        .onChange(of: filter) { selected = [] }
        .confirmationDialog("Delete all notifications in “\(title)”?", isPresented: $store.confirmingDeleteAll) {
            Button("Delete All", role: .destructive) {
                store.deleteAll(in: scope)
                selected = []
            }
        } message: {
            Text(store.config.deleteOnServer
                 ? "They'll also be deleted on the server, for everyone subscribed. This can't be undone."
                 : "This can't be undone.")
        }
    }

    private func messageList(_ items: [StoredMessage]) -> some View {
        List(selection: $selected) {
            ForEach(daySections(items), id: \.day) { section in
                Section(dayLabel(section.day)) {
                    ForEach(section.items) { msg in
                        row(msg)
                    }
                }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenu(ids)
        } primaryAction: { ids in
            openLinks(ids)
        }
        .onDeleteCommand {
            store.userDelete(selected)
            selected = []
        }
    }

    private func row(_ msg: StoredMessage) -> some View {
        MessageRow(store: store, message: msg, showTopic: scope == .all, expanded: selected.contains(msg.id)) {
            store.userDelete([msg.id])
            selected.remove(msg.id)
        }
        .tag(msg.id)
    }

    private var filterBar: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $filter) {
                ForEach(MessageFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            .padding(.vertical, 8)
            Divider()
        }
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    @ViewBuilder
    private var emptyView: some View {
        if !store.searchText.isEmpty {
            ContentUnavailableView.search(text: store.searchText)
        } else if filter == .unread {
            ContentUnavailableView("All Caught Up", systemImage: "checkmark.circle",
                                   description: Text("No unread notifications."))
        } else if filter == .important {
            ContentUnavailableView("Nothing Urgent", systemImage: "exclamationmark.2",
                                   description: Text("No high or urgent priority notifications."))
        } else if store.config.subscriptions.isEmpty {
            ContentUnavailableView("No Topics", systemImage: "bell",
                                   description: Text("Add a topic with the + button to start receiving notifications."))
        } else {
            ContentUnavailableView("No Notifications", systemImage: "bell",
                                   description: Text("New messages will appear here."))
        }
    }

    private func daySections(_ items: [StoredMessage]) -> [(day: Date, items: [StoredMessage])] {
        var sections: [(day: Date, items: [StoredMessage])] = []
        let calendar = Calendar.current
        for m in items {
            let day = calendar.startOfDay(for: m.date)
            if sections.last?.day == day {
                sections[sections.count - 1].items.append(m)
            } else {
                sections.append((day, [m]))
            }
        }
        return sections
    }

    private func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let sameYear = calendar.isDate(day, equalTo: .now, toGranularity: .year)
        return day.formatted(sameYear ? .dateTime.weekday(.wide).month(.wide).day()
                                      : .dateTime.month(.wide).day().year())
    }

    @ViewBuilder
    private func contextMenu(_ ids: Set<String>) -> some View {
        let msgs = store.messages.filter { ids.contains($0.id) }
        if !msgs.isEmpty {
            if msgs.contains(where: { !$0.read }) {
                Button("Mark as Read") { store.setRead(ids, true) }
            }
            if msgs.contains(where: \.read) {
                Button("Mark as Unread") { store.setRead(ids, false) }
            }
            if msgs.count == 1, let url = msgs[0].clickURL {
                Divider()
                Button("Open Link") { NSWorkspace.shared.open(url) }
            }
            if msgs.count == 1, store.wasSentHere(msgs[0]) {
                Divider()
                Button("Edit…") { store.sheet = .edit(msgs[0].id) }
            }
            Divider()
            Button("Copy Text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(msgs.map(\.text).joined(separator: "\n\n"), forType: .string)
            }
            Divider()
            Button(msgs.count == 1 ? "Delete" : "Delete \(msgs.count) Notifications", role: .destructive) {
                store.userDelete(ids)
                selected.subtract(ids)
            }
            // With "Delete on server too" off, your own messages can still be deleted for everyone.
            if !store.config.deleteOnServer, msgs.allSatisfy(store.wasSentHere) {
                Button("Delete for Everyone", role: .destructive) {
                    store.userDelete(ids, onServer: true)
                    selected.subtract(ids)
                }
            }
        }
    }

    private func openLinks(_ ids: Set<String>) {
        for m in store.messages where ids.contains(m.id) {
            if let url = m.clickURL { NSWorkspace.shared.open(url) }
        }
    }
}

private struct MessageRow: View {
    let store: Store
    let message: StoredMessage
    let showTopic: Bool
    let expanded: Bool
    let onDelete: () -> Void

    @State private var hovering = false
    @State private var hoveringDelete = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            content
            // Always laid out so rows don't shift; only visible and clickable on hover.
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .scaledFont(.callout, weight: .medium)
                    .foregroundStyle(hoveringDelete ? Color.red : Color.secondary)
                    .frame(width: 26, height: 26)
                    .background(hoveringDelete ? Color.red.opacity(0.15) : Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete")
            .onHover { hoveringDelete = $0 }
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(message.read ? Color.clear : Color.brand)
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            if let icon = message.iconURL, ImageLoader.shared.allowed(icon) {
                RemoteImage(url: icon)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            VStack(alignment: .leading, spacing: 5) {
                header
                if message.hasTitle, !message.text.isEmpty {
                    MessageBody(message: message, lineLimit: expanded ? nil : 4, flatten: false)
                        .scaledFont(.callout)
                        .foregroundStyle(message.read ? Color.secondary : Color.primary.opacity(0.85))
                }
                markdownImages
                attachment
                if !message.visibleActions.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(message.visibleActions.enumerated()), id: \.offset) { _, action in
                            Button {
                                ActionRunner.run(action, for: message, store: store)
                            } label: {
                                Label(action.label, systemImage: ActionRunner.symbol(for: action))
                            }
                            .controlSize(.small)
                        }
                    }
                }
                footer
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let p = priority {
                Label(p.label, systemImage: p.symbol)
                    .scaledFont(.caption2, weight: .bold)
                    .foregroundStyle(p.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(p.color.opacity(0.18), in: Capsule())
            }
            if let title = message.displayTitle {
                Text(title)
                    .scaledFont(.body, weight: message.read ? .regular : .semibold)
                    .lineLimit(1)
            } else {
                MessageBody(message: message, lineLimit: expanded ? nil : 2, flatten: !expanded)
                    .scaledFont(.body, weight: message.read ? .regular : .semibold)
            }
            Spacer(minLength: 8)
            if showTopic {
                let color = store.topicColor(message.ref)
                Text(store.displayName(message.ref))
                    .scaledFont(.caption, weight: .medium)
                    .foregroundStyle(color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(color.opacity(0.15), in: Capsule())
            }
            Text(message.date.formatted(date: .omitted, time: .shortened))
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    /// Images embedded in a Markdown message, under the same host rules as attachments.
    @ViewBuilder
    private var markdownImages: some View {
        let urls = message.isMarkdown ? MessageBody.imageURLs(message.text).filter(ImageLoader.shared.allowed) : []
        ForEach(urls.prefix(3), id: \.self) { url in
            RemoteImage(url: url)
                .frame(maxWidth: 360, maxHeight: expanded ? 360 : 160, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        }
    }

    @ViewBuilder
    private var attachment: some View {
        if let url = message.attachmentLink {
            if message.attachmentIsImage, ImageLoader.shared.allowed(url) {
                RemoteImage(url: url)
                    .frame(maxWidth: 360, maxHeight: expanded ? 360 : 160, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
            }
            Button { NSWorkspace.shared.open(url) } label: {
                Label(attachmentLabel, systemImage: "paperclip")
                    .scaledFont(.caption)
            }
            .buttonStyle(.link)
        } else if let name = message.attachmentName {
            Label("\(name) (expired)", systemImage: "paperclip")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if !message.plainTags.isEmpty || message.clickURL != nil {
            HStack(spacing: 6) {
                ForEach(message.plainTags, id: \.self) { tag in
                    Text(tag)
                        .scaledFont(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                if let url = message.clickURL {
                    Label(Config.mailAddress(url) ?? url.host() ?? "Link",
                          systemImage: Config.mailAddress(url) == nil ? "link" : "envelope")
                        .scaledFont(.caption)
                        .foregroundStyle(Color.brand)
                }
            }
        }
    }

    private var attachmentLabel: String {
        let name = message.attachmentName ?? "Attachment"
        guard let size = message.attachmentSize else { return name }
        return "\(name) · \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))"
    }

    private var priority: (label: String, symbol: String, color: Color)? {
        switch message.priority {
        case 5: ("Urgent", "exclamationmark.3", .red)
        case 4: ("High", "exclamationmark.2", .orange)
        case 2: ("Low", "arrow.down", .gray)
        case ...1: ("Min", "arrow.down.to.line", .gray)
        default: nil  // 3 is ntfy's default; no pill to keep the list calm
        }
    }
}

/// The message text, rendered as Markdown when the publisher flagged it so.
private struct MessageBody: View {
    let message: StoredMessage
    let lineLimit: Int?
    let flatten: Bool  // join lines, for one-line previews

    var body: some View {
        let text = message.displayTitle == nil ? message.displayText : message.text
        let rendered = message.isMarkdown
            ? Self.markdown(text, flatten: flatten)
            : AttributedString(flatten ? text.replacingOccurrences(of: "\n", with: " ") : text)
        return Text(rendered).lineLimit(lineLimit)
    }

    private static func parse(_ s: String) -> AttributedString? {
        try? AttributedString(markdown: s, options: .init(interpretedSyntax: .full,
                                                          failurePolicy: .returnPartiallyParsedIfPossible))
    }

    /// Markdown as Text can show it. Text has no block layout, so headings become bold lines,
    /// list items get bullets or numbers, quotes a bar and code blocks a monospaced font.
    /// Single line breaks are kept (ntfy messages rely on them). Links that aren't http(s) or
    /// mailto are stripped so a message can't trigger other URL schemes.
    static func markdown(_ s: String, flatten: Bool) -> AttributedString {
        guard let parsed = parse(s) else { return AttributedString(s) }
        let lineBreak = flatten ? " " : "\n"
        var out = AttributedString()
        var lastBlock: Int?     // identity of the innermost block of the previous run
        var lastOuter: Int?     // identity of its outermost block

        for run in parsed.runs {
            let blocks = run.presentationIntent?.components ?? []
            if let block = blocks.first?.identity, block != lastBlock {
                if lastBlock != nil {
                    // A blank line between top-level blocks; list items and nested blocks just break.
                    out += AttributedString(blocks.last?.identity != lastOuter && !flatten ? "\n\n" : lineBreak)
                }
                out += prefix(blocks)
                lastBlock = block
                lastOuter = blocks.last?.identity
            }

            var piece = AttributedString(parsed[run.range])
            var inline = run.inlinePresentationIntent ?? []
            if inline.contains(.softBreak) || inline.contains(.lineBreak) {
                piece = AttributedString(lineBreak)
            }
            for component in blocks {
                switch component.kind {
                case .header: inline.insert(.stronglyEmphasized)
                case .codeBlock:
                    inline.insert(.code)
                    var text = String(piece.characters)
                    while text.hasSuffix("\n") { text.removeLast() }
                    if flatten { text = text.replacingOccurrences(of: "\n", with: " ") }
                    piece = AttributedString(text)
                case .blockQuote: piece.foregroundColor = .secondary
                default: break
                }
            }
            piece.inlinePresentationIntent = inline.subtracting([.softBreak, .lineBreak])
            // Images can't be shown inline; their alt text links to the image (shown below the text).
            if let image = run.imageURL {
                if piece.characters.isEmpty { piece = AttributedString("image") }
                piece.link = image
            }
            out += piece
        }
        return secureLinks(out)
    }

    /// Bullets, numbers and quote bars for the block a run starts.
    private static func prefix(_ blocks: [PresentationIntent.IntentType]) -> AttributedString {
        var parts: [String] = []
        var depth = 0
        var marked = false  // only the innermost list item gets a bullet; outer ones indent
        for (i, component) in blocks.enumerated() {
            switch component.kind {
            case .listItem(let ordinal) where !marked:
                marked = true
                let ordered = blocks.dropFirst(i + 1).first.map { if case .orderedList = $0.kind { true } else { false } } ?? false
                parts.insert(ordered ? "\(ordinal). " : "• ", at: 0)
            case .orderedList, .unorderedList:
                depth += 1
            case .blockQuote:
                parts.insert("▎ ", at: 0)
            default:
                break
            }
        }
        let text = String(repeating: "    ", count: max(depth - 1, 0)) + parts.joined()
        if text.isEmpty { return AttributedString() }
        var a = AttributedString(text)
        a.foregroundColor = .secondary
        return a
    }

    /// Strips links that aren't http(s) or mailto, and shows the real target of a link whose
    /// text reads as a different one.
    private static func secureLinks(_ input: AttributedString) -> AttributedString {
        var a = input
        // Coalesced by link, so a link with mixed formatting is handled once. Walk backwards so
        // inserting text doesn't shift ranges that are still to be processed.
        for (link, range) in a.runs[\.link].reversed() {
            guard let link else { continue }
            guard let url = Config.linkURL(link.absoluteString) else {
                a[range].link = nil
                continue
            }
            // "[https://paypal.com](https://evil.example)" would show one host and open another,
            // so show the real target unless the visible text is itself exactly that target.
            let visible = String(a[range].characters)
            let target: String
            let shown: String?
            if let address = Config.mailAddress(url) {
                target = address.lowercased()
                shown = visible.trimmingCharacters(in: .whitespaces).lowercased()
            } else if let host = url.host() {
                target = host.lowercased()
                shown = visibleHost(visible)
            } else {
                a[range].link = nil
                continue
            }
            if shown != target {
                var suffix = AttributedString(" (\(target))")
                suffix.foregroundColor = .secondary
                a.insert(suffix, at: range.upperBound)
            }
        }
        return a
    }

    /// The host the text itself reads as, if it's a bare link ("example.com/x", "https://example.com").
    private static func visibleHost(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.contains(" ") else { return nil }
        let url = URL(string: t.contains("://") ? t : "https://" + t)
        guard url?.user == nil else { return nil }
        return url?.host()?.lowercased()
    }

    /// http(s) images embedded with ![alt](url).
    static func imageURLs(_ s: String) -> [URL] {
        guard let parsed = parse(s) else { return [] }
        var seen = Set<URL>()
        return parsed.runs.compactMap { run in
            guard let url = run.imageURL.flatMap({ Config.webURL($0.absoluteString) }), seen.insert(url).inserted else { return nil }
            return url
        }
    }
}
