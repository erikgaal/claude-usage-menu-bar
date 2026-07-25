import XCTest

@testable import ClaudeUsage

/// Exercises the Codex usage data path: window naming, the response →
/// `LimitStatus` mapping, and the two-URL fetch/fallback logic via an
/// injected `URLSession` backed by `URLProtocolStub` — no real network.
final class CodexProviderTests: XCTestCase {

    /// Fixed reset instants (epoch seconds, as the API sends them).
    private static let primaryReset: Double = 2_000_000_000
    private static let secondaryReset: Double = 2_000_500_000

    override func setUp() {
        super.setUp()
        URLProtocolStub.reset()
        CodexConfig.preferredUsageURLIndex = 0
    }

    override func tearDown() {
        URLProtocolStub.reset()
        CodexConfig.preferredUsageURLIndex = 0
        super.tearDown()
    }

    // MARK: Fixtures

    /// Realistic wham/usage payload: unnamed primary/secondary windows plus a
    /// named additional limit that itself carries both windows.
    private static let usageJSON = """
        {
          "plan_type": "plus",
          "rate_limit": {
            "primary_window": {
              "used_percent": 42.5,
              "limit_window_seconds": 18000,
              "reset_at": 2000000000
            },
            "secondary_window": {
              "used_percent": 61.0,
              "limit_window_seconds": 604800,
              "reset_at": 2000500000
            }
          },
          "additional_rate_limits": [
            {
              "limit_name": "gpt_5_pro",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 10.0,
                  "limit_window_seconds": 18000,
                  "reset_at": 2000000000
                },
                "secondary_window": {
                  "used_percent": 20.0,
                  "limit_window_seconds": 604800,
                  "reset_at": 2000500000
                }
              }
            }
          ]
        }
        """

    private func decode(_ json: String) throws -> CodexProvider.CodexUsageResponse {
        try JSONDecoder().decode(
            CodexProvider.CodexUsageResponse.self, from: Data(json.utf8))
    }

    // MARK: Window naming

    func testWindowNameDerivesFromWindowSeconds() {
        XCTAssertEqual(CodexProvider.windowName(seconds: 3600), "Session")
        XCTAssertEqual(CodexProvider.windowName(seconds: 18000), "Session")
        // Quirk pinned deliberately: anything up to 24h is "Session"...
        XCTAssertEqual(CodexProvider.windowName(seconds: 86400), "Session")
        // ...and 25h rounds to a "1-day" window.
        XCTAssertEqual(CodexProvider.windowName(seconds: 90000), "1-day")
        XCTAssertEqual(CodexProvider.windowName(seconds: 604800), "Weekly")
        XCTAssertEqual(CodexProvider.windowName(seconds: 1_209_600), "14-day")
    }

    func testWindowNameFallsBackForMissingOrBogusSeconds() {
        XCTAssertEqual(CodexProvider.windowName(seconds: nil), "Window")
        XCTAssertEqual(CodexProvider.windowName(seconds: 0), "Window")
        XCTAssertEqual(CodexProvider.windowName(seconds: -300), "Window")
    }

    // MARK: Limits mapping

    func testPrimaryAndSecondaryWindowsMapToNamedLimits() throws {
        let limits = CodexProvider.buildLimits(try decode(Self.usageJSON))

        XCTAssertEqual(
            limits.map(\.name), ["Session", "Weekly", "Gpt 5 Pro 5h", "Gpt 5 Pro 7d"])
        XCTAssertEqual(limits.map(\.percent), [42.5, 61.0, 10.0, 20.0])
        // Primary 0, secondary 1, the whole extra limit shares bucket 2.
        XCTAssertEqual(limits.map(\.sortOrder), [0, 1, 2, 2])
        XCTAssertEqual(limits.map(\.isActive), [false, false, false, false])

        let session = limits[0]
        XCTAssertEqual(session.id, "primary|Session")
        XCTAssertEqual(
            session.resetsAt, Date(timeIntervalSince1970: Self.primaryReset))
        let weekly = limits[1]
        XCTAssertEqual(weekly.id, "secondary|Weekly")
        XCTAssertEqual(
            weekly.resetsAt, Date(timeIntervalSince1970: Self.secondaryReset))
    }

    func testAdditionalLimitWithSingleWindowKeepsItsBaseName() throws {
        let response = try decode(
            """
            {
              "rate_limit": {
                "primary_window": { "used_percent": 5.0, "limit_window_seconds": 18000 }
              },
              "additional_rate_limits": [
                {
                  "limit_name": "gpt_5_pro",
                  "rate_limit": {
                    "primary_window": { "used_percent": 10.0, "limit_window_seconds": 18000 }
                  }
                },
                {
                  "rate_limit": {
                    "secondary_window": { "used_percent": 20.0, "limit_window_seconds": 604800 }
                  }
                }
              ]
            }
            """)
        let limits = CodexProvider.buildLimits(response)

        // One window → no "5h"/"7d" suffix; nil limit_name → "Extra limit".
        XCTAssertEqual(limits.map(\.name), ["Session", "Gpt 5 Pro", "Extra limit"])
        XCTAssertEqual(limits.map(\.sortOrder), [0, 2, 3])
        // A window without a reset timestamp maps to nil.
        XCTAssertNil(limits[1].resetsAt)
    }

    func testWindowsWithoutUsedPercentAreSkipped() throws {
        let response = try decode(
            """
            {
              "rate_limit": {
                "primary_window": { "limit_window_seconds": 18000, "reset_at": 2000000000 },
                "secondary_window": { "used_percent": 61.0, "limit_window_seconds": 604800 }
              }
            }
            """)
        XCTAssertEqual(CodexProvider.buildLimits(response).map(\.name), ["Weekly"])
    }

    func testEmptyResponseYieldsNoLimits() throws {
        XCTAssertEqual(CodexProvider.buildLimits(try decode("{}")).count, 0)
    }

    // MARK: Fetch path (stubbed session)

    private func makeProvider() -> CodexProvider {
        CodexProvider(session: URLProtocolStub.makeSession())
    }

    private func fetch() async throws -> UsageSnapshot {
        try await makeProvider().fetchUsage(
            accessToken: "codex-token", accountID: "acct-42")
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

    func testFetchSendsCodexHeadersToPrimaryUsageURL() async throws {
        URLProtocolStub.handler = { request in
            (URLProtocolStub.httpResponse(for: request, status: 200),
             Data(Self.usageJSON.utf8))
        }

        let snapshot = try await fetch()

        XCTAssertEqual(
            snapshot.limits.map(\.name), ["Session", "Weekly", "Gpt 5 Pro 5h", "Gpt 5 Pro 7d"])
        XCTAssertNil(snapshot.credits, "Codex has no credits concept")

        XCTAssertEqual(URLProtocolStub.requests.count, 1)
        let request = try XCTUnwrap(URLProtocolStub.requests.first)
        XCTAssertEqual(request.url, CodexConfig.usageURLs[0])
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"), "Bearer codex-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "chatgpt-account-id"), "acct-42")
        XCTAssertEqual(request.value(forHTTPHeaderField: "originator"), "codex_cli_rs")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testFetch404FallsBackToAlternateURLAndRemembersIt() async throws {
        URLProtocolStub.handler = { request in
            if request.url == CodexConfig.usageURLs[0] {
                return (URLProtocolStub.httpResponse(for: request, status: 404), Data())
            }
            return (URLProtocolStub.httpResponse(for: request, status: 200),
                    Data(Self.usageJSON.utf8))
        }

        let snapshot = try await fetch()
        XCTAssertEqual(snapshot.limits.count, 4)
        XCTAssertEqual(
            URLProtocolStub.requests.map(\.url),
            [CodexConfig.usageURLs[0], CodexConfig.usageURLs[1]])
        XCTAssertEqual(CodexConfig.preferredUsageURLIndex, 1)

        // The working route is remembered: the next poll goes there first.
        URLProtocolStub.reset()
        URLProtocolStub.handler = { request in
            (URLProtocolStub.httpResponse(for: request, status: 200),
             Data(Self.usageJSON.utf8))
        }
        _ = try await fetch()
        XCTAssertEqual(URLProtocolStub.requests.map(\.url), [CodexConfig.usageURLs[1]])
    }

    func testFetchBoth404sSurfacesLastError() async {
        URLProtocolStub.handler = { request in
            (URLProtocolStub.httpResponse(for: request, status: 404),
             Data("not found".utf8))
        }
        let error = await fetchError()
        guard case .http(let status, let body)? = error as? UsageError else {
            return XCTFail("Expected .http, got \(String(describing: error))")
        }
        XCTAssertEqual(status, 404)
        XCTAssertEqual(body, "not found")
        XCTAssertEqual(URLProtocolStub.requests.count, 2)
    }

    func testFetch401ThrowsUnauthorizedWithoutTryingAlternateURL() async {
        URLProtocolStub.handler = { request in
            (URLProtocolStub.httpResponse(for: request, status: 401), Data())
        }
        let error = await fetchError()
        guard case .unauthorized? = error as? UsageError else {
            return XCTFail("Expected .unauthorized, got \(String(describing: error))")
        }
        XCTAssertEqual(URLProtocolStub.requests.count, 1)
    }

    func testFetch429HonorsRetryAfterHeader() async {
        URLProtocolStub.handler = { request in
            (URLProtocolStub.httpResponse(
                for: request, status: 429, headers: ["Retry-After": "60"]), Data())
        }
        let before = Date()
        let error = await fetchError()
        guard case .rateLimited(let until)? = error as? UsageError else {
            return XCTFail("Expected .rateLimited, got \(String(describing: error))")
        }
        let delay = until.timeIntervalSince(before)
        XCTAssertGreaterThanOrEqual(delay, 59)
        XCTAssertLessThan(delay, 90)
        XCTAssertEqual(URLProtocolStub.requests.count, 1)
    }

    func testFetchServerErrorStopsWithoutTryingAlternateURL() async {
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
        // 500 applies to the account, not the routing style — no second probe.
        XCTAssertEqual(URLProtocolStub.requests.count, 1)
    }

    func testFetchMalformedBodyThrowsDecodingErrorNotCrash() async {
        URLProtocolStub.handler = { request in
            (URLProtocolStub.httpResponse(for: request, status: 200),
             Data(#"{"rate_limit": []}"#.utf8))
        }
        let error = await fetchError()
        XCTAssertTrue(
            error is DecodingError, "Expected DecodingError, got \(String(describing: error))")
    }
}
