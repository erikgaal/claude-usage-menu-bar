import XCTest

@testable import ClaudeUsage

/// Exercises the Claude usage data path: wire-format decoding, the
/// response → `LimitStatus`/`CreditsStatus` mapping, and the fetch path via
/// an injected `URLSession` backed by `URLProtocolStub` — no real network.
final class UsageAPITests: XCTestCase {

    /// Fixed reset instant used across fixtures: 2033-05-18T03:33:20Z.
    private static let resetDate = Date(timeIntervalSince1970: 2_000_000_000)

    override func setUp() {
        super.setUp()
        URLProtocolStub.reset()
    }

    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    // MARK: Fixtures

    /// Realistic modern payload: server-computed `limits[]` (including a
    /// model-scoped "Fable" entry) alongside the legacy flat windows, which
    /// deliberately disagree with `limits[]` so preference is observable.
    private static let limitsJSON = """
        {
          "five_hour": { "utilization": 10.0, "resets_at": "2033-05-18T03:33:20Z" },
          "seven_day": { "utilization": 20.0, "resets_at": "2033-05-21T00:00:00Z" },
          "limits": [
            {
              "kind": "weekly_all",
              "group": "usage",
              "percent": 61.5,
              "severity": "normal",
              "resets_at": "2033-05-21T00:00:00Z",
              "scope": null,
              "is_active": false
            },
            {
              "kind": "session",
              "group": "usage",
              "percent": 42.0,
              "severity": "warning",
              "resets_at": "2033-05-18T03:33:20.123456Z",
              "scope": null,
              "is_active": true
            },
            {
              "kind": "weekly_model",
              "group": "usage",
              "percent": 12.5,
              "severity": "normal",
              "resets_at": "2033-05-21T00:00:00Z",
              "scope": { "model": { "display_name": "Fable" } },
              "is_active": false
            }
          ]
        }
        """

    private func decode(_ json: String) throws -> UsageResponse {
        try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
    }

    // MARK: Limits mapping — limits[] preferred

    func testLimitsArrayIsPreferredOverFlatWindows() throws {
        let limits = UsageAPI.buildLimits(try decode(Self.limitsJSON))

        // Sorted Session → Weekly → model-scoped; percents come from
        // `limits[]` (42/61.5), not the flat windows (10/20).
        XCTAssertEqual(limits.map(\.name), ["Session", "Weekly", "Fable"])
        XCTAssertEqual(limits.map(\.percent), [42.0, 61.5, 12.5])
        XCTAssertEqual(limits.map(\.sortOrder), [0, 1, 2])
    }

    func testLimitEntriesCarryIdActiveFlagAndParsedReset() throws {
        let limits = UsageAPI.buildLimits(try decode(Self.limitsJSON))

        let session = try XCTUnwrap(limits.first { $0.name == "Session" })
        XCTAssertEqual(session.id, "session|")
        XCTAssertTrue(session.isActive)
        // The API's 6-digit fractional seconds parse into the right second
        // (sub-second precision varies by Foundation version — see
        // ISO8601Tests).
        let resetsAt = try XCTUnwrap(session.resetsAt)
        XCTAssertEqual(
            resetsAt.timeIntervalSince1970, Self.resetDate.timeIntervalSince1970,
            accuracy: 0.2)

        let fable = try XCTUnwrap(limits.first { $0.name == "Fable" })
        XCTAssertEqual(fable.id, "weekly_model|Fable")
        XCTAssertFalse(fable.isActive)

        let weekly = try XCTUnwrap(limits.first { $0.name == "Weekly" })
        XCTAssertEqual(weekly.id, "weekly_all|")
    }

    func testUnknownKindsFallBackToCapitalizedKindOrGroup() throws {
        let response = try decode(
            """
            {
              "limits": [
                { "kind": "monthly_all", "percent": 5.0 },
                { "kind": null, "group": "opus_tokens", "percent": 6.0 },
                { "percent": 7.0 }
              ]
            }
            """)
        let limits = UsageAPI.buildLimits(response)

        XCTAssertEqual(limits.map(\.name), ["Limit", "Monthly All", "Opus Tokens"])
        // All unknown kinds share the tail sort bucket and sort by name.
        XCTAssertEqual(limits.map(\.sortOrder), [3, 3, 3])
        // Missing kind is pinned into the id as "?".
        XCTAssertEqual(limits.first { $0.name == "Limit" }?.id, "?|")
        // Absent is_active defaults to false.
        XCTAssertEqual(limits.map(\.isActive), [false, false, false])
    }

    func testLimitEntriesWithoutPercentAreSkipped() throws {
        let response = try decode(
            """
            {
              "limits": [
                { "kind": "session", "percent": null, "resets_at": "2033-05-18T03:33:20Z" },
                { "kind": "weekly_all", "percent": 61.5 }
              ]
            }
            """)
        XCTAssertEqual(UsageAPI.buildLimits(response).map(\.name), ["Weekly"])
    }

    // MARK: Limits mapping — flat-window fallback

    func testEmptyLimitsArrayFallsBackToFlatWindows() throws {
        let response = try decode(
            """
            {
              "five_hour": { "utilization": 42.5, "resets_at": "2033-05-18T03:33:20Z" },
              "seven_day": { "utilization": 61.0, "resets_at": null },
              "seven_day_opus": { "utilization": 88.0, "resets_at": "2033-05-21T00:00:00Z" },
              "seven_day_sonnet": { "resets_at": "2033-05-21T00:00:00Z" },
              "limits": []
            }
            """)
        let limits = UsageAPI.buildLimits(response)

        // Sonnet has no utilization and is dropped; the rest keep the fixed
        // window naming and use the plain name as id.
        XCTAssertEqual(limits.map(\.name), ["Session", "Weekly", "Opus"])
        XCTAssertEqual(limits.map(\.id), ["Session", "Weekly", "Opus"])
        XCTAssertEqual(limits.map(\.percent), [42.5, 61.0, 88.0])
        XCTAssertEqual(limits.map(\.sortOrder), [0, 1, 2])
        XCTAssertEqual(limits[0].resetsAt, Self.resetDate)
        XCTAssertNil(limits[1].resetsAt)
        // Flat windows never carry an active flag.
        XCTAssertEqual(limits.map(\.isActive), [false, false, false])
    }

    func testCompletelyEmptyResponseYieldsNoLimits() throws {
        XCTAssertEqual(UsageAPI.buildLimits(try decode("{}")).count, 0)
    }

    // MARK: Credits mapping

    func testSpendBlockIsPreferredOverLegacyExtraUsage() throws {
        let response = try decode(
            """
            {
              "spend": {
                "used": { "amount_minor": 1234, "currency": "GBP", "exponent": 2 },
                "limit": { "amount_minor": 5000, "currency": "GBP", "exponent": 2 },
                "cap": { "money": { "amount_minor": 9999, "currency": "GBP", "exponent": 2 }, "credits": null },
                "percent": 24.68,
                "enabled": true
              },
              "extra_usage": {
                "is_enabled": true,
                "used_credits": 657.0,
                "monthly_limit": 10000.0,
                "utilization": 6.57,
                "currency": "USD",
                "decimal_places": 2
              }
            }
            """)
        let credits = try XCTUnwrap(UsageAPI.buildCredits(response))

        XCTAssertEqual(credits.usedMinor, 1234)
        // `limit` outranks the nested `cap.money` when both are present.
        XCTAssertEqual(credits.limitMinor, 5000)
        XCTAssertEqual(credits.currency, "GBP")
        XCTAssertEqual(credits.exponent, 2)
        XCTAssertEqual(credits.percent, 24.68)
        XCTAssertTrue(credits.enabled)
    }

    func testSpendCapNestsItsAmountUnderMoney() throws {
        let response = try decode(
            """
            {
              "spend": {
                "used": { "amount_minor": 657, "currency": "GBP", "exponent": 2 },
                "limit": null,
                "cap": { "money": { "amount_minor": 2500, "currency": "GBP", "exponent": 2 }, "credits": null },
                "percent": 26.28,
                "enabled": true
              }
            }
            """)
        XCTAssertEqual(UsageAPI.buildCredits(response)?.limitMinor, 2500)
    }

    func testSpendDefaultsCurrencyExponentAndEnabledWhenAbsent() throws {
        let response = try decode(
            """
            { "spend": { "used": { "amount_minor": 100 } } }
            """)
        let credits = try XCTUnwrap(UsageAPI.buildCredits(response))

        XCTAssertEqual(credits.usedMinor, 100)
        XCTAssertNil(credits.limitMinor)
        XCTAssertEqual(credits.currency, "USD")
        XCTAssertEqual(credits.exponent, 2)
        XCTAssertNil(credits.percent)
        XCTAssertTrue(credits.enabled)
    }

    func testSpendBorrowsCurrencyAndExponentFromLegacyBlockBeforeDefaults() throws {
        // Quirk pinned deliberately: a bare `spend.used` fills its missing
        // currency/exponent from the legacy `extra_usage` block if present.
        let response = try decode(
            """
            {
              "spend": { "used": { "amount_minor": 100 } },
              "extra_usage": { "currency": "GBP", "decimal_places": 0 }
            }
            """)
        let credits = try XCTUnwrap(UsageAPI.buildCredits(response))

        XCTAssertEqual(credits.currency, "GBP")
        XCTAssertEqual(credits.exponent, 0)
    }

    func testLegacyExtraUsageIsUsedWhenSpendIsAbsent() throws {
        let response = try decode(
            """
            {
              "extra_usage": {
                "is_enabled": false,
                "used_credits": 657.4,
                "monthly_limit": 2500.6,
                "utilization": 26.3,
                "currency": "GBP",
                "decimal_places": 2
              }
            }
            """)
        let credits = try XCTUnwrap(UsageAPI.buildCredits(response))

        // Legacy amounts are already minor units, rounded to Int.
        XCTAssertEqual(credits.usedMinor, 657)
        XCTAssertEqual(credits.limitMinor, 2501)
        XCTAssertEqual(credits.currency, "GBP")
        XCTAssertEqual(credits.exponent, 2)
        XCTAssertEqual(credits.percent, 26.3)
        XCTAssertFalse(credits.enabled)
    }

    func testSpendWithoutUsedFallsBackToLegacyBlock() throws {
        let response = try decode(
            """
            {
              "spend": { "percent": 0, "enabled": true },
              "extra_usage": { "is_enabled": true, "used_credits": 657.0 }
            }
            """)
        let credits = try XCTUnwrap(UsageAPI.buildCredits(response))
        XCTAssertEqual(credits.usedMinor, 657)
        XCTAssertEqual(credits.currency, "USD")
    }

    func testNoSpendFigureAnywhereYieldsNilCredits() throws {
        XCTAssertNil(UsageAPI.buildCredits(try decode("{}")))
        // An extra_usage block without used_credits carries no spend figure.
        XCTAssertNil(
            UsageAPI.buildCredits(try decode(#"{ "extra_usage": { "is_enabled": true } }"#)))
    }

    // MARK: Retry-After parsing

    private func http429(retryAfter: String?) -> HTTPURLResponse {
        HTTPURLResponse(
            url: UsageAPI.endpoint, statusCode: 429, httpVersion: "HTTP/1.1",
            headerFields: retryAfter.map { ["Retry-After": $0] })!
    }

    func testRetryAfterSecondsAreHonored() {
        let delay = http429(retryAfter: "120").retryAfterDate.timeIntervalSinceNow
        XCTAssertGreaterThan(delay, 115)
        XCTAssertLessThanOrEqual(delay, 120)
    }

    func testRetryAfterIsFlooredAtThirtySeconds() {
        let delay = http429(retryAfter: "5").retryAfterDate.timeIntervalSinceNow
        XCTAssertGreaterThan(delay, 25)
        XCTAssertLessThanOrEqual(delay, 30)
    }

    func testMissingOrHTTPDateRetryAfterFallsBackToFiveMinutes() {
        // The HTTP-date form of Retry-After is not parsed — pinned fallback.
        for header in [nil, "Wed, 18 May 2033 03:33:20 GMT"] {
            let delay = http429(retryAfter: header).retryAfterDate.timeIntervalSinceNow
            XCTAssertGreaterThan(delay, 295)
            XCTAssertLessThanOrEqual(delay, 300)
        }
    }

    // MARK: Fetch path (stubbed session)

    private func fetch(token: String = "token-123") async throws -> UsageSnapshot {
        try await UsageAPI.fetchUsage(
            accessToken: token, session: URLProtocolStub.makeSession())
    }

    private func fetchError(
        file: StaticString = #filePath, line: UInt = #line
    ) async -> Error? {
        do {
            _ = try await fetch()
            XCTFail("Expected fetchUsage to throw", file: file, line: line)
            return nil
        } catch {
            return error
        }
    }

    func testFetchSendsBearerTokenAndBetaHeaderToUsageEndpoint() async throws {
        URLProtocolStub.handler = { request in
            (URLProtocolStub.httpResponse(for: request, status: 200),
             Data(Self.limitsJSON.utf8))
        }

        let snapshot = try await fetch()

        XCTAssertEqual(snapshot.limits.map(\.name), ["Session", "Weekly", "Fable"])
        XCTAssertNil(snapshot.credits)

        XCTAssertEqual(URLProtocolStub.requests.count, 1)
        let request = try XCTUnwrap(URLProtocolStub.requests.first)
        XCTAssertEqual(request.url, UsageAPI.endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testFetch401And403ThrowUnauthorized() async {
        for status in [401, 403] {
            URLProtocolStub.handler = { request in
                (URLProtocolStub.httpResponse(for: request, status: status), Data())
            }
            let error = await fetchError()
            guard case .unauthorized? = error as? UsageError else {
                return XCTFail(
                    "Expected .unauthorized for \(status), got \(String(describing: error))")
            }
        }
    }

    func testFetch429HonorsRetryAfterHeader() async {
        URLProtocolStub.handler = { request in
            (URLProtocolStub.httpResponse(
                for: request, status: 429, headers: ["Retry-After": "120"]), Data())
        }
        let before = Date()
        let error = await fetchError()
        guard case .rateLimited(let until)? = error as? UsageError else {
            return XCTFail("Expected .rateLimited, got \(String(describing: error))")
        }
        let delay = until.timeIntervalSince(before)
        XCTAssertGreaterThanOrEqual(delay, 119)
        XCTAssertLessThan(delay, 150)
    }

    func testFetchNon200SurfacesStatusAndBody() async {
        URLProtocolStub.handler = { request in
            (URLProtocolStub.httpResponse(for: request, status: 500),
             Data("upstream oops".utf8))
        }
        let error = await fetchError()
        guard case .http(let status, let body)? = error as? UsageError else {
            return XCTFail("Expected .http, got \(String(describing: error))")
        }
        XCTAssertEqual(status, 500)
        XCTAssertEqual(body, "upstream oops")
    }

    func testFetchMalformedBodyThrowsDecodingErrorNotCrash() async {
        URLProtocolStub.handler = { request in
            (URLProtocolStub.httpResponse(for: request, status: 200),
             Data(#"{"limits": "nope"}"#.utf8))
        }
        let error = await fetchError()
        XCTAssertTrue(
            error is DecodingError, "Expected DecodingError, got \(String(describing: error))")
    }

    func testFetchEmptyObjectYieldsEmptySnapshot() async throws {
        URLProtocolStub.handler = { request in
            (URLProtocolStub.httpResponse(for: request, status: 200), Data("{}".utf8))
        }
        let snapshot = try await fetch()
        XCTAssertEqual(snapshot.limits, [])
        XCTAssertNil(snapshot.credits)
    }

    // MARK: Profile (plan detection)

    /// Real response shape observed live (values sanitized): an org-billed
    /// Max 5× Team account whose account-level plan booleans are false —
    /// which is exactly why `organization.rate_limit_tier` is authoritative.
    private static let profileJSON = """
        {
          "account": {
            "uuid": "aaaaaaaa-1111-2222-3333-444444444444",
            "full_name": "Erik", "display_name": "Erik",
            "email": "user@example.com",
            "has_claude_max": false, "has_claude_pro": false,
            "created_at": "2026-07-14T14:26:09.105965Z"
          },
          "organization": {
            "uuid": "bbbbbbbb-1111-2222-3333-444444444444",
            "name": "ExampleOrg",
            "organization_type": "claude_team",
            "billing_type": "stripe_subscription",
            "rate_limit_tier": "default_claude_max_5x",
            "seat_tier": "team_tier_1",
            "has_extra_usage_enabled": true,
            "subscription_status": "active"
          },
          "application": { "uuid": "…", "name": "Claude Code", "slug": "claude-code" }
        }
        """

    func testProfileResponseDecodesTierAndBooleans() throws {
        let parsed = try JSONDecoder().decode(
            ProfileResponse.self, from: Data(Self.profileJSON.utf8))
        XCTAssertEqual(parsed.organization?.rateLimitTier, "default_claude_max_5x")
        XCTAssertEqual(parsed.account?.hasClaudeMax, false)
        XCTAssertEqual(parsed.account?.hasClaudePro, false)
    }

    func testTierMappingTable() {
        XCTAssertEqual(ClaudeTier.multiplier(forRateLimitTier: "default_claude_max_5x"), 5)
        XCTAssertEqual(ClaudeTier.multiplier(forRateLimitTier: "default_claude_max_20x"), 20)
        XCTAssertEqual(ClaudeTier.multiplier(forRateLimitTier: "default_claude_pro"), 1)
        // Unknown strings are never guessed at…
        XCTAssertNil(ClaudeTier.multiplier(forRateLimitTier: "default_claude_enterprise"))
        // …and a present-but-unknown tier outranks the unreliable booleans.
        XCTAssertNil(
            ClaudeTier.multiplier(
                forRateLimitTier: "default_claude_enterprise", hasClaudePro: true))
        // With no tier string at all, has_claude_pro is a last-resort hint.
        XCTAssertEqual(ClaudeTier.multiplier(forRateLimitTier: nil, hasClaudePro: true), 1)
        XCTAssertNil(ClaudeTier.multiplier(forRateLimitTier: nil, hasClaudePro: false))
        XCTAssertNil(ClaudeTier.multiplier(forRateLimitTier: nil, hasClaudePro: nil))
    }

    func testFetchProfileSendsUsageHeadersToProfileEndpoint() async throws {
        URLProtocolStub.handler = { request in
            (URLProtocolStub.httpResponse(for: request, status: 200),
             Data(Self.profileJSON.utf8))
        }

        let plan = try await UsageAPI.fetchProfile(
            accessToken: "token-123", session: URLProtocolStub.makeSession())

        XCTAssertEqual(plan.rateLimitTier, "default_claude_max_5x")
        XCTAssertEqual(plan.quotaMultiplier, 5)

        let request = try XCTUnwrap(URLProtocolStub.requests.first)
        XCTAssertEqual(request.url, UsageAPI.profileEndpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testFetchProfileNon200Throws() async {
        URLProtocolStub.handler = { request in
            (URLProtocolStub.httpResponse(for: request, status: 401), Data())
        }
        do {
            _ = try await UsageAPI.fetchProfile(
                accessToken: "token", session: URLProtocolStub.makeSession())
            XCTFail("Expected fetchProfile to throw")
        } catch {
            guard case .http(let status, _)? = error as? UsageError else {
                return XCTFail("Expected .http, got \(error)")
            }
            XCTAssertEqual(status, 401)
        }
    }

    func testFetchProfileMalformedBodyThrows() async {
        URLProtocolStub.handler = { request in
            (URLProtocolStub.httpResponse(for: request, status: 200),
             Data(#"{"organization": "nope"}"#.utf8))
        }
        do {
            _ = try await UsageAPI.fetchProfile(
                accessToken: "token", session: URLProtocolStub.makeSession())
            XCTFail("Expected fetchProfile to throw")
        } catch {
            XCTAssertTrue(error is DecodingError, "Expected DecodingError, got \(error)")
        }
    }
}
