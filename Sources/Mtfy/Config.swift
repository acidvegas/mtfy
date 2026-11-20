import Foundation

enum AuthType: String, Codable, CaseIterable, Identifiable {
    case none, token, basic
    var id: Self { self }
    var label: String {
        switch self {
        case .none: "None"
        case .token: "Access token"
        case .basic: "Username & password"
        }
    }
}

struct TopicSettings: Codable, Equatable {
    var displayName = ""
    var muted = false
    var mutedUntil: Int?      // Unix time; a temporary mute
    var minPriority = 1       // notify only for messages at or above this priority
    var color: String?        // "RRGGBB"; nil picks one from the topic name
    var retentionDays: Int?   // nil follows the global setting; 0 keeps until deleted

    func isMuted(at now: Date = Date()) -> Bool {
        muted || mutedUntil.map { TimeInterval($0) > now.timeIntervalSince1970 } == true
    }
}

extension TopicSettings {
    /// Missing keys fall back to defaults, so adding a field never breaks older saved settings.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TopicSettings()
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? d.displayName
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? d.muted
        mutedUntil = try c.decodeIfPresent(Int.self, forKey: .mutedUntil)
        minPriority = try c.decodeIfPresent(Int.self, forKey: .minPriority) ?? d.minPriority
        color = try c.decodeIfPresent(String.self, forKey: .color)
        retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays)
    }
}

/// A topic on one of the configured servers.
struct TopicRef: Codable, Hashable, Sendable {
    var server: String  // ServerConfig.id
    var topic: String
}

struct Subscription: Codable, Equatable {
    var server: String
    var topic: String
    var settings = TopicSettings()

    var ref: TopicRef { TopicRef(server: server, topic: topic) }
}

/// A server and how to sign in to it. The token or password and the custom header values live
/// in the Keychain (see Secrets).
struct ServerConfig: Codable, Equatable, Identifiable {
    /// The ID of the server migrated from the single-server settings of earlier versions.
    static let legacyID = "default"

    var id = UUID().uuidString
    var url = "https://ntfy.sh"
    var auth: AuthType = .none
    var username = ""
    var headerNames: [String] = []    // custom headers sent with every request; values are secret
    var pinnedCertificate: String?    // SHA-256 of a self-signed certificate the user trusts

    var baseURL: URL? { Config.parseServer(url) }
    var label: String { baseURL.map(Config.hostLabel) ?? url }
    var isInsecure: Bool { baseURL?.scheme == "http" }
}

extension ServerConfig {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ServerConfig()
        id = try c.decode(String.self, forKey: .id)
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? d.url
        auth = try c.decodeIfPresent(AuthType.self, forKey: .auth) ?? d.auth
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? d.username
        headerNames = try c.decodeIfPresent([String].self, forKey: .headerNames) ?? d.headerNames
        pinnedCertificate = try c.decodeIfPresent(String.self, forKey: .pinnedCertificate)
    }
}

/// Non-secret settings, stored in UserDefaults. Secrets live in the Keychain.
struct Config: Codable, Equatable {
    var servers = [ServerConfig(id: ServerConfig.legacyID)]
    var subscriptions: [Subscription] = []
    var retentionDays = 0  // 0 keeps notifications until deleted
    var loadExternalImages = false
    var deleteOnServer = true

    private static let key = "config"

    /// Loads saved settings. If they exist but can't be read, the raw data is kept under a
    /// backup key (so a later save can't destroy it) and the error is returned with defaults.
    static func load() -> (config: Config, error: Error?) {
        guard let data = UserDefaults.standard.data(forKey: key) else { return (Config(), nil) }
        do {
            return (try JSONDecoder().decode(Config.self, from: data), nil)
        } catch {
            let defaults = UserDefaults.standard
            let alreadyBackedUp = defaults.dictionaryRepresentation().contains { k, v in
                k.hasPrefix("\(key).unreadable-") && (v as? Data) == data
            }
            if !alreadyBackedUp { defaults.set(data, forKey: "\(key).unreadable-\(Int(Date().timeIntervalSince1970))") }
            Log.app.error("Couldn't read saved settings: \(error.localizedDescription, privacy: .public)")
            return (Config(), error)
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    func server(_ id: String) -> ServerConfig? { servers.first { $0.id == id } }

    func isSubscribed(_ ref: TopicRef) -> Bool { subscriptions.contains { $0.ref == ref } }

    func settings(for ref: TopicRef) -> TopicSettings {
        subscriptions.first { $0.ref == ref }?.settings ?? TopicSettings()
    }

    func topics(on server: String) -> [String] {
        subscriptions.filter { $0.server == server }.map(\.topic)
    }

    /// The server a URL belongs to: same scheme, host, port and base path.
    func server(containing url: URL) -> ServerConfig? {
        servers.first { s in
            guard let base = s.baseURL,
                  url.scheme?.lowercased() == base.scheme,
                  url.host()?.lowercased() == base.host()?.lowercased(),
                  Self.port(url) == Self.port(base) else { return false }
            let path = base.path.hasSuffix("/") ? base.path : base.path + "/"
            return path == "/" || url.standardized.path.hasPrefix(path)  // standardized: no "/base/../other"
        }
    }

    /// Accepts only plain http(s) URLs: no credentials, query or fragment. Trailing slashes are dropped.
    static func parseServer(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard let c = URLComponents(string: s),
              let scheme = c.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil else { return nil }
        return c.url
    }

    static func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "http" ? 80 : 443) }

    /// "ntfy.example.com", with the port if it isn't the default one.
    static func hostLabel(_ url: URL) -> String {
        let host = url.host() ?? url.absoluteString
        return url.port.map { "\(host):\($0)" } ?? host
    }

    /// Same rule the ntfy server uses for topic names.
    static func isValidTopic(_ t: String) -> Bool {
        t.wholeMatch(of: /[-_A-Za-z0-9]{1,64}/) != nil
    }

    /// An HTTP header name (RFC 9110 token).
    static func isValidHeaderName(_ s: String) -> Bool {
        s.wholeMatch(of: /[!#$%&'*+\-.^_`|~0-9A-Za-z]{1,64}/) != nil
    }

    /// Rejects values that could break or inject HTTP headers.
    static func isSafeHeaderValue(_ s: String) -> Bool {
        !s.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// Only http(s) links with a host are ever opened.
    static func webURL(_ s: String) -> URL? {
        // Credentials in a URL ("https://bank.com@evil.example") are only used to disguise the host.
        guard let url = URL(string: s),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
        return url
    }

    /// Links a message may open: http(s), plus mailto: with an address.
    static func linkURL(_ s: String) -> URL? {
        if let url = webURL(s) { return url }
        guard let url = URL(string: s), url.scheme?.lowercased() == "mailto",
              mailAddress(url) != nil else { return nil }
        return url
    }

    /// The address a mailto: link writes to.
    static func mailAddress(_ url: URL) -> String? {
        guard url.scheme?.lowercased() == "mailto" else { return nil }
        let address = url.path(percentEncoded: false)
        return address.contains("@") ? address : nil
    }

    static func authorization(_ type: AuthType, username: String, secret: String?) -> String? {
        guard let secret, !secret.isEmpty else { return nil }
        switch type {
        case .none: return nil
        case .token: return "Bearer \(secret)"
        case .basic: return "Basic " + Data("\(username):\(secret)".utf8).base64EncodedString()
        }
    }
}

extension Config {
    private enum LegacyKeys: String, CodingKey {
        case server, auth, username, topics, topicSettings
    }

    /// Missing keys fall back to defaults, so settings saved by older versions still load.
    /// Settings from before multiple servers become one server with the ID "default".
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? d.retentionDays
        loadExternalImages = try c.decodeIfPresent(Bool.self, forKey: .loadExternalImages) ?? d.loadExternalImages
        deleteOnServer = try c.decodeIfPresent(Bool.self, forKey: .deleteOnServer) ?? d.deleteOnServer
        if let servers = try c.decodeIfPresent([ServerConfig].self, forKey: .servers) {
            self.servers = servers
            subscriptions = try c.decodeIfPresent([Subscription].self, forKey: .subscriptions) ?? []
            return
        }
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        var server = ServerConfig(id: ServerConfig.legacyID)
        server.url = try legacy.decodeIfPresent(String.self, forKey: .server) ?? server.url
        server.auth = try legacy.decodeIfPresent(AuthType.self, forKey: .auth) ?? server.auth
        server.username = try legacy.decodeIfPresent(String.self, forKey: .username) ?? server.username
        servers = [server]
        let topics = try legacy.decodeIfPresent([String].self, forKey: .topics) ?? []
        let settings = try legacy.decodeIfPresent([String: TopicSettings].self, forKey: .topicSettings) ?? [:]
        subscriptions = topics.map {
            Subscription(server: server.id, topic: $0, settings: settings[$0] ?? TopicSettings())
        }
    }
}
