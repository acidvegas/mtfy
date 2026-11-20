import SwiftUI

/// Shared layout for the small sheets: icon + title header, content, and Cancel/confirm buttons.
private struct SheetFrame<Content: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
    let confirmTitle: String
    let canConfirm: Bool
    let error: String?
    let busy: Bool
    let onConfirm: () -> Void
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 28))
                    .foregroundStyle(Color.brand)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            content
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConfirm || busy)
            }
        }
        .padding(20)
        .tint(.brand)
    }
}

struct AddTopicSheet: View {
    @ObservedObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var server: String
    @State private var error: String?

    init(store: Store) {
        self.store = store
        // Default to the server of the selected topic, else the first one.
        var server = store.config.servers.first?.id ?? ""
        if case .topic(let ref) = store.selection { server = ref.server }
        _server = State(initialValue: server)
    }

    var body: some View {
        SheetFrame(symbol: "number.square.fill", title: "Subscribe to Topic",
                   subtitle: store.config.server(server)?.label ?? "No server",
                   confirmTitle: "Subscribe",
                   canConfirm: store.config.server(server) != nil && !name.trimmingCharacters(in: .whitespaces).isEmpty,
                   error: error, busy: false, onConfirm: add) {
            if store.config.servers.isEmpty {
                Text("Add a server in Settings first.")
                    .foregroundStyle(.secondary)
            } else {
                if store.config.servers.count > 1 {
                    Picker("Server", selection: $server) {
                        ForEach(store.config.servers) { Text($0.label).tag($0.id) }
                    }
                }
                TextField("topic-name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
            }
        }
        .frame(width: 360)
    }

    private func add() {
        if let err = store.addTopic(name, server: server) {
            error = err
        } else {
            dismiss()
        }
    }
}

struct TopicSettingsSheet: View {
    @ObservedObject var store: Store
    let ref: TopicRef
    @Environment(\.dismiss) private var dismiss
    @State private var settings: TopicSettings
    @State private var mute: MuteChoice?  // nil: keep the current mute as it is

    init(store: Store, ref: TopicRef) {
        self.store = store
        self.ref = ref
        _settings = State(initialValue: store.config.settings(for: ref))
    }

    private var subtitle: String {
        guard store.config.servers.count > 1, let server = store.config.server(ref.server) else { return ref.topic }
        return "\(ref.topic) on \(server.label)"
    }

    /// What the mute picker shows before it's changed.
    private var currentMute: String {
        if settings.muted { return MuteChoice.always.label }
        guard let until = settings.mutedUntil, settings.isMuted() else { return MuteChoice.off.label }
        return "Until " + Date(timeIntervalSince1970: TimeInterval(until)).formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        SheetFrame(symbol: "slider.horizontal.3", title: "Topic Settings", subtitle: subtitle,
                   confirmTitle: "Save", canConfirm: true, error: nil, busy: false) {
            settings.displayName = String(settings.displayName.trimmingCharacters(in: .whitespaces).prefix(64))
            mute?.apply(to: &settings)
            if settings.mutedUntil.map({ TimeInterval($0) <= Date().timeIntervalSince1970 }) == true {
                settings.mutedUntil = nil  // an expired timed mute
            }
            store.setSettings(settings, for: ref)
            dismiss()
        } content: {
            Form {
                TextField("Display name", text: $settings.displayName, prompt: Text(ref.topic))
                LabeledContent("Color") {
                    HStack(spacing: 6) {
                        swatch(nil, TopicColor.color(hex: TopicColor.automatic(for: ref.topic)), "Automatic")
                        ForEach(TopicColor.palette, id: \.hex) { entry in
                            swatch(entry.hex, TopicColor.color(hex: entry.hex), entry.name)
                        }
                        ColorPicker("Custom", selection: Binding(
                            get: { TopicColor.color(hex: settings.color ?? TopicColor.automatic(for: ref.topic)) },
                            set: { settings.color = TopicColor.hex(from: $0) }), supportsOpacity: false)
                            .labelsHidden()
                            .accessibilityLabel("Custom color")
                    }
                }
                Picker("Mute", selection: $mute) {
                    Text(currentMute).tag(MuteChoice?.none)
                    Divider()
                    ForEach([MuteChoice.off] + MuteChoice.timed + [.always], id: \.self) { choice in
                        Text(choice.label).tag(MuteChoice?.some(choice))
                    }
                }
                Picker("Notify for", selection: $settings.minPriority) {
                    Text("All priorities").tag(1)
                    Text("Low and above").tag(2)
                    Text("Default and above").tag(3)
                    Text("High and above").tag(4)
                    Text("Urgent only").tag(5)
                }
                Picker("Keep notifications", selection: $settings.retentionDays) {
                    Text("Same as all topics").tag(Int?.none)
                    Divider()
                    ForEach([0, 1, 7, 30, 90], id: \.self) { days in
                        Text(Self.retentionLabel(days)).tag(Int?.some(days))
                    }
                }
            }
            Text("Muted and filtered messages are still saved here; they just don't pop up.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 520)
    }

    private static func retentionLabel(_ days: Int) -> String {
        switch days {
        case 0: "Forever"
        case 1: "1 day"
        case 7: "1 week"
        default: "\(days) days"
        }
    }

    private func swatch(_ hex: String?, _ color: Color, _ name: String) -> some View {
        let selected = settings.color?.uppercased() == hex?.uppercased()
        return Button { settings.color = hex } label: {
            ZStack {
                Circle().fill(color).frame(width: 18, height: 18)
                if hex == nil {
                    Image(systemName: "sparkles").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                }
            }
            .padding(2)
            .overlay(Circle().strokeBorder(selected ? Color.primary : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
    }
}

/// One action button being written in the compose sheet.
struct ActionDraft: Identifiable {
    let id = UUID()
    var kind = "view"
    var label = ""
    var url = ""
    var value = ""
    var method = "POST"
    var headers = ""  // "Name: value", one per line
    var body = ""
    var clear = false

    init() {}

    init(_ a: NtfyAction) {
        kind = a.action
        label = a.label
        url = a.url ?? ""
        value = a.value ?? ""
        method = (a.method ?? "POST").uppercased()
        headers = (a.headers ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        body = a.body ?? ""
        clear = a.clear ?? false
    }

    /// The action to publish. Throws a message for the user.
    func build() throws(ComposeError) -> NtfyAction {
        let label = label.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { throw ComposeError("Every button needs a label.") }
        var action = NtfyAction(action: kind, label: label, clear: clear ? true : nil)
        switch kind {
        case "copy":
            guard !value.isEmpty else { throw ComposeError("“\(label)” needs text to copy.") }
            action.value = value
        default:
            let link = url.trimmingCharacters(in: .whitespaces)
            guard Config.webURL(link) != nil else { throw ComposeError("“\(label)” needs an http(s) URL.") }
            action.url = link
        }
        if kind == "http" {
            action.method = method == "POST" ? nil : method
            var map: [String: String] = [:]
            for line in headers.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, Config.isValidHeaderName(parts[0]), Config.isSafeHeaderValue(parts[1]) else {
                    throw ComposeError("“\(label)”: write headers as Name: value, one per line.")
                }
                map[parts[0]] = parts[1]
            }
            action.headers = map.isEmpty ? nil : map
            action.body = body.isEmpty ? nil : body
        }
        return action
    }
}

struct ComposeError: Error {
    let text: String
    init(_ text: String) { self.text = text }
}

struct ComposeSheet: View {
    @ObservedObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let editing: StoredMessage?  // an update to a message sent from here
    @State private var topic: TopicRef?
    @State private var title = ""
    @State private var message = ""
    @State private var priority = 3
    @State private var tags = ""
    @State private var click = ""
    @State private var markdown = false
    @State private var delay = ""
    @State private var file: URL?
    @State private var attachURL = ""
    @State private var filename = ""
    @State private var icon = ""
    @State private var email = ""
    @State private var actions: [ActionDraft] = []
    @State private var choosingFile = false
    @State private var sending = false
    @State private var error: String?

    init(store: Store, topic: TopicRef?, editing: StoredMessage? = nil) {
        self.store = store
        self.editing = editing
        _topic = State(initialValue: editing?.ref ?? topic ?? store.config.subscriptions.first?.ref)
        if let m = editing {
            _title = State(initialValue: m.title ?? "")
            _message = State(initialValue: m.message)
            _priority = State(initialValue: m.priority)
            _tags = State(initialValue: m.tags.joined(separator: ", "))
            _click = State(initialValue: m.click ?? "")
            _markdown = State(initialValue: m.isMarkdown)
            _icon = State(initialValue: m.icon ?? "")
            // Re-attaching by URL keeps an uploaded file on the update, until it expires.
            _attachURL = State(initialValue: m.attachmentLink?.absoluteString ?? "")
            _filename = State(initialValue: m.attachmentName ?? "")
            _actions = State(initialValue: m.visibleActions.map(ActionDraft.init))
        }
    }

    private var canSend: Bool {
        topic.map(store.config.isSubscribed) == true
            && (!message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || file != nil
                || !attachURL.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        SheetFrame(symbol: editing == nil ? "square.and.pencil" : "pencil",
                   title: editing == nil ? "New Message" : "Edit Message",
                   subtitle: editing == nil ? (topic.flatMap { store.config.server($0.server)?.label } ?? "")
                       : "Replaces it for everyone subscribed",
                   confirmTitle: editing == nil ? (delay.isEmpty ? "Send" : "Schedule") : "Update",
                   canConfirm: canSend, error: error, busy: sending, onConfirm: send) {
            Form {
                Section {
                    Picker("Topic", selection: $topic) {
                        ForEach(store.config.subscriptions, id: \.ref) { Text(store.fullName($0.ref)).tag(TopicRef?.some($0.ref)) }
                    }
                    .disabled(editing != nil)
                    TextField("Title", text: $title, prompt: Text("Optional"))
                    LabeledContent("Message") {
                        TextEditor(text: $message)
                            .font(.body)
                            .frame(height: 90)
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    }
                    Picker("Priority", selection: $priority) {
                        Text("Min").tag(1)
                        Text("Low").tag(2)
                        Text("Default").tag(3)
                        Text("High").tag(4)
                        Text("Urgent").tag(5)
                    }
                    TextField("Tags", text: $tags, prompt: Text("warning, backup"))
                    TextField("Click URL", text: $click, prompt: Text("https://… or mailto:… (optional)"))
                    Toggle("Format as Markdown", isOn: $markdown)
                }

                Section {
                    TextField("Send later", text: $delay, prompt: Text("30m, 2h, tomorrow 9am (optional)"))
                } footer: {
                    Text("From 10 seconds up to 3 days ahead, in your time zone. Scheduled messages are listed under File → Scheduled Messages.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Attachment") {
                    if let file {
                        LabeledContent("File") {
                            HStack {
                                Text(file.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                Button { self.file = nil } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Remove file")
                            }
                        }
                    } else {
                        LabeledContent("File") {
                            Button("Choose File…") { choosingFile = true }
                        }
                        TextField("Or link", text: $attachURL, prompt: Text("https://… (optional)"))
                    }
                    if file != nil || !attachURL.isEmpty {
                        TextField("File name", text: $filename, prompt: Text(file?.lastPathComponent ?? "Optional"))
                    }
                }

                Section {
                    ForEach($actions) { $draft in
                        ActionEditor(draft: $draft) { actions.removeAll { $0.id == draft.id } }
                    }
                    if actions.count < 3 {
                        Button("Add Button") { actions.append(ActionDraft()) }
                    }
                } header: {
                    Text("Action Buttons")
                }

                Section("More") {
                    TextField("Icon URL", text: $icon, prompt: Text("https://….png (optional)"))
                    TextField("Forward to email", text: $email, prompt: Text("you@example.com (optional)"))
                }
            }
            .formStyle(.grouped)
            .frame(height: 520)
        }
        .frame(width: 540)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { file = url }
        }
    }

    private func send() {
        guard let topic else { return }
        func trimmed(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        let clickURL = trimmed(click)
        guard clickURL.map({ Config.linkURL($0) != nil }) ?? true else {
            error = "Click URL must be an http(s) or mailto: link."
            return
        }
        let attach = file == nil ? trimmed(attachURL) : nil
        guard attach.map({ Config.webURL($0) != nil }) ?? true else {
            error = "The attachment link must be an http(s) URL."
            return
        }
        let iconURL = trimmed(icon)
        guard iconURL.map({ Config.webURL($0) != nil }) ?? true else {
            error = "Icon URL must be an http(s) link to a JPEG or PNG."
            return
        }
        let mail = trimmed(email)
        guard mail.map({ $0.contains("@") && !$0.contains(" ") }) ?? true else {
            error = "Enter a valid email address."
            return
        }
        let tagList = tags.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // The server's limit (https://docs.ntfy.sh/publish/#limitations).
        guard tagList.joined(separator: ",").utf8.count <= 512 else {
            error = "Tags are too long (512 bytes in total at most)."
            return
        }
        var built: [NtfyAction] = []
        do {
            built = try actions.map { try $0.build() }
        } catch let e as ComposeError {
            error = e.text
            return
        } catch {
            return
        }
        let when = trimmed(delay)
        let request = PublishRequest(
            topic: topic.topic,
            message: message,
            title: trimmed(title),
            priority: priority == 3 ? nil : priority,
            tags: tagList.isEmpty ? nil : tagList,
            click: clickURL,
            markdown: markdown ? true : nil,
            actions: built.isEmpty ? nil : built,
            attach: attach,
            filename: (file != nil || attach != nil) ? trimmed(filename) ?? file?.lastPathComponent : nil,
            icon: iconURL,
            email: mail,
            delay: when,
            timezone: when == nil ? nil : TimeZone.current.identifier,
            sequenceID: editing?.sequence)
        sending = true
        error = nil
        Task {
            defer { sending = false }
            do {
                try await store.publish?(topic, request, file)
                dismiss()
            } catch {
                self.error = NtfyError.describe(error)
            }
        }
    }
}

private struct ActionEditor: View {
    @Binding var draft: ActionDraft
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Type", selection: $draft.kind) {
                    Text("Open link").tag("view")
                    Text("Copy text").tag("copy")
                    Text("HTTP request").tag("http")
                }
                .labelsHidden()
                .fixedSize()
                TextField("Label", text: $draft.label, prompt: Text("Button label"))
                    .labelsHidden()
                Button(action: onRemove) { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove button")
            }
            if draft.kind == "copy" {
                TextField("Text", text: $draft.value, prompt: Text("Text to copy"))
            } else {
                HStack {
                    if draft.kind == "http" {
                        Picker("Method", selection: $draft.method) {
                            ForEach(["POST", "GET", "PUT", "DELETE"], id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    TextField("URL", text: $draft.url, prompt: Text("https://…"))
                        .labelsHidden()
                }
            }
            if draft.kind == "http" {
                TextField("Headers", text: $draft.headers, prompt: Text("Name: value, one per line"), axis: .vertical)
                    .lineLimit(1...4)
                TextField("Body", text: $draft.body, prompt: Text("Request body (optional)"), axis: .vertical)
                    .lineLimit(1...4)
            }
            Toggle("Clear the notification when tapped", isOn: $draft.clear)
                .font(.caption)
        }
        .padding(.vertical, 2)
    }
}

/// Scheduled messages that haven't been delivered yet, with a way to cancel each.
struct ScheduledSheet: View {
    @ObservedObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var items: [(ref: TopicRef, message: NtfyMessage)] = []
    @State private var errors: [String] = []
    @State private var loading = true
    @State private var cancelError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "clock.badge")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.brand)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scheduled Messages").font(.headline)
                    Text("Waiting to be delivered on your topics").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if items.isEmpty {
                    ContentUnavailableView("Nothing Scheduled", systemImage: "clock",
                                           description: Text("Use “Send later” in New Message to schedule one."))
                } else {
                    List {
                        ForEach(items, id: \.message.id) { item in row(item) }
                    }
                    .listStyle(.inset)
                }
            }
            .frame(height: 320)
            ForEach(errors + (cancelError.map { [$0] } ?? []), id: \.self) { e in
                Label(e, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Refresh") { Task { await load() } }
                    .disabled(loading)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .tint(.brand)
        .task { await load() }
    }

    private func row(_ item: (ref: TopicRef, message: NtfyMessage)) -> some View {
        let m = item.message
        let date = Date(timeIntervalSince1970: TimeInterval(m.time))
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(m.title ?? m.message ?? "").lineLimit(1).font(.body.weight(.medium))
                if m.title != nil, let text = m.message { Text(text).lineLimit(2).foregroundStyle(.secondary) }
                Text("\(store.fullName(item.ref)) · \(date.formatted(date: .abbreviated, time: .shortened)) (\(date.formatted(.relative(presentation: .named))))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel Delivery", role: .destructive) { Task { await cancel(item) } }
                .controlSize(.small)
        }
        .padding(.vertical, 3)
    }

    private func load() async {
        loading = true
        let (found, failures) = await store.fetchScheduled?() ?? ([], [])
        items = found
        errors = failures
        loading = false
    }

    private func cancel(_ item: (ref: TopicRef, message: NtfyMessage)) async {
        do {
            try await store.cancelScheduled?(item.ref, item.message.sequence)
            items.removeAll { $0.message.id == item.message.id }
            cancelError = nil
        } catch {
            cancelError = "Couldn't cancel: \(NtfyError.describe(error))"
        }
    }
}
