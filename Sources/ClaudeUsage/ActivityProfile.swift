import Foundation

/// When, during the day, an account actually spends its quota — learned from
/// its own recorded history.
///
/// A weekly burndown is projected days ahead, and a single fitted %/hour
/// spends quota straight through every night, which recorded history says
/// never happens: across observed weeks the busiest eight hours of the day
/// take roughly four fifths of a week's usage, and the small hours take
/// almost none — for model-scoped windows, exactly none. This profile is what
/// lets a projection stand still overnight and move during working hours.
///
/// Twenty-four cells, one per local hour of day. Each holds how many
/// percentage points were spent during that hour and how many hours of it
/// were actually observed; their ratio is an intensity in points per hour.
///
/// **Shape only.** The cells describe the shape of a typical day and nothing
/// about today's volume — they pool over weeks, because *when* someone works
/// is far more stable than *how much*. The level is fitted separately, over a
/// much shorter window (`UsageHistoryStore.activityScale`). Keeping the two
/// apart is the whole point: one least-squares fit conflates them, so a busy
/// afternoon sitting inside its lookback lifts the entire forecast and the
/// projection lurches every time the panel is opened.
///
/// **Decayed, not windowed.** Every write multiplies the cells down by the
/// elapsed time (`halfLife`), so a routine that has changed fades instead of
/// dropping off a cliff, and the profile stays a few hundred bytes however
/// long it accumulates. That last part is why this is stored rather than
/// derived: raw samples are pruned at `UsageHistoryStore.retention` (14 days),
/// but the routine worth learning outlasts them.
///
/// Cells are keyed on *local* hour, so the profile follows the user through a
/// timezone change and re-learns over a couple of half-lives rather than
/// tracking a stale offset.
struct ActivityProfile: Codable, Equatable {

    // MARK: Tuning

    static let hourCount = 24
    /// Behavior a fortnight old counts half as much as today's.
    static let halfLife: TimeInterval = 14 * 86400
    /// Below this much observed time a cell states nothing on its own and the
    /// profile's overall mean stands in, so an hour that simply hasn't been
    /// seen yet is never mistaken for an hour that is reliably idle.
    static let minimumCellHours: Double = 0.5
    /// The profile may only shape a projection once it has this much observed
    /// time — comfortably more than one day/night cycle, so "nights are quiet"
    /// is a pattern rather than a single night's coincidence.
    static let minimumTotalHours: Double = 30
    /// …spread across at least this many different hours of the day, so a
    /// profile built entirely from afternoons can't claim to know mornings.
    static let minimumCoveredHours = 12

    // MARK: State

    /// Decay-weighted percentage points spent during each local hour.
    private(set) var points: [Double]
    /// Decay-weighted hours actually observed for each local hour. The
    /// denominator of the intensity, and the only evidence of coverage — a
    /// zero cell means "never watched", not "watched and idle".
    private(set) var observedHours: [Double]
    /// Timestamp of the newest sample folded in. Doubles as the decay clock
    /// (decay is measured in sample time, not wall time, so a stretch with the
    /// app quit neither ages the profile nor counts as idle) and as the
    /// watermark that keeps re-folding the same history idempotent.
    private(set) var updatedAt: Date?

    init() {
        points = Array(repeating: 0, count: Self.hourCount)
        observedHours = Array(repeating: 0, count: Self.hourCount)
        updatedAt = nil
    }

    /// Whether the cell arrays survived decoding intact. A profile is a cache
    /// that can always be rebuilt from raw samples, so a malformed one is
    /// discarded rather than repaired.
    var isWellFormed: Bool {
        points.count == Self.hourCount && observedHours.count == Self.hourCount
    }

    // MARK: Learning

    /// Folds one observed stretch into the cells: `points` spent between
    /// `start` and `end`, spread evenly across the local hours it covers.
    ///
    /// Stretches at or before `updatedAt` are ignored, so replaying history
    /// that has already been folded is a no-op and the caller needs no
    /// bookkeeping of its own.
    mutating func add(points spent: Double, from start: Date, to end: Date, calendar: Calendar = .current) {
        guard isWellFormed, end > start else { return }
        if let updatedAt, end <= updatedAt { return }

        let pieces = Self.hourPieces(from: start, to: end, calendar: calendar)
        let covered = pieces.reduce(0) { $0 + $1.hours }
        // Bail before aging anything: a decay that isn't paired with an
        // advance of the watermark would be applied again by the next write.
        guard covered > 0 else { return }
        decay(to: end)
        for piece in pieces {
            observedHours[piece.hour] += piece.hours
            // Nothing records *when* inside the stretch the points went, so
            // they spread with the time — the same assumption the projection
            // makes when it integrates back out.
            points[piece.hour] += spent * (piece.hours / covered)
        }
        updatedAt = end
    }

    /// Ages every cell by the time since the last write. Applied on write
    /// rather than on read so a profile is a plain snapshot: two profiles that
    /// have seen the same history compare equal.
    private mutating func decay(to now: Date) {
        // A first write has nothing to age; `add` sets the watermark itself.
        guard let previous = updatedAt, now > previous else { return }
        let factor = pow(0.5, now.timeIntervalSince(previous) / Self.halfLife)
        guard factor < 1 else { return }
        for index in points.indices { points[index] *= factor }
        for index in observedHours.indices { observedHours[index] *= factor }
    }

    // MARK: Reading

    private var totalObservedHours: Double { observedHours.reduce(0, +) }
    private var coveredHourCount: Int {
        observedHours.filter { $0 >= Self.minimumCellHours }.count
    }

    /// Whether there is enough evidence here to shape a projection. Callers
    /// fall back to a straight line when this is false, which is also what
    /// keeps a freshly installed app honest.
    var isUsable: Bool {
        isWellFormed
            && totalObservedHours >= Self.minimumTotalHours
            && coveredHourCount >= Self.minimumCoveredHours
    }

    /// Mean intensity across everything observed, in points per hour. Stands
    /// in for hours too thinly covered to speak for themselves.
    private var meanIntensity: Double {
        let hours = totalObservedHours
        return hours > 0 ? points.reduce(0, +) / hours : 0
    }

    /// Learned intensity for one local hour, in percentage points per hour.
    func intensity(atHour hour: Int) -> Double {
        guard isWellFormed, observedHours.indices.contains(hour) else { return 0 }
        guard observedHours[hour] >= Self.minimumCellHours else { return meanIntensity }
        return points[hour] / observedHours[hour]
    }

    /// Points this profile expects to be spent between two instants — the
    /// integral of the hourly intensity, and the one operation both the level
    /// fit and the projection are built from.
    func expectedPoints(from start: Date, to end: Date, calendar: Calendar = .current) -> Double {
        guard end > start else { return 0 }
        return Self.hourPieces(from: start, to: end, calendar: calendar)
            .reduce(0) { $0 + intensity(atHour: $1.hour) * $1.hours }
    }

    // MARK: Hour arithmetic

    /// Splits `start..<end` on local hour boundaries, giving each piece's hour
    /// of day and its length in hours. Boundaries come from the calendar
    /// rather than from 3600-second arithmetic so a DST change shifts the grid
    /// instead of smearing every later hour.
    ///
    /// The iteration cap only guards against a calendar that fails to advance;
    /// real spans are a poll interval (folding) or a window length
    /// (projecting), so a week of hourly steps is the practical maximum.
    static func hourPieces(
        from start: Date, to end: Date, calendar: Calendar = .current
    ) -> [(hour: Int, hours: Double)] {
        guard end > start else { return [] }
        var pieces: [(hour: Int, hours: Double)] = []
        var cursor = start
        var steps = 0
        while cursor < end, steps < 24 * 14 {
            steps += 1
            let boundary = calendar.dateInterval(of: .hour, for: cursor)?.end
            let sliceEnd = min(end, boundary ?? end)
            // A calendar that won't advance past `cursor` would spin forever;
            // take the rest of the span in one piece instead.
            guard sliceEnd > cursor else {
                pieces.append(
                    (calendar.component(.hour, from: cursor), end.timeIntervalSince(cursor) / 3600))
                break
            }
            pieces.append(
                (calendar.component(.hour, from: cursor), sliceEnd.timeIntervalSince(cursor) / 3600))
            cursor = sliceEnd
        }
        return pieces
    }
}
