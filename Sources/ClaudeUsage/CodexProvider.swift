import AppKit
import Foundation

/// OAuth + usage constants for OpenAI Codex, matching the Codex CLI's public
/// client (extracted from codex-rs `login/src/server.rs` / `auth/manager.rs`).
enum CodexConfig {
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let issuer = "https://auth.openai.com"
    static var authorizeURL: String { "\(issuer)/oauth/authorize" }
    static var tokenURL: String { "\(issuer)/oauth/token" }
    static let callbackPort: UInt16 = 1455
    static let callbackPath = "/auth/callback"
    static var redirectURI: String { "http://localhost:\(callbackPort)\(callbackPath)" }
    static let scope =
        "openid profile email offline_access api.connectors.read api.connectors.invoke"
    /// Primary path is what the Codex CLI uses against the ChatGPT backend;
    /// the second is the same endpoint under its alternative routing style.
    static let usageURLs = [
        URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
        URL(string: "https://chatgpt.com/backend-api/api/codex/usage")!,
    ]
    /// Index of the last usage URL that returned 200, so polling doesn't
    /// probe dead routes every cycle. Benign if racy.
    nonisolated(unsafe) static var preferredUsageURLIndex = 0
}

struct CodexProvider: UsageProvider {
    let id = ProviderID.codex
    let accountKind = "Add Codex Account… (ChatGPT)"

    // MARK: - Login

    func login() async throws -> LoginResult {
        let verifier = PKCE.randomURLSafeString()
        let challenge = PKCE.challenge(for: verifier)
        let state = PKCE.randomURLSafeString()

        let server = CallbackServer()
        defer { server.stop() }

        async let callback = server.waitForCallback(
            port: CodexConfig.callbackPort, path: CodexConfig.callbackPath)

        try await Task.sleep(nanoseconds: 200_000_000)
        _ = await MainActor.run {
            NSWorkspace.shared.open(authorizeURL(challenge: challenge, state: state))
        }

        let (code, returnedState) = try await callback
        guard returnedState == state else { throw OAuthError.stateMismatch }

        let response = try await exchangeCode(code: code, verifier: verifier)
        return try makeLoginResult(response)
    }

    private func authorizeURL(challenge: String, state: String) -> URL {
        var components = URLComponents(string: CodexConfig.authorizeURL)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: CodexConfig.clientID),
            URLQueryItem(name: "redirect_uri", value: CodexConfig.redirectURI),
            URLQueryItem(name: "scope", value: CodexConfig.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "originator", value: "codex_cli_rs"),
        ]
        return components.url!
    }

    // MARK: - Token endpoint

    private struct CodexTokenResponse: Decodable {
        let idToken: String?
        let accessToken: String?
        let refreshToken: String?

        enum CodingKeys: String, CodingKey {
            case idToken = "id_token"
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
        }
    }

    /// Authorization-code exchange is form-encoded (like the Codex CLI does it).
    private func exchangeCode(code: String, verifier: String) async throws -> CodexTokenResponse {
        var request = URLRequest(url: URL(string: CodexConfig.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": CodexConfig.redirectURI,
            "client_id": CodexConfig.clientID,
            "code_verifier": verifier,
        ])
        return try await send(request)
    }

    /// Refresh is a JSON POST (also mirroring the Codex CLI).
    func refresh(tokens: StoredTokens) async throws -> StoredTokens {
        var request = URLRequest(url: URL(string: CodexConfig.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "client_id": CodexConfig.clientID,
            "grant_type": "refresh_token",
            "refresh_token": tokens.refreshToken,
        ])
        let response: CodexTokenResponse = try await send(request)

        let accessToken = response.accessToken ?? tokens.accessToken
        return StoredTokens(
            accessToken: accessToken,
            refreshToken: response.refreshToken ?? tokens.refreshToken,
            expiresAt: JWT.expiry(accessToken) ?? Date().addingTimeInterval(8 * 3600)
        )
    }

    private func send(_ request: URLRequest) async throws -> CodexTokenResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw OAuthError.httpError(status, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(CodexTokenResponse.self, from: data)
    }

    private func makeLoginResult(_ response: CodexTokenResponse) throws -> LoginResult {
        guard let accessToken = response.accessToken,
            let refreshToken = response.refreshToken
        else {
            throw OAuthError.httpError(200, "Token response is missing tokens")
        }

        let idClaims = JWT.claims(response.idToken)
        let accessClaims = JWT.claims(accessToken)
        let auth =
            (idClaims?["https://api.openai.com/auth"]
                ?? accessClaims?["https://api.openai.com/auth"]) as? [String: Any]
        let profile =
            (idClaims?["https://api.openai.com/profile"]
                ?? accessClaims?["https://api.openai.com/profile"]) as? [String: Any]

        let email =
            (idClaims?["email"] as? String)
            ?? (profile?["email"] as? String)
            ?? "ChatGPT account"
        let plan = (auth?["chatgpt_plan_type"] as? String).map { "ChatGPT \($0)" }

        return LoginResult(
            accountID: auth?["chatgpt_account_id"] as? String ?? UUID().uuidString,
            email: email,
            organizationName: plan,
            tokens: StoredTokens(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: JWT.expiry(accessToken) ?? Date().addingTimeInterval(8 * 3600)
            )
        )
    }

    private static func formEncode(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = fields.map { key, value in
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(key)=\(v)"
        }
        return Data(encoded.joined(separator: "&").utf8)
    }

    // MARK: - Usage

    struct CodexUsageResponse: Decodable {
        struct Window: Decodable {
            let usedPercent: Double?
            let limitWindowSeconds: Double?
            let resetAt: Double?

            enum CodingKeys: String, CodingKey {
                case usedPercent = "used_percent"
                case limitWindowSeconds = "limit_window_seconds"
                case resetAt = "reset_at"
            }
        }
        struct Details: Decodable {
            let primaryWindow: Window?
            let secondaryWindow: Window?

            enum CodingKeys: String, CodingKey {
                case primaryWindow = "primary_window"
                case secondaryWindow = "secondary_window"
            }
        }
        struct AdditionalLimit: Decodable {
            let limitName: String?
            let rateLimit: Details?

            enum CodingKeys: String, CodingKey {
                case limitName = "limit_name"
                case rateLimit = "rate_limit"
            }
        }

        let planType: String?
        let rateLimit: Details?
        let additionalRateLimits: [AdditionalLimit]?

        enum CodingKeys: String, CodingKey {
            case planType = "plan_type"
            case rateLimit = "rate_limit"
            case additionalRateLimits = "additional_rate_limits"
        }
    }

    func fetchLimits(accessToken: String, accountID: String) async throws -> [LimitStatus] {
        var lastError: Error = UsageError.http(0, "No usage URL configured")
        let urlCount = CodexConfig.usageURLs.count
        let startIndex = CodexConfig.preferredUsageURLIndex

        for offset in 0..<urlCount {
            let index = (startIndex + offset) % urlCount
            var request = URLRequest(url: CodexConfig.usageURLs[index])
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
            request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15

            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if status == 401 {
                throw UsageError.unauthorized
            }
            if status == 429 {
                throw UsageError.rateLimited(until: http?.retryAfterDate ?? Date() + 300)
            }
            guard status == 200 else {
                lastError = UsageError.http(status, String(data: data, encoding: .utf8) ?? "")
                // Only try the alternative route when this one doesn't exist;
                // other failures apply to the account, not the routing style.
                if status == 404 || status == 405 { continue }
                throw lastError
            }
            CodexConfig.preferredUsageURLIndex = index
            let parsed = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
            return Self.buildLimits(parsed)
        }
        throw lastError
    }

    static func buildLimits(_ response: CodexUsageResponse) -> [LimitStatus] {
        var result: [LimitStatus] = []

        func add(
            _ window: CodexUsageResponse.Window?, label: String?, sortOrder: Int, idPrefix: String
        ) {
            guard let window, let percent = window.usedPercent else { return }
            let name = label ?? windowName(seconds: window.limitWindowSeconds)
            result.append(
                LimitStatus(
                    id: "\(idPrefix)|\(name)",
                    name: name,
                    percent: percent,
                    resetsAt: window.resetAt.map { Date(timeIntervalSince1970: $0) },
                    isActive: false,
                    sortOrder: sortOrder
                ))
        }

        add(response.rateLimit?.primaryWindow, label: nil, sortOrder: 0, idPrefix: "primary")
        add(response.rateLimit?.secondaryWindow, label: nil, sortOrder: 1, idPrefix: "secondary")

        for (index, extra) in (response.additionalRateLimits ?? []).enumerated() {
            let base =
                extra.limitName?
                .replacingOccurrences(of: "_", with: " ")
                .capitalized ?? "Extra limit"
            let details = extra.rateLimit
            let hasBoth = details?.primaryWindow != nil && details?.secondaryWindow != nil
            add(
                details?.primaryWindow,
                label: hasBoth ? "\(base) · session" : base,
                sortOrder: 2 + index, idPrefix: "extra-p\(index)")
            add(
                details?.secondaryWindow,
                label: hasBoth ? "\(base) · weekly" : base,
                sortOrder: 2 + index, idPrefix: "extra-s\(index)")
        }

        return result.sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
    }

    static func windowName(seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "Window" }
        let hours = Int((seconds / 3600).rounded())
        if hours <= 24 { return "Session (\(hours)h)" }
        let days = Int((seconds / 86400).rounded())
        return days == 7 ? "Weekly" : "\(days)-day window"
    }
}
