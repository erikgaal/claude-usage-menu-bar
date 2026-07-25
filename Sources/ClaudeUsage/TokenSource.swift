import Foundation

/// Where an account's access token may legitimately come from, and — the part
/// that matters — whether this app is allowed to refresh it.
///
/// Refresh tokens rotate single-use: the moment one is redeemed the previous
/// one is rejected (`invalid_grant`). While the app manages Claude Code's
/// sign-in, both sides hold the *same* chain for the signed-in account, so an
/// uncoordinated refresh here doesn't just waste a round trip — it signs the
/// CLI, the desktop app and the IDE extensions out. That rule is easy to lose
/// in the control flow of `AccountStore.validTokens`, so it lives here as a
/// pure function instead, testable without a store, a Keychain or a network —
/// the same treatment `BestAccount.winners` gets.
enum TokenSource: Equatable {
    /// Our mirrored copy is still valid; use it as-is and touch nothing else.
    case mirrored(StoredTokens)
    /// Claude Code owns this chain. Read through its store, which refreshes
    /// under its own lock. Refreshing here is forbidden.
    case claudeCode
    /// We own this chain outright, and it needs refreshing.
    case ownRefresh(StoredTokens)
    /// Nothing usable to work with.
    case unauthorized

    /// Treat a token expiring within this window as already gone, so a poll
    /// never races the expiry.
    static let refreshWindow: TimeInterval = 120

    static func of(
        accountID: String,
        vault: [String: StoredTokens],
        claudeCodeManages: Bool,
        claudeCodeActiveID: String?,
        now: Date = Date()
    ) -> TokenSource {
        let tokens = vault[accountID]

        // Rotation invalidates the *refresh* token, not an access token
        // already issued, so a copy Claude Code has since rotated past is
        // still perfectly good for reading usage until it expires. Checking
        // this first is what keeps us off Claude Code's Keychain item — and
        // off its authorization prompt — on all but roughly one poll per
        // token lifetime, instead of every five minutes.
        if let tokens, tokens.expiresAt.timeIntervalSince(now) > refreshWindow {
            return .mirrored(tokens)
        }

        // Past here a refresh is needed, so ownership decides who may do it.
        if claudeCodeManages, accountID == claudeCodeActiveID {
            return .claudeCode
        }

        guard let tokens, !tokens.refreshToken.isEmpty else { return .unauthorized }
        return .ownRefresh(tokens)
    }
}
