import AppKit
import Foundation

/// The `mtfy` command: the app's own executable run with arguments (build.sh installs a small
/// wrapper script in ~/.local/bin). Being the same signed program, it reads the saved logins
/// without a Keychain prompt. Sending, listing and scheduled messages work on their own;
/// commands that change the app's state are sent to the running app (launching it if needed),
/// so its saved data has a single writer.
@MainActor
enum CLI {
    static let requestName = Notification.Name("local.mtfy.cli.request")
    static let replyName = Notification.Name("local.mtfy.cli.reply")

    private static let commands: Set<String> = [
        "send", "topics", "list", "scheduled", "cancel", "status",
        "pause", "resume", "read", "open", "subscribe", "unsubscribe", "help", "version",
    ]

    /// True when the process was started to run a command rather than the app.
    static func isCommand(_ args: [String]) -> Bool {
        guard args.count > 1 else { return false }
        return commands.contains(args[1]) || ["-h", "--help", "-v", "--version"].contains(args[1])
    }

    static func run(_ args: [String]) async -> Int32 {
        var args = args
        let command = args.isEmpty ? "help" : args.removeFirst()
        do {
            switch command {
            case "help", "-h", "--help": print(help)
            case "version", "-v", "--version": print("mtfy (ntfy for macOS) \(version)")
            case "send": try await send(args)
            case "topics": try topics(args)
            case "list": try list(args)
            case "scheduled": try await scheduled(args)
            case "cancel": try await cancel(args)
            default: try await control(command, args)
            }
            return 0
        } catch let e as CLIError {
            fail(e.message)
            return e.usage ? 2 : 1
        } catch {
            fail(NtfyError.describe(error))
            return 1
        }
    }

    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data("mtfy: \(message)\n".utf8))
    }

    static let help = """
    Usage: mtfy <command> [options]

    Uses the servers and logins saved in Mtfy.

    Sending
      send <topic> [message]    Send a message. Without a message, reads it from stdin.
          --title <text>        --priority <1-5|min|low|default|high|urgent>
          --tags <a,b>          --click <url>        --markdown
          --icon <url>          --email <address>
          --delay <when>        e.g. 30m, 2h, "tomorrow 9am" (10 seconds to 3 days ahead)
          --attach <file|url>   --filename <name>
          --action <spec>       Up to 3: "view, Label, https://…", "copy, Label, text",
                                "http, Label, https://…[, method=PUT][, body=…]", or JSON
      scheduled [--json]        List messages waiting to be delivered
      cancel <topic> <id>       Cancel a scheduled message (the ID from `scheduled`)

    Reading
      topics [--json]           List subscribed topics with unread counts
      list [topic] [--unread] [--limit <n>] [--json]
                                Show saved notifications, newest last (default 20)

    Controlling the app
      status                    Connection status and diagnostics
      pause | resume            Pause or resume notifications
      read [topic]              Mark a topic's notifications read (all topics without one)
      open [topic]              Open the window, at a topic
      subscribe <topic> [--name <display name>]
      unsubscribe <topic> [--yes]

    Topic commands take --server <host or URL> when you use more than one server.
    """

    // MARK: Sending

    private static func send(_ raw: [String]) async throws {
        let a = try Args(raw, valued: ["title", "priority", "tags", "click", "icon", "email", "delay",
                                       "attach", "filename", "action", "server"],
                         flags: ["markdown"])
        guard let topic = a.positional.first else { throw CLIError.usage("send needs a topic.") }
        guard Config.isValidTopic(topic) else { throw CLIError("“\(topic)” isn't a valid topic name.") }
        let config = Config.load().config
        let server = try resolveServer(config, a.value("server"), topic: topic)

        var message = a.positional.dropFirst().joined(separator: " ")
        if message.isEmpty, isatty(STDIN_FILENO) == 0 {
            message = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            while message.hasSuffix("\n") { message.removeLast() }
        }

        var file: URL?
        var attach: String?
        if let target = a.value("attach") {
            let path = URL(fileURLWithPath: (target as NSString).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: path.path) {
                file = path
            } else if Config.webURL(target) != nil {
                attach = target
            } else {
                throw CLIError("--attach must be an existing file or an http(s) URL.")
            }
        }
        guard !message.isEmpty || file != nil || attach != nil else {
            throw CLIError.usage("Nothing to send: give a message, pipe one in, or --attach a file.")
        }

        var request = PublishRequest(topic: topic, message: message)
        request.title = a.value("title")
        if let p = a.value("priority") { request.priority = try priority(p) }
        request.tags = a.value("tags").map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        if let click = a.value("click") {
            guard Config.linkURL(click) != nil else { throw CLIError("--click must be an http(s) or mailto: link.") }
            request.click = click
        }
        request.markdown = a.flags.contains("markdown") ? true : nil
        request.icon = a.value("icon")
        request.email = a.value("email")
        request.delay = a.value("delay")
        request.timezone = request.delay == nil ? nil : TimeZone.current.identifier
        request.attach = attach
        request.filename = a.value("filename") ?? file?.lastPathComponent
        let actions = try a.values("action").map(parseAction)
        guard actions.count <= 3 else { throw CLIError("At most 3 --action buttons.") }
        request.actions = actions.isEmpty ? nil : actions

        let sent = try await Net.publish(endpoint(config, server), request, file: file)
        if request.delay != nil {
            let when = Date(timeIntervalSince1970: TimeInterval(sent.time))
            print("Scheduled \(sent.id) on \(topic) for \(when.formatted(date: .abbreviated, time: .shortened))")
        } else {
            print("Sent \(sent.id) to \(topic) on \(server.label)")
        }
    }

    private static func priority(_ s: String) throws -> Int {
        let names = ["min": 1, "low": 2, "default": 3, "high": 4, "max": 5, "urgent": 5]
        if let n = Int(s), (1...5).contains(n) { return n }
        if let n = names[s.lowercased()] { return n }
        throw CLIError("--priority must be 1–5 or min, low, default, high, urgent.")
    }

    /// "view, Label, https://…", "copy, Label, text", "http, Label, https://…, method=PUT,
    /// body=…, headers.X-Name=value", like ntfy's simple format, or a JSON object.
    private static func parseAction(_ spec: String) throws -> NtfyAction {
        if spec.trimmingCharacters(in: .whitespaces).hasPrefix("{") {
            guard let action = try? JSONDecoder().decode(NtfyAction.self, from: Data(spec.utf8)) else {
                throw CLIError("Couldn't read the --action JSON.")
            }
            return action
        }
        let parts = spec.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3, ["view", "copy", "http"].contains(parts[0]), !parts[1].isEmpty else {
            throw CLIError("--action must look like \"view, Label, https://…\" (or copy / http).")
        }
        var action = NtfyAction(action: parts[0], label: parts[1])
        if parts[0] == "copy" { action.value = parts[2] } else { action.url = parts[2] }
        for option in parts.dropFirst(3) {
            let kv = option.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { throw CLIError("Unknown --action option “\(option)”.") }
            switch kv[0] {
            case "clear": action.clear = kv[1] == "true"
            case "method": action.method = kv[1].uppercased()
            case "body": action.body = kv[1]
            case let key where key.hasPrefix("headers."):
                action.headers = (action.headers ?? [:]).merging([String(key.dropFirst(8)): kv[1]]) { $1 }
            default: throw CLIError("Unknown --action option “\(kv[0])”.")
            }
        }
        if action.action != "copy", Config.webURL(action.url ?? "") == nil {
            throw CLIError("The “\(action.label)” button needs an http(s) URL.")
        }
        return action
    }

    // MARK: Reading

    /// Saved notifications on subscribed topics, newest first. The app saves within a second
    /// of any change.
    private static func savedMessages(_ config: Config) -> [StoredMessage] {
        guard let data = try? Data(contentsOf: Store.messagesFileURL),
              let all = try? JSONDecoder().decode([StoredMessage].self, from: data) else { return [] }
        return all.filter { config.isSubscribed($0.ref) }
    }

    private static func topics(_ raw: [String]) throws {
        let a = try Args(raw, valued: [], flags: ["json"])
        let config = Config.load().config
        let messages = savedMessages(config)
        let rows = config.subscriptions.map { sub in
            let mine = messages.filter { $0.ref == sub.ref }
            return (sub, mine.count, mine.filter { !$0.read }.count)
        }
        if a.flags.contains("json") {
            return try printJSON(rows.map { sub, total, unread in
                ["server": config.server(sub.server)?.label ?? sub.server, "topic": sub.topic,
                 "name": sub.settings.displayName, "total": total, "unread": unread, "muted": sub.settings.isMuted()] as [String: Any]
            })
        }
        guard !rows.isEmpty else { return print("No topics. Subscribe with: mtfy subscribe <topic>") }
        let multi = config.servers.count > 1
        for (sub, total, unread) in rows {
            var line = sub.topic
            if !sub.settings.displayName.isEmpty { line += " (\(sub.settings.displayName))" }
            if multi { line += " on \(config.server(sub.server)?.label ?? "?")" }
            line += unread > 0 ? " · \(unread) unread of \(total)" : " · \(total)"
            if sub.settings.isMuted() { line += " · muted" }
            print(line)
        }
    }

    private static func list(_ raw: [String]) throws {
        let a = try Args(raw, valued: ["limit", "server"], flags: ["unread", "json"])
        let config = Config.load().config
        var messages = savedMessages(config)
        if let topic = a.positional.first {
            let ref = try resolveSubscribed(config, topic, server: a.value("server"))
            messages = messages.filter { $0.ref == ref }
        }
        if a.flags.contains("unread") { messages = messages.filter { !$0.read } }
        let limit = try a.value("limit").map { s -> Int in
            guard let n = Int(s), n > 0 else { throw CLIError("--limit must be a positive number.") }
            return n
        } ?? 20
        let shown = Array(messages.prefix(limit).reversed())  // newest last, like a log

        if a.flags.contains("json") {
            return try printJSON(shown.map { m in
                var o: [String: Any] = ["id": m.id, "time": m.time, "topic": m.topic, "message": m.message,
                                        "priority": m.priority, "tags": m.tags, "read": m.read,
                                        "server": config.server(m.serverID)?.label ?? m.serverID]
                if let t = m.title { o["title"] = t }
                if let c = m.click { o["click"] = c }
                if let u = m.attachmentURL { o["attachment"] = u }
                return o
            })
        }
        guard !shown.isEmpty else { return print(a.flags.contains("unread") ? "No unread notifications." : "No notifications.") }
        let priorities = [1: "min", 2: "low", 4: "HIGH", 5: "URGENT"]
        for m in shown {
            var line = m.date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute())
            line += m.read ? "   " : " • "
            line += m.topic
            if let p = priorities[m.priority] { line += " [\(p)]" }
            let text = m.displayText.replacingOccurrences(of: "\n", with: " ")
            line += "  " + (m.displayTitle.map { "\($0): \(text)" } ?? text)
            print(line)
        }
    }

    private static func scheduled(_ raw: [String]) async throws {
        let a = try Args(raw, valued: [], flags: ["json"])
        let config = Config.load().config
        Net.setPins(config.servers)
        let now = Int(Date().timeIntervalSince1970)
        var found: [(Subscription, NtfyMessage)] = []
        for sub in config.subscriptions {
            guard let server = config.server(sub.server) else { continue }
            do {
                let msgs = try await Net.history(endpoint(config, server), topic: sub.topic, scheduled: true)
                found += msgs.filter { $0.event == "message" && $0.time > now }.map { (sub, $0) }
            } catch {
                fail("\(sub.topic): \(NtfyError.describe(error))")
            }
        }
        found.sort { $0.1.time < $1.1.time }
        if a.flags.contains("json") {
            return try printJSON(found.map { sub, m in
                ["id": m.sequence, "time": m.time, "topic": sub.topic, "message": m.message ?? "",
                 "title": m.title ?? "", "server": config.server(sub.server)?.label ?? sub.server] as [String: Any]
            })
        }
        guard !found.isEmpty else { return print("Nothing scheduled.") }
        for (sub, m) in found {
            let when = Date(timeIntervalSince1970: TimeInterval(m.time)).formatted(date: .abbreviated, time: .shortened)
            let text = (m.title.map { "\($0): " } ?? "") + (m.message ?? "")
            print("\(m.sequence)  \(when)  \(sub.topic)  \(text.replacingOccurrences(of: "\n", with: " "))")
        }
    }

    private static func cancel(_ raw: [String]) async throws {
        let a = try Args(raw, valued: ["server"], flags: [])
        guard a.positional.count == 2 else { throw CLIError.usage("cancel needs a topic and a message ID.") }
        let config = Config.load().config
        let server = try resolveServer(config, a.value("server"), topic: a.positional[0])
        try await Net.delete(endpoint(config, server), topic: a.positional[0], sequence: a.positional[1])
        print("Cancelled \(a.positional[1]).")
    }

    // MARK: Controlling the app

    private static func control(_ command: String, _ raw: [String]) async throws {
        let a = try Args(raw, valued: ["server", "name"], flags: ["yes"])
        let config = Config.load().config
        var info = ["command": command]
        switch command {
        case "status", "pause", "resume":
            break
        case "read", "open":
            if let topic = a.positional.first {
                let ref = try resolveSubscribed(config, topic, server: a.value("server"))
                info["server"] = ref.server
                info["topic"] = ref.topic
            }
        case "subscribe":
            guard let topic = a.positional.first else { throw CLIError.usage("subscribe needs a topic.") }
            info["server"] = try resolveServer(config, a.value("server"), topic: nil).id
            info["topic"] = topic
            info["name"] = a.value("name")
        case "unsubscribe":
            guard let topic = a.positional.first else { throw CLIError.usage("unsubscribe needs a topic.") }
            let ref = try resolveSubscribed(config, topic, server: a.value("server"))
            if !a.flags.contains("yes") {
                guard isatty(STDIN_FILENO) != 0 else { throw CLIError("Add --yes to unsubscribe without asking.") }
                print("Unsubscribe from \(topic)? Its saved notifications will be deleted. [y/N] ", terminator: "")
                guard readLine()?.lowercased().hasPrefix("y") == true else { return print("Cancelled.") }
            }
            info["server"] = ref.server
            info["topic"] = ref.topic
        default:
            throw CLIError.usage("Unknown command “\(command)”. See: mtfy help")
        }
        let output = try await ask(info, launch: command != "status")
        if !output.isEmpty { print(output) }
    }

    /// Sends a request to the running app and waits for its answer. Requests reach it even
    /// while it's in the background (deliverImmediately; NSDistributedNotificationCenter.h).
    private static func ask(_ info: [String: String], launch: Bool) async throws -> String {
        let id = UUID().uuidString
        let center = DistributedNotificationCenter.default()
        var reply: (ok: Bool, output: String)?
        let observer = center.addObserver(forName: replyName, object: id, queue: .main) { note in
            let info = note.userInfo as? [String: String] ?? [:]
            MainActor.assumeIsolated { reply = (info["ok"] == "1", info["output"] ?? "") }
        }
        defer { center.removeObserver(observer) }

        let bundleID = Bundle.main.bundleIdentifier ?? "local.mtfy"
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != getpid() }  // this command runs the same program
        if running.isEmpty {
            guard launch else { throw CLIError("Mtfy isn't running.") }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            _ = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config)
        }
        // A just-launched app only hears requests once it has finished launching, so repeat
        // until it answers. Each command is safe to receive twice.
        for _ in 0..<40 {
            center.postNotificationName(requestName, object: id, userInfo: info, deliverImmediately: true)
            for _ in 0..<5 {
                try? await Task.sleep(for: .milliseconds(100))
                if let reply {
                    guard reply.ok else { throw CLIError(reply.output) }
                    return reply.output
                }
            }
        }
        throw CLIError("Mtfy didn't answer.")
    }

    // MARK: Helpers

    private static func endpoint(_ config: Config, _ server: ServerConfig) throws -> Endpoint {
        guard let base = server.baseURL else { throw CLIError("\(server.label) has an invalid URL.") }
        Net.setPins(config.servers)
        let secrets = Secrets.load(server)
        if server.auth != .none, secrets.credential == nil {
            throw CLIError("No saved login for \(server.label). Add it in the app's Settings.")
        }
        return Endpoint(base: base,
                        authorization: Config.authorization(server.auth, username: server.username, secret: secrets.credential),
                        headers: secrets.headers)
    }

    /// --server by host, host:port, URL or ID. Without it: the only server, or the only one
    /// with this topic.
    private static func resolveServer(_ config: Config, _ name: String?, topic: String?) throws -> ServerConfig {
        if let name {
            let n = name.lowercased()
            let url = Config.parseServer(name)
            let match = config.servers.first { s in
                s.id == name || s.label.lowercased() == n || s.baseURL?.host()?.lowercased() == n
                    || (url != nil && s.baseURL == url)
            }
            guard let match else { throw CLIError("No server “\(name)”. Servers: \(serverList(config))") }
            return match
        }
        if config.servers.count == 1 { return config.servers[0] }
        if let topic {
            let owners = config.servers.filter { config.topics(on: $0.id).contains(topic) }
            if owners.count == 1 { return owners[0] }
        }
        guard !config.servers.isEmpty else { throw CLIError("No servers. Add one in the app's Settings.") }
        throw CLIError("Add --server: \(serverList(config))")
    }

    private static func resolveSubscribed(_ config: Config, _ topic: String, server: String?) throws -> TopicRef {
        let s = try resolveServer(config, server, topic: topic)
        let ref = TopicRef(server: s.id, topic: topic)
        guard config.isSubscribed(ref) else { throw CLIError("Not subscribed to \(topic) on \(s.label).") }
        return ref
    }

    private static func serverList(_ config: Config) -> String {
        config.servers.map(\.label).joined(separator: ", ")
    }

    private static func printJSON(_ value: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: data, as: UTF8.self))
    }
}

struct CLIError: Error {
    let message: String
    var usage = false
    init(_ message: String) { self.message = message }
    static func usage(_ message: String) -> CLIError {
        var e = CLIError(message)
        e.usage = true
        return e
    }
}

/// --name value, --name=value, flags, and positional arguments ("--" ends options).
struct Args {
    var positional: [String] = []
    var flags: Set<String> = []
    private var options: [String: [String]] = [:]

    init(_ raw: [String], valued: Set<String>, flags known: Set<String>) throws {
        var i = 0
        var onlyPositional = false
        while i < raw.count {
            let arg = raw[i]
            i += 1
            guard !onlyPositional, arg.hasPrefix("--") else {
                positional.append(arg)
                continue
            }
            if arg == "--" { onlyPositional = true; continue }
            var name = String(arg.dropFirst(2))
            var value: String?
            if let eq = name.firstIndex(of: "=") {
                value = String(name[name.index(after: eq)...])
                name = String(name[..<eq])
            }
            if known.contains(name), value == nil {
                flags.insert(name)
            } else if valued.contains(name) {
                if value == nil {
                    guard i < raw.count else { throw CLIError.usage("--\(name) needs a value.") }
                    value = raw[i]
                    i += 1
                }
                options[name, default: []].append(value!)
            } else {
                throw CLIError.usage("Unknown option --\(name). See: mtfy help")
            }
        }
    }

    func value(_ name: String) -> String? { options[name]?.last }
    func values(_ name: String) -> [String] { options[name] ?? [] }
}
