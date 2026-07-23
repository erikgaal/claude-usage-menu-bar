import Foundation

/// A saved account (one provider subscription). Token material lives in the
/// Keychain, keyed by `id`; this metadata is persisted in UserDefaults.
struct AccountMeta: Codable, Identifiable, Equatable {
    let id: String
    var email: String
    var organizationName: String?
    var provider: ProviderID
    /// User-chosen display name ("Work", "Personal"); nil → provider name.
    var label: String?

    var displayLabel: String { label ?? provider.displayName }

    init(
        id: String, email: String, organizationName: String?, provider: ProviderID,
        label: String? = nil
    ) {
        self.id = id
        self.email = email
        self.organizationName = organizationName
        self.provider = provider
        self.label = label
    }

    // Accounts saved before multi-provider/label support lack those keys.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        email = try container.decode(String.self, forKey: .email)
        organizationName = try container.decodeIfPresent(String.self, forKey: .organizationName)
        provider = try container.decodeIfPresent(ProviderID.self, forKey: .provider) ?? .claude
        label = try container.decodeIfPresent(String.self, forKey: .label)
    }
}

/// OAuth token material stored in the Keychain per account.
struct StoredTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

/// One rate-limit window as displayed in the UI.
struct LimitStatus: Identifiable, Equatable {
    let id: String
    let name: String
    /// 0–100
    let percent: Double
    let resetsAt: Date?
    let isActive: Bool
    let sortOrder: Int
}

/// Extra-usage ("credits") spend for an account, rendered as its own bar.
/// Amounts are in minor currency units (e.g. pence). `limitMinor` is the spend
/// cap when one is set — nil means uncapped, so the bar has no denominator to
/// fill and only the spent amount is meaningful.
struct CreditsStatus: Equatable {
    let usedMinor: Int
    let limitMinor: Int?
    let currency: String
    let exponent: Int
    /// Server-computed cap consumption (0 when uncapped); used only as a
    /// fallback when we can't compute used/limit ourselves.
    let percent: Double?
    let enabled: Bool

    var hasCap: Bool { (limitMinor ?? 0) > 0 }

    /// Bar fill: used/cap when a cap exists, else the server percent (≈0).
    var fillPercent: Double {
        if let limitMinor, limitMinor > 0 {
            return min(100, Double(usedMinor) / Double(limitMinor) * 100)
        }
        return percent ?? 0
    }

    /// Only worth showing when the feature is on and there's something to see
    /// (money spent or a cap to track) — hides idle £0/no-cap accounts.
    var isMeaningful: Bool { enabled && (usedMinor > 0 || hasCap) }

    var usedText: String { Self.money(usedMinor, currency: currency, exponent: exponent) }
    var limitText: String? {
        limitMinor.map { Self.money($0, currency: currency, exponent: exponent) }
    }

    private static func money(_ minor: Int, currency: String, exponent: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.minimumFractionDigits = exponent
        formatter.maximumFractionDigits = exponent
        let value = Double(minor) / pow(10.0, Double(exponent))
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

/// One fetch's worth of an account's usage: rate-limit windows plus optional
/// extra-usage credits. Providers with no credits concept leave it nil.
struct UsageSnapshot: Equatable {
    var limits: [LimitStatus]
    var credits: CreditsStatus?
}

/// Per-account UI state.
struct AccountDisplayState: Equatable {
    var limits: [LimitStatus] = []
    var credits: CreditsStatus?
    var lastUpdated: Date?
    var error: String?
    var needsReauth: Bool = false
}

// MARK: - Wire formats

/// Response of `GET https://api.anthropic.com/api/oauth/usage`.
struct UsageResponse: Decodable {
    struct Window: Decodable {
        let utilization: Double?
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    struct Limit: Decodable {
        struct Scope: Decodable {
            struct Model: Decodable {
                let displayName: String?
                enum CodingKeys: String, CodingKey {
                    case displayName = "display_name"
                }
            }
            let model: Model?
        }

        let kind: String?
        let group: String?
        let percent: Double?
        let severity: String?
        let resetsAt: String?
        let scope: Scope?
        let isActive: Bool?

        enum CodingKeys: String, CodingKey {
            case kind, group, percent, severity, scope
            case resetsAt = "resets_at"
            case isActive = "is_active"
        }
    }

    /// A monetary amount, e.g. `{ "amount_minor": 657, "currency": "GBP", "exponent": 2 }`.
    struct Money: Decodable {
        let amountMinor: Int
        let currency: String?
        let exponent: Int?

        enum CodingKeys: String, CodingKey {
            case amountMinor = "amount_minor"
            case currency, exponent
        }
    }

    /// Newer, richer extra-usage block. Preferred over `extraUsage`.
    struct Spend: Decodable {
        /// `cap` nests its amount a level deeper than `limit` does:
        /// `{ "money": { "amount_minor": … }, "credits": null }`.
        struct Cap: Decodable {
            let money: Money?
        }

        let used: Money?
        let limit: Money?
        let cap: Cap?
        let percent: Double?
        let enabled: Bool?
    }

    /// Legacy extra-usage block; fallback when `spend` is absent. Amounts are
    /// already in minor units (`used_credits: 657.0` == 657 pence).
    struct ExtraUsage: Decodable {
        let isEnabled: Bool?
        let usedCredits: Double?
        let monthlyLimit: Double?
        let utilization: Double?
        let currency: String?
        let decimalPlaces: Int?

        enum CodingKeys: String, CodingKey {
            case isEnabled = "is_enabled"
            case usedCredits = "used_credits"
            case monthlyLimit = "monthly_limit"
            case utilization, currency
            case decimalPlaces = "decimal_places"
        }
    }

    let fiveHour: Window?
    let sevenDay: Window?
    let sevenDayOpus: Window?
    let sevenDaySonnet: Window?
    let limits: [Limit]?
    let spend: Spend?
    let extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case limits, spend
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case extraUsage = "extra_usage"
    }
}

/// Response of `POST /v1/oauth/token`.
struct TokenResponse: Decodable {
    struct Account: Decodable {
        let uuid: String?
        let emailAddress: String?
        enum CodingKeys: String, CodingKey {
            case uuid
            case emailAddress = "email_address"
        }
    }
    struct Organization: Decodable {
        let uuid: String?
        let name: String?
    }

    let accessToken: String
    let refreshToken: String?
    let expiresIn: Double?
    let account: Account?
    let organization: Organization?

    enum CodingKeys: String, CodingKey {
        case account, organization
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

// MARK: - Date parsing

enum ISO8601 {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ string: String?) -> Date? {
        guard let string else { return nil }
        if let d = fractional.date(from: string) { return d }
        if let d = plain.date(from: string) { return d }
        // Strip sub-second digits of any length and retry (the API sends 6 digits).
        let stripped = string.replacingOccurrences(
            of: #"\.\d+"#, with: "", options: .regularExpression)
        return plain.date(from: stripped)
    }
}
