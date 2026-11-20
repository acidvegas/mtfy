import CryptoKit
import Foundation
import ImageIO
import os

/// An action button attached to a message (https://docs.ntfy.sh/publish/#action-buttons).
struct NtfyAction: Codable, Hashable, Sendable {
    var action: String  // view, http, broadcast, copy
    var label: String
    var url: String?
    var method: String?
    var headers: [String: String]?
    var body: String?
    var value: String?
    var clear: Bool?
}

/// One event from the JSON stream. Only id, time, event and topic are required; everything else
/// is decoded leniently so a single malformed field never drops a message.
struct NtfyMessage: Decodable, Sendable {
    struct Attachment: Decodable, Sendable {
        let name: String?
        let url: String?
        let type: String?
        let size: Int?
        let expires: Int?
    }

    let id: String
    let time: Int
    let event: String
    let topic: String
    let sequenceID: String?
    let message: String?
    let title: String?
    let priority: Int?
    let tags: [String]?
    let click: String?
    let icon: String?
    let actions: [NtfyAction]?
    let attachment: Attachment?
    let markdown: Bool

    /// Messages that replace, clear or delete each other share a sequence ID (defaults to the ID).
    var sequence: String { sequenceID ?? id }

    private enum CodingKeys: String, CodingKey {
        case id, time, event, topic, message, title, priority, tags, click, icon, actions, attachment, markdown
        case sequenceID = "sequence_id"
        case contentType = "content_type"
    }

    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func opt<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            (try? c.decodeIfPresent(type, forKey: key)) ?? nil
        }
        id = try c.decode(String.self, forKey: .id)
        time = try c.decode(Int.self, forKey: .time)
        event = try c.decode(String.self, forKey: .event)
        topic = try c.decode(String.self, forKey: .topic)
        sequenceID = opt(String.self, .sequenceID)
        message = opt(String.self, .message)
        title = opt(String.self, .title)
        priority = opt(Int.self, .priority)
        tags = opt([String].self, .tags)
        click = opt(String.self, .click)
        icon = opt(String.self, .icon)
        actions = opt([Lossy<NtfyAction>].self, .actions)?.compactMap(\.value)
        attachment = opt(Attachment.self, .attachment)
        markdown = opt(Bool.self, .markdown) == true || opt(String.self, .contentType) == "text/markdown"
    }

    static let handledEvents: Set<String> = ["message", "message_clear", "message_delete"]
}

/// Body for publishing a message as JSON (https://docs.ntfy.sh/publish/#publish-as-json).
struct PublishRequest: Encodable, Sendable {
    var topic: String
    var message: String
    var title: String?
    var priority: Int?
    var tags: [String]?
    var click: String?
    var markdown: Bool?
    var actions: [NtfyAction]?
    var attach: String?     // a link to a file; uploads go in the request body instead
    var filename: String?
    var icon: String?
    var email: String?
    var delay: String?      // "30m", "tomorrow, 9am", a Unix time…; the server parses it
    var timezone: String?   // for natural-language delays
    var sequenceID: String? // replaces the message with this sequence ID

    private enum CodingKeys: String, CodingKey {
        case topic, message, title, priority, tags, click, markdown, actions, attach, filename, icon, email, delay, timezone
        case sequenceID = "sequence_id"
    }

    /// The same fields as query parameters, for uploads, whose body is the file
    /// (https://docs.ntfy.sh/publish/#list-of-all-parameters). Actions go as a JSON array,
    /// which the server accepts in place of the simple format (ntfy action/action.go, Parse).
    func queryItems() throws -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        func add(_ name: String, _ value: String?) {
            if let value, !value.isEmpty { items.append(URLQueryItem(name: name, value: value)) }
        }
        add("message", message)
        add("title", title)
        add("priority", priority.map(String.init))
        add("tags", tags?.joined(separator: ","))
        add("click", click)
        add("markdown", markdown == true ? "yes" : nil)
        add("icon", icon)
        add("email", email)
        add("delay", delay)
        add("timezone", timezone)
        add("filename", filename)
        add("sequence-id", sequenceID)
        if let actions, !actions.isEmpty {
            add("actions", String(data: try JSONEncoder().encode(actions), encoding: .utf8))
        }
        return items
    }
}

enum NtfyError: LocalizedError {
    case http(Int)
    case badResponse
    case closed
    case tooLarge
    case rejected(String)  // the server's own explanation, e.g. "invalid delay parameter"

    var errorDescription: String? {
        switch self {
        case .http(401), .http(403): "Authentication failed"
        case .http(429): "Rate limited by server"
        case .http(let code) where (300..<400).contains(code): "Server redirected (refused)"
        case .http(let code): "Server error (HTTP \(code))"
        case .badResponse: "Invalid server response"
        case .closed: "Connection closed"
        case .tooLarge: "File too large"
        case .rejected(let reason): reason
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case let e as NtfyError: return e.errorDescription ?? "Error"
        case let e as URLError:
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost: return "Offline"
            case .timedOut: return "Connection timed out"
            case .cannotFindHost, .dnsLookupFailed: return "Server not found"
            case .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .secureConnectionFailed:
                return "TLS error"
            default: return e.localizedDescription
            }
        default: return error.localizedDescription
        }
    }
}

/// Where a request goes and how it signs in: a server's base URL, its Authorization header
/// value and its custom headers.
struct Endpoint: Sendable {
    let base: URL
    var authorization: String?
    var headers: [String: String] = [:]
}

/// Refuses redirects so credentials are never forwarded to another host, and accepts a
/// self-signed certificate only if the user trusted that exact certificate for the server.
final class SessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let pin: @Sendable (String) -> String?
    private let sawUntrusted: (@Sendable (String) -> Void)?

    /// pin: "host:port" → SHA-256 of the trusted certificate. sawUntrusted receives the SHA-256
    /// of a certificate that failed the normal checks, so the user can be asked to trust it.
    init(pin: @escaping @Sendable (String) -> String?, sawUntrusted: (@Sendable (String) -> Void)? = nil) {
        self.pin = pin
        self.sawUntrusted = sawUntrusted
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }

    // App Transport Security is off (see Info.plist), so this can extend trust to a pinned
    // certificate: https://developer.apple.com/documentation/foundation/performing-manual-server-trust-authentication
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust else { return (.performDefaultHandling, nil) }
        if SecTrustEvaluateWithError(trust, nil) { return (.performDefaultHandling, nil) }
        guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            return (.performDefaultHandling, nil)
        }
        let fingerprint = Certificates.fingerprint(leaf)
        if let expected = pin("\(space.host.lowercased()):\(space.port)"), expected == fingerprint {
            return (.useCredential, URLCredential(trust: trust))
        }
        sawUntrusted?(fingerprint)
        return (.performDefaultHandling, nil)  // fails as untrusted
    }
}

enum Certificates {
    static func fingerprint(_ cert: SecCertificate) -> String {
        SHA256.hash(data: SecCertificateCopyData(cert) as Data).map { String(format: "%02x", $0) }.joined()
    }

    /// "AB:CD:…", the way certificate viewers show fingerprints.
    static func display(_ fingerprint: String) -> String {
        stride(from: 0, to: fingerprint.count, by: 2).map {
            let i = fingerprint.index(fingerprint.startIndex, offsetBy: $0)
            return fingerprint[i..<fingerprint.index(i, offsetBy: 2)].uppercased()
        }.joined(separator: ":")
    }
}

enum Net {
    /// Trusted self-signed certificates, by "host:port". Set from the server settings.
    private static let pins = OSAllocatedUnfairLock(initialState: [String: String]())

    static func setPins(_ servers: [ServerConfig]) {
        var map: [String: String] = [:]
        for s in servers {
            guard let pin = s.pinnedCertificate, let url = s.baseURL, url.scheme == "https",
                  let host = url.host()?.lowercased() else { continue }
            map["\(host):\(Config.port(url))"] = pin
        }
        pins.withLock { [map] in $0 = map }
    }

    static func makeSession(_ delegate: SessionDelegate) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        // ntfy sends a keepalive every ~45s, so 90s of silence means the connection is dead.
        c.timeoutIntervalForRequest = 90
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.tlsMinimumSupportedProtocolVersion = .TLSv12
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        c.httpAdditionalHeaders = ["User-Agent": "mtfy/\(version)"]
        return URLSession(configuration: c, delegate: delegate, delegateQueue: nil)
    }

    static let session = makeSession(SessionDelegate(pin: { key in pins.withLock { $0[key] } }))

    static func request(_ url: URL, _ endpoint: Endpoint?, timeout: TimeInterval) -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        if let endpoint {
            for (name, value) in endpoint.headers { req.setValue(value, forHTTPHeaderField: name) }
            if let authorization = endpoint.authorization { req.setValue(authorization, forHTTPHeaderField: "Authorization") }
        }
        return req
    }

    static func check(_ response: URLResponse, accept: Range<Int> = 200..<201) throws {
        guard let http = response as? HTTPURLResponse else { throw NtfyError.badResponse }
        guard accept.contains(http.statusCode) else { throw NtfyError.http(http.statusCode) }
    }

    /// Returns the username the server sees for these credentials ("*" means anonymous).
    static func account(_ endpoint: Endpoint, session: URLSession = session) async throws -> String {
        struct Account: Decodable { let username: String }
        let url = endpoint.base.appendingPathComponent("v1/account")
        let (data, resp) = try await session.data(for: request(url, endpoint, timeout: 15))
        try check(resp)
        return try JSONDecoder().decode(Account.self, from: data).username
    }

    /// The server's ntfy version. Only admins may ask (https://github.com/binwiederhier/ntfy,
    /// server/server.go: GET /v1/version is wrapped in ensureAdmin), so others get 401/403.
    static func version(_ endpoint: Endpoint) async throws -> String {
        struct Version: Decodable { let version: String }
        let url = endpoint.base.appendingPathComponent("v1/version")
        let (data, resp) = try await session.data(for: request(url, endpoint, timeout: 15))
        try check(resp)
        return try JSONDecoder().decode(Version.self, from: data).version
    }

    /// The newest ntfy release on GitHub, e.g. "2.34.0".
    static func latestNtfyRelease() async throws -> String {
        struct Release: Decodable { let tag_name: String }
        let url = URL(string: "https://api.github.com/repos/binwiederhier/ntfy/releases/latest")!
        var req = request(url, nil, timeout: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        try check(resp)
        return try JSONDecoder().decode(Release.self, from: data).tag_name.trimmingPrefix("v").description
    }

    /// Compares dotted version numbers ("2.9.0" < "2.10.0"). Anything after a "-" or "+" is ignored.
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map {
                $0.split(separator: ".").map { Int($0) ?? 0 }
            } ?? []
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Fetches the messages the server still has cached for a topic.
    /// scheduled: also return messages whose delivery is still pending.
    static func history(_ endpoint: Endpoint, topic: String, scheduled: Bool = false) async throws -> [NtfyMessage] {
        var comps = URLComponents(url: endpoint.base.appendingPathComponent(topic).appendingPathComponent("json"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "poll", value: "1"), URLQueryItem(name: "since", value: "all")]
        if scheduled { comps.queryItems?.append(URLQueryItem(name: "scheduled", value: "1")) }
        let (data, resp) = try await session.data(for: request(comps.url!, endpoint, timeout: 20))
        try check(resp)
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n"))
            .compactMap { try? decoder.decode(NtfyMessage.self, from: Data($0)) }
            .filter { NtfyMessage.handledEvents.contains($0.event) }
    }

    /// Publishes as JSON, or with a file: then the file is the body of a PUT to the topic and
    /// everything else goes in query parameters.
    static func publish(_ endpoint: Endpoint, _ body: PublishRequest, file: URL? = nil) async throws -> NtfyMessage {
        let data: Data
        let resp: URLResponse
        if let file {
            guard Config.isValidTopic(body.topic) else { throw NtfyError.badResponse }
            var comps = URLComponents(url: endpoint.base.appendingPathComponent(body.topic), resolvingAgainstBaseURL: false)!
            comps.queryItems = try body.queryItems()
            // URLComponents leaves "+" as is, but the server (Go's url.ParseQuery) reads it as a space.
            comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            var req = request(comps.url!, endpoint, timeout: 300)
            req.httpMethod = "PUT"
            (data, resp) = try await session.upload(for: req, fromFile: file)
        } else {
            var req = request(endpoint.base, endpoint, timeout: 20)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
            (data, resp) = try await session.data(for: req)
        }
        // Errors carry a JSON body like {"code":40035,"http":400,"error":"invalid delay parameter"}.
        struct ServerError: Decodable { let error: String }
        if let http = resp as? HTTPURLResponse, http.statusCode != 200,
           let reason = try? JSONDecoder().decode(ServerError.self, from: data).error, !reason.isEmpty {
            throw NtfyError.rejected("The server refused it: \(reason) (HTTP \(http.statusCode))")
        }
        try check(resp)
        return try JSONDecoder().decode(NtfyMessage.self, from: data)
    }

    /// Deletes a message for every subscriber: the server records a `message_delete` event for
    /// its sequence, which all clients apply (https://docs.ntfy.sh/publish/#deleting-notifications).
    static func delete(_ endpoint: Endpoint, topic: String, sequence: String) async throws {
        guard Config.isValidTopic(topic), Config.isValidTopic(sequence) else { throw NtfyError.badResponse }
        var req = request(endpoint.base.appendingPathComponent(topic).appendingPathComponent(sequence), endpoint, timeout: 15)
        req.httpMethod = "DELETE"
        let (_, resp) = try await session.data(for: req)
        try check(resp)
    }

    /// Performs an `http` action button's request. The caller confirms with the user first.
    static func perform(_ action: NtfyAction) async throws {
        guard let url = action.url.flatMap(Config.webURL), url.scheme?.lowercased() == "https" else {
            throw NtfyError.badResponse
        }
        var req = request(url, nil, timeout: 15)  // never the user's credentials or headers
        let method = (action.method ?? "POST").uppercased()
        guard method.wholeMatch(of: /[A-Z]{1,10}/) != nil else { throw NtfyError.badResponse }
        req.httpMethod = method
        for (name, value) in action.headers ?? [:] where Config.isValidHeaderName(name) && Config.isSafeHeaderValue(value) {
            req.setValue(value, forHTTPHeaderField: name)
        }
        if let body = action.body { req.httpBody = Data(body.utf8) }
        let (_, resp) = try await session.data(for: req)
        try check(resp, accept: 200..<300)
    }

/// Downloads an image with a hard size cap and decodes a bounded-size thumbnail from it.
    static func image(url: URL, endpoint: Endpoint?, maxBytes: Int = 10_000_000,
                      maxPixels: Int = 1200) async throws -> CGImage {
        let (bytes, resp) = try await session.bytes(for: request(url, endpoint, timeout: 30))
        try check(resp)
        guard resp.expectedContentLength <= maxBytes else { throw NtfyError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxBytes { throw NtfyError.tooLarge }
        }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: maxPixels] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { throw NtfyError.badResponse }
        return image
    }
}

/// Keeps one streaming JSON connection open for all topics and reconnects with backoff.
@MainActor
final class Subscriber {
    enum State: Equatable {
        case idle, connecting, connected
        case failed(String)
    }

    var onState: ((State) -> Void)?
    var onEvent: ((NtfyMessage) -> Void)?
    var onError: ((Error) -> Void)?

    private var task: Task<Void, Never>?
    private let decoder = JSONDecoder()

    // Where to resume after a reconnect or restart. Only written to disk by persist(), which runs
    // after the store has saved, so a crash can't record a position past unsaved messages.
    private var lastTime: Int?
    private var seenIDs: [String]
    private var seenSet: Set<String>
    private static let maxSeen = 5000
    private let lastTimeKey: String
    private let seenKey: String

    /// One per server. The server from the single-server versions keeps its saved position.
    init(server: String) {
        let suffix = server == ServerConfig.legacyID ? "" : ".\(server)"
        lastTimeKey = "lastTime" + suffix
        seenKey = "seenIDs" + suffix
        let d = UserDefaults.standard
        lastTime = d.object(forKey: lastTimeKey) as? Int
        seenIDs = d.stringArray(forKey: seenKey) ?? []
        seenSet = Set(seenIDs)
    }

    func start(_ endpoint: Endpoint, topics: [String]) {
        stop()
        let url = endpoint.base.appendingPathComponent(topics.joined(separator: ",")).appendingPathComponent("json")
        task = Task { [weak self] in await self?.run(url: url, endpoint: endpoint) }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func persist() {
        let d = UserDefaults.standard
        d.set(lastTime, forKey: lastTimeKey)
        d.set(seenIDs, forKey: seenKey)
    }

    /// For a different server URL: its clock and message IDs have nothing to do with the old one's.
    func resetPosition() {
        lastTime = nil
        persist()
    }

    /// The server was removed: drop its saved position.
    func forget() {
        stop()
        UserDefaults.standard.removeObject(forKey: lastTimeKey)
        UserDefaults.standard.removeObject(forKey: seenKey)
    }

    private func run(url: URL, endpoint: Endpoint) async {
        var delay: Double = 1
        while !Task.isCancelled {
            onState?(.connecting)
            do {
                var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                if let lastTime { comps.queryItems = [URLQueryItem(name: "since", value: String(lastTime))] }
                let req = Net.request(comps.url!, endpoint, timeout: 90)

                let (bytes, response) = try await Net.session.bytes(for: req)
                try Net.check(response)

                for try await line in bytes.lines {
                    guard !Task.isCancelled else { return }  // don't process buffered lines after stop()
                    guard let msg = try? decoder.decode(NtfyMessage.self, from: Data(line.utf8)) else {
                        Log.network.notice("Skipped an unreadable line from the stream (\(line.utf8.count) bytes)")
                        continue
                    }
                    switch msg.event {
                    case "open":
                        // The server sends `open` (stamped "now") before replaying missed messages,
                        // so it must not move the resume position.
                        Log.network.info("Connected to \(url.host() ?? "?", privacy: .public)")
                        onState?(.connected)
                    case "keepalive":
                        // Keepalives only start after the replay, so the stream is caught up and stable.
                        delay = 1
                        advance(to: msg.time)
                    case _ where NtfyMessage.handledEvents.contains(msg.event):
                        receive(msg)
                        advance(to: msg.time)
                    default:
                        break
                    }
                }
                throw NtfyError.closed
            } catch {
                if Task.isCancelled { return }
                Log.network.error("Connection failed: \(NtfyError.describe(error), privacy: .public); retrying in \(Int(delay))s")
                onError?(error)
                onState?(.failed(NtfyError.describe(error)))
            }
            // Jitter keeps many clients (or a flapping proxy) from retrying in lockstep.
            try? await Task.sleep(for: .seconds(delay * Double.random(in: 1...1.3)))
            delay = min(delay * 2, 60)
        }
    }

    private func advance(to time: Int) {
        if time > (lastTime ?? 0) { lastTime = time }
    }

    private func receive(_ msg: NtfyMessage) {
        // `since` is inclusive at one-second resolution, so drop repeats by ID.
        guard remember(msg.id) else { return }
        onEvent?(msg)
    }

    /// Records IDs obtained elsewhere (history fetches, own publishes) so the stream won't
    /// deliver them again.
    func markSeen(_ ids: [String]) {
        for id in ids { remember(id) }
    }

    @discardableResult
    private func remember(_ id: String) -> Bool {
        guard seenSet.insert(id).inserted else { return false }
        seenIDs.append(id)
        if seenIDs.count > Self.maxSeen {
            seenSet.remove(seenIDs.removeFirst())
        }
        return true
    }
}
