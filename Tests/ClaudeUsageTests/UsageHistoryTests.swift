import XCTest

@testable import ClaudeUsage

// MARK: - Shared fixtures

/// Fixed poll epoch (2025-06-15T15:06:40Z) so fits and projections are stable
/// regardless of when the tests run. No store query reads the wall clock —
/// lookbacks anchor to the newest sample — so this is all the determinism
/// the tests need.
private let epoch = Date(timeIntervalSince1970: 1_750_000_000)
/// Limit ids as the Claude provider produces them (`kind|model`).
private let sessionID = "session|"
private let weeklyID = "weekly_all|"

private func limit(
    _ id: String, _ name: String, _ percent: Double, resetsAt: Date? = nil
) -> LimitStatus {
    LimitStatus(
        id: id, name: name, percent: percent, resetsAt: resetsAt,
        isActive: true, sortOrder: 0)
}

// MARK: - Tests

@MainActor
final class UsageHistoryTests: XCTestCase {

    /// Fresh store on an isolated temp directory, removed with the test, so
    /// tests never touch the real Application Support location.
    private func makeStore() -> (store: UsageHistoryStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-history-tests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (UsageHistoryStore(directory: directory), directory)
    }

    /// Records `count` samples for one limit, `interval` seconds apart,
    /// climbing `step` percent per sample. Returns the newest timestamp.
    @discardableResult
    private func recordRamp(
        _ store: UsageHistoryStore, account: String = "acct",
        limitID: String = sessionID, name: String = "Session",
        start: Double, step: Double, interval: TimeInterval = 300, count: Int,
        from date: Date = epoch
    ) -> Date {
        for index in 0..<count {
            store.record(
                [limit(limitID, name, start + Double(index) * step)],
                accountID: account, at: date.addingTimeInterval(Double(index) * interval))
        }
        return date.addingTimeInterval(Double(count - 1) * interval)
    }

    // MARK: Slope fitting

    func testBurnRateFitsSteadyRamp() throws {
        let (store, _) = makeStore()
        // 1% per 5 minutes over an hour = 12%/h.
        recordRamp(store, start: 20, step: 1, count: 13)
        let rate = try XCTUnwrap(store.burnRate(accountID: "acct", limitID: sessionID))
        XCTAssertEqual(rate, 12, accuracy: 0.01)
    }

    func testFlatUsageHasZeroRateAndNoProjection() throws {
        let (store, _) = makeStore()
        recordRamp(store, start: 40, step: 0, count: 13)
        let rate = try XCTUnwrap(store.burnRate(accountID: "acct", limitID: sessionID))
        XCTAssertEqual(rate, 0, accuracy: 0.001)
        XCTAssertNil(store.projectedExhaustion(accountID: "acct", limitID: sessionID))
    }

    func testUnknownAccountOrLimitReturnsNil() {
        let (store, _) = makeStore()
        XCTAssertNil(store.burnRate(accountID: "nobody", limitID: sessionID))
        recordRamp(store, start: 20, step: 1, count: 13)
        XCTAssertNil(store.burnRate(accountID: "acct", limitID: weeklyID))
    }

    // MARK: Reset handling

    func testFitCrossingResetUsesOnlyCurrentWindow() throws {
        let (store, _) = makeStore()
        // Previous window climbing toward its cap…
        recordRamp(store, start: 80, step: 1, count: 6)
        // …then a reset (sharp drop to ~2%) and a clean 6%/h climb. Fitting
        // across the drop would produce a large negative slope.
        recordRamp(store, start: 2, step: 0.5, count: 12, from: epoch.addingTimeInterval(1800))
        let rate = try XCTUnwrap(store.burnRate(accountID: "acct", limitID: sessionID))
        XCTAssertEqual(rate, 6, accuracy: 0.01)
    }

    func testResetLeavingTooFewSamplesReturnsNil() {
        let (store, _) = makeStore()
        recordRamp(store, start: 50, step: 1, count: 10)
        // Only two samples since the reset: not enough to project from, and
        // pre-reset samples must not be borrowed to make up the difference.
        recordRamp(store, start: 3, step: 1, count: 2, from: epoch.addingTimeInterval(3000))
        XCTAssertNil(store.burnRate(accountID: "acct", limitID: sessionID))
    }

    func testSmallDipIsJitterNotReset() {
        let (store, _) = makeStore()
        // A 4-point dip (rounding jitter, ≤5) must not split the window: the
        // two post-dip samples alone would fail the sample-count gate.
        for (index, percent) in [20.0, 21, 22, 23, 24, 25, 21, 22].enumerated() {
            store.record(
                [limit(sessionID, "Session", percent)],
                accountID: "acct", at: epoch.addingTimeInterval(Double(index) * 300))
        }
        XCTAssertNotNil(store.burnRate(accountID: "acct", limitID: sessionID))
    }

    // MARK: Lookback windows

    func testSessionLookbackIgnoresSamplesOlderThanAnHour() throws {
        let (store, _) = makeStore()
        // Two flat hours followed by a clean 12%/h climb in the final hour:
        // the 1h session lookback must fit only the climb, or the flat prefix
        // would drag the slope down.
        recordRamp(store, start: 30, step: 0, count: 25)
        recordRamp(store, start: 31, step: 1, count: 12, from: epoch.addingTimeInterval(7500))
        let rate = try XCTUnwrap(store.burnRate(accountID: "acct", limitID: sessionID))
        XCTAssertEqual(rate, 12, accuracy: 0.01)
    }

    func testWeeklyLookbackSpansHoursSessionDoesNot() throws {
        let (store, _) = makeStore()
        // Hourly cadence climbing 1%/h: plenty for a weekly limit's 12h
        // lookback, but a session limit's 1h lookback keeps only the last
        // two samples — too few to fit.
        recordRamp(
            store, account: "weekly-acct", limitID: weeklyID, name: "Weekly",
            start: 10, step: 1, interval: 3600, count: 8)
        recordRamp(
            store, account: "session-acct", limitID: sessionID, name: "Session",
            start: 10, step: 1, interval: 3600, count: 8)
        let rate = try XCTUnwrap(store.burnRate(accountID: "weekly-acct", limitID: weeklyID))
        XCTAssertEqual(rate, 1, accuracy: 0.001)
        XCTAssertNil(store.burnRate(accountID: "session-acct", limitID: sessionID))
    }

    func testWeeklyLookbackIgnoresSamplesOlderThanTwelveHours() throws {
        let (store, _) = makeStore()
        // A steep early climb (hours 0–2), then a steady 1%/h for twelve
        // hours. The 12h lookback keeps exactly the steady stretch; including
        // the steep prefix would inflate the slope well past 1.
        recordRamp(
            store, limitID: weeklyID, name: "Weekly",
            start: 0, step: 20, interval: 3600, count: 3)
        recordRamp(
            store, limitID: weeklyID, name: "Weekly",
            start: 41, step: 1, interval: 3600, count: 12,
            from: epoch.addingTimeInterval(3 * 3600))
        let rate = try XCTUnwrap(store.burnRate(accountID: "acct", limitID: weeklyID))
        XCTAssertEqual(rate, 1, accuracy: 0.01)
    }

    // MARK: Gating

    func testTwoSamplesAreNotEnough() {
        let (store, _) = makeStore()
        recordRamp(store, start: 10, step: 1, count: 2)
        XCTAssertNil(store.burnRate(accountID: "acct", limitID: sessionID))
    }

    func testThirtyMinuteSpanRequired() {
        let (store, _) = makeStore()
        // Three samples spanning 20 minutes: below the span floor.
        recordRamp(store, start: 10, step: 1, interval: 600, count: 3)
        XCTAssertNil(store.burnRate(accountID: "acct", limitID: sessionID))
        // A fourth sample stretches the span to exactly 30 minutes: enough.
        store.record(
            [limit(sessionID, "Session", 13)],
            accountID: "acct", at: epoch.addingTimeInterval(1800))
        XCTAssertNotNil(store.burnRate(accountID: "acct", limitID: sessionID))
    }

    // MARK: Projection

    func testProjectedExhaustionExtrapolatesFromLatestSample() throws {
        let (store, _) = makeStore()
        // 12%/h; newest sample is 32% at epoch+1h, so 100% lands 68/12 hours
        // (5h40m) after that.
        let latest = recordRamp(store, start: 20, step: 1, count: 13)
        let projected = try XCTUnwrap(
            store.projectedExhaustion(accountID: "acct", limitID: sessionID))
        let expected = latest.addingTimeInterval(68.0 / 12.0 * 3600)
        XCTAssertEqual(projected.timeIntervalSince(expected), 0, accuracy: 1)
    }

    // MARK: Pace caption gates

    func testPaceCaptionShownWhenProjectionBeatsReset() {
        let (store, _) = makeStore()
        // 30%/h from 70%: exhaustion one hour after the newest sample, well
        // before a reset five hours out.
        let latest = recordRamp(store, start: 40, step: 2.5, count: 13)
        let text = AccountSection.paceText(
            rows: [limit(sessionID, "Session", 70)],
            resetsAt: latest.addingTimeInterval(5 * 3600),
            accountID: "acct", history: store)
        XCTAssertEqual(text?.hasPrefix("on pace to run out") ?? false, true)
    }

    func testPaceCaptionSilentWhenResetComesFirst() {
        let (store, _) = makeStore()
        // Same burn, but the window resets before the projection lands:
        // running out after the reset is a non-event, so say nothing.
        let latest = recordRamp(store, start: 40, step: 2.5, count: 13)
        let text = AccountSection.paceText(
            rows: [limit(sessionID, "Session", 70)],
            resetsAt: latest.addingTimeInterval(1800),
            accountID: "acct", history: store)
        XCTAssertNil(text)
    }

    func testPaceCaptionSilentBelowUtilizationFloor() {
        let (store, _) = makeStore()
        // A projectable 6%/h burn, but only 11% used: too early to warn.
        recordRamp(store, start: 5, step: 0.5, count: 13)
        let text = AccountSection.paceText(
            rows: [limit(sessionID, "Session", 11)],
            resetsAt: epoch.addingTimeInterval(20 * 3600),
            accountID: "acct", history: store)
        XCTAssertNil(text)
    }

    func testPaceCaptionNamesLimitInMultiRowGroups() throws {
        let (store, _) = makeStore()
        // Session exhausts within the window; Weekly doesn't. With multiple
        // bars sharing the caption line, the one that runs out is named.
        let latest = recordRamp(store, start: 40, step: 2.5, count: 13)
        recordRamp(store, limitID: weeklyID, name: "Weekly", start: 24, step: 0.5, count: 13)
        let text = try XCTUnwrap(
            AccountSection.paceText(
                rows: [limit(sessionID, "Session", 70), limit(weeklyID, "Weekly", 30)],
                resetsAt: latest.addingTimeInterval(5 * 3600),
                accountID: "acct", history: store))
        XCTAssertTrue(text.hasPrefix("Session on pace to run out"), text)
    }

    // MARK: Persistence

    func testPersistenceRoundTripsThroughDisk() throws {
        let (store, directory) = makeStore()
        recordRamp(store, start: 20, step: 1, count: 13)
        // A fresh store over the same directory must answer identically.
        let reloaded = UsageHistoryStore(directory: directory)
        let rate = try XCTUnwrap(reloaded.burnRate(accountID: "acct", limitID: sessionID))
        XCTAssertEqual(rate, 12, accuracy: 0.01)
    }

    func testPruningDropsSamplesBeyondRetention() throws {
        let (store, directory) = makeStore()
        store.record(
            [limit(sessionID, "Session", 5)],
            accountID: "acct", at: epoch.addingTimeInterval(-15 * 86400))
        recordRamp(store, start: 20, step: 1, count: 13)

        let data = try Data(contentsOf: directory.appendingPathComponent("acct.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let rows = try decoder.decode([UsageSample].self, from: data)
        XCTAssertEqual(rows.count, 13, "the 15-day-old sample should be pruned")
        XCTAssertEqual(rows.first?.percent, 20)
    }

    func testRemoveHistoryDeletesFile() {
        let (store, directory) = makeStore()
        recordRamp(store, start: 20, step: 1, count: 13)
        let file = directory.appendingPathComponent("acct.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        store.removeHistory(accountID: "acct")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(store.burnRate(accountID: "acct", limitID: sessionID))
    }

    func testHostileAccountIDsBecomeSafeFileNames() throws {
        let (store, directory) = makeStore()
        // A "/" in an account id would otherwise address a subdirectory.
        recordRamp(store, account: "acct/1:evil", start: 20, step: 1, count: 13)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("acct_1_evil.json").path))
        let rate = try XCTUnwrap(store.burnRate(accountID: "acct/1:evil", limitID: sessionID))
        XCTAssertEqual(rate, 12, accuracy: 0.01)
    }

    func testCorruptFileIsTreatedAsEmpty() throws {
        let (_, directory) = makeStore()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("acct.json"))

        let store = UsageHistoryStore(directory: directory)
        XCTAssertNil(store.burnRate(accountID: "acct", limitID: sessionID))
        // Recording must recover by overwriting the corrupt file.
        recordRamp(store, start: 20, step: 1, count: 13)
        XCTAssertNotNil(store.burnRate(accountID: "acct", limitID: sessionID))
    }

    func testRecordingNothingCreatesNoFile() {
        let (store, directory) = makeStore()
        store.record([], accountID: "acct", at: epoch)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("acct.json").path))
    }

    // MARK: Mock mode

    func testMockModeDoesNotRecord() {
        let (store, directory) = makeStore()
        // Mock.isEnabled reads the live environment, so flipping the variable
        // for the duration of this test is enough — no other test reads it.
        setenv("CLAUDE_USAGE_MOCK", "1", 1)
        defer { unsetenv("CLAUDE_USAGE_MOCK") }

        recordRamp(store, start: 20, step: 1, count: 13)
        XCTAssertNil(store.burnRate(accountID: "acct", limitID: sessionID))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("acct.json").path))
    }
}
