import XCTest

@testable import ClaudeUsage

/// Exercises the pure payload/config reshaping behind Claude Code sign-in
/// switching. All fixtures — nothing here reads a Keychain, a home directory
/// or a lockfile; `ClaudeCodeStore` owns that and stays out of the tests.
///
/// The through-line of most of these is preservation: we rewrite two small
/// parts of files Claude Code owns, and everything we don't understand has to
/// survive the round trip untouched.
final class ClaudeCodeSessionTests: XCTestCase {

    /// 2033-05-18T03:33:20Z, comfortably inside millisecond territory.
    private static let expiry = Date(timeIntervalSince1970: 2_000_000_000)

    // MARK: Fixtures

    /// Shaped like the real payload, including a field we don't model
    /// (`subscriptionType`) and one invented to stand in for whatever
    /// Anthropic adds next.
    private func makePayload(
        expiresAt: Double = 2_000_000_000_000,
        extraOAuthKeys: [String: Any] = [:],
        topLevel: [String: Any] = [:]
    ) -> [String: Any] {
        var oauth: [String: Any] = [
            "accessToken": "access-abc",
            "refreshToken": "refresh-xyz",
            "expiresAt": expiresAt,
            "scopes": ["user:inference", "user:profile"],
            "subscriptionType": "max",
        ]
        oauth.merge(extraOAuthKeys) { _, new in new }
        var payload: [String: Any] = [ClaudeCodeSession.oauthKey: oauth]
        payload.merge(topLevel) { _, new in new }
        return payload
    }

    private func makeTokens(
        access: String = "new-access", refresh: String = "new-refresh"
    ) -> StoredTokens {
        StoredTokens(accessToken: access, refreshToken: refresh, expiresAt: Self.expiry)
    }

    private func oauthBlock(of payload: [String: Any]) -> [String: Any] {
        payload[ClaudeCodeSession.oauthKey] as? [String: Any] ?? [:]
    }

    // MARK: Reading tokens

    func testReadsTokensStoredInMilliseconds() {
        let result = ClaudeCodeSession.tokens(from: makePayload())
        XCTAssertEqual(result?.tokens.accessToken, "access-abc")
        XCTAssertEqual(result?.tokens.refreshToken, "refresh-xyz")
        XCTAssertEqual(result?.tokens.expiresAt, Self.expiry)
        XCTAssertEqual(result?.unit, .milliseconds)
    }

    func testReadsTokensStoredInSeconds() {
        // Claude Code writes milliseconds, but an install that ever stored
        // seconds must not be read as a 1970 timestamp.
        let result = ClaudeCodeSession.tokens(from: makePayload(expiresAt: 2_000_000_000))
        XCTAssertEqual(result?.tokens.expiresAt, Self.expiry)
        XCTAssertEqual(result?.unit, .seconds)
    }

    func testUnrecognizedPayloadYieldsNoTokens() {
        // A format change must read as "don't touch this" rather than produce
        // half-populated tokens we'd then write back over a working sign-in.
        XCTAssertNil(ClaudeCodeSession.tokens(from: [:]))
        XCTAssertNil(ClaudeCodeSession.tokens(from: ["somethingElse": ["accessToken": "a"]]))
    }

    func testMissingExpiryYieldsNoTokens() {
        var oauth = oauthBlock(of: makePayload())
        oauth.removeValue(forKey: "expiresAt")
        XCTAssertNil(ClaudeCodeSession.tokens(from: [ClaudeCodeSession.oauthKey: oauth]))
    }

    func testEmptyAccessTokenYieldsNoTokens() {
        // Present-but-blank is a signed-out store, not a usable credential.
        let payload = makePayload(extraOAuthKeys: ["accessToken": ""])
        XCTAssertNil(ClaudeCodeSession.tokens(from: payload))
    }

    // MARK: Extracting a profile

    func testExtrasDropOnlyTokenFields() {
        let extras = ClaudeCodeSession.oauthExtras(from: makePayload())
        for key in ClaudeCodeSession.tokenKeys {
            XCTAssertNil(extras[key], "\(key) is per-account and must not be kept")
        }
        XCTAssertEqual(extras["subscriptionType"] as? String, "max")
        XCTAssertEqual(extras["scopes"] as? [String], ["user:inference", "user:profile"])
    }

    func testExtrasKeepUnknownOAuthFieldsButNotSiblingCredentials() {
        // Forward compatibility is the whole reason profiles are captured
        // rather than synthesized, so unknown fields *of this account* have to
        // survive. Anything beside the OAuth block belongs to the item rather
        // than to the account: capturing it would restore a stale copy over
        // whatever is live, and would carry credentials this app doesn't own
        // into the profile store.
        let payload = makePayload(
            extraOAuthKeys: ["futureFlag": true],
            topLevel: ["someOtherProvider": ["token": "not-ours"]])
        let extras = ClaudeCodeSession.oauthExtras(from: payload)

        XCTAssertEqual(extras["futureFlag"] as? Bool, true)
        XCTAssertNil(extras["someOtherProvider"])
        XCTAssertFalse(
            "\(extras)".contains("not-ours"),
            "a credential sitting beside ours must not reach the profile store")
    }

    func testExtrasOfPayloadWithoutAnOAuthBlockAreEmpty() {
        // A format we don't recognize yields nothing to restore rather than a
        // wholesale copy of the item.
        XCTAssertTrue(ClaudeCodeSession.oauthExtras(from: ["mystery": 1]).isEmpty)
    }

    // MARK: Rebuilding a payload

    func testPayloadWritesTokensInRequestedUnit() {
        let extras = ClaudeCodeSession.oauthExtras(from: makePayload())
        let rebuilt = ClaudeCodeSession.payload(
            base: [:], extras: extras, tokens: makeTokens(), unit: .milliseconds)
        let oauth = oauthBlock(of: rebuilt)
        XCTAssertEqual(oauth["accessToken"] as? String, "new-access")
        XCTAssertEqual(oauth["refreshToken"] as? String, "new-refresh")
        XCTAssertEqual(oauth["expiresAt"] as? Double, 2_000_000_000_000)
    }

    func testPayloadHonoursSecondsUnit() {
        let rebuilt = ClaudeCodeSession.payload(
            base: [:], extras: [:], tokens: makeTokens(), unit: .seconds)
        XCTAssertEqual(oauthBlock(of: rebuilt)["expiresAt"] as? Double, 2_000_000_000)
    }

    func testPayloadTakesSiblingCredentialsFromTheLiveItemNotTheProfile() {
        // A profile describes one account. Everything else in the item is
        // whatever Claude Code last wrote, so a switch has to leave it standing
        // rather than restore this account's stale snapshot over it.
        let live = makePayload(topLevel: ["someOtherProvider": ["token": "current"]])
        let profile: [String: Any] = ["subscriptionType": "max", "futureFlag": true]

        let rebuilt = ClaudeCodeSession.payload(
            base: live, extras: profile, tokens: makeTokens(), unit: .milliseconds)

        XCTAssertEqual(
            (rebuilt["someOtherProvider"] as? [String: Any])?["token"] as? String, "current")
        let oauth = oauthBlock(of: rebuilt)
        XCTAssertEqual(oauth["futureFlag"] as? Bool, true)
        XCTAssertEqual(oauth["accessToken"] as? String, "new-access")
        // The incoming account's block replaces the outgoing one outright —
        // no field of the account being switched away from may survive in it.
        XCTAssertNil(oauth["scopes"], "the outgoing account's scopes must not linger")
    }

    func testRoundTripPreservesEverythingButTokens() {
        // Read a payload, strip it to a profile, put fresh tokens back: the
        // result must differ from the original in exactly the token fields.
        let original = makePayload(
            extraOAuthKeys: ["futureFlag": true], topLevel: ["other": "value"])
        let read = ClaudeCodeSession.tokens(from: original)
        let rebuilt = ClaudeCodeSession.payload(
            base: original,
            extras: ClaudeCodeSession.oauthExtras(from: original),
            tokens: makeTokens(), unit: read!.unit)

        XCTAssertEqual(rebuilt["other"] as? String, "value")
        let before = oauthBlock(of: original), after = oauthBlock(of: rebuilt)
        XCTAssertEqual(Set(before.keys), Set(after.keys))
        for key in before.keys where !ClaudeCodeSession.tokenKeys.contains(key) {
            XCTAssertEqual(
                before[key] as? NSObject, after[key] as? NSObject,
                "\(key) should have survived untouched")
        }
        XCTAssertNotEqual(after["accessToken"] as? String, before["accessToken"] as? String)
    }

    func testPayloadFromEmptyExtrasStillProducesUsableBlock() {
        // Switching to an account never seen signed in: no captured profile.
        let tokens = makeTokens()
        let rebuilt = ClaudeCodeSession.payload(
            base: [:], extras: ClaudeCodeSession.synthesizedExtras(for: tokens),
            tokens: tokens, unit: .milliseconds)
        let oauth = oauthBlock(of: rebuilt)
        XCTAssertEqual(oauth["accessToken"] as? String, "new-access")
        // Scopes must be the ones this token was actually minted with, and
        // must include the scope Claude Code checks before inferencing.
        XCTAssertEqual(oauth["scopes"] as? [String], OAuthConfig.scopes)
        XCTAssertTrue((oauth["scopes"] as? [String] ?? []).contains("user:inference"))
    }

    func testSynthesizedExtrasReportTheTokensOwnScopesNotTheCurrentConstant() {
        // A token minted before the scope list grew keeps the narrower grant
        // for life. Advertising `OAuthConfig.scopes` for it would tell Claude
        // Code the session can do things the token isn't authorized for.
        let legacy = StoredTokens(
            accessToken: "a", refreshToken: "r", expiresAt: Self.expiry,
            scopes: ["org:create_api_key", "user:profile", "user:inference"])
        let extras = ClaudeCodeSession.synthesizedExtras(for: legacy)

        XCTAssertEqual(extras["scopes"] as? [String], legacy.scopes)
        XCTAssertFalse(
            (extras["scopes"] as? [String] ?? []).contains("user:sessions:claude_code"),
            "a scope the token never had must not be claimed on its behalf")
    }

    func testCurrentScopesCoverTheFeaturesClaudeCodeExpects() {
        // Claude Code's own login requests these; a switched-in account whose
        // token lacks one silently loses that feature — `user:sessions:claude_code`
        // is what /rc (remote-control) needs.
        for scope in [
            "org:create_api_key", "user:profile", "user:inference",
            "user:sessions:claude_code", "user:mcp_servers", "user:file_upload",
        ] {
            XCTAssertTrue(OAuthConfig.scopes.contains(scope), "missing \(scope)")
        }
    }

    // MARK: Expiry units

    func testUnitInferenceBoundary() {
        XCTAssertEqual(
            ClaudeCodeSession.ExpiresAtUnit.infer(from: 1_800_000_000), .seconds)
        XCTAssertEqual(
            ClaudeCodeSession.ExpiresAtUnit.infer(from: 1_800_000_000_000), .milliseconds)
    }

    func testUnitRoundTripsDate() {
        for unit in [ClaudeCodeSession.ExpiresAtUnit.seconds, .milliseconds] {
            let raw = unit.raw(from: Self.expiry)
            XCTAssertEqual(unit.date(from: raw), Self.expiry, "\(unit) lost precision")
        }
    }

    // MARK: Config file

    func testReadsActiveAccountUUID() {
        let config: [String: Any] = [
            "oauthAccount": ["accountUuid": "abc-123", "emailAddress": "a@example.com"]
        ]
        XCTAssertEqual(ClaudeCodeSession.activeAccountUUID(inConfig: config), "abc-123")
    }

    func testMissingOAuthAccountHasNoActiveUUID() {
        XCTAssertNil(ClaudeCodeSession.activeAccountUUID(inConfig: [:]))
        XCTAssertNil(ClaudeCodeSession.activeAccountUUID(inConfig: ["oauthAccount": [:]]))
    }

    func testSettingOAuthAccountLeavesTheRestOfConfigAlone() {
        // `~/.claude.json` is mostly project history and onboarding state; we
        // rewrite one key and must not disturb the rest.
        let config: [String: Any] = [
            "oauthAccount": ["accountUuid": "old"],
            "projects": ["/tmp/x": ["allowedTools": ["Bash"]]],
            "userID": "user-1",
        ]
        let updated = ClaudeCodeSession.config(
            config, settingOAuthAccount: ["accountUuid": "new"])
        XCTAssertEqual(
            (updated["oauthAccount"] as? [String: Any])?["accountUuid"] as? String, "new")
        XCTAssertEqual(updated["userID"] as? String, "user-1")
        XCTAssertNotNil(updated["projects"])
    }

    // MARK: Identity block

    func testOAuthAccountCarriesWhatWeActuallyKnow() {
        let account = AccountMeta(
            id: "uuid-1", email: "me@example.com", organizationName: "Acme",
            provider: .claude, label: "Work")
        let block = ClaudeCodeSession.oauthAccount(for: account)
        XCTAssertEqual(block["accountUuid"] as? String, "uuid-1")
        XCTAssertEqual(block["emailAddress"] as? String, "me@example.com")
        XCTAssertEqual(block["organizationName"] as? String, "Acme")
        // Nothing invented: Claude Code refetches the profile and fills in
        // seatTier, billing and rate-limit tiers itself.
        XCTAssertNil(block["seatTier"])
        XCTAssertNil(block["billingType"])
    }

    func testOAuthAccountOmitsAbsentOrganization() {
        let account = AccountMeta(
            id: "uuid-2", email: "solo@example.com", organizationName: nil,
            provider: .claude)
        let block = ClaudeCodeSession.oauthAccount(for: account)
        XCTAssertNil(block["organizationName"])
        XCTAssertEqual(block["accountUuid"] as? String, "uuid-2")
    }

    func testIdentityBlockSurvivesJSONEncoding() {
        // It crosses to the store as Data, so it has to be JSON-serializable.
        let account = AccountMeta(
            id: "uuid-3", email: "x@example.com", organizationName: "Org", provider: .claude)
        let block = ClaudeCodeSession.oauthAccount(for: account)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(block))
        let data = try? JSONSerialization.data(withJSONObject: block)
        XCTAssertNotNil(data)
    }

    // MARK: Restoring a captured identity

    func testRestoredIdentityKeepsEverythingButTheFetchStamp() {
        // Switching away and back must not degrade a full record to the
        // minimal block we can synthesize — these fields can't be derived and
        // Claude Code only refetches them lazily.
        let captured: [String: Any] = [
            "accountUuid": "uuid-1",
            "emailAddress": "me@example.com",
            "organizationName": "Acme",
            "seatTier": "team_tier_1",
            "billingType": "stripe_subscription",
            "hasExtraUsageEnabled": true,
            "profileFetchedAt": 1_800_000_000_000,
        ]
        let restored = ClaudeCodeSession.identityForRestore(captured)

        XCTAssertEqual(restored["seatTier"] as? String, "team_tier_1")
        XCTAssertEqual(restored["billingType"] as? String, "stripe_subscription")
        XCTAssertEqual(restored["hasExtraUsageEnabled"] as? Bool, true)
        XCTAssertEqual(restored.count, captured.count - 1)
        // Dropped so Claude Code re-fetches rather than trusting our snapshot,
        // which may be arbitrarily old.
        XCTAssertNil(restored["profileFetchedAt"])
    }

    func testRestoringIdentityWithoutAFetchStampIsHarmless() {
        let restored = ClaudeCodeSession.identityForRestore(["accountUuid": "uuid-2"])
        XCTAssertEqual(restored["accountUuid"] as? String, "uuid-2")
    }

    // MARK: Write lock

    func testLockIsStaleOnlyAfterTheInterval() {
        // Matches proper-lockfile's 15s: a lock held by a live process must
        // never be stolen, or two writers race on the credential store.
        let now = Date()
        XCTAssertFalse(
            StorageWriteLock.isStale(modifiedAt: now.addingTimeInterval(-14), now: now))
        XCTAssertTrue(
            StorageWriteLock.isStale(modifiedAt: now.addingTimeInterval(-16), now: now))
    }

    func testBackoffGrowsAndIsCapped() {
        XCTAssertEqual(StorageWriteLock.backoff(attempt: 0), 0.1, accuracy: 0.0001)
        XCTAssertEqual(StorageWriteLock.backoff(attempt: 1), 0.2, accuracy: 0.0001)
        // Capped at proper-lockfile's maxTimeout rather than growing forever.
        XCTAssertEqual(StorageWriteLock.backoff(attempt: 20), 1.0, accuracy: 0.0001)
    }
}
