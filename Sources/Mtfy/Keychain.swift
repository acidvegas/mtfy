import Foundation
import Security

/// Generic password items, one per secret: each server's access token or password, and the
/// value of each of its custom headers.
enum Keychain {
    private static let service = Bundle.main.bundleIdentifier ?? "local.mtfy"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Checks for the item without reading the secret.
    static func exists(_ account: String) -> Bool {
        var q = query(account)
        q[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func save(_ secret: String, account: String, label: String) -> OSStatus {
        let data = Data(secret.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var add = query(account)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = label
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

/// Where each server's secrets are kept.
enum Secrets {
    /// The single-server versions stored the credential as "credential"; that server keeps it.
    static func credentialAccount(_ server: String) -> String {
        server == ServerConfig.legacyID ? "credential" : "credential-\(server)"
    }

    static func headerAccount(_ server: String, _ name: String) -> String {
        "header-\(server)-\(name.lowercased())"
    }

    /// Reads the credential and header values. May show a Keychain prompt, so call it off the
    /// main thread.
    static func load(_ server: ServerConfig) -> (credential: String?, headers: [String: String]) {
        let credential = server.auth == .none ? nil : Keychain.read(credentialAccount(server.id))
        var headers: [String: String] = [:]
        for name in server.headerNames {
            if let value = Keychain.read(headerAccount(server.id, name)) { headers[name] = value }
        }
        return (credential, headers)
    }

    static func deleteAll(_ server: ServerConfig) {
        Keychain.delete(credentialAccount(server.id))
        for name in server.headerNames { Keychain.delete(headerAccount(server.id, name)) }
    }
}
