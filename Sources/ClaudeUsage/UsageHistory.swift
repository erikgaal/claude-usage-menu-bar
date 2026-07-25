import Foundation

// MARK: - Sample

/// One observation of a single rate-limit window at poll time. Stored as flat
/// rows rather than nested snapshots so pruning and per-limit queries stay
/// trivial, and so the format survives limits appearing or disappearing.
struct UsageSample: Codable, Equatable {
    let timestamp: Date
    let limitID: String
    let limitName: String
    let percent: Double
    let resetsAt: Date?
}

// MARK: - Store

/// Persists each successful poll's per-limit percents and answers burn-rate
/// questions: how fast is a window filling, and when does it run out?
///
/// Storage is one JSON file per account under Application Support. At the
/// 5-minute poll cadence, 14 days of a few limits is ~10k tiny rows — small
/// enough that a synchronous encode-and-write per poll is fine and keeps the
/// store free of async plumbing.
@MainActor
final class UsageHistoryStore {
    static let shared = UsageHistoryStore()

    /// Keep this much history on disk — enough runway for weekly-limit trends
    /// (and the follow-up sparklines) without the files ever getting big.
    private let retention: TimeInterval = 14 * 86400
    /// A projection needs at least this many samples…
    private let minimumSamples = 3
    /// …spanning at least this long, or the slope is dominated by API noise.
    private let minimumSpan: TimeInterval = 30 * 60
    /// Slopes below this (%/hour) project exhaustion days out; treat as flat.
    private let minimumRate = 0.1
    /// Percent can only fall when the window resets, so a drop bigger than
    /// rounding jitter marks a window boundary that projections must not cross.
    private let resetDropThreshold = 5.0

    private let directory: URL
    /// In-memory copy of each account's file, so polls don't re-read disk.
    private var cache: [String: [UsageSample]] = [:]

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(directory: URL? = nil) {
        self.directory =
            directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("dev.erikgaal.claude-usage/history", isDirectory: true)
    }

    // MARK: - Recording

    /// Appends one poll's limits for an account, prunes anything beyond the
    /// retention window, and writes the file back.
    func record(_ limits: [LimitStatus], accountID: String, at now: Date = Date()) {
        #if DEBUG
            // Screenshot/mock runs must never pollute real on-disk history.
            if Mock.isEnabled { return }
        #endif
        guard !limits.isEmpty else { return }

        var samples = samples(for: accountID)
        for limit in limits {
            samples.append(
                UsageSample(
                    timestamp: now,
                    limitID: limit.id,
                    limitName: limit.name,
                    percent: limit.percent,
                    resetsAt: limit.resetsAt
                ))
        }
        let cutoff = now.addingTimeInterval(-retention)
        // Samples are appended in time order, so pruning is a prefix drop.
        if let firstKept = samples.firstIndex(where: { $0.timestamp >= cutoff }) {
            samples.removeFirst(firstKept)
        } else {
            samples.removeAll()
        }
        cache[accountID] = samples
        persist(samples, accountID: accountID)
    }

    /// Drops an account's history (called when the account is removed) so
    /// stale files don't accumulate in Application Support.
    func removeHistory(accountID: String) {
        cache[accountID] = nil
        try? FileManager.default.removeItem(at: fileURL(accountID: accountID))
    }

    // MARK: - Burn rate & projection

    /// Fill rate in percentage points per hour for one limit, from a
    /// least-squares fit over recent samples of the *current* window only.
    /// Nil when history is too thin to trust (see `minimumSamples`/`Span`).
    func burnRate(accountID: String, limitID: String) -> Double? {
        fit(accountID: accountID, limitID: limitID)?.ratePerHour
    }

    /// When the limit hits 100% if the current pace holds. Nil when the pace
    /// is flat or history is too thin — callers should treat nil as "nothing
    /// worth saying", since silence beats a noisy forecast.
    func projectedExhaustion(accountID: String, limitID: String) -> Date? {
        guard let (rate, latest) = fit(accountID: accountID, limitID: limitID),
            rate >= minimumRate, latest.percent < 100
        else { return nil }
        let hoursLeft = (100 - latest.percent) / rate
        return latest.timestamp.addingTimeInterval(hoursLeft * 3600)
    }

    /// Regression over the current window's recent samples, gated on having
    /// enough of them to mean something.
    private func fit(accountID: String, limitID: String) -> (
        ratePerHour: Double, latest: UsageSample
    )? {
        let window = currentWindowSamples(accountID: accountID, limitID: limitID)
        guard window.count >= minimumSamples,
            let first = window.first, let latest = window.last,
            latest.timestamp.timeIntervalSince(first.timestamp) >= minimumSpan,
            let rate = slopePerHour(of: window)
        else { return nil }
        return (rate, latest)
    }

    /// Recent samples for one limit, restricted to its current window: a
    /// short lookback keeps the fit responsive, and anything before the most
    /// recent reset is discarded — fitting across a reset (a sharp percent
    /// drop) would produce a nonsense slope.
    private func currentWindowSamples(accountID: String, limitID: String) -> [UsageSample] {
        let all = samples(for: accountID).filter { $0.limitID == limitID }
        guard let latest = all.last else { return [] }

        let cutoff = latest.timestamp.addingTimeInterval(-lookback(for: latest))
        var window = all.filter { $0.timestamp >= cutoff }
        guard window.count >= 2 else { return window }

        var start = 0
        for index in 1..<window.count
        where window[index].percent < window[index - 1].percent - resetDropThreshold {
            start = index
        }
        if start > 0 { window.removeFirst(start) }
        return window
    }

    /// Session windows fill fast, so hours-old samples mislead; weekly
    /// windows fill slowly, so a short lookback would only see noise.
    private func lookback(for sample: UsageSample) -> TimeInterval {
        let key = "\(sample.limitID) \(sample.limitName)".lowercased()
        if key.contains("session") || key.contains("five") || key.contains("5h") {
            return 1 * 3600
        }
        return 12 * 3600
    }

    /// Least-squares slope of percent over time, in %/hour. Nil when all
    /// samples share one timestamp (no time axis to fit against).
    private func slopePerHour(of samples: [UsageSample]) -> Double? {
        guard samples.count >= 2, let first = samples.first else { return nil }
        let points = samples.map {
            (x: $0.timestamp.timeIntervalSince(first.timestamp) / 3600, y: $0.percent)
        }
        let count = Double(points.count)
        let meanX = points.reduce(0) { $0 + $1.x } / count
        let meanY = points.reduce(0) { $0 + $1.y } / count
        let varianceX = points.reduce(0) { $0 + ($1.x - meanX) * ($1.x - meanX) }
        guard varianceX > 0 else { return nil }
        let covariance = points.reduce(0) { $0 + ($1.x - meanX) * ($1.y - meanY) }
        return covariance / varianceX
    }

    // MARK: - Persistence

    private func samples(for accountID: String) -> [UsageSample] {
        if let cached = cache[accountID] { return cached }
        let loaded = load(accountID: accountID)
        cache[accountID] = loaded
        return loaded
    }

    private func load(accountID: String) -> [UsageSample] {
        guard let data = try? Data(contentsOf: fileURL(accountID: accountID)),
            let decoded = try? decoder.decode([UsageSample].self, from: data)
        else { return [] }
        // Sort defensively: every query assumes chronological order.
        return decoded.sorted { $0.timestamp < $1.timestamp }
    }

    private func persist(_ samples: [UsageSample], accountID: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(samples) else { return }
        try? data.write(to: fileURL(accountID: accountID), options: .atomic)
    }

    private func fileURL(accountID: String) -> URL {
        // Account IDs are UUIDs today, but don't trust them as file names.
        let safe = String(
            accountID.map { $0.isLetter || $0.isNumber || "-._".contains($0) ? $0 : "_" })
        return directory.appendingPathComponent("\(safe).json")
    }
}
