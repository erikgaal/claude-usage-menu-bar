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
    static let scopes = ["org:create_api_key", "user:profile", "user:inference"]
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

    static func refresh(refreshToken: String) async throws -> LoginResult {
        let response = try await postToken(body: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": OAuthConfig.clientID,
        ])
        return makeResult(from: response, previousRefreshToken: refreshToken)
    }

    // MARK: - Internals

    private static func makeResult(
        from response: TokenResponse, previousRefreshToken: String?
    ) -> LoginResult {
        let tokens = StoredTokens(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? previousRefreshToken ?? "",
            expiresAt: Date().addingTimeInterval(response.expiresIn ?? 3600)
        )
        return LoginResult(
            accountID: response.account?.uuid ?? UUID().uuidString,
            email: response.account?.emailAddress ?? "Claude account",
            organizationName: response.organization?.name,
            tokens: tokens
        )
    }

    private static func authorizeURL(challenge: String, state: String) -> URL {
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

    private static func exchangeCode(
        code: String, state: String, verifier: String
    ) async throws -> TokenResponse {
        try await postToken(body: [
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "redirect_uri": OAuthConfig.redirectURI,
            "client_id": OAuthConfig.clientID,
            "code_verifier": verifier,
        ])
    }

    private static func postToken(body: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: OAuthConfig.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw OAuthError.httpError(status, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }
}
