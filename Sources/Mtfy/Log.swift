import Foundation
import os

/// Unified logging. Watch it live with:
///     log stream --predicate 'subsystem == "local.mtfy"' --level debug
/// Never log credentials or message contents.
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "local.mtfy"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let network = Logger(subsystem: subsystem, category: "network")
    static let storage = Logger(subsystem: subsystem, category: "storage")
    static let notifications = Logger(subsystem: subsystem, category: "notifications")
}

/// Something wrong that the user should know about, shown in a bar at the top of the window.
struct Problem: Identifiable, Equatable {
    enum Kind: String {
        case notificationsDisabled, authFailed, missingCredentials, disconnected
        case loadFailed, saveFailed, historyFailed, settingsUnreadable
    }

    enum Action: Equatable {
        case openNotificationSettings, openSettings, retry
        case reveal(URL)

        var title: String {
            switch self {
            case .openNotificationSettings: "Open System Settings"
            case .openSettings: "Open Settings"
            case .retry: "Retry Now"
            case .reveal: "Show in Finder"
            }
        }
    }

    let kind: Kind
    var server: String? = nil  // for connection problems: which server
    var title: String
    var detail: String
    var action: Action?

    var id: String { "\(kind.rawValue)|\(server ?? "")" }

    /// Serious problems also get one desktop notification, so they're noticed with the window closed.
    var postsAlert: Bool { ![.notificationsDisabled, .historyFailed].contains(kind) }
}
