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

/// Per-account UI state.
struct AccountDisplayState: Equatable {
    var limits: [LimitStatus] = []
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

    let fiveHour: Window?
    let sevenDay: Window?
    let sevenDayOpus: Window?
    let sevenDaySonnet: Window?
    let limits: [Limit]?

    enum CodingKeys: String, CodingKey {
        case limits
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
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
