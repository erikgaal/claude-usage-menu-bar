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

/// The slice of Keychain behavior `AccountStore` needs, as plain load/save/
/// delete so tests can substitute an in-memory fake and never touch the real
/// login keychain. The thin Security wrapper below stays untested by design.
protocol KeychainStoring {
    func save(_ data: Data, account: String) throws
    func load(account: String) -> Data?
    func delete(account: String)
}

/// Production storage backed by the real Keychain wrapper below.
struct SystemKeychain: KeychainStoring {
    func save(_ data: Data, account: String) throws {
        try Keychain.save(data, account: account)
    }

    func load(account: String) -> Data? {
        Keychain.load(account: account)
    }

    func delete(account: String) {
        Keychain.delete(account: account)
    }
}

enum Keychain {
    static let service = "dev.erikgaal.claude-usage"
    /// Single item holding every account's tokens (accountID → StoredTokens),
    /// so unlocking the app costs at most one Keychain prompt.
    static let vaultAccount = "oauth-tokens"

    static func save(_ data: Data, account: String) throws {
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

    static func load(account: String) -> Data? {
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
