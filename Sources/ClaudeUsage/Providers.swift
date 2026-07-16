import Foundation

enum ProviderID: String, Codable, CaseIterable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}

/// One subscription-based AI provider (Claude, Codex, …). Implementations do
/// browser OAuth login, token refresh, and usage fetching; everything else in
/// the app is provider-agnostic.
protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    /// Menu entry title for adding an account, e.g. "Claude (subscription)".
    var accountKind: String { get }
    func login() async throws -> LoginResult
    func refresh(tokens: StoredTokens) async throws -> StoredTokens
    func fetchLimits(accessToken: String, accountID: String) async throws -> [LimitStatus]
}

enum Providers {
    static let claude = ClaudeProvider()
    static let codex = CodexProvider()

    static func provider(for id: ProviderID) -> any UsageProvider {
        switch id {
        case .claude: return claude
        case .codex: return codex
        }
    }
}

struct ClaudeProvider: UsageProvider {
    let id = ProviderID.claude
    let accountKind = "Add Claude Account…"

    func login() async throws -> LoginResult {
        try await OAuthClient.login()
    }

    func refresh(tokens: StoredTokens) async throws -> StoredTokens {
        try await OAuthClient.refresh(refreshToken: tokens.refreshToken).tokens
    }

    func fetchLimits(accessToken: String, accountID: String) async throws -> [LimitStatus] {
        try await UsageAPI.fetchLimits(accessToken: accessToken)
    }
}

/// Decodes the payload segment of a JWT without verifying the signature —
/// good enough for reading our own token's claims (account id, email, expiry).
enum JWT {
    static func claims(_ token: String?) -> [String: Any]? {
        guard let token else { return nil }
        let segments = token.components(separatedBy: ".")
        guard segments.count >= 2 else { return nil }
        var payload =
            segments[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func expiry(_ token: String?) -> Date? {
        guard let exp = claims(token)?["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}
