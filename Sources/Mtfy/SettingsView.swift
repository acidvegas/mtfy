import AppKit
import os
import ServiceManagement
import SwiftUI

/// One editable custom header. Saved values are never loaded back into the UI.
struct HeaderRow: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var value = ""
    var saved = false  // has a value in the Keychain under this name
}

@MainActor
final class ServerEditorModel: ObservableObject {
    @Published var url: String
    @Published var auth: AuthType
    @Published var username: String
    @Published var secret = ""  // only ever holds a newly typed value
    @Published var headers: [HeaderRow]
    @Published var pinnedCertificate: String?
    @Published var untrustedCertificate: String?  // offered for trust after a failed test
    @Published var status = ""
    @Published var statusIsError = false
    @Published var testing = false

    let isNew: Bool
    private let original: ServerConfig
    private let hasStoredSecret: Bool

    init(server: ServerConfig?) {
        let s = server ?? ServerConfig(url: "")
        original = s
        isNew = server == nil
        url = s.url
        auth = s.auth
        username = s.username
        headers = s.headerNames.map { HeaderRow(name: $0, saved: true) }
        pinnedCertificate = s.pinnedCertificate
        hasStoredSecret = server != nil && Keychain.exists(Secrets.credentialAccount(s.id))
    }

    var id: String { original.id }

    /// Saved secrets only apply to the server URL they were saved for; they must never be sent
    /// to a newly entered server.
    private var sameServer: Bool { !isNew && Config.parseServer(url) == original.baseURL }

    var storedSecretUsable: Bool {
        hasStoredSecret && sameServer && auth == original.auth && auth != .none
    }

    func storedHeaderUsable(_ row: HeaderRow) -> Bool {
        row.saved && sameServer && original.headerNames.contains { $0.caseInsensitiveCompare(row.name) == .orderedSame }
    }

    var isInsecure: Bool { Config.parseServer(url)?.scheme == "http" }

    private func validated() -> (server: ServerConfig, secret: String?, headers: [String: String])? {
        guard let parsed = Config.parseServer(url) else {
            report("Server must be an http:// or https:// URL with no query or credentials.", error: true)
            return nil
        }
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if auth == .basic, user.isEmpty || user.contains(":") || !Config.isSafeHeaderValue(user) {
            report("Enter a valid username.", error: true)
            return nil
        }
        let s = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Config.isSafeHeaderValue(s) else {
            report("Credential contains invalid characters.", error: true)
            return nil
        }
        if auth != .none, s.isEmpty, !storedSecretUsable {
            report(auth == .token ? "Enter an access token." : "Enter a password.", error: true)
            return nil
        }

        var names: [String] = []
        var values: [String: String] = [:]
        for row in headers {
            let name = row.name.trimmingCharacters(in: .whitespaces)
            let value = row.value.trimmingCharacters(in: .whitespaces)
            if name.isEmpty && value.isEmpty { continue }
            guard Config.isValidHeaderName(name) else {
                report("“\(name)” isn't a valid header name.", error: true)
                return nil
            }
            guard !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
                report("The header \(name) is listed twice.", error: true)
                return nil
            }
            if auth != .none, name.caseInsensitiveCompare("Authorization") == .orderedSame {
                report("Remove the Authorization header, or set Authentication to None.", error: true)
                return nil
            }
            guard Config.isSafeHeaderValue(value) else {
                report("The value of \(name) contains invalid characters.", error: true)
                return nil
            }
            if value.isEmpty {
                guard storedHeaderUsable(row) else {
                    report("Enter a value for \(name).", error: true)
                    return nil
                }
            } else {
                values[name] = value
            }
            names.append(name)
        }

        var server = original
        server.url = parsed.absoluteString
        server.auth = auth
        server.username = auth == .basic ? user : ""
        server.headerNames = names
        server.pinnedCertificate = parsed.scheme == "https" ? pinnedCertificate : nil
        return (server, s.isEmpty ? nil : s, values)
    }

    /// Returns true when the server was saved.
    func save(_ store: Store) -> Bool {
        guard let (server, newSecret, newHeaders) = validated() else { return false }
        if let err = store.onSaveServer?(server, newSecret, newHeaders) {
            report(err, error: true)
            return false
        }
        return true
    }

    func test() {
        guard let (server, newSecret, newHeaders) = validated(), let base = server.baseURL else { return }
        testing = true
        untrustedCertificate = nil
        report("Testing…", error: false)
        let useStoredSecret = newSecret == nil && server.auth != .none
        let storedHeaders = server.headerNames.filter { newHeaders[$0] == nil }
        Task {
            defer { testing = false }
            // Stored values are read off the main thread, since the Keychain may prompt.
            let stored = await Task.detached {
                (useStoredSecret ? Keychain.read(Secrets.credentialAccount(server.id)) : nil,
                 storedHeaders.compactMap { name in Keychain.read(Secrets.headerAccount(server.id, name)).map { (name, $0) } })
            }.value
            let endpoint = Endpoint(base: base,
                                    authorization: Config.authorization(server.auth, username: server.username,
                                                                        secret: newSecret ?? stored.0),
                                    headers: newHeaders.merging(stored.1) { new, _ in new })
            // A session of its own, trusting the certificate pinned here rather than the saved one.
            let seen = OSAllocatedUnfairLock<String?>(initialState: nil)
            let pin = server.pinnedCertificate
            let session = Net.makeSession(SessionDelegate(pin: { _ in pin }, sawUntrusted: { fp in seen.withLock { $0 = fp } }))
            defer { session.finishTasksAndInvalidate() }
            do {
                let user = try await Net.account(endpoint, session: session)
                report(user == "*" ? "Connected anonymously." : "Signed in as \(user).", error: false)
            } catch {
                if let fingerprint = seen.withLock({ $0 }), server.baseURL?.scheme == "https" {
                    untrustedCertificate = fingerprint
                    report("The server's certificate isn't trusted.", error: true)
                } else {
                    report(NtfyError.describe(error), error: true)
                }
            }
        }
    }

    func trustCertificate() {
        pinnedCertificate = untrustedCertificate
        untrustedCertificate = nil
        report("Certificate trusted. Test again, or save.", error: false)
    }

    private func report(_ text: String, error: Bool) {
        status = text
        statusIsError = error
    }
}

struct SettingsView: View {
    @ObservedObject var store: Store
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var copied = false
    @State private var editing: EditTarget?
    @Environment(\.dismiss) private var dismiss

    private struct EditTarget: Identifiable {
        let id = UUID()
        let server: ServerConfig?
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Settings")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], 20)
            Form {
                Section {
                    ForEach(store.config.servers) { server in
                        serverRow(server)
                    }
                    Button("Add Server…") { editing = EditTarget(server: nil) }
                } header: {
                    Text("Servers")
                } footer: {
                    Text("Tokens, passwords and custom header values are stored in your login Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("General") {
                    Toggle("Launch at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                    if let loginError {
                        Text(loginError).font(.caption).foregroundStyle(.red)
                    }
                    Toggle("Pause notifications", isOn: $store.paused)
                    Toggle("Delete on server too", isOn: Binding(
                        get: { store.config.deleteOnServer }, set: { store.setDeleteOnServer($0) }))
                    Picker("Keep notifications", selection: Binding(
                        get: { store.config.retentionDays }, set: { store.setRetention(days: $0) })) {
                        RetentionOptions()
                    }
                }

                Section("Diagnostics") {
                    LabeledContent("Status", value: store.statusText)
                    LabeledContent("Last connected",
                                   value: store.lastConnected?.formatted(date: .abbreviated, time: .standard) ?? "Never")
                    if let error = store.lastError {
                        LabeledContent("Last error", value: error)
                    }
                    LabeledContent("Notifications", value: store.notificationStatus)
                    LabeledContent("Saved", value: "\(store.messages.count) notifications")
                    HStack {
                        Button("Copy Diagnostics") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(store.diagnostics(), forType: .string)
                            copied = true
                        }
                        if copied { Text("Copied").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Retry Connection") { store.onRetry?() }
                    }
                    Text("No tokens, passwords, header values, topic names or message contents are included.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Load images from other servers", isOn: Binding(
                        get: { store.config.loadExternalImages }, set: { store.setLoadExternalImages($0) }))
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Images and icons from your ntfy servers always load. Loading them from other hosts reveals your IP address to those hosts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 18)
        }
        .tint(.brand)
        .frame(width: 520, height: 680)
        .sheet(item: $editing) { target in
            ServerEditor(store: store, model: ServerEditorModel(server: target.server))
        }
    }

    private func serverRow(_ server: ServerConfig) -> some View {
        let topics = store.config.topics(on: server.id).count
        return HStack {
            Image(systemName: server.isInsecure ? "lock.open" : "lock")
                .foregroundStyle(server.isInsecure ? Color.orange : Color.secondary)
                .help(server.isInsecure ? "Plain http: not encrypted" : "https")
            VStack(alignment: .leading, spacing: 1) {
                Text(server.label)
                Text("\(server.auth.label) · \(topics == 1 ? "1 topic" : "\(topics) topics")"
                     + (store.serverVersions[server.id].map { " · ntfy \($0)" } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let update = store.availableUpdate(server.id) {
                    Link("ntfy \(update) is available", destination: URL(string: "https://github.com/binwiederhier/ntfy/releases/latest")!)
                        .font(.caption)
                }
            }
            Spacer()
            Button("Edit…") { editing = EditTarget(server: server) }
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        guard on != (service.status == .enabled) else { return }
        do {
            try on ? service.register() : service.unregister()
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            launchAtLogin = service.status == .enabled
        }
    }
}

/// The "Keep notifications" choices, shared by the global and per-topic pickers.
struct RetentionOptions: View {
    var body: some View {
        Text("Forever").tag(0)
        Text("1 day").tag(1)
        Text("1 week").tag(7)
        Text("30 days").tag(30)
        Text("90 days").tag(90)
    }
}

private struct ServerEditor: View {
    @ObservedObject var store: Store
    @StateObject var model: ServerEditorModel
    @State private var confirmingRemove = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text(model.isNew ? "Add Server" : "Edit Server")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], 20)
            Form {
                Section {
                    TextField("Server URL", text: $model.url, prompt: Text("https://ntfy.sh"))
                        .autocorrectionDisabled()
                    if model.isInsecure {
                        Label("Plain http isn't encrypted: anyone on the network can read your notifications"
                              + (model.auth == .none ? "." : " and your login."),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Picker("Authentication", selection: $model.auth) {
                        ForEach(AuthType.allCases) { Text($0.label).tag($0) }
                    }
                    if model.auth == .basic {
                        TextField("Username", text: $model.username)
                            .autocorrectionDisabled()
                    }
                    if model.auth != .none {
                        SecureField(model.auth == .token ? "Access token" : "Password", text: $model.secret,
                                    prompt: Text(model.storedSecretUsable ? "Saved in Keychain" : "Required"))
                    }
                }

                Section {
                    ForEach($model.headers) { $row in
                        HStack {
                            TextField("Name", text: $row.name, prompt: Text("X-Header"))
                                .labelsHidden()
                                .autocorrectionDisabled()
                            SecureField("Value", text: $row.value,
                                        prompt: Text(model.storedHeaderUsable(row) ? "Saved in Keychain" : "Value"))
                                .labelsHidden()
                            Button { model.headers.removeAll { $0.id == row.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove header")
                        }
                    }
                    Button("Add Header") { model.headers.append(HeaderRow(name: "")) }
                } header: {
                    Text("Custom Headers")
                } footer: {
                    Text("Sent with every request to this server, for example to get through a login proxy.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !model.isInsecure, model.pinnedCertificate != nil || model.untrustedCertificate != nil {
                    Section("Certificate") {
                        if let fp = model.untrustedCertificate {
                            Text("Only trust this certificate if this fingerprint matches the one on your server:")
                                .font(.caption)
                            Text("SHA-256 " + Certificates.display(fp))
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            Button("Trust This Certificate") { model.trustCertificate() }
                        } else if let fp = model.pinnedCertificate {
                            Text("Trusted self-signed certificate")
                            Text("SHA-256 " + Certificates.display(fp))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Button("Stop Trusting") { model.pinnedCertificate = nil }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack(spacing: 8) {
                if !model.isNew {
                    Button("Remove…", role: .destructive) { confirmingRemove = true }
                }
                if !model.status.isEmpty {
                    Image(systemName: model.statusIsError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                        .foregroundStyle(model.statusIsError ? Color.red : Color.green)
                        .opacity(model.testing ? 0 : 1)
                    Text(model.status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Test Connection", action: model.test)
                    .disabled(model.testing)
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { if model.save(store) { dismiss() } }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 18)
        }
        .tint(.brand)
        .frame(width: 560, height: 560)
        .confirmationDialog("Remove \(Config.parseServer(model.url).map(Config.hostLabel) ?? "this server")?",
                            isPresented: $confirmingRemove) {
            Button("Remove Server", role: .destructive) {
                store.onRemoveServer?(model.id)
                dismiss()
            }
        } message: {
            let n = store.config.topics(on: model.id).count
            Text(n == 0 ? "Its saved login is deleted from the Keychain."
                 : "Its \(n == 1 ? "topic" : "\(n) topics") and their notifications are removed from this Mac, and its saved login is deleted from the Keychain.")
        }
    }
}
