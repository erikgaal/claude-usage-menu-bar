import Foundation

enum UsageError: LocalizedError {
    case unauthorized
    case rateLimited(until: Date)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Session expired — sign in again."
        case .rateLimited(let until):
            return "Rate limited — retrying after \(until.formatted(date: .omitted, time: .shortened))"
        case .http(let code, let body):
            return "Usage request failed (HTTP \(code)): \(body.prefix(120))"
        }
    }
}

/// Maps Claude's `organization.rate_limit_tier` strings to relative quota
/// weights (one full Pro session window = ×1).
///
/// Matching is by *marker substring*, not exact string: `rate_limit_tier` is
/// the API's own statement of the rate-limit allocation, so any prefix or
/// suffix variant carrying a known marker — `team_claude_max_5x`,
/// `default_claude_max_5x_trial`, … — inherits that marker's weight. This is
/// what makes unobserved Team/enterprise variants land correctly: two real
/// Team seats were observed reporting plain `default_claude_max_5x`, i.e.
/// Team seats speak the same `max_Nx` vocabulary.
///
/// `organization.seat_tier` (e.g. "team_tier_1") is deliberately ignored: it
/// is a billing/entitlement axis, not a rate-limit one. A tier string with no
/// recognizable marker maps to nil — never guessed — so the ranking falls
/// back to equal weights rather than silently mis-weighting the pool, and
/// the raw string is surfaced in the UI so the user can pick a weight
/// knowingly.
enum ClaudeTier {
    /// The 20× marker must be checked first: "…max_20x" also contains the
    /// substring "max_2"/"max" and would otherwise fall through wrongly.
    /// The account-level `has_claude_pro` boolean is only a last-resort ×1
    /// hint when the tier string is absent entirely (the booleans were
    /// observed false on org-billed plans, so they must never override or
    /// second-guess a tier string that exists).
    static func multiplier(
        forRateLimitTier tier: String?, hasClaudePro: Bool? = nil
    ) -> Double? {
        guard let tier else { return hasClaudePro == true ? 1 : nil }
        let normalized = tier.lowercased()
        if normalized.contains("max_20x") { return 20 }
        if normalized.contains("max_5x") { return 5 }
        // "pro" only counts when no Max marker is present at all, so an
        // unfamiliar "…max_50x…" never reads as Pro.
        if normalized.contains("pro"), !normalized.contains("max") { return 1 }
        return nil  // unrecognized allocation — don't guess
    }
}

extension HTTPURLResponse {
    /// Backoff deadline for a 429, honoring Retry-After when present.
    var retryAfterDate: Date {
        if let value = value(forHTTPHeaderField: "Retry-After"),
            let seconds = TimeInterval(value) {
            return Date().addingTimeInterval(max(30, seconds))
        }
        return Date().addingTimeInterval(300)
    }
}

enum UsageAPI {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let profileEndpoint = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    /// `session` is injectable for tests; production uses the shared session.
    static func fetchUsage(
        accessToken: String, session: URLSession = .shared
    ) async throws -> UsageSnapshot {
        let request = makeRequest(url: endpoint, accessToken: accessToken)

        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw UsageError.unauthorized
        }
        if status == 429 {
            throw UsageError.rateLimited(until: http?.retryAfterDate ?? Date() + 300)
        }
        guard status == 200 else {
            throw UsageError.http(status, String(data: data, encoding: .utf8) ?? "")
        }

        let parsed = try JSONDecoder().decode(UsageResponse.self, from: data)
        return UsageSnapshot(limits: buildLimits(parsed), credits: buildCredits(parsed))
    }

    /// Plan detection via `GET /api/oauth/profile` (same headers as the
    /// usage fetch). Callers treat every thrown error as "unknown" and stay
    /// silent — plan detection must never affect usage display or login.
    static func fetchProfile(
        accessToken: String, session: URLSession = .shared
    ) async throws -> DetectedPlan {
        let request = makeRequest(url: profileEndpoint, accessToken: accessToken)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw UsageError.http(status, String(data: data, encoding: .utf8) ?? "")
        }

        let parsed = try JSONDecoder().decode(ProfileResponse.self, from: data)
        let tier = parsed.organization?.rateLimitTier
        return DetectedPlan(
            rateLimitTier: tier,
            quotaMultiplier: ClaudeTier.multiplier(
                forRateLimitTier: tier, hasClaudePro: parsed.account?.hasClaudePro))
    }

    /// Shared request shape for the OAuth-scoped endpoints.
    private static func makeRequest(url: URL, accessToken: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        return request
    }

    /// Extract extra-usage ("credits") spend. Prefers the newer `spend` block;
    /// falls back to the legacy `extra_usage` block. Returns nil when neither
    /// carries a spend figure.
    static func buildCredits(_ response: UsageResponse) -> CreditsStatus? {
        if let spend = response.spend, let used = spend.used {
            let cap = spend.limit ?? spend.cap?.money
            return CreditsStatus(
                usedMinor: used.amountMinor,
                limitMinor: cap?.amountMinor,
                currency: used.currency ?? response.extraUsage?.currency ?? "USD",
                exponent: used.exponent ?? response.extraUsage?.decimalPlaces ?? 2,
                percent: spend.percent,
                enabled: spend.enabled ?? true
            )
        }
        if let extra = response.extraUsage, let used = extra.usedCredits {
            return CreditsStatus(
                usedMinor: Int(used.rounded()),
                limitMinor: extra.monthlyLimit.map { Int($0.rounded()) },
                currency: extra.currency ?? "USD",
                exponent: extra.decimalPlaces ?? 2,
                percent: extra.utilization,
                enabled: extra.isEnabled ?? true
            )
        }
        return nil
    }

    /// Prefer the server-computed `limits` array (it carries the model-scoped
    /// entries like the Fable weekly limit); fall back to the flat windows.
    static func buildLimits(_ response: UsageResponse) -> [LimitStatus] {
        var result: [LimitStatus] = []

        if let limits = response.limits, !limits.isEmpty {
            for limit in limits {
                guard let percent = limit.percent else { continue }
                let modelName = limit.scope?.model?.displayName
                let name: String
                let sortOrder: Int
                switch (limit.kind, modelName) {
                case ("session", _):
                    name = "Session"
                    sortOrder = 0
                case ("weekly_all", _):
                    name = "Weekly"
                    sortOrder = 1
                case (_, .some(let model)):
                    name = model
                    sortOrder = 2
                default:
                    let kind = limit.kind ?? limit.group ?? "limit"
                    name = kind.replacingOccurrences(of: "_", with: " ").capitalized
                    sortOrder = 3
                }
                result.append(
                    LimitStatus(
                        id: "\(limit.kind ?? "?")|\(modelName ?? "")",
                        name: name,
                        percent: percent,
                        resetsAt: ISO8601.parse(limit.resetsAt),
                        isActive: limit.isActive ?? false,
                        sortOrder: sortOrder,
                        windowSeconds: windowSeconds(forKind: limit.kind)
                    ))
            }
        } else {
            // The window length is in each field's own name (`five_hour`,
            // `seven_day…`), so it's stated data here, not an inference.
            let windows: [(String, UsageResponse.Window?, Int, TimeInterval)] = [
                ("Session", response.fiveHour, 0, 5 * 3600),
                ("Weekly", response.sevenDay, 1, 7 * 86400),
                ("Opus", response.sevenDayOpus, 2, 7 * 86400),
                ("Sonnet", response.sevenDaySonnet, 3, 7 * 86400),
            ]
            for (name, window, sortOrder, windowSeconds) in windows {
                guard let window, let utilization = window.utilization else { continue }
                result.append(
                    LimitStatus(
                        id: name,
                        name: name,
                        percent: utilization,
                        resetsAt: ISO8601.parse(window.resetsAt),
                        isActive: false,
                        sortOrder: sortOrder,
                        windowSeconds: windowSeconds
                    ))
            }
        }

        return result.sorted {
            ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name)
        }
    }

    /// Window length for a `limits[].kind`. The usage endpoint never states a
    /// duration, but the kind vocabulary names one: `session` is the
    /// five-hour window, and every `weekly_*` kind (all-models and the
    /// model-scoped ones like Fable) is the seven-day window. Anything
    /// unrecognized maps to nil rather than a guess — a wrong length would
    /// silently mis-date the start of the window on the trend chart.
    static func windowSeconds(forKind kind: String?) -> TimeInterval? {
        guard let kind = kind?.lowercased() else { return nil }
        if kind.contains("session") { return 5 * 3600 }
        if kind.contains("weekly") { return 7 * 86400 }
        return nil
    }
}
