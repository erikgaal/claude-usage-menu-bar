import XCTest

@testable import ClaudeUsage

// MARK: - Fixtures

/// Same fixed poll epoch as `UsageHistoryTests` (2025-06-15T15:06:40Z): the
/// trend query reads no wall clock — the window comes from the limit and the
/// series from the samples — so a frozen epoch is all the determinism needed.
private let epoch = Date(timeIntervalSince1970: 1_750_000_000)
private let weeklyID = "weekly_all|"
private let week: TimeInterval = 7 * 86400

/// A weekly limit resetting `resetsIn` after the epoch. `windowSeconds: nil`
/// models a provider that never stated the window length.
private func weekly(
    _ percent: Double, resetsIn: TimeInterval = 3 * 86400,
    windowSeconds: TimeInterval? = week
) -> LimitStatus {
    LimitStatus(
        id: weeklyID, name: "Weekly", percent: percent,
        resetsAt: epoch.addingTimeInterval(resetsIn), isActive: false, sortOrder: 1,
        windowSeconds: windowSeconds)
}

@MainActor
final class UsageTrendTests: XCTestCase {

    private func makeStore() -> UsageHistoryStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-trend-tests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return UsageHistoryStore(directory: directory)
    }

    /// Records `count` samples ending at the epoch, `interval` apart, climbing
    /// `step` per sample — i.e. a ramp whose newest point is "now".
    @discardableResult
    private func recordRamp(
        _ store: UsageHistoryStore, limitID: String = weeklyID, name: String = "Weekly",
        start: Double, step: Double, interval: TimeInterval = 3600, count: Int,
        endingAt end: Date = epoch
    ) -> Double {
        let first = end.addingTimeInterval(-Double(count - 1) * interval)
        for index in 0..<count {
            store.record(
                [
                    LimitStatus(
                        id: limitID, name: name, percent: start + Double(index) * step,
                        resetsAt: nil, isActive: false, sortOrder: 1)
                ],
                accountID: "acct", at: first.addingTimeInterval(Double(index) * interval))
        }
        return start + Double(count - 1) * step
    }

    // MARK: Window framing

    func testWindowSpansResetMinusWindowLength() throws {
        let store = makeStore()
        recordRamp(store, start: 40, step: 1, count: 7)
        let limit = weekly(46)
        let trend = try XCTUnwrap(store.trend(for: limit, accountID: "acct"))

        XCTAssertEqual(trend.windowEnd, limit.resetsAt)
        // The window began four days before the epoch: reset (+3d) minus 7d.
        XCTAssertEqual(trend.windowStart, epoch.addingTimeInterval(-4 * 86400))
    }

    func testLimitWithoutStatedWindowLengthHasNoTrend() {
        let store = makeStore()
        recordRamp(store, start: 40, step: 1, count: 7)
        // An unrecognized limit kind never gets a guessed window length, so
        // there is no honest x-axis to draw.
        XCTAssertNil(store.trend(for: weekly(46, windowSeconds: nil), accountID: "acct"))
    }

    func testNoSamplesInWindowHasNoTrend() {
        let store = makeStore()
        // Samples exist, but all of them predate this window.
        recordRamp(store, start: 5, step: 1, count: 7, endingAt: epoch.addingTimeInterval(-5 * 86400))
        XCTAssertNil(store.trend(for: weekly(46), accountID: "acct"))
    }

    func testSamplesBeforeWindowStartAreExcluded() throws {
        let store = makeStore()
        // A low sample from the previous window (low, so the reset-drop trim
        // can't be what excludes it — only the window's start date can) …
        recordRamp(store, start: 5, step: 0, count: 1, endingAt: epoch.addingTimeInterval(-5 * 86400))
        // … then this window's ramp.
        recordRamp(store, start: 40, step: 1, count: 7)

        let trend = try XCTUnwrap(store.trend(for: weekly(46), accountID: "acct"))
        XCTAssertEqual(trend.recorded.count, 7)
        XCTAssertEqual(trend.recorded.first?.percent, 40)
        XCTAssertEqual(trend.latest.percent, 46)
    }

    func testResetInsideWindowTrimsThePreviousTail() throws {
        let store = makeStore()
        // A stale `resetsAt` can leave a spent window's tail inside the range;
        // the sharp drop marks the boundary and everything before it goes.
        recordRamp(store, start: 90, step: 1, count: 4, endingAt: epoch.addingTimeInterval(-10 * 3600))
        recordRamp(store, start: 3, step: 1, count: 7)

        let trend = try XCTUnwrap(store.trend(for: weekly(9), accountID: "acct"))
        XCTAssertEqual(trend.recorded.count, 7)
        XCTAssertEqual(trend.recorded.first?.percent, 3)
    }

    // MARK: Projection

    func testProjectionExtrapolatesRecentPaceToReset() throws {
        let store = makeStore()
        // 0.5%/h for six hours, newest sample 42.5% at the epoch; the reset is
        // 72h out, so the pace lands 36 points higher.
        let latest = recordRamp(store, start: 40, step: 0.5, count: 6)
        let trend = try XCTUnwrap(store.trend(for: weekly(latest), accountID: "acct"))

        XCTAssertEqual(try XCTUnwrap(trend.ratePerHour), 0.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(trend.projectedAtReset), latest + 36, accuracy: 0.01)
        XCTAssertNil(trend.exhaustsAt)
        // Two points: from "now" straight to the reset.
        XCTAssertEqual(trend.projected.count, 2)
        XCTAssertEqual(trend.projected.first?.date, trend.latest.date)
        XCTAssertEqual(trend.projected.last?.date, trend.windowEnd)
        XCTAssertEqual(try XCTUnwrap(trend.projected.last?.percent), latest + 36, accuracy: 0.01)
    }

    func testProjectionFlattensAtTheCapWhenThePaceOverrunsIt() throws {
        let store = makeStore()
        // 2%/h from 58% with 72h to go would reach 202%; it can only reach
        // 100, and it gets there 21 hours after the newest sample.
        let latest = recordRamp(store, start: 48, step: 2, count: 6)
        let trend = try XCTUnwrap(store.trend(for: weekly(latest), accountID: "acct"))

        XCTAssertEqual(try XCTUnwrap(trend.projectedAtReset), 202, accuracy: 0.01)
        let exhaustsAt = try XCTUnwrap(trend.exhaustsAt)
        XCTAssertEqual(
            exhaustsAt.timeIntervalSince(epoch), 21 * 3600, accuracy: 1)
        // Up to the cap, then flat across the runway spent locked out.
        XCTAssertEqual(trend.projected.count, 3)
        XCTAssertEqual(trend.projected[1].percent, 100)
        XCTAssertEqual(trend.projected[2].percent, 100)
        XCTAssertEqual(trend.projected[2].date, trend.windowEnd)
    }

    func testThinHistoryDrawsRecordedOnlyWithNoProjection() throws {
        let store = makeStore()
        // Two samples: enough to draw, too few to fit a pace from.
        recordRamp(store, start: 40, step: 1, count: 2)
        let trend = try XCTUnwrap(store.trend(for: weekly(41), accountID: "acct"))

        XCTAssertEqual(trend.recorded.count, 2)
        XCTAssertTrue(trend.projected.isEmpty)
        XCTAssertNil(trend.ratePerHour)
        XCTAssertNil(trend.projectedAtReset)
    }

    func testFlatUsageProjectsAFlatLine() throws {
        let store = makeStore()
        recordRamp(store, start: 30, step: 0, count: 6)
        let trend = try XCTUnwrap(store.trend(for: weekly(30), accountID: "acct"))

        XCTAssertEqual(try XCTUnwrap(trend.ratePerHour), 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(trend.projectedAtReset), 30, accuracy: 0.001)
        XCTAssertNil(trend.exhaustsAt)
    }

    // MARK: Thinning

    func testLongHistoryIsThinnedButKeepsItsEnds() throws {
        let store = makeStore()
        // Four days of five-minute polls: ~1150 rows for one limit.
        let latest = recordRamp(store, start: 0, step: 0.05, interval: 300, count: 1152)
        let trend = try XCTUnwrap(store.trend(for: weekly(latest), accountID: "acct"))

        XCTAssertLessThanOrEqual(trend.recorded.count, 121)
        XCTAssertGreaterThan(trend.recorded.count, 60)
        // The ends must survive exactly: the first is where recording began,
        // and the last anchors both the projection and the caption's percent.
        XCTAssertEqual(trend.recorded.first?.percent, 0)
        XCTAssertEqual(trend.latest.percent, latest)
        XCTAssertEqual(trend.latest.date, epoch)
        // Still chronological after bucketing.
        XCTAssertEqual(trend.recorded.map(\.date), trend.recorded.map(\.date).sorted())
    }

    // MARK: Caption

    /// The caption states both framings: the panel's bars count usage up, the
    /// chart counts the quota down, and the projection is named in the chart's
    /// terms so it matches where the dashed line lands.
    func testSummaryReportsWhatIsLeftAndWhereThePaceLands() throws {
        let store = makeStore()
        let latest = recordRamp(store, start: 40, step: 0.5, count: 6)
        let trend = try XCTUnwrap(store.trend(for: weekly(latest), accountID: "acct"))
        // 42.5% used ⇒ 57.5% left; the pace lands at 78.5% used ⇒ 21.5% left.
        XCTAssertEqual(
            UsageTrendChart.summary(for: trend, percent: latest),
            "43% used · 58% left · on pace to land at 22%")
    }

    func testSummaryNamesTheRunOutTimeWhenThePaceOverruns() throws {
        let store = makeStore()
        let latest = recordRamp(store, start: 48, step: 2, count: 6)
        let trend = try XCTUnwrap(store.trend(for: weekly(latest), accountID: "acct"))
        let text = UsageTrendChart.summary(for: trend, percent: latest)
        XCTAssertTrue(text.hasPrefix("58% used · 42% left · on pace to run out"), text)
    }

    func testSummarySaysSoWhenThereIsNothingToProjectFrom() throws {
        let store = makeStore()
        recordRamp(store, start: 40, step: 1, count: 2)
        let trend = try XCTUnwrap(store.trend(for: weekly(41), accountID: "acct"))
        XCTAssertEqual(
            UsageTrendChart.summary(for: trend, percent: 41),
            "41% used · 59% left · not enough history to project yet")
    }

    // MARK: Window lengths from the providers

    func testClaudeKindsMapToTheirWindowLengths() {
        XCTAssertEqual(UsageAPI.windowSeconds(forKind: "session"), 5 * 3600)
        XCTAssertEqual(UsageAPI.windowSeconds(forKind: "weekly_all"), week)
        XCTAssertEqual(UsageAPI.windowSeconds(forKind: "weekly_model"), week)
        // Unrecognized kinds are never guessed at.
        XCTAssertNil(UsageAPI.windowSeconds(forKind: "monthly_tokens"))
        XCTAssertNil(UsageAPI.windowSeconds(forKind: nil))
    }

    func testOnlyMultiDayWindowsAreChartable() {
        XCTAssertTrue(weekly(50).isMultiDay)
        XCTAssertFalse(weekly(50, windowSeconds: 5 * 3600).isMultiDay)
        XCTAssertFalse(weekly(50, windowSeconds: nil).isMultiDay)
    }
}
