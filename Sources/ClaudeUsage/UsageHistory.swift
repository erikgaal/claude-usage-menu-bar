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

// MARK: - Trend

/// One limit's shape over its current window: what was recorded, and where
/// the current pace lands. Plain data with no formatting or drawing decisions,
/// so the chart view has nothing to compute and the whole thing is testable
/// without a view.
///
/// The projection reuses the same fitted burn rate as the pace caption and
/// the best-account hint, so the chart can never disagree with the sentence
/// printed next to it.
struct UsageTrend: Equatable {
    struct Point: Equatable, Identifiable {
        let date: Date
        let percent: Double

        var id: Date { date }
    }

    /// Which shape `projected` follows. Worth naming rather than inferring
    /// from the point count: the two models answer the same question in
    /// different units, and a test that means to exercise one must not
    /// silently pass on the other.
    enum Projection: Equatable {
        /// Nothing to project — history too thin, or the window already over.
        case unavailable
        /// One constant fitted %/hour carried to the reset. What every window
        /// got before daily patterns existed, and still what a five-hour
        /// session gets: there is no day/night shape inside five hours to use,
        /// and holding session projections still leaves the Best badge and the
        /// switch notifications exactly as they were.
        case constantRate
        /// The account's learned hour-of-day intensity, scaled to how hard it
        /// is currently being used. Multi-day windows only.
        case dailyPattern
    }

    /// Start of the current window (`resetsAt - windowSeconds`) — the x-axis
    /// origin and the anchor of the even-pace reference.
    let windowStart: Date
    /// When the window resets: the x-axis end and the projection's horizon.
    let windowEnd: Date
    /// Recorded samples inside this window, oldest first, thinned for
    /// drawing. Never empty — `trend(for:)` returns nil instead.
    let recorded: [Point]
    /// The projected path from the newest sample to `windowEnd`, empty when
    /// there's no fittable pace. Flattens at 100% when the pace gets there
    /// first, since usage can't exceed the cap.
    let projected: [Point]
    /// Recent average fill rate in percentage points per hour, nil when
    /// unfittable. Still the straight-line least-squares fit even when
    /// `projection` is `.dailyPattern` — in that case it describes the pace
    /// just gone, *not* the slope of the dashed line, which has no single one.
    let ratePerHour: Double?
    /// Where the projection lands at reset, *uncapped* — above 100 means the
    /// window runs out first, which is the interesting case.
    let projectedAtReset: Double?
    /// When the projection crosses 100%, if that happens before the reset.
    let exhaustsAt: Date?
    /// Which model drew `projected`.
    let projection: Projection

    init(
        windowStart: Date, windowEnd: Date, recorded: [Point], projected: [Point],
        ratePerHour: Double?, projectedAtReset: Double?, exhaustsAt: Date?,
        projection: Projection = .constantRate
    ) {
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.recorded = recorded
        self.projected = projected
        self.ratePerHour = ratePerHour
        self.projectedAtReset = projectedAtReset
        self.exhaustsAt = exhaustsAt
        self.projection = projected.isEmpty ? .unavailable : projection
    }

    /// Newest recorded observation — the "you are here" point.
    var latest: Point { recorded[recorded.count - 1] }

    /// Straight-line extrapolation of one pace from the newest observation to
    /// the window's end. The path flattens at 100% once the pace gets there,
    /// because usage can't exceed the cap — the flat stretch is exactly the
    /// runway that would be spent locked out.
    static func project(
        from latest: Point, ratePerHour: Double, windowEnd: Date
    ) -> (points: [Point], atReset: Double, exhaustsAt: Date?) {
        let hoursToReset = windowEnd.timeIntervalSince(latest.date) / 3600
        let atReset = latest.percent + ratePerHour * hoursToReset
        guard atReset > 100, ratePerHour > 0 else {
            return ([latest, Point(date: windowEnd, percent: min(100, atReset))], atReset, nil)
        }
        let hoursLeft = (100 - latest.percent) / ratePerHour
        let crossing = latest.date.addingTimeInterval(hoursLeft * 3600)
        return (
            [latest, Point(date: crossing, percent: 100), Point(date: windowEnd, percent: 100)],
            atReset, crossing
        )
    }

    /// Walks an `ActivityProfile` forward from the newest observation to the
    /// window's end, spending `scale` times the profile's expected points each
    /// hour. The result is a staircase — flat across the hours this account is
    /// reliably idle, steep across the hours it works — which is the same
    /// shape the recorded line has, so the dashed continuation finally reads
    /// as a continuation instead of an alien ramp.
    ///
    /// One vertex per local hour boundary. Because intensity is constant
    /// within a cell, that polyline is the model exactly rather than a
    /// sampling of it, and a week caps out at 168 points — the same order as
    /// the thinned recorded series.
    ///
    /// Like the constant-rate projection this flattens at 100% and reports the
    /// crossing, and `atReset` stays uncapped so callers can still tell "just
    /// barely" from "days ago".
    static func project(
        from latest: Point, profile: ActivityProfile, scale: Double, windowEnd: Date,
        calendar: Calendar = .current
    ) -> (points: [Point], atReset: Double, exhaustsAt: Date?) {
        var vertices = [latest]
        var percent = latest.percent
        var crossing: Date?
        var cursor = latest.date

        while cursor < windowEnd {
            let boundary = calendar.dateInterval(of: .hour, for: cursor)?.end
            let next = min(windowEnd, boundary ?? windowEnd)
            guard next > cursor else { break }

            let before = percent
            percent += scale * profile.expectedPoints(from: cursor, to: next, calendar: calendar)
            // Land the crossing on the minute it happens rather than on the
            // hour that contains it: this is the figure the caption turns into
            // "on pace to run out 16:19".
            if crossing == nil, percent >= 100, percent > before {
                let fraction = (100 - before) / (percent - before)
                let at = cursor.addingTimeInterval(next.timeIntervalSince(cursor) * fraction)
                if at < next {
                    crossing = at
                    vertices.append(Point(date: at, percent: 100))
                } else {
                    crossing = next
                }
            }
            vertices.append(Point(date: next, percent: min(100, percent)))
            cursor = next
        }

        // A window whose reset is already behind the newest sample leaves
        // nothing to draw; the caller treats an empty path as no projection.
        guard vertices.count > 1 else { return ([], latest.percent, nil) }
        return (vertices, percent, crossing)
    }
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
    /// Longest gap between two samples still treated as observed time. Past
    /// this the app was asleep or quit, and the stretch is unknowable rather
    /// than idle: crediting it as idle would flatten the learned pattern, and
    /// crediting the whole jump to one hour would spike it.
    private let maximumObservedGap: TimeInterval = 30 * 60
    /// A window pinned at its cap records no growth however hard it is being
    /// used, so those stretches teach the pattern nothing and are left out.
    private let saturationFloor = 99.5
    /// How far back the *level* of current activity is fitted. Two days spans
    /// enough day/night cycles that the answer doesn't depend on the hour it
    /// is asked — which it can afford to, because the profile now carries the
    /// within-day variation that a short lookback used to chase.
    private let calibrationSpan: TimeInterval = 48 * 3600
    /// Minimum observed time inside that span before a level is trusted.
    private let minimumCalibrationHours: Double = 6
    /// Ceiling on the level multiple. Guards the case where the profile
    /// expects almost nothing of the hours just gone but they were busy
    /// anyway: without it, dividing by a near-zero expectation projects a
    /// wall.
    private let maximumScale = 3.0

    private let directory: URL
    /// In-memory copy of each account's file, so polls don't re-read disk.
    private var cache: [String: [UsageSample]] = [:]
    /// Learned hour-of-day profiles, per account then per limit. Separate
    /// files from the samples: they outlive `retention` by design, and they're
    /// small enough that rewriting one per poll costs nothing.
    private var profileCache: [String: [String: ActivityProfile]] = [:]

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

    /// Resolves the local hours a pattern is keyed on. Injectable only so
    /// tests can pin a zone: a fixture that means "busy at 14:00" would
    /// otherwise assert something different on a UTC runner than on a machine
    /// in London.
    private let calendar: Calendar

    init(directory: URL? = nil, calendar: Calendar = .current) {
        self.directory =
            directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("dev.erikgaal.claude-usage/history", isDirectory: true)
        self.calendar = calendar
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
        learnPattern(accountID: accountID)
    }

    /// Drops an account's history (called when the account is removed) so
    /// stale files don't accumulate in Application Support.
    func removeHistory(accountID: String) {
        cache[accountID] = nil
        profileCache[accountID] = nil
        try? FileManager.default.removeItem(at: fileURL(accountID: accountID))
        try? FileManager.default.removeItem(at: profileURL(accountID: accountID))
    }

    // MARK: - Learning the daily pattern

    /// Folds everything not yet folded into each limit's hour-of-day profile.
    ///
    /// Driven off the stored samples rather than off the poll that just landed,
    /// so one code path covers both the incremental case and the first run
    /// against history recorded before profiles existed — an install that
    /// upgrades gets a usable pattern immediately instead of waiting days for
    /// one to accumulate. `ActivityProfile.add` ignores stretches at or before
    /// its watermark, which is what makes re-folding free.
    private func learnPattern(accountID: String) {
        var learned = profiles(for: accountID)
        var byLimit: [String: [UsageSample]] = [:]
        for sample in samples(for: accountID) {
            byLimit[sample.limitID, default: []].append(sample)
        }
        for (limitID, rows) in byLimit {
            var profile = learned[limitID] ?? ActivityProfile()
            for (previous, next) in zip(rows, rows.dropFirst()) {
                guard let step = usableInterval(from: previous, to: next) else { continue }
                profile.add(
                    points: step.points, from: step.start, to: step.end,
                    calendar: calendar)
            }
            learned[limitID] = profile
        }
        profileCache[accountID] = learned
        persistProfiles(learned, accountID: accountID)
    }

    /// One stretch of genuinely observed time between consecutive samples, or
    /// nil when nothing can honestly be attributed to it — the single
    /// definition of "usable" shared by the profile and the level fit, so the
    /// two can't disagree about what counts as evidence.
    private func usableInterval(from previous: UsageSample, to next: UsageSample)
        -> (start: Date, end: Date, points: Double)?
    {
        let span = next.timestamp.timeIntervalSince(previous.timestamp)
        guard span > 0, span <= maximumObservedGap else { return nil }
        // A reset makes the delta meaningless; the cap makes it censored.
        guard next.percent - previous.percent >= -resetDropThreshold else { return nil }
        guard previous.percent < saturationFloor else { return nil }
        return (previous.timestamp, next.timestamp, max(0, next.percent - previous.percent))
    }

    /// How hard a limit is being used right now, as a multiple of what its
    /// profile expects of the same hours. This is the *level*, the fast-moving
    /// half of the forecast; the profile supplies the shape.
    ///
    /// Expectation accumulates over observed stretches only, never over
    /// wall-clock — an app quit for half the calibration span must not have
    /// its usage divided by two days of expected demand.
    ///
    /// Deliberately *not* trimmed at the last window reset, unlike everything
    /// the chart draws. How hard someone is working is a fact about them, not
    /// about which window their usage was billed to, so a window that renewed
    /// this morning still gets a level fitted from yesterday instead of
    /// falling back to a straight line for two days. The reset itself
    /// contributes nothing: `usableInterval` drops the stretch it lands in.
    ///
    /// Nil means "don't project a pattern": either too little was observed, or
    /// the profile expects so little of these hours that the ratio would be
    /// noise. Both fall back to the straight line.
    private func activityScale(
        accountID: String, limitID: String, profile: ActivityProfile, asOf now: Date
    ) -> Double? {
        let cutoff = now.addingTimeInterval(-calibrationSpan)
        let rows = samples(for: accountID).filter {
            $0.limitID == limitID && $0.timestamp >= cutoff && $0.timestamp <= now
        }
        var observed = 0.0
        var actual = 0.0
        var expected = 0.0
        for (previous, next) in zip(rows, rows.dropFirst()) {
            guard let step = usableInterval(from: previous, to: next) else { continue }
            observed += step.end.timeIntervalSince(step.start) / 3600
            actual += step.points
            expected += profile.expectedPoints(
                from: step.start, to: step.end, calendar: calendar)
        }
        guard observed >= minimumCalibrationHours else { return nil }
        // Genuinely idle is a real answer, and the only one that keeps an
        // untouched account's projection flat.
        guard actual > 0 else { return 0 }
        guard expected >= 0.5 else { return nil }
        return min(maximumScale, actual / expected)
    }

    /// The pattern-shaped projection for one limit, or nil when the account
    /// hasn't earned one yet. Gated on `isMultiDay`: a five-hour session has
    /// no day/night shape inside it to exploit, and leaving it alone keeps the
    /// Best badge and the switch notifications on exactly the behavior they
    /// were built and tested against.
    private func patternProjection(
        for limit: LimitStatus, accountID: String, latest: UsageTrend.Point, windowEnd: Date
    ) -> (points: [UsageTrend.Point], atReset: Double, exhaustsAt: Date?)? {
        guard limit.isMultiDay, latest.date < windowEnd else { return nil }
        guard let profile = profiles(for: accountID)[limit.id], profile.isUsable else { return nil }
        guard
            let scale = activityScale(
                accountID: accountID, limitID: limit.id, profile: profile, asOf: latest.date)
        else { return nil }

        let projection = UsageTrend.project(
            from: latest, profile: profile, scale: scale, windowEnd: windowEnd,
            calendar: calendar)
        return projection.points.isEmpty ? nil : projection
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

    /// The same question, asked with the limit in hand so a multi-day window
    /// can be answered from its daily pattern instead of a flat rate.
    ///
    /// Callers that only have a limit id keep the flat answer. Everything the
    /// panel prints next to a chart must come through here: the chart's own
    /// caption reads `UsageTrend.exhaustsAt`, and the reset line above it reads
    /// this — two models would put two different times on one card.
    func projectedExhaustion(for limit: LimitStatus, accountID: String) -> Date? {
        guard limit.isMultiDay, let windowStart = limit.windowStart, let windowEnd = limit.resetsAt
        else { return projectedExhaustion(accountID: accountID, limitID: limit.id) }
        // The same window-restricted samples `trend(for:)` reads, so both land
        // on the same "you are here" — thinning preserves the newest exactly.
        guard
            let newest = windowSamples(
                accountID: accountID, limitID: limit.id, since: windowStart).last,
            newest.percent < 100
        else { return projectedExhaustion(accountID: accountID, limitID: limit.id) }

        let latest = UsageTrend.Point(date: newest.timestamp, percent: newest.percent)
        guard
            let patterned = patternProjection(
                for: limit, accountID: accountID, latest: latest, windowEnd: windowEnd)
        else { return projectedExhaustion(accountID: accountID, limitID: limit.id) }
        // Bounded by the reset, exactly as the chart's dashed line is: a
        // crossing that would land after the window renews is a non-event.
        return patterned.exhaustsAt
    }

    // MARK: - Trend series

    /// Recorded-and-projected series for one limit's current window, or nil
    /// when there's nothing to draw: the limit doesn't state its window, or
    /// no samples have landed inside it yet.
    ///
    /// The window comes from the limit itself (`resetsAt - windowSeconds`)
    /// rather than from history, so the x-axis is the real window even when
    /// recording started partway through it — a line that begins on Thursday
    /// tells the truth about what's known.
    func trend(for limit: LimitStatus, accountID: String) -> UsageTrend? {
        guard let windowStart = limit.windowStart, let windowEnd = limit.resetsAt else {
            return nil
        }
        #if DEBUG
            // Mock mode records nothing, so synthesize a plausible series for
            // the README screenshots instead of an empty chart.
            if Mock.isEnabled {
                return Mock.trend(for: limit, windowStart: windowStart, windowEnd: windowEnd)
            }
        #endif

        let samples = windowSamples(accountID: accountID, limitID: limit.id, since: windowStart)
        let recorded = thin(samples, from: windowStart, to: windowEnd)
        guard let latest = recorded.last else { return nil }

        // A rate is only fitted from the current window's recent samples, so
        // it agrees with the pace caption; clamp the noise floor at zero
        // because a window's usage never falls except at its reset.
        let rate = fit(accountID: accountID, limitID: limit.id).map { max(0, $0.ratePerHour) }

        // A multi-day window that has earned a pattern gets the staircase;
        // everything else keeps the straight line. The pattern needs no fitted
        // rate of its own, so it can draw a window whose flat fit was rejected.
        if let patterned = patternProjection(
            for: limit, accountID: accountID, latest: latest, windowEnd: windowEnd)
        {
            return UsageTrend(
                windowStart: windowStart, windowEnd: windowEnd, recorded: recorded,
                projected: patterned.points, ratePerHour: rate,
                projectedAtReset: patterned.atReset, exhaustsAt: patterned.exhaustsAt,
                projection: .dailyPattern)
        }

        guard let rate, latest.date < windowEnd else {
            return UsageTrend(
                windowStart: windowStart, windowEnd: windowEnd, recorded: recorded,
                projected: [], ratePerHour: rate, projectedAtReset: nil, exhaustsAt: nil,
                projection: .unavailable)
        }

        let projection = UsageTrend.project(
            from: latest, ratePerHour: rate, windowEnd: windowEnd)
        return UsageTrend(
            windowStart: windowStart, windowEnd: windowEnd, recorded: recorded,
            projected: projection.points, ratePerHour: rate,
            projectedAtReset: projection.atReset, exhaustsAt: projection.exhaustsAt,
            projection: .constantRate)
    }

    /// Every sample for one limit inside the current window. Unlike
    /// `currentWindowSamples` there's no lookback — the chart wants the whole
    /// window — but the same reset-drop trim applies, so a window that reset
    /// early (or a stale `resetsAt`) can't drag a previous window's tail in.
    private func windowSamples(accountID: String, limitID: String, since: Date) -> [UsageSample] {
        let window = samples(for: accountID).filter {
            $0.limitID == limitID && $0.timestamp >= since
        }
        return trimAtLastReset(window)
    }

    /// Thins samples to at most `maxPoints` evenly spaced buckets, keeping
    /// each bucket's newest sample (percent only climbs within a window, so
    /// the newest is the bucket's peak) plus the first and last overall. A
    /// week of 5-minute polls is ~2000 rows; drawing them all costs time and
    /// shows nothing extra at 300 points wide.
    private func thin(
        _ samples: [UsageSample], from: Date, to: Date, maxPoints: Int = 120
    ) -> [UsageTrend.Point] {
        guard !samples.isEmpty else { return [] }
        let span = to.timeIntervalSince(from)
        guard span > 0, samples.count > maxPoints else {
            return samples.map { UsageTrend.Point(date: $0.timestamp, percent: $0.percent) }
        }

        func bucket(_ sample: UsageSample) -> Int {
            let offset = sample.timestamp.timeIntervalSince(from) / span
            return min(maxPoints - 1, max(0, Int(offset * Double(maxPoints))))
        }

        // Keep the very first sample so the line starts where recording did,
        // then one per bucket as each one closes.
        var kept: [UsageSample] = [samples[0]]
        var openBucket = bucket(samples[0])
        var newestInBucket = samples[0]
        for sample in samples.dropFirst() {
            let index = bucket(sample)
            if index != openBucket {
                if newestInBucket.timestamp != kept[kept.count - 1].timestamp {
                    kept.append(newestInBucket)
                }
                openBucket = index
            }
            newestInBucket = sample
        }
        if newestInBucket.timestamp != kept[kept.count - 1].timestamp {
            kept.append(newestInBucket)
        }
        return kept.map { UsageTrend.Point(date: $0.timestamp, percent: $0.percent) }
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
        return trimAtLastReset(all.filter { $0.timestamp >= cutoff })
    }

    /// Drops everything up to and including the most recent window reset, so
    /// no caller ever reads across one. A reset shows up as a percent drop
    /// bigger than rounding jitter.
    private func trimAtLastReset(_ samples: [UsageSample]) -> [UsageSample] {
        guard samples.count >= 2 else { return samples }
        var start = 0
        for index in 1..<samples.count
        where samples[index].percent < samples[index - 1].percent - resetDropThreshold {
            start = index
        }
        return start > 0 ? Array(samples[start...]) : samples
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

    /// Learned profiles for one account, keyed by limit id. A profile is only
    /// ever a cache of what the samples already say, so anything that fails to
    /// decode — or decodes with the wrong cell count — is dropped and rebuilt
    /// by the next `learnPattern` rather than migrated.
    private func profiles(for accountID: String) -> [String: ActivityProfile] {
        if let cached = profileCache[accountID] { return cached }
        var loaded: [String: ActivityProfile] = [:]
        if let data = try? Data(contentsOf: profileURL(accountID: accountID)),
            let decoded = try? decoder.decode([String: ActivityProfile].self, from: data)
        {
            loaded = decoded.filter { $0.value.isWellFormed }
        }
        profileCache[accountID] = loaded
        // Nothing on disk but samples to learn from: the first launch after an
        // upgrade, or a profile file that failed to decode. Build it now rather
        // than drawing straight lines until the next poll lands — `learnPattern`
        // reads this cache, which is already primed, so it can't recurse.
        if loaded.isEmpty, !samples(for: accountID).isEmpty {
            learnPattern(accountID: accountID)
            return profileCache[accountID] ?? loaded
        }
        return loaded
    }

    private func persistProfiles(_ profiles: [String: ActivityProfile], accountID: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(profiles) else { return }
        try? data.write(to: profileURL(accountID: accountID), options: .atomic)
    }

    private func fileURL(accountID: String) -> URL {
        directory.appendingPathComponent("\(safeName(accountID)).json")
    }

    private func profileURL(accountID: String) -> URL {
        directory.appendingPathComponent("\(safeName(accountID)).pattern.json")
    }

    private func safeName(_ accountID: String) -> String {
        // Account IDs are UUIDs today, but don't trust them as file names.
        String(accountID.map { $0.isLetter || $0.isNumber || "-._".contains($0) ? $0 : "_" })
    }
}
