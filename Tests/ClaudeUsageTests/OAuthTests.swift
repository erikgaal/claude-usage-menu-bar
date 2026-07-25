import XCTest

@testable import ClaudeUsage

final class OAuthTests: XCTestCase {

    // MARK: - PKCE verifier

    /// 32 random bytes → 43 unpadded base64url characters, which is the
    /// minimum (and thus a valid) code-verifier length per RFC 7636 §4.1.
    func testVerifierLengthSatisfiesRFC7636() {
        let verifier = PKCE.randomURLSafeString()
        XCTAssertEqual(verifier.count, 43)
        XCTAssertTrue((43...128).contains(verifier.count))
    }

    func testVerifierUsesOnlyBase64URLCharacters() {
        let allowed = Set(
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        for _ in 0..<20 {
            let verifier = PKCE.randomURLSafeString()
            XCTAssertTrue(verifier.allSatisfy { allowed.contains($0) }, verifier)
        }
    }

    /// Verifiers and states share this generator; a repeated value would
    /// defeat both PKCE and the CSRF state check, so every call must draw
    /// fresh randomness.
    func testRandomStringsAreFreshPerInvocation() {
        let values = (0..<100).map { _ in PKCE.randomURLSafeString() }
        XCTAssertEqual(Set(values).count, values.count)
    }

    // MARK: - PKCE challenge

    /// Fixed pair from RFC 7636 Appendix B (independently verifiable):
    /// challenge = BASE64URL(SHA256(ASCII(verifier))).
    func testChallengeMatchesRFC7636AppendixB() {
        XCTAssertEqual(
            PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testChallengeIsDeterministicPerVerifier() {
        let verifier = PKCE.randomURLSafeString()
        let challenge = PKCE.challenge(for: verifier)
        XCTAssertEqual(challenge, PKCE.challenge(for: verifier))
        XCTAssertNotEqual(challenge, PKCE.challenge(for: verifier + "x"))
        // SHA-256 is 32 bytes → always 43 unpadded base64url characters.
        XCTAssertEqual(challenge.count, 43)
    }

    // MARK: - base64url

    func testBase64URLEncodingSubstitutesUnsafeCharactersAndStripsPadding() {
        // 0xfb 0xff is "+/8=" in standard base64: one value exercises both
        // character substitutions and padding removal.
        XCTAssertEqual(Data([0xfb, 0xff]).base64URLEncodedString(), "-_8")
        XCTAssertEqual(Data().base64URLEncodedString(), "")
    }

    // MARK: - Authorize URL

    private func queryDictionary(of url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func testAuthorizeURLContainsAllRequiredParameters() throws {
        let url = OAuthClient.authorizeURL(challenge: "the-challenge", state: "the-state")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "claude.com")
        XCTAssertEqual(components.path, "/cai/oauth/authorize")

        let query = queryDictionary(of: url)
        XCTAssertEqual(query["client_id"], OAuthConfig.clientID)
        XCTAssertEqual(query["response_type"], "code")
        XCTAssertEqual(query["redirect_uri"], "http://localhost:54545/callback")
        XCTAssertEqual(query["scope"], "org:create_api_key user:profile user:inference")
        XCTAssertEqual(query["code_challenge"], "the-challenge")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["state"], "the-state")
        XCTAssertEqual(query.count, 7, "no unexpected query items")
    }

    func testAuthorizeURLPercentEncodesSpecialCharacters() throws {
        // Not a value the generator can produce, but the builder must not
        // corrupt the query if it ever receives one.
        let hostile = "a b&c=d#e"
        let url = OAuthClient.authorizeURL(challenge: hostile, state: hostile)

        // Round-trip: a standards-compliant parser recovers the exact value.
        XCTAssertEqual(queryDictionary(of: url)["state"], hostile)
        XCTAssertEqual(queryDictionary(of: url)["code_challenge"], hostile)

        // Characters that would break the query apart are escaped: a raw "#"
        // would truncate it into a fragment, a raw "&" would split the value.
        let absolute = url.absoluteString
        XCTAssertNil(url.fragment)
        XCTAssertFalse(absolute.contains(" "))
        XCTAssertTrue(absolute.contains("a%20b%26c"))
    }

    /// The scope parameter is space-separated per RFC 6749 §3.3; spaces must
    /// arrive percent-encoded, not as raw bytes.
    func testAuthorizeURLEncodesScopeSpaces() {
        let url = OAuthClient.authorizeURL(challenge: "c", state: "s")
        XCTAssertTrue(
            url.absoluteString.contains("org:create_api_key%20user:profile%20user:inference"),
            url.absoluteString)
    }

    // MARK: - Token requests

    func testExchangeRequestBuildsAuthorizationCodePost() throws {
        let request = try OAuthClient.exchangeRequest(
            code: "the-code", state: "the-state", verifier: "the-verifier")

        XCTAssertEqual(request.url?.absoluteString, "https://platform.claude.com/v1/oauth/token")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try JSONDecoder().decode(
            [String: String].self, from: XCTUnwrap(request.httpBody))
        XCTAssertEqual(
            body,
            [
                "grant_type": "authorization_code",
                "code": "the-code",
                "state": "the-state",
                "redirect_uri": "http://localhost:54545/callback",
                "client_id": OAuthConfig.clientID,
                "code_verifier": "the-verifier",
            ])
    }

    func testRefreshRequestBuildsRefreshTokenPost() throws {
        let request = try OAuthClient.refreshRequest(refreshToken: "the-refresh-token")

        XCTAssertEqual(request.url?.absoluteString, OAuthConfig.tokenURL)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try JSONDecoder().decode(
            [String: String].self, from: XCTUnwrap(request.httpBody))
        XCTAssertEqual(
            body,
            [
                "grant_type": "refresh_token",
                "refresh_token": "the-refresh-token",
                "client_id": OAuthConfig.clientID,
            ])
    }

    // MARK: - TokenResponse decoding

    func testTokenResponseDecodesFullPayload() throws {
        let fixture = """
            {
              "access_token": "at-123",
              "refresh_token": "rt-456",
              "expires_in": 28800,
              "account": { "uuid": "acct-uuid", "email_address": "user@example.com" },
              "organization": { "uuid": "org-uuid", "name": "Example Org" }
            }
            """
        let response = try JSONDecoder().decode(TokenResponse.self, from: Data(fixture.utf8))
        XCTAssertEqual(response.accessToken, "at-123")
        XCTAssertEqual(response.refreshToken, "rt-456")
        XCTAssertEqual(response.expiresIn, 28800)
        XCTAssertEqual(response.account?.uuid, "acct-uuid")
        XCTAssertEqual(response.account?.emailAddress, "user@example.com")
        XCTAssertEqual(response.organization?.uuid, "org-uuid")
        XCTAssertEqual(response.organization?.name, "Example Org")
    }

    /// Refresh responses may carry nothing but a new access token; every
    /// other field must be optional.
    func testTokenResponseDecodesMinimalPayload() throws {
        let fixture = #"{ "access_token": "at-only" }"#
        let response = try JSONDecoder().decode(TokenResponse.self, from: Data(fixture.utf8))
        XCTAssertEqual(response.accessToken, "at-only")
        XCTAssertNil(response.refreshToken)
        XCTAssertNil(response.expiresIn)
        XCTAssertNil(response.account)
        XCTAssertNil(response.organization)
    }

    func testTokenResponseRequiresAccessToken() {
        let fixture = #"{ "refresh_token": "rt-only" }"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(TokenResponse.self, from: Data(fixture.utf8)))
    }
}
