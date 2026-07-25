import Foundation

/// Reads and writes the credential store Claude Code itself uses, so the app
/// can switch which account the CLI is signed in as without the browser OAuth
/// cycle. The desktop app and IDE extensions read the same store, so they
/// follow along.
///
/// Everything here mirrors Claude Code 2.1.220, verified against the shipped
/// binary:
///
/// - Credentials are a Keychain generic password, service
///   `Claude Code-credentials`, account = the macOS short username. The JSON
///   payload nests the tokens under `claudeAiOauth`.
/// - Identity metadata lives *separately*, in `~/.claude.json` under
///   `oauthAccount` — swapping the token alone leaves `/status` naming the
///   previous account.
/// - Every mutation runs under a `.storage-write` lockfile in the Claude config
///   dir, as *invalidate → re-read → modify → write*, and credentials are
///   cached for only 30 seconds before being re-read.
///
/// That protocol is load-bearing rather than incidental. Refresh tokens rotate
/// on every use and the previous one is rejected immediately (`invalid_grant`),
/// so two processes refreshing the same chain would sign each other out. Taking
/// the same lock and re-reading inside it is what lets this app participate
/// safely alongside any number of running `claude` sessions — and it's why a
/// swap reaches those sessions instead of only new ones.
enum ClaudeCodeSession {

    // MARK: - Locations

    static let credentialsService = "Claude Code-credentials"

    /// Claude Code keys its Keychain item by the macOS short username.
    static var credentialsAccount: String { NSUserName() }

    /// Mirrors the binary's `gK()`: an explicit secure-storage override wins,
    /// then the general config-dir override, then `~/.claude`. An override set
    /// to the empty string means "use the default", as it does there.
    static var configDirectory: URL {
        let environment = ProcessInfo.processInfo.environment
        for key in ["CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDE_CONFIG_DIR"] {
            if let value = environment[key], !value.isEmpty {
                return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
    }

    /// `~/.claude.json` — the main config, holding `oauthAccount`. Note this is
    /// the sibling *file*, not a file inside `configDirectory`.
    static var configFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
    }

    /// proper-lockfile represents a held lock as a *directory* at `<name>.lock`.
    static var lockFile: URL {
        configDirectory.appendingPathComponent(".storage-write.lock", isDirectory: true)
    }

    // MARK: - Payload keys

    static let oauthKey = "claudeAiOauth"
    /// Per-account material, replaced on every switch. Everything else in the
    /// payload (`scopes`, `subscriptionType`, anything Anthropic adds later)
    /// belongs to the profile and is carried across verbatim.
    static let tokenKeys = ["accessToken", "refreshToken", "expiresAt"]

    // MARK: - Expiry units

    /// Claude Code writes `expiresAt` as epoch milliseconds. We infer the unit
    /// from the value we read and write back in the same one, so an install
    /// that ever used seconds keeps round-tripping cleanly instead of being
    /// silently shifted by three orders of magnitude.
    enum ExpiresAtUnit {
        case seconds
        case milliseconds

        /// Between plausible second-timestamps (~1.8e9 today) and plausible
        /// millisecond-timestamps (~1.8e12), so neither is misread.
        static let threshold: Double = 1e11

        static func infer(from raw: Double) -> ExpiresAtUnit {
            raw >= threshold ? .milliseconds : .seconds
        }

        func date(from raw: Double) -> Date {
            switch self {
            case .seconds: return Date(timeIntervalSince1970: raw)
            case .milliseconds: return Date(timeIntervalSince1970: raw / 1000)
            }
        }

        func raw(from date: Date) -> Double {
            switch self {
            case .seconds: return date.timeIntervalSince1970.rounded()
            case .milliseconds: return (date.timeIntervalSince1970 * 1000).rounded()
            }
        }
    }

    // MARK: - Credential payload (pure)

    /// Pulls the tokens out of a payload, reporting the unit they were stored
    /// in so a later write can match it. Nil when the payload isn't shaped the
    /// way we expect — callers treat that as "don't touch this", which is the
    /// safe response to a format change.
    static func tokens(from payload: [String: Any]) -> (tokens: StoredTokens, unit: ExpiresAtUnit)? {
        guard let oauth = payload[oauthKey] as? [String: Any],
            let accessToken = oauth["accessToken"] as? String, !accessToken.isEmpty,
            let refreshToken = oauth["refreshToken"] as? String,
            let rawExpiry = oauth["expiresAt"] as? Double
        else { return nil }

        let unit = ExpiresAtUnit.infer(from: rawExpiry)
        let stored = StoredTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: unit.date(from: rawExpiry))
        return (stored, unit)
    }

    /// The payload with per-account token material stripped — what we keep as
    /// an account's profile so a later switch can restore fields we never
    /// synthesize ourselves.
    static func extras(from payload: [String: Any]) -> [String: Any] {
        var stripped = payload
        if var oauth = stripped[oauthKey] as? [String: Any] {
            for key in tokenKeys { oauth.removeValue(forKey: key) }
            stripped[oauthKey] = oauth
        }
        return stripped
    }

    /// Rebuilds a full payload from a profile's extras plus live tokens.
    static func payload(
        extras: [String: Any], tokens: StoredTokens, unit: ExpiresAtUnit
    ) -> [String: Any] {
        var payload = extras
        var oauth = payload[oauthKey] as? [String: Any] ?? [:]
        oauth["accessToken"] = tokens.accessToken
        oauth["refreshToken"] = tokens.refreshToken
        oauth["expiresAt"] = unit.raw(from: tokens.expiresAt)
        payload[oauthKey] = oauth
        return payload
    }

    /// Extras for an account we've never captured from Claude Code. The scopes
    /// are the ones our own tokens were actually minted with, so this is
    /// accurate by construction rather than a guess. `subscriptionType` is
    /// deliberately omitted — Claude Code refetches the profile and fills in
    /// what it needs, and inventing a wrong value is worse than absence.
    static func synthesizedExtras() -> [String: Any] {
        [oauthKey: ["scopes": OAuthConfig.scopes]]
    }

    // MARK: - Config file (pure)

    static func activeAccountUUID(inConfig config: [String: Any]) -> String? {
        (config["oauthAccount"] as? [String: Any])?["accountUuid"] as? String
    }

    /// Minimal identity block. Claude Code refetches the full profile when
    /// `profileFetchedAt` is stale and rewrites this itself, so writing only
    /// what we genuinely know keeps `/status` correct immediately and lets the
    /// rest self-heal — no need to invent `seatTier`, tiers or billing fields.
    static func oauthAccount(for account: AccountMeta) -> [String: Any] {
        var block: [String: Any] = [
            "accountUuid": account.id,
            "emailAddress": account.email,
        ]
        if let organization = account.organizationName {
            block["organizationName"] = organization
        }
        return block
    }

    /// An identity block we captured earlier, readied for writing back. The
    /// fetch timestamp is dropped so Claude Code treats the record as stale and
    /// refreshes it against the API rather than trusting however old our copy
    /// is — the restored fields are that account's real ones, just possibly out
    /// of date.
    static func identityForRestore(_ block: [String: Any]) -> [String: Any] {
        var restored = block
        restored.removeValue(forKey: "profileFetchedAt")
        return restored
    }

    /// Replaces just the identity block, leaving the rest of `~/.claude.json`
    /// (projects, history, onboarding state — the bulk of the file) untouched.
    static func config(
        _ config: [String: Any], settingOAuthAccount block: [String: Any]
    ) -> [String: Any] {
        var updated = config
        updated["oauthAccount"] = block
        return updated
    }
}

// MARK: - Write lock

/// A proper-lockfile-compatible hold on Claude Code's `.storage-write` lock,
/// so app writes serialize against the CLI's rather than racing them.
///
/// proper-lockfile represents a held lock as a directory (mkdir is atomic) and
/// treats one older than `staleInterval` as abandoned. These constants match
/// the options in the binary: 10 retries, 100–1000 ms backoff, 15 s stale.
struct StorageWriteLock {
    static let staleInterval: TimeInterval = 15
    static let maxRetries = 10
    static let minBackoff: TimeInterval = 0.1
    static let maxBackoff: TimeInterval = 1.0

    private let url: URL
    /// Touches the lock's mtime while we hold it. Without this, holding the
    /// lock across a token refresh (a network round trip) risks another
    /// process deciding at 15 s that we died and stealing it mid-write.
    private let keepAlive: DispatchSourceTimer

    /// Pure so the staleness rule can be tested without touching a filesystem.
    static func isStale(modifiedAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(modifiedAt) > staleInterval
    }

    static func backoff(attempt: Int) -> TimeInterval {
        min(maxBackoff, minBackoff * pow(2, Double(attempt)))
    }

    /// Async so waiting for a busy lock suspends rather than blocking a thread
    /// — the caller may hold this across a token refresh.
    static func acquire(at url: URL = ClaudeCodeSession.lockFile) async throws -> StorageWriteLock {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        for attempt in 0...maxRetries {
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
                return StorageWriteLock(url: url, keepAlive: startKeepAlive(for: url))
            } catch {
                // Someone holds it. Reclaim it if they died mid-write, else wait.
                let modified = (try? fileManager.attributesOfItem(atPath: url.path))?[
                    .modificationDate] as? Date
                if let modified, isStale(modifiedAt: modified) {
                    try? fileManager.removeItem(at: url)
                    continue
                }
                if attempt == maxRetries { break }
                try? await Task.sleep(
                    nanoseconds: UInt64(backoff(attempt: attempt) * 1_000_000_000))
            }
        }
        throw ClaudeCodeError.lockUnavailable
    }

    /// Refreshes the mtime at half the stale interval, the same cadence
    /// proper-lockfile's own updater uses.
    private static func startKeepAlive(for url: URL) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + staleInterval / 2, repeating: staleInterval / 2)
        timer.setEventHandler {
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()], ofItemAtPath: url.path)
        }
        timer.resume()
        return timer
    }

    func release() {
        keepAlive.cancel()
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Errors

enum ClaudeCodeError: LocalizedError {
    case lockUnavailable
    case notSignedIn
    case unrecognizedFormat
    case noTokens

    var errorDescription: String? {
        switch self {
        case .lockUnavailable:
            return "Claude Code is busy writing its credentials — try again in a moment."
        case .notSignedIn:
            return "Claude Code isn't signed in yet. Sign in once with `claude`, then retry."
        case .unrecognizedFormat:
            return "Claude Code's credential format has changed; not touching it."
        case .noTokens:
            return "No stored tokens for that account — sign in to it first."
        }
    }
}

// MARK: - System store

/// The real reads and writes. Kept apart from the pure logic above so the
/// interesting parts stay unit-testable without a Keychain or a home directory.
struct ClaudeCodeStore {

    func readCredentials() throws -> [String: Any]? {
        guard let data = Keychain.load(
            account: ClaudeCodeSession.credentialsAccount,
            service: ClaudeCodeSession.credentialsService)
        else { return nil }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeCodeError.unrecognizedFormat
        }
        return object
    }

    /// Writing costs no authorization prompt — the item grants `Encrypt` to
    /// every application — and leaves its ACL untouched. If Claude Code has
    /// never signed in there is no item and nothing to switch, so `Keychain`'s
    /// create-on-missing path simply won't trigger here.
    func writeCredentials(_ payload: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        try Keychain.save(
            data,
            account: ClaudeCodeSession.credentialsAccount,
            service: ClaudeCodeSession.credentialsService)
    }

    func readConfig() throws -> [String: Any] {
        let url = ClaudeCodeSession.configFile
        guard let data = try? Data(contentsOf: url) else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeCodeError.unrecognizedFormat
        }
        return object
    }

    /// Atomic, and preserves the original mode — `~/.claude.json` is 0600 and
    /// must not be widened by a rewrite.
    ///
    /// Known gap: `.storage-write` guards the *credential* store, not this
    /// file, so a Claude Code write landing between our read and rename would
    /// be lost. The window is a few milliseconds and the blast radius is one
    /// identity block that Claude Code refetches anyway, which is why this
    /// isn't worth a second locking scheme.
    func writeConfig(_ config: [String: Any]) throws {
        let url = ClaudeCodeSession.configFile
        let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path))?[
            .posixPermissions] as? NSNumber
        let data = try JSONSerialization.data(
            withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        if let permissions {
            try? FileManager.default.setAttributes(
                [.posixPermissions: permissions], ofItemAtPath: url.path)
        }
    }

    /// Runs `body` holding Claude Code's write lock. Callers must do their
    /// reads *inside* the closure: the whole point is that the state may have
    /// changed while we waited for the lock.
    func withWriteLock<T>(_ body: () async throws -> T) async throws -> T {
        let lock = try await StorageWriteLock.acquire()
        defer { lock.release() }
        return try await body()
    }
}

// MARK: - Operations

extension ClaudeCodeStore {

    /// What a switch salvaged from the outgoing account, for the caller to fold
    /// back into its own storage.
    struct SwitchResult: Sendable {
        var harvestedAccountID: String?
        var harvestedTokens: StoredTokens?
        var harvestedExtras: Data?
        /// The outgoing account's `oauthAccount` block as Claude Code had it.
        /// Without keeping this, switching back would replace a fully
        /// populated record with our minimal stand-in and lose everything
        /// Claude Code had fetched.
        var harvestedIdentity: Data?
    }

    /// Which account Claude Code is signed in as, read from `~/.claude.json`
    /// alone. Deliberately avoids the Keychain so the UI can show this without
    /// ever triggering an authorization prompt — only an actual switch does.
    func currentAccountID() -> String? {
        guard let config = try? readConfig() else { return nil }
        return ClaudeCodeSession.activeAccountUUID(inConfig: config)
    }

    /// Points Claude Code at `accountID`, returning whatever the outgoing
    /// account was holding.
    ///
    /// The harvest is not bookkeeping: Claude Code may have rotated the
    /// outgoing account's tokens since we last looked, and because rotation is
    /// single-use, the copy in our own vault is dead the moment it did. Reading
    /// them out here is the only chance to keep that account working.
    /// `knownCurrentID` is a fallback for identifying the outgoing account when
    /// `~/.claude.json` has no `oauthAccount` block — without an identity we
    /// couldn't file the harvested tokens anywhere, and overwriting blind would
    /// strand that account's chain.
    func switchAccount(
        to accountID: String,
        knownCurrentID: String?,
        tokens: StoredTokens,
        extras: Data?,
        oauthAccount: Data
    ) async throws -> SwitchResult {
        try await withWriteLock {
            var result = SwitchResult()
            let currentPayload = try readCredentials()
            let config = try readConfig()

            if let currentPayload,
                let currentID = ClaudeCodeSession.activeAccountUUID(inConfig: config)
                    ?? knownCurrentID,
                currentID != accountID
            {
                result.harvestedAccountID = currentID
                result.harvestedTokens = ClaudeCodeSession.tokens(from: currentPayload)?.tokens
                result.harvestedExtras = try? JSONSerialization.data(
                    withJSONObject: ClaudeCodeSession.extras(from: currentPayload))
                if let identity = config["oauthAccount"] as? [String: Any] {
                    result.harvestedIdentity = try? JSONSerialization.data(
                        withJSONObject: identity)
                }
            }

            // Match whatever unit this install stores expiries in; default to
            // milliseconds, which is what Claude Code writes.
            let unit =
                currentPayload
                .flatMap { ClaudeCodeSession.tokens(from: $0)?.unit } ?? .milliseconds
            let restored =
                extras
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                ?? ClaudeCodeSession.synthesizedExtras()

            try writeCredentials(
                ClaudeCodeSession.payload(extras: restored, tokens: tokens, unit: unit))

            if let block = try? JSONSerialization.jsonObject(with: oauthAccount)
                as? [String: Any]
            {
                try writeConfig(ClaudeCodeSession.config(config, settingOAuthAccount: block))
            }
            return result
        }
    }

    /// The signed-in account's current access token, refreshing through
    /// `refresh` if it has expired.
    ///
    /// While the app manages sign-in, this store — not the app's own vault — is
    /// the source of truth for that account's token chain: both sides hold the
    /// same chain, and whichever refreshes without coordinating signs the other
    /// out. The common path takes no lock at all, since a valid token only
    /// needs reading.
    func activeAccessToken(
        refresh: @Sendable (StoredTokens) async throws -> StoredTokens
    ) async throws -> StoredTokens {
        if let payload = try readCredentials(),
            let current = ClaudeCodeSession.tokens(from: payload),
            current.tokens.expiresAt.timeIntervalSinceNow > 120
        {
            return current.tokens
        }

        return try await withWriteLock {
            // Re-read inside the lock: a `claude` session may have refreshed
            // while we waited, in which case its token is the live one and
            // refreshing again would invalidate it.
            guard let payload = try readCredentials(),
                let current = ClaudeCodeSession.tokens(from: payload)
            else { throw ClaudeCodeError.notSignedIn }

            if current.tokens.expiresAt.timeIntervalSinceNow > 120 {
                return current.tokens
            }

            let refreshed = try await refresh(current.tokens)
            try writeCredentials(
                ClaudeCodeSession.payload(
                    extras: ClaudeCodeSession.extras(from: payload),
                    tokens: refreshed, unit: current.unit))
            return refreshed
        }
    }
}
