import Foundation
import Security

enum KeychainError: LocalizedError {
    case status(OSStatus)

    var errorDescription: String? {
        if case .status(let code) = self {
            return "Keychain error \(code)"
        }
        return nil
    }
}

enum Keychain {
    static let service = "dev.erikgaal.claude-usage"
    /// Single item holding every account's tokens (accountID → StoredTokens),
    /// so unlocking the app costs at most one Keychain prompt.
    static let vaultAccount = "oauth-tokens"

    /// Only ever writes this app's own items, and takes no `service` so it
    /// can't be pointed at anyone else's.
    ///
    /// Writing a *foreign* item from here is not safe, however harmless it
    /// looks: a write from a third-party-signed binary resets the item's
    /// partition list to this app's `teamid:`, and the owner loses its silent
    /// read. `ClaudeCodeStore.writeCredentials` explains the mechanism and
    /// drives `/usr/bin/security` instead.
    static func save(_ data: Data, account: String) throws {
        let service = Keychain.service
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]

        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    /// Updates an item belonging to another application, and *only* updates:
    /// there is deliberately no create-on-missing path here, because an item
    /// this app creates gets an ACL naming only this app, which would lock the
    /// real owner out of credentials it still writes to — broken in a way that
    /// looks fine from its side. Missing is the caller's problem to report.
    static func saveForeign(_ data: Data, account: String, service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemUpdate(
            query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    /// Reads may target a foreign `service` — Claude Code's item, when the app
    /// manages the CLI's sign-in. Unlike a write, a read leaves the partition
    /// list alone; it costs this app one authorization the first time, and
    /// nothing thereafter.
    static func load(account: String, service: String = Keychain.service) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
