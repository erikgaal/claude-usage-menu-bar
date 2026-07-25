import AppKit
import CryptoKit
import Foundation

/// OAuth constants matching Claude Code's public client, extracted from the
/// Claude Code 2.1.211 binary. Logging in here is the same flow as `/login`
/// with "Claude account with subscription".
enum OAuthConfig {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeURL = "https://claude.com/cai/oauth/authorize"
    static let tokenURL = "https://platform.claude.com/v1/oauth/token"
    static let callbackPort: UInt16 = 54545
    static var redirectURI: String { "http://localhost:\(callbackPort)/callback" }

    /// Exactly what `claude auth login` asks for, and it has to stay exactly
    /// that while the app can hand its tokens to Claude Code.
    ///
    /// A token carries the scopes it was minted with, permanently — a refresh
    /// never widens them. So a token minted with a narrower set doesn't just
    /// limit this app; handed over by a Claude Code switch, it silently
    /// downgrades the CLI. Requesting only the first three left
    /// `user:sessions:claude_code` off, and `/rc` (remote-control, "control
    /// this session from your phone or claude.ai/code") stopped working for
    /// any account switched in this way.
    ///
    /// Mirrors the binary's own list, which is the dedup of
    /// `[org:create_api_key, user:profile]` with `[user:profile,
    /// user:inference, user:sessions:claude_code, user:mcp_servers,
    /// user:file_upload]`.
    static let scopes = [
        "org:create_api_key",
        "user:profile",
        "user:inference",
        "user:sessions:claude_code",
        "user:mcp_servers",
        "user:file_upload",
    ]
}

enum OAuthError: LocalizedError {
    case stateMismatch
    case httpError(Int, String)
    case authorizationDenied(String)

    var errorDescription: String? {
        switch self {
        case .stateMismatch:
            return "Login failed: OAuth state mismatch."
        case .httpError(let code, let body):
            return "Token endpoint returned HTTP \(code): \(body.prefix(200))"
        case .authorizationDenied(let reason):
            return "Authorization was denied: \(reason)"
        }
    }
}

enum PKCE {
    static func randomURLSafeString(bytes count: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct LoginResult {
    let accountID: String
    let email: String
    let organizationName: String?
    let tokens: StoredTokens
}

enum OAuthClient {
    /// Runs the full browser login: starts the localhost callback listener,
    /// opens the authorize page, waits for the redirect, exchanges the code.
    static func login() async throws -> LoginResult {
        let verifier = PKCE.randomURLSafeString()
        let challenge = PKCE.challenge(for: verifier)
        let state = PKCE.randomURLSafeString()

        let server = CallbackServer()
        defer { server.stop() }

        async let callback = server.waitForCallback(port: OAuthConfig.callbackPort)

        // Give the listener a beat to bind before the browser redirects back.
        try await Task.sleep(nanoseconds: 200_000_000)
        _ = await MainActor.run {
            NSWorkspace.shared.open(authorizeURL(challenge: challenge, state: state))
        }

        let (code, returnedState) = try await callback
        guard returnedState == state else { throw OAuthError.stateMismatch }

        let response = try await exchangeCode(code: code, state: state, verifier: verifier)
        return makeResult(from: response, previousRefreshToken: nil)
    }

    static func refresh(
        refreshToken: String, previousScopes: [String]? = nil
    ) async throws -> LoginResult {
        let response = try await postToken(refreshRequest(refreshToken: refreshToken))
        return makeResult(
            from: response, previousRefreshToken: refreshToken,
            previousScopes: previousScopes)
    }

    // MARK: - Request building (internal so tests can inspect without network)

    static func authorizeURL(challenge: String, state: String) -> URL {
        var components = URLComponents(string: OAuthConfig.authorizeURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: OAuthConfig.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: OAuthConfig.redirectURI),
            URLQueryItem(name: "scope", value: OAuthConfig.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    /// The authorization-code exchange request `login()` sends.
    static func exchangeRequest(code: String, state: String, verifier: String) throws -> URLRequest
    {
        try tokenRequest(body: [
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "redirect_uri": OAuthConfig.redirectURI,
            "client_id": OAuthConfig.clientID,
            "code_verifier": verifier,
        ])
    }

    /// The refresh request `refresh(refreshToken:)` sends.
    static func refreshRequest(refreshToken: String) throws -> URLRequest {
        try tokenRequest(body: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": OAuthConfig.clientID,
        ])
    }

    // MARK: - Internals

    private static func makeResult(
        from response: TokenResponse, previousRefreshToken: String?,
        previousScopes: [String]? = nil
    ) -> LoginResult {
        let tokens = StoredTokens(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? previousRefreshToken ?? "",
            expiresAt: Date().addingTimeInterval(response.expiresIn ?? 3600),
            // A refresh returns the grant the token already had; it never
            // widens it. When the server doesn't restate the scopes, the
            // previous ones are the truth — falling back to the current
            // constant would claim scopes this chain was never granted.
            scopes: response.scope.map { _ in response.grantedScopes }
                ?? previousScopes ?? response.grantedScopes
        )
        return LoginResult(
            accountID: response.account?.uuid ?? UUID().uuidString,
            email: response.account?.emailAddress ?? "Claude account",
            organizationName: response.organization?.name,
            tokens: tokens
        )
    }

    private static func tokenRequest(body: [String: String]) throws -> URLRequest {
        var request = URLRequest(url: URL(string: OAuthConfig.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private static func exchangeCode(
        code: String, state: String, verifier: String
    ) async throws -> TokenResponse {
        try await postToken(exchangeRequest(code: code, state: state, verifier: verifier))
    }

    private static func postToken(_ request: URLRequest) async throws -> TokenResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw OAuthError.httpError(status, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }
}
