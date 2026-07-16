import Foundation

enum UsageError: LocalizedError {
    case unauthorized
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Session expired — sign in again."
        case .http(let code, let body):
            return "Usage request failed (HTTP \(code)): \(body.prefix(120))"
        }
    }
}

enum UsageAPI {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func fetchLimits(accessToken: String) async throws -> [LimitStatus] {
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw UsageError.unauthorized
        }
        guard status == 200 else {
            throw UsageError.http(status, String(data: data, encoding: .utf8) ?? "")
        }

        let parsed = try JSONDecoder().decode(UsageResponse.self, from: data)
        return buildLimits(parsed)
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
                    name = "Session (5h)"
                    sortOrder = 0
                case ("weekly_all", _):
                    name = "Weekly · all models"
                    sortOrder = 1
                case (_, .some(let model)):
                    name = "Weekly · \(model)"
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
                        sortOrder: sortOrder
                    ))
            }
        } else {
            let windows: [(String, UsageResponse.Window?, Int)] = [
                ("Session (5h)", response.fiveHour, 0),
                ("Weekly · all models", response.sevenDay, 1),
                ("Weekly · Opus", response.sevenDayOpus, 2),
                ("Weekly · Sonnet", response.sevenDaySonnet, 3),
            ]
            for (name, window, sortOrder) in windows {
                guard let window, let utilization = window.utilization else { continue }
                result.append(
                    LimitStatus(
                        id: name,
                        name: name,
                        percent: utilization,
                        resetsAt: ISO8601.parse(window.resetsAt),
                        isActive: false,
                        sortOrder: sortOrder
                    ))
            }
        }

        return result.sorted {
            ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name)
        }
    }
}
