import AppKit

/// Runs a message's action buttons, from the message list or a notification banner.
@MainActor
enum ActionRunner {
    static func run(_ action: NtfyAction, for message: StoredMessage, store: Store) {
        switch action.action {
        case "view":
            guard let url = action.url.flatMap(Config.webURL) else {
                return alert("Can't open this link", "Only http and https links are opened.")
            }
            NSWorkspace.shared.open(url)
            finish(action, message, store)
        case "copy":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(action.value ?? "", forType: .string)
            finish(action, message, store)
        case "http":
            guard confirm(action) else { return }
            Task {
                do {
                    try await Net.perform(action)
                    finish(action, message, store)
                } catch {
                    alert("“\(action.label)” failed", NtfyError.describe(error))
                }
            }
        default:
            break
        }
    }

    static func symbol(for action: NtfyAction) -> String {
        switch action.action {
        case "view": "arrow.up.right.square"
        case "copy": "doc.on.doc"
        default: "paperplane"
        }
    }

    private static func finish(_ action: NtfyAction, _ message: StoredMessage, _ store: Store) {
        if action.clear == true { store.setRead([message.id], true) }
    }

    /// http actions send a request chosen by whoever published the message, so show exactly
    /// what will be sent before doing it.
    private static func confirm(_ action: NtfyAction) -> Bool {
        guard let url = action.url.flatMap(Config.webURL), url.scheme?.lowercased() == "https" else {
            alert("Can't run “\(action.label)”", "Only https requests are allowed.")
            return false
        }
        var details = "Host: \(url.host() ?? "?")\n\((action.method ?? "POST").uppercased()) \(url.absoluteString)"
        let headers = (action.headers ?? [:]).sorted { $0.key < $1.key }
        if !headers.isEmpty {
            details += "\n\nHeaders:\n" + headers.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        }
        if let body = action.body, !body.isEmpty {
            details += "\n\nBody:\n" + (body.count > 1000 ? body.prefix(1000) + "… (\(body.count) characters)" : body)
        }
        let alert = NSAlert()
        alert.messageText = "Run “\(action.label)”?"
        alert.informativeText = "This sends a request on behalf of the message:\n\n" + details
        alert.addButton(withTitle: "Send Request")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate()
        alert.runModal()
    }
}
