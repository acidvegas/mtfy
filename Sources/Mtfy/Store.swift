import Foundation
import UserNotifications

struct StoredMessage: Codable, Identifiable, Hashable {
    let id: String
    let time: Int
    let topic: String
    let title: String?
    let message: String
    let priority: Int
    let tags: [String]
    let click: String?
    let attachmentName: String?
    var read: Bool
    // Added after the first release, so optional for messages saved by older versions.
    let sequenceID: String?
    let actions: [NtfyAction]?
    let attachmentURL: String?
    let attachmentType: String?
    let attachmentSize: Int?
    let attachmentExpires: Int?
    let icon: String?
    let markdown: Bool?
    let server: String?  // nil: saved before multiple servers, so the "default" server

    init(_ m: NtfyMessage, server: String, read: Bool) {
        id = m.id
        time = m.time
        topic = m.topic
        // The server allows 1 KB titles and 512 bytes of tags, so these caps only stop a
        // misbehaving server.
        title = m.title.map { String($0.prefix(1024)) }
        message = String((m.message ?? "").prefix(4096))
        priority = m.priority ?? 3
        tags = Array((m.tags ?? []).prefix(256))
        click = m.click
        attachmentName = m.attachment?.name
        self.read = read
        sequenceID = m.sequenceID
        actions = m.actions.map { Array($0.prefix(3)) }
        attachmentURL = m.attachment?.url
        attachmentType = m.attachment?.type
        attachmentSize = m.attachment?.size
        attachmentExpires = m.attachment?.expires
        icon = m.icon
        markdown = m.markdown
        self.server = server
    }

    var serverID: String { server ?? ServerConfig.legacyID }
    var ref: TopicRef { TopicRef(server: serverID, topic: topic) }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(time)) }
    var sequence: String { sequenceID ?? id }
    /// Updates to a message reuse its sequence, so the system notification is replaced in place.
    var notificationID: String {
        serverID == ServerConfig.legacyID ? "\(topic)/\(sequence)" : "\(serverID)/\(topic)/\(sequence)"
    }
    var clickURL: URL? { click.flatMap(Config.linkURL) }
    var iconURL: URL? { icon.flatMap(Config.webURL) }
    var isMarkdown: Bool { markdown == true }

    var text: String {
        if !message.isEmpty { return message }
        return attachmentName.map { "Attachment: \($0)" } ?? ""
    }

    /// Like ntfy, tags that are emoji shortcodes ("warning", "green_circle") are shown as emoji
    /// in front of the title, or the message if there is no title. Other tags stay as tags.
    var emojiPrefix: String {
        let e = tags.compactMap { Emoji.byTag[$0] }.joined()
        return e.isEmpty ? "" : e + " "
    }
    var plainTags: [String] { tags.filter { Emoji.byTag[$0] == nil } }
    var hasTitle: Bool { !(title ?? "").isEmpty }
    var displayTitle: String? { hasTitle ? emojiPrefix + title! : nil }
    var displayText: String { hasTitle ? text : emojiPrefix + text }

    /// Action buttons this client can perform (broadcast is Android-only).
    var visibleActions: [NtfyAction] {
        (actions ?? []).filter { ["view", "http", "copy"].contains($0.action) && !$0.label.isEmpty }
    }

    var attachmentLink: URL? {
        guard let url = attachmentURL.flatMap(Config.webURL) else { return nil }
        if let expires = attachmentExpires, TimeInterval(expires) < Date().timeIntervalSince1970 { return nil }
        return url
    }

    var attachmentIsImage: Bool {
        if let type = attachmentType { return type.hasPrefix("image/") }
        let ext = (attachmentName ?? attachmentURL ?? "").split(separator: ".").last?.lowercased() ?? ""
        return ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(ext)
    }
}

enum SidebarItem: Hashable {
    case all
    case topic(TopicRef)
}

enum MessageFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case unread = "Unread"
    case important = "High Priority"
    var id: Self { self }

    func includes(_ m: StoredMessage) -> Bool {
        switch self {
        case .all: true
        case .unread: !m.read
        case .important: m.priority >= 4
        }
    }
}

enum ActiveSheet: Identifiable, Hashable {
    case settings
    case addTopic
    case compose(topic: TopicRef?)
    case edit(String)  // message ID
    case topicSettings(TopicRef)
    case scheduled

    var id: Self { self }
}

/// App state shared by the windows, the tray menu and the subscribers.
@MainActor
final class Store: ObservableObject {
    @Published private(set) var config: Config
    @Published private(set) var messages: [StoredMessage] = []  // newest first
    @Published var states: [String: Subscriber.State] = [:]  // by server ID; only servers with topics
    @Published var selection: SidebarItem? = .all
    @Published var sheet: ActiveSheet?
    @Published var searchText = ""             // from the toolbar's search field
    @Published var confirmingDeleteAll = false  // set by the toolbar's Delete All button
    @Published var paused = UserDefaults.standard.bool(forKey: "paused") {
        didSet { UserDefaults.standard.set(paused, forKey: "paused") }
    }
    @Published private(set) var textScale = UserDefaults.standard.object(forKey: "textScale") as? Double ?? 1 {
        didSet { UserDefaults.standard.set(textScale, forKey: "textScale") }
    }

    var onTopicsChanged: (() -> Void)?
    var onTopicAdded: ((TopicRef) -> Void)?
    var publish: ((TopicRef, PublishRequest, URL?) async throws -> Void)?  // URL: a file to upload
    /// Messages on every subscribed topic whose scheduled delivery is still pending.
    var fetchScheduled: (() async -> (messages: [(ref: TopicRef, message: NtfyMessage)], errors: [String]))?
    var cancelScheduled: ((TopicRef, String) async throws -> Void)?
    var deleteOnServer: (([(ref: TopicRef, sequence: String)]) -> Void)?
    var onProblem: ((Problem) -> Void)?
    var onRetry: (() -> Void)?
    var onSaved: (() -> Void)?
    /// Saves a server with any newly typed secret and header values; returns an error message.
    var onSaveServer: ((ServerConfig, String?, [String: String]) -> String?)?
    var onRemoveServer: ((String) -> Void)?

    // Problems and diagnostics
    @Published private(set) var problems: [Problem] = []
    @Published var lastConnected: Date?
    @Published var lastError: String?
    @Published var notificationStatus = "Unknown"
    @Published var serverVersions: [String: String] = [:]  // by server ID; only known for admin logins
    @Published var latestNtfy: String?                     // newest ntfy release on GitHub

    /// The newer ntfy release, if this server is known to run an older one.
    func availableUpdate(_ server: String) -> String? {
        guard let running = serverVersions[server], let latest = latestNtfy,
              Net.isNewer(latest, than: running) else { return nil }
        return latest
    }
    private var dismissed = Set<String>()  // Problem IDs

    private static let perTopicLimit = 500
    private let fileURL: URL
    /// Saved messages whose topic isn't subscribed (e.g. after settings were lost). Kept on disk,
    /// never shown, and restored if the topic is added again. Unsubscribing deletes for real.
    private var orphaned: [StoredMessage] = []
    private var deletedURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("deleted.json") }
    private var saveTask: Task<Void, Never>?
    private var canSave = true

    nonisolated static var messagesFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "local.mtfy", isDirectory: true)
            .appendingPathComponent("messages.json")
    }

    init() {
        fileURL = Self.messagesFileURL
        let (config, configError) = Config.load()
        self.config = config
        if configError != nil {
            problems.append(Problem(kind: .settingsUnreadable, title: "Couldn't read your settings",
                                    detail: "Defaults are in use and the old settings were backed up. Saved notifications are kept and come back when you re-add their topics.",
                                    action: .openSettings))
        }
        loadMessages()
        loadDeleted()
        prune()
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
                self?.prune()
            }
        }
    }

    private func loadMessages() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let saved = try JSONDecoder().decode([StoredMessage].self, from: Data(contentsOf: fileURL))
            messages = saved.filter { config.isSubscribed($0.ref) }
            orphaned = saved.filter { !config.isSubscribed($0.ref) }
            Log.storage.info("Loaded \(self.messages.count) saved notifications")
        } catch {
            // Never overwrite an unreadable history with an empty one: move it aside first.
            Log.storage.error("Couldn't read saved notifications: \(error.localizedDescription, privacy: .public)")
            let backup = fileURL.deletingLastPathComponent()
                .appendingPathComponent("messages-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            var problem = Problem(kind: .loadFailed, title: "Couldn't read saved notifications",
                                  detail: "The file was moved to \(backup.lastPathComponent) and history starts empty.",
                                  action: .reveal(backup))
            do {
                try FileManager.default.moveItem(at: fileURL, to: backup)
            } catch {
                canSave = false
                problem.detail = "It couldn't be backed up either, so saving is turned off to avoid losing it."
                problem.action = .reveal(fileURL)
            }
            problems.append(problem)
        }
    }

    // MARK: Problems

    /// Shows a problem; it's only announced (desktop alert) when it first appears.
    func report(_ problem: Problem) {
        guard !dismissed.contains(problem.id) else { return }
        if let i = problems.firstIndex(where: { $0.id == problem.id }) {
            problems[i] = problem
        } else {
            problems.append(problem)
            onProblem?(problem)
        }
    }

    /// The problem went away: clear it, and allow it to be shown again if it comes back.
    /// Without a server, clears it for every server.
    func resolve(_ kind: Problem.Kind, server: String? = nil) {
        let matches = { (p: Problem) in p.kind == kind && (server == nil || p.server == server) }
        problems.removeAll(where: matches)
        dismissed = dismissed.filter { id in
            !(id.hasPrefix("\(kind.rawValue)|") && (server == nil || id == "\(kind.rawValue)|\(server!)"))
        }
    }

    /// The user hid it: keep it hidden until it's resolved.
    func dismiss(_ problem: Problem) {
        problems.removeAll { $0.id == problem.id }
        dismissed.insert(problem.id)
    }

    func diagnostics() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))"
        let connected = lastConnected.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "never"
        let servers = config.servers.map { s in
            let state = states[s.id].map(Self.describe) ?? "no topics"
            var extras: [String] = []
            if s.isInsecure { extras.append("http") }
            if s.pinnedCertificate != nil { extras.append("pinned certificate") }
            if !s.headerNames.isEmpty { extras.append("\(s.headerNames.count) custom headers") }
            if let v = serverVersions[s.id] { extras.append("ntfy \(v)") }
            let suffix = extras.isEmpty ? "" : ", " + extras.joined(separator: ", ")
            return "  \(s.label): \(s.auth.label)\(suffix), \(config.topics(on: s.id).count) topics, \(state)"
        }
        return """
        Mtfy \(version)
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        Servers:
        \(servers.joined(separator: "\n"))
        Status: \(statusText)
        Last connected: \(connected)
        Last error: \(lastError ?? "none")
        Saved notifications: \(messages.count) (\(unreadCount(in: .all)) unread)
        Notification permission: \(notificationStatus)
        Paused: \(paused ? "yes" : "no")
        Problems: \(problems.isEmpty ? "none" : problems.map(\.kind.rawValue).joined(separator: ", "))
        """
    }

    // MARK: Queries

    func messages(in scope: SidebarItem, matching search: String = "") -> [StoredMessage] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return messages.filter { m in
            if case .topic(let ref) = scope, m.ref != ref { return false }
            guard !q.isEmpty else { return true }
            return m.text.localizedCaseInsensitiveContains(q)
                || (m.title?.localizedCaseInsensitiveContains(q) ?? false)
                || m.tags.contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    func unreadCount(in scope: SidebarItem) -> Int {
        messages.reduce(0) { n, m in
            if case .topic(let ref) = scope, m.ref != ref { return n }
            return m.read ? n : n + 1
        }
    }

    /// Total and unread counts per topic, computed in one pass.
    func topicCounts() -> [TopicRef: (total: Int, unread: Int)] {
        var counts: [TopicRef: (total: Int, unread: Int)] = [:]
        for m in messages {
            counts[m.ref, default: (0, 0)].total += 1
            if !m.read { counts[m.ref, default: (0, 0)].unread += 1 }
        }
        return counts
    }

    func displayName(_ ref: TopicRef) -> String {
        let name = config.settings(for: ref).displayName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? ref.topic : name
    }

    /// The display name, plus the server when there's more than one and it isn't renamed.
    func fullName(_ ref: TopicRef) -> String {
        let name = displayName(ref)
        guard config.servers.count > 1, name == ref.topic, let server = config.server(ref.server) else { return name }
        return "\(name) (\(server.label))"
    }

    func shouldNotify(_ m: StoredMessage) -> Bool {
        let s = config.settings(for: m.ref)
        return !paused && !s.isMuted() && m.priority >= s.minPriority
    }

    /// All servers together: failed if any failed, connected only if all are.
    var state: Subscriber.State {
        let all = Array(states.values)
        if let failed = all.first(where: { if case .failed = $0 { true } else { false } }) { return failed }
        if all.contains(.connecting) { return .connecting }
        if all.isEmpty || all.contains(.idle) { return .idle }
        return .connected
    }

    var statusText: String {
        if config.subscriptions.isEmpty { return "No topics" }
        let label = { (id: String) in self.config.server(id)?.label ?? "server" }
        switch state {
        case .idle: return "Not connected"
        case .connecting: return "Connecting…"
        case .connected:
            return states.count == 1 ? "Connected to \(label(states.keys.first!))" : "Connected to \(states.count) servers"
        case .failed(let reason):
            guard states.count > 1,
                  let id = states.first(where: { if case .failed = $0.value { true } else { false } })?.key
            else { return reason }
            return "\(label(id)): \(reason)"
        }
    }

    private static func describe(_ state: Subscriber.State) -> String {
        switch state {
        case .idle: "not connected"
        case .connecting: "connecting"
        case .connected: "connected"
        case .failed(let reason): reason
        }
    }

    // MARK: Messages

    /// Applies one stream event. Returns the stored message if it was newly added; whether to
    /// notify for it is the caller's decision.
    @discardableResult
    func apply(_ event: NtfyMessage, server: String, read: Bool = false) -> StoredMessage? {
        apply([event], server: server, read: read).first
    }

    /// Applies events in order on a working copy and publishes the result once, so a history
    /// replay of hundreds of events costs one UI update instead of hundreds. Returns the
    /// messages that were newly added.
    @discardableResult
    func apply(_ events: [NtfyMessage], server: String, read: Bool) -> [StoredMessage] {
        var list = messages
        var ids = Set(list.map(\.id))
        var added: [StoredMessage] = []
        var removed = Set<String>()
        var cleared = Set<String>()
        let topics = Set(config.topics(on: server))

        for event in events where topics.contains(event.topic) {
            let ref = TopicRef(server: server, topic: event.topic)
            let matching = list.indices.filter { list[$0].ref == ref && list[$0].sequence == event.sequence }
            switch event.event {
            case "message":
                guard !ids.contains(event.id), deleted[event.id] == nil else { continue }
                if let cutoff = retentionCutoff(for: ref), event.time < cutoff { continue }
                // An update only replaces older versions; a stale update arriving late is ignored.
                if let newest = matching.first, list[newest].time > event.time { continue }
                // A full topic only takes messages newer than its oldest one.
                let others = list.indices.filter { list[$0].ref == ref && !matching.contains($0) }
                if others.count >= Self.perTopicLimit, let oldest = others.last, event.time < list[oldest].time { continue }

                let replaced = Set(matching.map { list[$0].id })
                list.removeAll { replaced.contains($0.id) }
                ids.subtract(replaced)
                removed.formUnion(replaced)

                let stored = StoredMessage(event, server: server, read: read)
                list.insert(stored, at: list.firstIndex { $0.time <= stored.time } ?? list.endIndex)
                ids.insert(stored.id)
                added.append(stored)

                var count = 0
                list.removeAll { m in
                    guard m.ref == ref else { return false }
                    count += 1
                    guard count > Self.perTopicLimit else { return false }
                    ids.remove(m.id)
                    removed.insert(m.id)
                    return true
                }
            case "message_clear":
                for i in matching where !list[i].read {
                    list[i].read = true
                    cleared.insert(list[i].id)
                }
            case "message_delete":
                let gone = Set(matching.map { list[$0].id })
                list.removeAll { gone.contains($0.id) }
                ids.subtract(gone)
                removed.formUnion(gone)
            default:
                break
            }
        }

        // Report each added message as it ended up: gone if replaced or trimmed later in the batch,
        // read if cleared later in it.
        added = added.compactMap { a in list.first { $0.id == a.id } }
        guard !added.isEmpty || !removed.isEmpty || !cleared.isEmpty else { return [] }
        removeDelivered(removed.union(cleared))
        remember(deleted: removed)
        messages = list
        scheduleSave()
        return added
    }

    func setRead(_ ids: Set<String>, _ read: Bool) {
        var changed = false
        for i in messages.indices where ids.contains(messages[i].id) && messages[i].read != read {
            messages[i].read = read
            changed = true
        }
        guard changed else { return }
        if read { removeDelivered(ids) }
        scheduleSave()
    }

    /// remember: record the IDs so the same messages can never be added back (by a history
    /// load or a stream replay). Off for unsubscribing, so re-subscribing restores history.
    func delete(_ ids: Set<String>, remember: Bool = true) {
        guard !ids.isEmpty else { return }
        removeDelivered(ids)
        if remember { self.remember(deleted: ids) }
        messages.removeAll { ids.contains($0.id) }
        scheduleSave()
    }

    // MARK: Deleted message IDs

    /// ID → when it was deleted. Kept 30 days, well past how long servers cache messages
    /// (12 hours by default), after which a message can't be delivered again anyway.
    private var deleted: [String: Int] = [:]
    private static let deletedTTL = 30 * 86_400

    private func remember(deleted ids: Set<String>) {
        let now = Int(Date().timeIntervalSince1970)
        for id in ids { deleted[id] = now }
    }

    private func loadDeleted() {
        guard let data = try? Data(contentsOf: deletedURL),
              let saved = try? JSONDecoder().decode([String: Int].self, from: data) else { return }
        deleted = saved  // expired entries are dropped by prune()
    }

    /// A delete the user asked for: removed here, and on the server too if that's enabled
    /// (or asked for with onServer).
    func userDelete(_ ids: Set<String>, onServer: Bool? = nil) {
        let targets = messages.filter { ids.contains($0.id) }.map { (ref: $0.ref, sequence: $0.sequence) }
        delete(ids)
        if onServer ?? config.deleteOnServer, !targets.isEmpty { deleteOnServer?(targets) }
    }

    // MARK: Sent messages

    /// Messages published from this Mac, as "server/topic/sequence", so they can be edited.
    /// Updates keep the sequence, so an edited message stays editable. Newest last.
    private var sent = UserDefaults.standard.stringArray(forKey: "sentSequences") ?? []

    private static func sentKey(_ ref: TopicRef, _ sequence: String) -> String {
        "\(ref.server)/\(ref.topic)/\(sequence)"
    }

    func recordSent(_ ref: TopicRef, sequence: String) {
        let key = Self.sentKey(ref, sequence)
        sent.removeAll { $0 == key }
        sent.append(key)
        if sent.count > 1000 { sent.removeFirst(sent.count - 1000) }
        UserDefaults.standard.set(sent, forKey: "sentSequences")
        objectWillChange.send()
    }

    func wasSentHere(_ m: StoredMessage) -> Bool { sent.contains(Self.sentKey(m.ref, m.sequence)) }

    func markAllRead(in scope: SidebarItem) {
        setRead(Set(messages(in: scope).filter { !$0.read }.map(\.id)), true)
    }

    func deleteAll(in scope: SidebarItem) {
        userDelete(Set(messages(in: scope).map(\.id)))
    }

    /// Clears the delivered system notifications for these messages.
    private func removeDelivered(_ ids: Set<String>) {
        // Older versions used the message ID as the notification identifier.
        let identifiers = messages.filter { ids.contains($0.id) }.flatMap { [$0.notificationID, $0.id] }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    /// Messages older than this are removed: the topic's own setting, else the global one.
    private func retentionCutoff(for ref: TopicRef?) -> Int? {
        let days = ref.flatMap { config.settings(for: $0).retentionDays } ?? config.retentionDays
        guard days > 0 else { return nil }
        return Int(Date().timeIntervalSince1970) - days * 86_400
    }

    /// Runs at launch, hourly and when retention settings change. Also drops expired deleted
    /// IDs, so long-running sessions don't accumulate them.
    private func prune() {
        let deletedCutoff = Int(Date().timeIntervalSince1970) - Self.deletedTTL
        deleted = deleted.filter { $0.value >= deletedCutoff }
        if let cutoff = retentionCutoff(for: nil) { orphaned.removeAll { $0.time < cutoff } }
        var cutoffs: [TopicRef: Int?] = [:]
        let old = messages.filter { m in
            let cutoff = cutoffs[m.ref] ?? retentionCutoff(for: m.ref)
            cutoffs[m.ref] = cutoff
            return cutoff.map { m.time < $0 } ?? false
        }
        delete(Set(old.map(\.id)))
    }

    // MARK: Topics & settings

    /// Returns an error message, or nil on success.
    func addTopic(_ raw: String, server: String) -> String? {
        let topic = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Config.isValidTopic(topic) else {
            return "Use 1–64 letters, digits, - or _."
        }
        guard config.server(server) != nil else { return "Choose a server." }
        let ref = TopicRef(server: server, topic: topic)
        guard !config.isSubscribed(ref) else { return "Already subscribed." }
        config.subscriptions.append(Subscription(server: server, topic: topic))
        config.save()
        let restored = orphaned.filter { $0.ref == ref }
        if !restored.isEmpty {
            orphaned.removeAll { $0.ref == ref }
            messages = (messages + restored).sorted { $0.time > $1.time }
        }
        selection = .topic(ref)
        onTopicsChanged?()
        onTopicAdded?(ref)
        return nil
    }

    func removeTopic(_ ref: TopicRef) {
        delete(Set(messages.filter { $0.ref == ref }.map(\.id)), remember: false)
        config.subscriptions.removeAll { $0.ref == ref }
        config.save()
        if selection == .topic(ref) { selection = .all }
        onTopicsChanged?()
    }

    func setSettings(_ settings: TopicSettings, for ref: TopicRef) {
        guard let i = config.subscriptions.firstIndex(where: { $0.ref == ref }) else { return }
        config.subscriptions[i].settings = settings
        config.save()
        prune()  // in case its retention changed
    }

    func setRetention(days: Int) {
        config.retentionDays = days
        config.save()
        prune()
    }

    func setDeleteOnServer(_ on: Bool) {
        config.deleteOnServer = on
        config.save()
    }

    func setLoadExternalImages(_ on: Bool) {
        config.loadExternalImages = on
        config.save()
    }

    /// Steps the main window's text size; 0 resets it.
    func zoom(_ step: Int) {
        let scale = step == 0 ? 1 : textScale + Double(step) * 0.1
        textScale = (min(max(scale, 0.8), 2.0) * 10).rounded() / 10
    }

    /// Adds the server, or replaces the one with the same ID.
    func saveServer(_ server: ServerConfig) {
        if let i = config.servers.firstIndex(where: { $0.id == server.id }) {
            config.servers[i] = server
        } else {
            config.servers.append(server)
        }
        config.save()
    }

    /// Removes the server with its topics and their saved notifications.
    func removeServer(_ id: String) {
        delete(Set(messages.filter { $0.serverID == id }.map(\.id)), remember: false)
        orphaned.removeAll { $0.serverID == id }
        config.subscriptions.removeAll { $0.server == id }
        config.servers.removeAll { $0.id == id }
        config.save()
        if case .topic(let ref) = selection, ref.server == id { selection = .all }
        scheduleSave()
        onTopicsChanged?()
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard canSave else { return }
        do {
            let fm = FileManager.default
            let dir = fileURL.deletingLastPathComponent()
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // The atomic write's temporary file starts out world-readable; a private folder covers it.
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try JSONEncoder().encode(messages + orphaned).write(to: fileURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            try JSONEncoder().encode(deleted).write(to: deletedURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: deletedURL.path)
            resolve(.saveFailed)
            onSaved?()
        } catch {
            Log.storage.error("Couldn't save notifications: \(error.localizedDescription, privacy: .public)")
            report(Problem(kind: .saveFailed, title: "Couldn't save notifications",
                           detail: error.localizedDescription, action: .reveal(fileURL.deletingLastPathComponent())))
        }
    }
}
