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

    /// `service` is a parameter rather than a constant because the app also
    /// reads and writes Claude Code's own item (`Claude Code-credentials`) when
    /// it manages the CLI's sign-in.
    ///
    /// Updating a foreign item this way is safe: `SecItemUpdate` leaves the
    /// item's ACL intact (verified against a restricted probe item), and the
    /// `Encrypt` authorization is granted to every application anyway, so
    /// writes never prompt. Reads are the operation that costs an
    /// authorization — see `AccountStore.hasUsableToken`.
    static func save(_ data: Data, account: String, service: String = Keychain.service) throws {
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
