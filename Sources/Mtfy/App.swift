import AppKit
import Combine
import Network
import ServiceManagement
import SwiftUI
import UserNotifications

@main
@MainActor
enum Main {
    static let delegate = AppDelegate()

    static func main() {
        if CLI.isCommand(CommandLine.arguments) {
            Task { exit(await CLI.run(Array(CommandLine.arguments.dropFirst()))) }
            CFRunLoopRun()  // serves the main queue and the replies from the app
            return
        }
        let app = NSApplication.shared
        app.appearance = NSAppearance(named: .darkAqua)
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate,
                         NSMenuItemValidation, NSToolbarDelegate, NSToolbarItemValidation,
                         UNUserNotificationCenterDelegate {
    private let store = Store()
    private var statusItem: NSStatusItem!
    private var mainWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private let pathMonitor = NWPathMonitor()
    private var networkUp = true
    private var networkInterfaces: [String]?  // nil until the first path update

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([Self.baseCategory])

        store.onProblem = { [weak self] in self?.announce($0) }
        store.onRetry = { [weak self] in self?.connect() }
        store.onTopicsChanged = { [weak self] in
            self?.connect()
            self?.updateHistoryProblem()
        }
        store.onTopicAdded = { [weak self] in self?.fetchHistory($0) }
        store.publish = { [weak self] in try await self?.publish($0, $1, file: $2) }
        store.fetchScheduled = { [weak self] in await self?.fetchScheduled() ?? ([], []) }
        store.cancelScheduled = { [weak self] ref, sequence in
            guard let endpoint = await self?.endpoint(ref.server) else { throw NtfyError.badResponse }
            try await Net.delete(endpoint, topic: ref.topic, sequence: sequence)
        }
        store.deleteOnServer = { [weak self] in self?.deleteOnServer($0) }
        store.onSaved = { [weak self] in self?.subscribers.values.forEach { $0.persist() } }
        store.onSaveServer = { [weak self] server, secret, headers in
            // applyServer returns nil on success, so don't use `??` on its result.
            guard let self else { return "Mtfy is quitting; settings weren't saved." }
            return self.applyServer(server, secret: secret, headers: headers)
        }
        store.onRemoveServer = { [weak self] in self?.removeServer($0) }
        ImageLoader.shared.store = store
        ImageLoader.shared.endpoint = { [weak self] in await self?.endpoint($0) }

        store.$messages.map { _ in () }
            .merge(with: store.$states.map { _ in () }, store.$paused.map { _ in () },
                   store.$problems.map { _ in () })
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)  // history replays change these in bursts
            .sink { [weak self] in self?.updateStatusItem() }
            .store(in: &cancellables)
        store.$paused
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updatePauseItem() }
            .store(in: &cancellables)

        enableLoginItemOnFirstRun()
        observeSystemEvents()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(cliRequest(_:)), name: CLI.requestName, object: nil,
            suspensionBehavior: .deliverImmediately)
        Task {
            while !Task.isCancelled {
                await checkServerVersions()
                try? await Task.sleep(for: .seconds(86_400))
            }
        }
        checkNotificationPermission()
        store.problems.forEach(announce)  // problems found while loading, before this was wired up
        connect()
        for sub in store.config.subscriptions where !historyLoaded.contains(historyKey(sub.ref)) {
            fetchHistory(sub.ref)
        }

        if store.config.subscriptions.isEmpty { showMain() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // The user may have just changed notification permissions in System Settings.
        checkNotificationPermission()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.saveNow()  // also persists the stream positions, via onSaved
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMain()
        return false
    }

    // MARK: Connection

    private var subscribers: [String: Subscriber] = [:]  // by server ID
    private var secretTasks: [String: Task<(credential: String?, headers: [String: String]), Never>] = [:]

    private func subscriber(for server: String) -> Subscriber {
        if let sub = subscribers[server] { return sub }
        let sub = Subscriber(server: server)
        sub.onState = { [weak self] in self?.connectionChanged(server, $0) }
        sub.onError = { [weak self] in self?.connectionFailed(server, $0) }
        sub.onEvent = { [weak self] in self?.handle($0, server: server) }
        subscribers[server] = sub
        return sub
    }

    /// How to reach a server. Its secrets are read once, off the main thread, since the Keychain
    /// may show an access prompt. Concurrent callers share the same read.
    private func endpoint(_ id: String) async -> Endpoint? {
        guard let server = store.config.server(id), let base = server.baseURL else { return nil }
        guard server.auth != .none || !server.headerNames.isEmpty else { return Endpoint(base: base) }
        let task = secretTasks[id] ?? Task.detached { Secrets.load(server) }
        secretTasks[id] = task
        let secrets = await task.value
        if server.auth != .none, secrets.credential == nil { secretTasks[id] = nil }  // denied or missing: try again next time
        return Endpoint(base: base,
                        authorization: Config.authorization(server.auth, username: server.username, secret: secrets.credential),
                        headers: secrets.headers)
    }

    private var connectGeneration = 0

    /// (Re)connects every server that has topics.
    private func connect() {
        connectGeneration += 1
        let generation = connectGeneration
        let config = store.config
        Net.setPins(config.servers)
        failingSince = [:]  // a fresh attempt gets the full grace period again
        for (id, sub) in subscribers where config.topics(on: id).isEmpty {
            sub.stop()
            subscribers[id] = nil
        }
        store.states = store.states.filter { !config.topics(on: $0.key).isEmpty }
        for kind in [Problem.Kind.disconnected, .authFailed, .missingCredentials] {
            for p in store.problems where p.kind == kind && config.topics(on: p.server ?? "").isEmpty {
                store.resolve(kind, server: p.server)
            }
        }

        for server in config.servers {
            let topics = config.topics(on: server.id)
            guard !topics.isEmpty else { continue }
            let sub = subscriber(for: server.id)
            sub.stop()
            guard server.baseURL != nil else {
                store.states[server.id] = .failed("Invalid server URL")
                continue
            }
            store.states[server.id] = .connecting
            Task {
                let endpoint = await endpoint(server.id)
                guard generation == connectGeneration, let endpoint else { return }  // superseded by a newer connect()
                if server.auth != .none, endpoint.authorization == nil {
                    store.states[server.id] = .failed("Missing credentials")
                    store.report(Problem(kind: .missingCredentials, server: server.id,
                                         title: "No saved login for \(server.label)",
                                         detail: "Enter your access token or password in Settings to connect.",
                                         action: .openSettings))
                    return
                }
                store.resolve(.missingCredentials, server: server.id)
                sub.start(endpoint, topics: topics)
            }
        }
    }

    /// Topics whose server history has been loaded, so it's fetched once per topic rather than
    /// on every launch (read state of re-fetched messages would otherwise be reset).
    private var historyLoaded = Set(UserDefaults.standard.stringArray(forKey: "historyLoaded") ?? []) {
        didSet { UserDefaults.standard.set(Array(historyLoaded), forKey: "historyLoaded") }
    }
    private var historyFailures = [TopicRef: String]()  // topic → error
    private var historyGenerations = [String: Int]()  // bumped on a server URL change, so late results from the old URL are dropped

    /// Topics of the server from the single-server versions keep their saved keys (the bare name).
    private func historyKey(_ ref: TopicRef) -> String {
        ref.server == ServerConfig.legacyID ? ref.topic : "\(ref.server)/\(ref.topic)"
    }

    /// Loads the server's cached messages for a newly added topic, without notifying.
    private func fetchHistory(_ ref: TopicRef) {
        guard store.config.server(ref.server)?.baseURL != nil else { return }
        let generation = historyGenerations[ref.server, default: 0]
        Task {
            guard let endpoint = await endpoint(ref.server) else { return }
            do {
                let msgs = try await Net.history(endpoint, topic: ref.topic)
                guard generation == historyGenerations[ref.server, default: 0] else { return }
                subscriber(for: ref.server).markSeen(msgs.map(\.id))
                store.apply(msgs, server: ref.server, read: true)
                historyLoaded.insert(historyKey(ref))
                historyFailures[ref] = nil
            } catch {
                guard generation == historyGenerations[ref.server, default: 0] else { return }
                Log.network.error("History for a topic failed: \(NtfyError.describe(error), privacy: .public)")
                historyFailures[ref] = NtfyError.describe(error)
            }
            updateHistoryProblem()
        }
    }

    private func updateHistoryProblem() {
        historyFailures = historyFailures.filter { store.config.isSubscribed($0.key) }
        if historyFailures.isEmpty {
            store.resolve(.historyFailed)
        } else {
            let names = historyFailures.keys.map(store.fullName).sorted().joined(separator: ", ")
            store.report(Problem(kind: .historyFailed, title: "Couldn't load past messages for \(names)",
                                 detail: Set(historyFailures.values).sorted().joined(separator: "; ") + ". Retrying when connected.",
                                 action: .retry))
        }
    }

    /// Sends deletes one at a time (a big "Delete All" shouldn't burst into the server's rate
    /// limit) and reports failures once. The local copies are already gone either way.
    private func deleteOnServer(_ targets: [(ref: TopicRef, sequence: String)]) {
        Task {
            var failed = 0
            var lastError: Error?
            for (server, group) in Dictionary(grouping: targets, by: \.ref.server) {
                guard let endpoint = await endpoint(server) else { continue }
                for (i, t) in group.enumerated() {
                    do {
                        try await Net.delete(endpoint, topic: t.ref.topic, sequence: t.sequence)
                    } catch NtfyError.http(429) {
                        failed += group.count - i  // rate limited: stop instead of hammering the server
                        lastError = NtfyError.http(429)
                        break
                    } catch {
                        failed += 1
                        lastError = error
                    }
                }
            }
            guard failed > 0, let lastError else { return }
            let what = failed == 1 ? "1 notification" : "\(failed) notifications"
            var reason = NtfyError.describe(lastError)
            if case NtfyError.http(403) = lastError { reason = "You don't have write access to that topic." }
            ActionRunner.alert("Couldn't delete \(what) on the server",
                               "\(reason)\n\nThey were removed from this Mac only.")
        }
    }

    /// Messages being published right now. The server can stream the echo back before the
    /// publish response (with its ID) arrives, so until then echoes are matched by topic and text.
    /// Entries exist only for the duration of the publish call.
    private var pendingPublishes: [(token: UUID, ref: TopicRef, message: String)] = []

    /// Publishes a message. The echo from the subscription is stored as read, without notifying.
    /// A scheduled message instead arrives like any other when it's delivered.
    private func publish(_ ref: TopicRef, _ request: PublishRequest, file: URL?) async throws {
        guard let endpoint = await endpoint(ref.server) else { throw NtfyError.badResponse }
        let scheduled = request.delay != nil
        let token = UUID()
        if !scheduled { pendingPublishes.append((token, ref, request.message)) }
        defer { pendingPublishes.removeAll { $0.token == token } }
        let sent = try await Net.publish(endpoint, request, file: file)
        store.recordSent(ref, sequence: sent.sequence)
        guard !scheduled else { return }
        subscriber(for: ref.server).markSeen([sent.id])  // an echo arriving after this is dropped by the subscriber
        store.apply(sent, server: ref.server, read: true)
        store.setRead([sent.id], true)  // in case the echo was stored first
    }

    /// Pending scheduled messages on every subscribed topic, soonest first.
    private func fetchScheduled() async -> (messages: [(ref: TopicRef, message: NtfyMessage)], errors: [String]) {
        var found: [(ref: TopicRef, message: NtfyMessage)] = []
        var errors = Set<String>()
        let now = Int(Date().timeIntervalSince1970)
        for sub in store.config.subscriptions {
            guard let endpoint = await endpoint(sub.server) else { continue }
            do {
                // Cancelling or replacing a scheduled message deletes it on the server
                // (server.go, DeleteScheduledBySequenceID), so whatever is still ahead is pending.
                let msgs = try await Net.history(endpoint, topic: sub.topic, scheduled: true)
                found += msgs.filter { $0.event == "message" && $0.time > now }.map { (sub.ref, $0) }
            } catch {
                errors.insert("\(store.fullName(sub.ref)): \(NtfyError.describe(error))")
            }
        }
        return (found.sorted { $0.message.time < $1.message.time }, errors.sorted())
    }

    // MARK: Command line

    /// A request from the `mtfy` command (see CLI.swift). Answered on the same request ID.
    @objc private func cliRequest(_ note: Notification) {
        guard let id = note.object as? String, let info = note.userInfo as? [String: String] else { return }
        let (ok, output) = handleCLI(info)
        DistributedNotificationCenter.default().postNotificationName(
            CLI.replyName, object: id, userInfo: ["ok": ok ? "1" : "0", "output": output], deliverImmediately: true)
    }

    /// Every command is safe to receive twice: the command line repeats a request until the
    /// app answers.
    private func handleCLI(_ info: [String: String]) -> (Bool, String) {
        let ref = info["topic"].map { TopicRef(server: info["server"] ?? ServerConfig.legacyID, topic: $0) }
        switch info["command"] {
        case "status":
            return (true, store.diagnostics())
        case "pause":
            store.paused = true
            return (true, "Notifications paused.")
        case "resume":
            store.paused = false
            return (true, "Notifications resumed.")
        case "read":
            let scope = ref.map(SidebarItem.topic) ?? .all
            let n = store.unreadCount(in: scope)
            store.markAllRead(in: scope)
            return (true, n == 1 ? "Marked 1 notification read." : "Marked \(n) notifications read.")
        case "open":
            showMain(topic: ref)
            return (true, "")
        case "subscribe":
            guard let ref else { return (false, "No topic.") }
            if store.config.isSubscribed(ref) { return (true, "Already subscribed to \(ref.topic).") }
            if let err = store.addTopic(ref.topic, server: ref.server) { return (false, err) }
            if let name = info["name"]?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
                var settings = store.config.settings(for: ref)
                settings.displayName = String(name.prefix(64))
                store.setSettings(settings, for: ref)
            }
            return (true, "Subscribed to \(ref.topic).")
        case "unsubscribe":
            guard let ref else { return (false, "No topic.") }
            guard store.config.isSubscribed(ref) else { return (true, "Not subscribed to \(ref.topic).") }
            store.removeTopic(ref)
            return (true, "Unsubscribed from \(ref.topic).")
        default:
            return (false, "This version of Mtfy doesn't know that command.")
        }
    }

    // MARK: ntfy:// links

    /// Opens ntfy://host[:port]/topic[?display=Name&secure=false] links, the format the official
    /// apps use (https://docs.ntfy.sh/subscribe/phone/). Links can come from anywhere, so
    /// subscribing is always confirmed.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "ntfy" { openNtfyLink(url) }
    }

    private func openNtfyLink(_ url: URL) {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let topic = url.pathComponents.dropFirst().first ?? ""
        let insecure = comps?.queryItems?.first { $0.name == "secure" }?.value == "false"
        let display = comps?.queryItems?.first { $0.name == "display" }?.value
        guard let host = url.host(), !host.isEmpty, Config.isValidTopic(topic),
              let base = Config.parseServer("\(insecure ? "http" : "https")://\(host)\(url.port.map { ":\($0)" } ?? "")")
        else {
            return ActionRunner.alert("Can't open this link", "It isn't a valid ntfy://server/topic link.")
        }
        let existing = store.config.servers.first { $0.baseURL == base }
        if let existing, store.config.isSubscribed(TopicRef(server: existing.id, topic: topic)) {
            return showMain(topic: TopicRef(server: existing.id, topic: topic))
        }

        let alert = NSAlert()
        alert.messageText = "Subscribe to “\(topic)” on \(Config.hostLabel(base))?"
        var info = existing == nil
            ? "\(Config.hostLabel(base)) isn't one of your servers yet. It will be added without a login; you can add one in Settings."
            : "You'll get notifications for messages on this topic."
        if insecure { info += "\n\nThis server uses plain http, which isn't encrypted." }
        alert.informativeText = info
        alert.addButton(withTitle: "Subscribe")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var server = existing
        if server == nil {
            let added = ServerConfig(url: base.absoluteString)
            if let err = applyServer(added, secret: nil, headers: [:]) { return ActionRunner.alert("Couldn't add the server", err) }
            server = added
        }
        guard let server else { return }
        if let err = store.addTopic(topic, server: server.id) { return ActionRunner.alert("Couldn't subscribe", err) }
        let ref = TopicRef(server: server.id, topic: topic)
        if let display = display?.trimmingCharacters(in: .whitespaces), !display.isEmpty {
            var settings = store.config.settings(for: ref)
            settings.displayName = String(display.prefix(64))
            store.setSettings(settings, for: ref)
        }
        showMain(topic: ref)
    }

    private func isOwnEcho(_ event: NtfyMessage, server: String) -> Bool {
        let ref = TopicRef(server: server, topic: event.topic)
        guard event.event == "message",
              let i = pendingPublishes.firstIndex(where: { $0.ref == ref && $0.message == event.message })
        else { return false }
        pendingPublishes.remove(at: i)
        return true
    }

    /// Persists a server's settings and secrets, then reconnects. Returns an error message on failure.
    /// secret and headers hold only newly typed values; nil or missing keeps what's saved.
    private func applyServer(_ server: ServerConfig, secret: String?, headers: [String: String]) -> String? {
        let old = store.config.server(server.id)
        let credential = Secrets.credentialAccount(server.id)
        if server.auth == .none {
            Keychain.delete(credential)
        } else if let secret {
            let status = Keychain.save(secret, account: credential, label: "Mtfy credential for \(server.label)")
            guard status == errSecSuccess else { return Self.keychainError(status) }
        }
        let kept = Set(server.headerNames.map { $0.lowercased() })
        for name in old?.headerNames ?? [] where !kept.contains(name.lowercased()) {
            Keychain.delete(Secrets.headerAccount(server.id, name))
        }
        for (name, value) in headers {
            let status = Keychain.save(value, account: Secrets.headerAccount(server.id, name),
                                       label: "Mtfy header \(name) for \(server.label)")
            guard status == errSecSuccess else { return Self.keychainError(status) }
        }
        secretTasks[server.id] = nil

        let urlChanged = old != nil && old?.baseURL != server.baseURL
        store.saveServer(server)
        if urlChanged {
            subscribers[server.id]?.resetPosition()
            historyLoaded.subtract(store.config.topics(on: server.id).map { historyKey(TopicRef(server: server.id, topic: $0)) })
            historyFailures = historyFailures.filter { $0.key.server != server.id }
            historyGenerations[server.id, default: 0] += 1
        }
        connect()
        Task { await checkServerVersions() }
        if urlChanged {
            store.config.topics(on: server.id).forEach { fetchHistory(TopicRef(server: server.id, topic: $0)) }
        }
        return nil
    }

    private static func keychainError(_ status: OSStatus) -> String {
        "Couldn't save to Keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? "\(status)")"
    }

    /// Removes a server, its topics and notifications, and its saved secrets and position.
    private func removeServer(_ id: String) {
        guard let server = store.config.server(id) else { return }
        let refs = store.config.topics(on: id).map { TopicRef(server: id, topic: $0) }
        Secrets.deleteAll(server)
        secretTasks[id] = nil
        subscribers[id]?.forget()
        subscribers[id] = nil
        historyLoaded.subtract(refs.map(historyKey))
        historyFailures = historyFailures.filter { $0.key.server != id }
        for kind in [Problem.Kind.disconnected, .authFailed, .missingCredentials] { store.resolve(kind, server: id) }
        store.removeServer(id)  // reconnects via onTopicsChanged
    }

    /// Finds which ntfy version each server runs and whether a newer one is out. Servers only
    /// tell admins their version, so this checks servers with a login and quietly skips the
    /// rest. GitHub is only asked when at least one version is known.
    private func checkServerVersions() async {
        var versions: [String: String] = [:]
        for server in store.config.servers where server.auth != .none {
            guard let endpoint = await endpoint(server.id) else { continue }
            do {
                versions[server.id] = try await Net.version(endpoint)
            } catch {
                Log.network.notice("No ntfy version from \(server.label, privacy: .public): \(NtfyError.describe(error), privacy: .public)")
            }
        }
        store.serverVersions = versions
        guard !versions.isEmpty else { return }
        do {
            store.latestNtfy = try await Net.latestNtfyRelease()
        } catch {
            Log.network.notice("Couldn't check for ntfy releases: \(NtfyError.describe(error), privacy: .public)")
        }
    }

    // MARK: Health

    private var failingSince: [String: Date] = [:]

    private func connectionChanged(_ server: String, _ state: Subscriber.State) {
        guard !store.config.topics(on: server).isEmpty else { return }
        store.states[server] = state
        let label = store.config.server(server)?.label ?? "the server"
        switch state {
        case .connected:
            failingSince[server] = nil
            store.lastConnected = Date()
            store.resolve(.disconnected, server: server)
            store.resolve(.authFailed, server: server)
            historyFailures.keys.filter { $0.server == server }.forEach(fetchHistory)  // the server is reachable again
        case .failed(let reason):
            store.lastError = store.config.servers.count > 1 ? "\(label): \(reason)" : reason
            let since = failingSince[server] ?? Date()
            failingSince[server] = since
            // Brief drops (sleep, Wi-Fi changes) recover on their own; only speak up if it lasts.
            if Date().timeIntervalSince(since) >= 120 {
                store.report(Problem(kind: .disconnected, server: server, title: "Not connected to \(label)",
                                     detail: "\(reason). Retrying automatically; you won't get notifications until it's back.",
                                     action: .retry))
            }
        case .idle, .connecting:
            break
        }
    }

    private func connectionFailed(_ server: String, _ error: Error) {
        guard case NtfyError.http(let code) = error, code == 401 || code == 403 else { return }
        let label = store.config.server(server)?.label ?? "The server"
        store.report(Problem(kind: .authFailed, server: server, title: "\(label) rejected your login",
                             detail: "Your access token or password may have been changed or revoked (HTTP \(code)).",
                             action: .openSettings))
    }

    private nonisolated static func notificationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func checkNotificationPermission() {
        Task {
            var status = await Self.notificationStatus()
            if status == .notDetermined {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                status = await Self.notificationStatus()
            }
            switch status {
            case .denied:
                store.notificationStatus = "Denied"
                Log.notifications.error("Notifications are turned off for Mtfy in System Settings")
                store.report(Problem(kind: .notificationsDisabled, title: "Notifications are turned off",
                                     detail: "macOS is blocking Mtfy's notifications, so new messages won't pop up.",
                                     action: .openNotificationSettings))
            case .notDetermined:
                store.notificationStatus = "Not requested"
            default:
                store.notificationStatus = "Allowed"
                store.resolve(.notificationsDisabled)
            }
        }
    }

    /// Posts one desktop notification for a serious problem.
    private func announce(_ problem: Problem) {
        Log.app.error("Problem \(problem.kind.rawValue, privacy: .public): \(problem.title, privacy: .private)")
        guard problem.postsAlert else { return }
        let content = UNMutableNotificationContent()
        content.title = problem.title
        content.body = problem.detail
        content.sound = .default
        content.userInfo = ["problem": problem.kind.rawValue]
        let request = UNNotificationRequest(identifier: "problem-\(problem.kind.rawValue)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Log.notifications.error("Couldn't post alert: \(error.localizedDescription, privacy: .public)") }
        }
    }

    private func observeSystemEvents() {
        // A sleeping Mac's connection is silently dead, so reconnect right away on wake.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.connect() }
        }
        // Delivered on the main queue, so updates are handled in order. Reconnect when the network
        // comes back or switches (say Ethernet unplugged with Wi-Fi up): the old socket is dead
        // but would otherwise linger until the read timeout.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            let interfaces = path.availableInterfaces.map(\.name)
            MainActor.assumeIsolated {
                guard let self else { return }
                // The first update only reports the current state; launch already connected.
                if up, let known = self.networkInterfaces, !self.networkUp || interfaces != known { self.connect() }
                self.networkUp = up
                self.networkInterfaces = interfaces
            }
        }
        pathMonitor.start(queue: .main)
    }

    // MARK: Notifications

    private func handle(_ event: NtfyMessage, server: String) {
        if isOwnEcho(event, server: server) {
            store.apply(event, server: server, read: true)
            return
        }
        guard let stored = store.apply(event, server: server), store.shouldNotify(stored) else { return }
        notify(stored)
    }

    private static let baseCategory = UNNotificationCategory(
        identifier: "message",
        actions: [UNNotificationAction(identifier: "read", title: "Mark as Read"),
                  UNNotificationAction(identifier: "delete", title: "Delete", options: [.destructive])],
        intentIdentifiers: [])

    /// Categories for recent messages with action buttons; titles differ per message, so each
    /// needs its own category. Kept short so the registered set stays small.
    private var actionCategories: [UNNotificationCategory] = []

    private func category(for msg: StoredMessage) -> String {
        let actions = msg.visibleActions
        guard !actions.isEmpty else { return Self.baseCategory.identifier }
        let buttons = actions.enumerated().map { i, a in
            UNNotificationAction(identifier: "action-\(i)", title: a.label,
                                 options: a.action == "http" ? [.foreground] : [])
        } + Self.baseCategory.actions
        let category = UNNotificationCategory(identifier: "actions-\(msg.id)", actions: buttons, intentIdentifiers: [])
        actionCategories.append(category)
        if actionCategories.count > 30 { actionCategories.removeFirst() }
        UNUserNotificationCenter.current().setNotificationCategories(Set([Self.baseCategory] + actionCategories))
        return category.identifier
    }

    private func notify(_ msg: StoredMessage) {
        let content = UNMutableNotificationContent()
        let topic = store.fullName(msg.ref)
        if let title = msg.displayTitle {
            content.title = title
            content.subtitle = topic
        } else {
            content.title = topic
        }
        content.body = String(msg.displayText.prefix(1000))
        content.threadIdentifier = "\(msg.serverID)/\(msg.topic)"
        content.categoryIdentifier = category(for: msg)
        content.userInfo = ["id": msg.id, "server": msg.serverID, "topic": msg.topic]

        // No .timeSensitive for 4–5: it needs an entitlement only paid Apple Developer accounts can get.
        if msg.priority <= 2 {
            content.interruptionLevel = .passive
        } else {
            content.sound = .default
        }

        let request = UNNotificationRequest(identifier: msg.notificationID, content: content, trigger: nil)
        Task {
            // Registering categories is asynchronous; read them back first so a notification with
            // action buttons isn't posted before its category exists.
            if content.categoryIdentifier != Self.baseCategory.identifier { await Self.awaitCategoryRegistration() }
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                Log.notifications.error("Couldn't post notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Reading the categories back waits for earlier setNotificationCategories calls to land.
    private nonisolated static func awaitCategoryRegistration() async {
        _ = await UNUserNotificationCenter.current().notificationCategories()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let id = info["id"] as? String
        // Notifications posted before multiple servers have no server: the "default" one.
        let ref = (info["topic"] as? String).map {
            TopicRef(server: info["server"] as? String ?? ServerConfig.legacyID, topic: $0)
        }
        let isProblem = info["problem"] != nil
        let action = response.actionIdentifier
        // Handled after returning, so a confirmation dialog doesn't hold up the system callback.
        Task { @MainActor in
            if isProblem { self.showMain() } else { self.respond(to: action, id: id, topic: ref) }
        }
    }

    private func respond(to action: String, id: String?, topic: TopicRef?) {
        guard let id else { return }
        switch action {
        case UNNotificationDefaultActionIdentifier:
            openNotification(id: id, topic: topic)
        case "read":
            store.setRead([id], true)
        case "delete":
            store.userDelete([id])
        case let a where a.hasPrefix("action-"):
            guard let index = Int(a.dropFirst("action-".count)),
                  let msg = store.messages.first(where: { $0.id == id }),
                  msg.visibleActions.indices.contains(index) else { return }
            ActionRunner.run(msg.visibleActions[index], for: msg, store: store)
        default:
            break
        }
    }

    /// Clicking a notification opens its http(s) link if it has one, otherwise shows it in the app.
    private func openNotification(id: String, topic: TopicRef?) {
        let msg = store.messages.first { $0.id == id }
        store.setRead([id], true)
        if let url = msg?.clickURL {
            NSWorkspace.shared.open(url)
        } else {
            showMain(topic: topic)
        }
    }

    // MARK: Status item & menu

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let unread = store.unreadCount(in: .all)
        button.image = MenuBarIcon.image(!store.problems.isEmpty ? .problem
            : store.paused ? .paused : unread > 0 ? .unread : .none)
        button.imagePosition = .imageLeading
        button.title = unread > 0 ? " \(unread)" : ""
        button.appearsDisabled = store.state != .connected
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: store.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        for problem in store.problems {
            let entry = item("⚠️ \(problem.title)", #selector(showMainAction))
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(item("Open Mtfy", #selector(showMainAction), key: "o"))
        let compose = item("New Message…", #selector(composeAction), key: "n")
        menu.addItem(compose)
        menu.addItem(item("Scheduled Messages…", #selector(scheduledAction)))

        for server in store.config.servers {
            guard let update = store.availableUpdate(server.id) else { continue }
            let entry = item("⚠️ ntfy \(update) is available for \(server.label)", #selector(openNtfyReleases))
            menu.addItem(entry)
        }

        let unread = store.messages.filter { !$0.read }
        if !unread.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "\(unread.count) Unread"))
            for msg in unread.prefix(5) {
                let entry = item(menuTitle(msg), #selector(openRecent(_:)))
                entry.representedObject = msg.id
                menu.addItem(entry)
            }
            menu.addItem(item("Mark All as Read", #selector(markAllRead)))
        }

        menu.addItem(.separator())
        let pause = item("Pause Notifications", #selector(togglePause))
        pause.state = store.paused ? .on : .off
        menu.addItem(pause)
        menu.addItem(item("Settings…", #selector(showSettingsAction), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit Mtfy", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
    }

    private func item(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target ?? self
        return item
    }

    private func menuTitle(_ msg: StoredMessage) -> String {
        var text = msg.displayText
        if let title = msg.displayTitle { text = "\(title): \(text)" }
        text = text.replacingOccurrences(of: "\n", with: " ")
        if text.count > 50 { text = text.prefix(49) + "…" }
        return "\(store.fullName(msg.ref)) · \(text)"
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let msg = store.messages.first(where: { $0.id == id }) else { return }
        showMain(topic: msg.ref)
    }

    @objc private func markAllRead() { store.markAllRead(in: .all) }
    @objc private func openNtfyReleases() {
        NSWorkspace.shared.open(URL(string: "https://github.com/binwiederhier/ntfy/releases/latest")!)
    }
    @objc private func zoomIn() { store.zoom(1) }
    @objc private func zoomOut() { store.zoom(-1) }
    @objc private func zoomReset() { store.zoom(0) }
    @objc private func togglePause() { store.paused.toggle() }

    private func enableLoginItemOnFirstRun() {
        let key = "didSetUpLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            Log.app.error("Couldn't add login item: \(error.localizedDescription, privacy: .public)")
        }
        UserDefaults.standard.set(true, forKey: key)
    }

    // MARK: Windows

    @objc private func showMainAction() { showMain() }
    @objc private func showSettingsAction() { showSettings() }

    @objc private func composeAction() {
        guard !store.config.subscriptions.isEmpty else { return }
        guard store.sheet == nil else { return showMain() }  // don't throw away an open sheet's input
        var topic: TopicRef?
        if case .topic(let t) = store.selection { topic = t }
        showMain()
        store.sheet = .compose(topic: topic)
    }

    @objc private func scheduledAction() {
        guard !store.config.subscriptions.isEmpty else { return }
        showMain()
        if store.sheet == nil { store.sheet = .scheduled }  // don't throw away an open sheet's input
    }

    private func showMain(topic: TopicRef? = nil) {
        if let topic, store.config.isSubscribed(topic) { store.selection = .topic(topic) }
        if mainWindow == nil {
            let view = MainView(store: store)
            let hosting = NSHostingController(rootView: view)
            hosting.sceneBridgingOptions = [.title]  // the toolbar is native (see Toolbar below)
            hosting.sizingOptions = [.minSize]
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            let toolbar = NSToolbar(identifier: "main")
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            window.toolbar = toolbar
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 900, height: 580))
            window.center()
            window.setFrameAutosaveName("MainWindow")
            mainWindow = window
            updatePauseItem()  // in case notifications are already paused
        }
        // The app stays menu-bar-only (LSUIElement) and never switches activation policy: switching
        // between accessory and regular is a known AppKit bug that stops tooltips and can stop mouse
        // events (rdar://24027003).
        NSApp.activate()
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    private func showSettings() {
        showMain()
        if store.sheet == nil { store.sheet = .settings }  // don't throw away an open sheet's input
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(composeAction) || menuItem.action == #selector(scheduledAction) {
            return !store.config.subscriptions.isEmpty
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        store.sheet = nil
    }

    // MARK: Toolbar

    // A native NSToolbar, so enablement and the Pause icon are under our control.
    private static let toolbarItems: [(id: NSToolbarItem.Identifier, label: String, symbol: String, action: Selector)] = [
        (.init("compose"), "New Message", "square.and.pencil", #selector(composeAction)),
        (.init("markAllRead"), "Mark All as Read", "checkmark.circle", #selector(markAllReadHere)),
        (.init("deleteAll"), "Delete All", "trash", #selector(deleteAllHere)),
        (.init("pause"), "Pause", "bell", #selector(togglePause)),
        (.init("settings"), "Settings", "gearshape", #selector(showSettingsAction)),
    ]
    private static let searchItem = NSToolbarItem.Identifier("search")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace] + Self.toolbarItems.map(\.id) + [Self.searchItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == Self.searchItem {
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField.placeholderString = "Search"
            item.searchField.sendsSearchStringImmediately = true
            item.searchField.target = self
            item.searchField.action = #selector(searchChanged(_:))
            return item
        }
        guard let spec = Self.toolbarItems.first(where: { $0.id == id }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = spec.label
        item.paletteLabel = spec.label
        item.image = NSImage(systemSymbolName: spec.symbol, accessibilityDescription: spec.label)
        item.isBordered = true
        item.target = self
        item.action = spec.action
        return item
    }

    /// Called by AppKit on window updates, i.e. after most events. Per Apple's docs it only decides
    /// enablement, so it doesn't change the items themselves.
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        let scope = store.selection ?? .all
        switch item.itemIdentifier.rawValue {
        case "compose":
            return !store.config.subscriptions.isEmpty
        case "markAllRead":
            return store.unreadCount(in: scope) > 0
        case "deleteAll":
            return !store.messages(in: scope).isEmpty
        default:
            return true
        }
    }

    /// Pause's icon changes only when pausing is toggled.
    private func updatePauseItem() {
        guard let item = mainWindow?.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "pause" }) else { return }
        item.image = NSImage(systemSymbolName: store.paused ? "bell.slash.fill" : "bell", accessibilityDescription: item.label)
    }

    @objc private func markAllReadHere() { store.markAllRead(in: store.selection ?? .all) }
    @objc private func deleteAllHere() { store.confirmingDeleteAll = true }
    @objc private func searchChanged(_ sender: NSSearchField) { store.searchText = sender.stringValue }

    // MARK: Main menu

    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Mtfy", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(showSettingsAction), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Mtfy", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Mtfy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(item("New Message…", #selector(composeAction), key: "n"))
        fileMenu.addItem(item("Scheduled Messages…", #selector(scheduledAction)))
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(item("Actual Size", #selector(zoomReset), key: "0"))
        viewMenu.addItem(item("Bigger", #selector(zoomIn), key: "+"))
        // ⌘= is the same key as ⌘+ without Shift; accept both, like Safari does.
        let zoomInAlt = item("Bigger", #selector(zoomIn), key: "=")
        zoomInAlt.isHidden = true
        zoomInAlt.allowsKeyEquivalentWhenHidden = true
        viewMenu.addItem(zoomInAlt)
        viewMenu.addItem(item("Smaller", #selector(zoomOut), key: "-"))
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }
}
