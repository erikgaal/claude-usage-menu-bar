import XCTest

@testable import ClaudeUsage

/// Midnight UTC on 2025-06-15, with a UTC calendar to read it by — hour-of-day
/// cells are keyed on local hours, so a fixture meaning "works 09:00–17:00"
/// has to pin the zone or it means something else on a London machine.
private let midnight = Date(timeIntervalSince1970: 1_749_945_600)
private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func at(day: Int = 0, _ hour: Double) -> Date {
    midnight.addingTimeInterval(Double(day) * 86400 + hour * 3600)
}

private let weeklyID = "weekly_all|"
private let sessionID = "session|"

/// A limit whose window is the seven days ending at `resetsAt`.
private func weekly(_ percent: Double, resetsAt: Date) -> LimitStatus {
    LimitStatus(
        id: weeklyID, name: "Weekly", percent: percent, resetsAt: resetsAt,
        isActive: false, sortOrder: 1, windowSeconds: 7 * 86400)
}

/// The daily-pattern projection replaces a straight line for multi-day windows
/// only, and only once an account's own history has earned it. These cover the
/// gates, the shape that comes out, and the two APIs that have to agree about
/// it (`UsageTrend.exhaustsAt` and `projectedExhaustion(for:accountID:)`) —
/// the panel prints both on one card.
@MainActor
final class UsagePatternTests: XCTestCase {

    private func makeStore() -> (UsageHistoryStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-pattern-tests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (UsageHistoryStore(directory: directory, calendar: utc), directory)
    }

    /// Records a routine: a sample every 20 minutes from midnight on day 0
    /// through `endingDay`/`endingHour`, with percent climbing `pointsPerHour`
    /// during `activeHours` and standing perfectly still the rest of the day.
    /// Returns the newest sample's percent.
    @discardableResult
    private func recordRoutine(
        _ store: UsageHistoryStore, limitID: String = weeklyID, name: String = "Weekly",
        fromDay: Int = 0, endingDay: Int, endingHour: Double, activeHours: Range<Int>,
        pointsPerHour: Double, startingAt startPercent: Double = 0,
        interval: TimeInterval = 1200
    ) -> Double {
        var percent = startPercent
        var cursor = at(day: fromDay, 0)
        let end = at(day: endingDay, endingHour)
        while cursor <= end {
            store.record(
                [
                    LimitStatus(
                        id: limitID, name: name, percent: percent, resetsAt: nil,
                        isActive: false, sortOrder: 1)
                ],
                accountID: "acct", at: cursor)
            if activeHours.contains(utc.component(.hour, from: cursor)) {
                percent += pointsPerHour * interval / 3600
            }
            cursor.addTimeInterval(interval)
        }
        return percent
    }

    /// Uniform intensity in every hour of the day — for exercising the
    /// projection walk itself without a day/night shape confusing the maths.
    private func flatProfile(pointsPerHour: Double, days: Int = 3) -> ActivityProfile {
        var profile = ActivityProfile()
        for day in 0..<days {
            for hour in 0..<24 {
                profile.add(
                    points: pointsPerHour, from: at(day: day, Double(hour)),
                    to: at(day: day, Double(hour + 1)), calendar: utc)
            }
        }
        return profile
    }

    // MARK: The projection walk

    func testProjectionStandsStillThroughHoursTheAccountIsIdle() {
        var profile = ActivityProfile()
        for day in 0..<3 {
            for hour in 0..<24 {
                profile.add(
                    points: (9..<17).contains(hour) ? 2 : 0,
                    from: at(day: day, Double(hour)), to: at(day: day, Double(hour + 1)),
                    calendar: utc)
            }
        }
        let latest = UsageTrend.Point(date: at(day: 5, 18), percent: 40)
        let result = UsageTrend.project(
            from: latest, profile: profile, scale: 1, windowEnd: at(day: 6, 18), calendar: utc)

        // One day on: eight active hours at 2 points.
        XCTAssertEqual(result.atReset, 56, accuracy: 0.001)
        XCTAssertNil(result.exhaustsAt)
        // Nothing is spent between 18:00 and 09:00 — the stretch a straight
        // line would have burned through.
        let overnight = result.points.filter {
            $0.date >= at(day: 5, 18) && $0.date <= at(day: 6, 9)
        }
        XCTAssertEqual(Set(overnight.map { $0.percent.rounded() }), [40])
        XCTAssertEqual(result.points.first, latest)
    }

    func testProjectionFlattensAtTheCapAndDatesTheCrossingWithinTheHour() {
        let latest = UsageTrend.Point(date: at(day: 5, 0), percent: 95)
        let result = UsageTrend.project(
            from: latest, profile: flatProfile(pointsPerHour: 10), scale: 1,
            windowEnd: at(day: 5, 5), calendar: utc)

        // 10 points/hour from 95: the cap arrives half an hour in.
        XCTAssertEqual(try! XCTUnwrap(result.exhaustsAt), at(day: 5, 0.5))
        XCTAssertEqual(result.atReset, 145, accuracy: 0.001)
        XCTAssertTrue(result.points.contains(UsageTrend.Point(date: at(day: 5, 0.5), percent: 100)))
        // Everything past the crossing is the runway spent locked out.
        XCTAssertEqual(result.points.last?.percent, 100)
        XCTAssertEqual(result.points.last?.date, at(day: 5, 5))
    }

    func testCrossingLandingExactlyOnAnHourAddsNoDuplicateVertex() {
        let latest = UsageTrend.Point(date: at(day: 5, 0), percent: 90)
        let result = UsageTrend.project(
            from: latest, profile: flatProfile(pointsPerHour: 10), scale: 1,
            windowEnd: at(day: 5, 3), calendar: utc)

        XCTAssertEqual(try! XCTUnwrap(result.exhaustsAt), at(day: 5, 1))
        // `Point` is identified by its date, so a duplicate would break the
        // chart's ForEach as well as being wrong.
        XCTAssertEqual(result.points.map(\.date).count, Set(result.points.map(\.date)).count)
    }

    func testIdleLevelProjectsAFlatLineEvenWithABusyProfile() {
        let latest = UsageTrend.Point(date: at(day: 5, 0), percent: 40)
        let result = UsageTrend.project(
            from: latest, profile: flatProfile(pointsPerHour: 10), scale: 0,
            windowEnd: at(day: 5, 12), calendar: utc)

        XCTAssertEqual(result.atReset, 40, accuracy: 0.001)
        XCTAssertEqual(Set(result.points.map(\.percent)), [40])
    }

    func testWindowAlreadyOverProjectsNothing() {
        let latest = UsageTrend.Point(date: at(day: 5, 12), percent: 40)
        let result = UsageTrend.project(
            from: latest, profile: flatProfile(pointsPerHour: 10), scale: 1,
            windowEnd: at(day: 5, 12), calendar: utc)
        XCTAssertTrue(result.points.isEmpty)
    }

    // MARK: Gates

    func testMultiDayWindowWithARoutineGetsTheDailyPattern() throws {
        let (store, _) = makeStore()
        let latest = recordRoutine(
            store, endingDay: 3, endingHour: 18, activeHours: 9..<17, pointsPerHour: 1)
        let trend = try XCTUnwrap(
            store.trend(for: weekly(latest, resetsAt: at(day: 7, 0)), accountID: "acct"))

        XCTAssertEqual(trend.projection, .dailyPattern)
    }

    func testOneDayOfHistoryIsNotEnoughAndKeepsTheStraightLine() throws {
        let (store, _) = makeStore()
        let latest = recordRoutine(
            store, endingDay: 0, endingHour: 18, activeHours: 9..<17, pointsPerHour: 1)
        let trend = try XCTUnwrap(
            store.trend(for: weekly(latest, resetsAt: at(day: 7, 0)), accountID: "acct"))

        // A single day can't tell a routine from a coincidence.
        XCTAssertEqual(trend.projection, .constantRate)
    }

    func testSessionWindowKeepsTheStraightLine() throws {
        let (store, _) = makeStore()
        let latest = recordRoutine(
            store, limitID: sessionID, name: "Session", endingDay: 3, endingHour: 18,
            activeHours: 9..<17, pointsPerHour: 1)
        // Five hours hold no day/night shape to exploit, and leaving them on
        // the fitted rate is what keeps the Best badge and the switch
        // notifications on the behavior they were built against.
        let session = LimitStatus(
            id: sessionID, name: "Session", percent: latest, resetsAt: at(day: 3, 20),
            isActive: true, sortOrder: 0, windowSeconds: 5 * 3600)
        let trend = try XCTUnwrap(store.trend(for: session, accountID: "acct"))

        XCTAssertEqual(trend.projection, .constantRate)
    }

    func testLimitPinnedAtTheCapTeachesNoPatternAtAll() throws {
        let (store, _) = makeStore()
        // Growth is censored at 100%, so those stretches say nothing about
        // when the account is busy and must not be read as idle hours.
        recordRoutine(
            store, endingDay: 3, endingHour: 18, activeHours: 9..<17, pointsPerHour: 0,
            startingAt: 100)
        let trend = try XCTUnwrap(
            store.trend(for: weekly(100, resetsAt: at(day: 7, 0)), accountID: "acct"))

        XCTAssertEqual(trend.projection, .constantRate)
    }

    func testPatternSurvivesARelaunch() throws {
        let (store, directory) = makeStore()
        let latest = recordRoutine(
            store, endingDay: 3, endingHour: 18, activeHours: 9..<17, pointsPerHour: 1)

        // A fresh store records nothing, so a pattern can only come off disk.
        let reloaded = UsageHistoryStore(directory: directory, calendar: utc)
        let trend = try XCTUnwrap(
            reloaded.trend(for: weekly(latest, resetsAt: at(day: 7, 0)), accountID: "acct"))

        XCTAssertEqual(trend.projection, .dailyPattern)
    }

    // MARK: What it fixes

    func testEveningProjectionNoLongerSpendsTheNight() throws {
        let (store, _) = makeStore()
        // Four identical days: 09:00–17:00 at 1 point/hour, so 8 points a day
        // and 32 banked. Asked at 18:00, right after a day's work.
        let latest = recordRoutine(
            store, endingDay: 3, endingHour: 18, activeHours: 9..<17, pointsPerHour: 1)
        XCTAssertEqual(latest, 32, accuracy: 0.001)

        let limit = weekly(latest, resetsAt: at(day: 7, 0))
        let trend = try XCTUnwrap(store.trend(for: limit, accountID: "acct"))
        XCTAssertEqual(trend.projection, .dailyPattern)

        // Three working days remain before the reset, so the routine spends
        // 24 more points and lands at 56.
        XCTAssertEqual(try XCTUnwrap(trend.projectedAtReset), 56, accuracy: 1)

        // The straight line, fitted over a lookback dominated by the working
        // day just finished, carries that pace through three nights as well —
        // which is the over-projection this whole change exists to remove.
        let rate = try XCTUnwrap(trend.ratePerHour)
        let straightLine = latest + rate * at(day: 7, 0).timeIntervalSince(at(day: 3, 18)) / 3600
        XCTAssertGreaterThan(straightLine, 70)
        XCTAssertGreaterThan(straightLine, try XCTUnwrap(trend.projectedAtReset) + 10)
    }

    func testProjectedPathIsAStaircaseNotARamp() throws {
        let (store, _) = makeStore()
        let latest = recordRoutine(
            store, endingDay: 3, endingHour: 18, activeHours: 9..<17, pointsPerHour: 1)
        let trend = try XCTUnwrap(
            store.trend(for: weekly(latest, resetsAt: at(day: 7, 0)), accountID: "acct"))

        func percent(at date: Date) throws -> Double {
            try XCTUnwrap(trend.projected.last { $0.date <= date }).percent
        }
        // Overnight: perfectly flat.
        XCTAssertEqual(try percent(at: at(day: 3, 20)), try percent(at: at(day: 4, 8)), accuracy: 0.2)
        // Across the next working day: eight points.
        let dayStart = try percent(at: at(day: 4, 9))
        let dayEnd = try percent(at: at(day: 4, 17))
        XCTAssertEqual(dayEnd - dayStart, 8, accuracy: 0.5)
        // And still flat again the following night.
        XCTAssertEqual(try percent(at: at(day: 4, 20)), try percent(at: at(day: 5, 8)), accuracy: 0.2)
    }

    func testRunOutTimeLandsInWorkingHoursAndBothAPIsAgree() throws {
        let (store, _) = makeStore()
        // A heavier routine: 3 points an hour, 24 a day, 72 banked by day 2.
        let latest = recordRoutine(
            store, endingDay: 2, endingHour: 18, activeHours: 9..<17, pointsPerHour: 3)
        XCTAssertEqual(latest, 72, accuracy: 0.001)

        let limit = weekly(latest, resetsAt: at(day: 7, 0))
        let trend = try XCTUnwrap(store.trend(for: limit, accountID: "acct"))
        XCTAssertEqual(trend.projection, .dailyPattern)

        // Day 3 spends 24 to reach 96; the last four points land early on the
        // morning of day 4 — during working hours, not at 04:00.
        let exhaustsAt = try XCTUnwrap(trend.exhaustsAt)
        XCTAssertEqual(utc.component(.hour, from: exhaustsAt), 10)
        XCTAssertEqual(utc.dateComponents([.day], from: midnight, to: exhaustsAt).day, 4)

        // The chart's caption and the reset line above it read these two
        // separate APIs; if they ever diverge the panel contradicts itself.
        XCTAssertEqual(store.projectedExhaustion(for: limit, accountID: "acct"), exhaustsAt)

        // The straight-line answer arrives sooner because it burns the night.
        let flat = try XCTUnwrap(
            store.projectedExhaustion(accountID: "acct", limitID: weeklyID))
        XCTAssertLessThan(flat, exhaustsAt)
    }

    func testSessionExhaustionIsUnchangedByTheLimitAwareOverload() throws {
        let (store, _) = makeStore()
        recordRoutine(
            store, limitID: sessionID, name: "Session", endingDay: 3, endingHour: 16,
            activeHours: 9..<17, pointsPerHour: 8)
        let session = LimitStatus(
            id: sessionID, name: "Session", percent: 60, resetsAt: at(day: 3, 20),
            isActive: true, sortOrder: 0, windowSeconds: 5 * 3600)

        // The overload must be a pass-through for anything that isn't
        // multi-day: `BestAccount` and the switch notifications depend on it.
        XCTAssertEqual(
            store.projectedExhaustion(for: session, accountID: "acct"),
            store.projectedExhaustion(accountID: "acct", limitID: sessionID))
    }

    func testWindowThatJustResetStillProjectsAPattern() throws {
        let (store, _) = makeStore()
        // Four days of routine, then the window renews and only half a day of
        // the new one has been recorded.
        recordRoutine(
            store, endingDay: 3, endingHour: 23.5, activeHours: 9..<17, pointsPerHour: 1)
        let latest = recordRoutine(
            store, fromDay: 4, endingDay: 4, endingHour: 12, activeHours: 9..<17,
            pointsPerHour: 1, startingAt: 0)

        // The new window starts on day 4, so only its own samples are drawn —
        // but the level is still fittable from before the reset, which is what
        // keeps a fresh window off a straight line for its first two days.
        let limit = weekly(latest, resetsAt: at(day: 11, 0))
        let trend = try XCTUnwrap(store.trend(for: limit, accountID: "acct"))

        XCTAssertEqual(trend.projection, .dailyPattern)
        XCTAssertEqual(trend.windowStart, at(day: 4, 0))
        XCTAssertEqual(trend.recorded.first?.percent, 0, "previous window's tail must not leak in")
    }

    // MARK: Level

    func testASlowerWeekProjectsLessThanTheProfileAlonePredicts() throws {
        let (store, _) = makeStore()
        // Three days at 2 points an hour teach the shape and set the level…
        recordRoutine(
            store, endingDay: 2, endingHour: 23.5, activeHours: 9..<17, pointsPerHour: 2)
        // …then two quiet days at a quarter of that pace. The shape still says
        // "works 09:00–17:00"; only the level should come down.
        let latest = recordRoutine(
            store, endingDay: 4, endingHour: 18, activeHours: 9..<17, pointsPerHour: 0.5,
            startingAt: 48)
        let trend = try XCTUnwrap(
            store.trend(for: weekly(latest, resetsAt: at(day: 7, 0)), accountID: "acct"))

        XCTAssertEqual(trend.projection, .dailyPattern)
        // Two working days remain. At the recent quiet pace that's ~8 points;
        // at the pace of the first three days it would be ~32.
        let gained = try XCTUnwrap(trend.projectedAtReset) - latest
        XCTAssertLessThan(gained, 16)
        XCTAssertGreaterThan(gained, 2)
    }
}
