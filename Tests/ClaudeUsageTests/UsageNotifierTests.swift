import XCTest

@testable import ClaudeUsage

// MARK: - Spy

/// Stands in for the real notification center. Everything runs synchronously
/// — `pendingIdentifiers` answers inline — so tests can assert immediately
/// after `accountDidUpdate` without waiting.
@MainActor
private final class SchedulerSpy: NotificationScheduling {
    struct Request: Equatable {
        let identifier: String
        let title: String
        let body: String
        let fireDate: Date?
    }

    private(set) var authorizationRequests = 0
    /// Immediate banners (nil fire date), in posting order.
    private(set) var posted: [Request] = []
    /// Every future-dated add, in order — catches duplicate scheduling that
    /// the keyed `pending` dictionary alone would silently absorb.
    private(set) var scheduled: [Request] = []
    /// Mimics the center's pending queue so reconciliation across polls runs
    /// against realistic state.
    private(set) var pending: [String: Request] = [:]
    private(set) var removedIdentifiers: [String] = []
    private(set) var removeAllCount = 0

    func requestAuthorization() { authorizationRequests += 1 }

    func add(identifier: String, title: String, body: String, fireDate: Date?) {
        let request = Request(
            identifier: identifier, title: title, body: body, fireDate: fireDate)
        if fireDate == nil {
            posted.append(request)
        } else {
            scheduled.append(request)
            pending[identifier] = request
        }
    }

    func pendingIdentifiers(completion: @escaping @MainActor ([String]) -> Void) {
        completion(Array(pending.keys))
    }

    func removePending(identifiers: [String]) {
        removedIdentifiers.append(contentsOf: identifiers)
        for identifier in identifiers { pending[identifier] = nil }
    }

    func removeAllPending() {
        removeAllCount += 1
        pending.removeAll()
    }
}

// MARK: - Tests

@MainActor
final class UsageNotifierTests: XCTestCase {

    /// Fixed, far-future reset time so `resetsAt`-in-the-future checks are
    /// stable without injecting a clock (2033-05-18T03:33:20Z).
    private static let resetDate = Date(timeIntervalSince1970: 2_000_000_000)
    /// Deterministic id the notifier derives for `resetDate` on the default
    /// account/limit fixtures below.
    private static let resetID = "reset|acct-a|session||2000000000"

    // MARK: Fixtures

    /// Fresh notifier + spy on an isolated defaults suite, enabled by default
    /// (the real default is off; most behaviors only exist while enabled).
    private func makeNotifier(enabled: Bool = true) -> (UsageNotifier, SchedulerSpy) {
        let spy = SchedulerSpy()
        let notifier = UsageNotifier(scheduler: spy, defaults: makeDefaults())
        if enabled { notifier.isEnabled = true }
        return (notifier, spy)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "UsageNotifierTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func makeAccount(id: String = "acct-a", label: String = "Work") -> AccountMeta {
        AccountMeta(
            id: id, email: "work@example.com", organizationName: nil,
            provider: .claude, label: label)
    }

    // Default id "session|" mirrors production ids, which embed a "|" —
    // account-prefix matching must survive that.
    private func makeLimit(
        id: String = "session|", name: String = "Session", percent: Double,
        resetsAt: Date? = nil
    ) -> LimitStatus {
        LimitStatus(
            id: id, name: name, percent: percent, resetsAt: resetsAt,
            isActive: true, sortOrder: 0)
    }

    private func makeState(
        _ limits: [LimitStatus] = [], needsReauth: Bool = false
    ) -> AccountDisplayState {
        var state = AccountDisplayState()
        state.limits = limits
        state.needsReauth = needsReauth
        return state
    }

    // MARK: Threshold alerts

    func testCrossingThresholdPostsOneAlert() {
        let (notifier, spy) = makeNotifier()
        notifier.accountDidUpdate(
            makeAccount(),
            old: makeState([makeLimit(percent: 85)]),
            new: makeState([makeLimit(percent: 92)]))
        XCTAssertEqual(spy.posted.count, 1)
        XCTAssertEqual(spy.posted.first?.title, "Work")
        XCTAssertEqual(spy.posted.first?.body, "Session limit at 92%")
        XCTAssertNil(spy.posted.first?.fireDate)
    }

    func testReachingExactThresholdPosts() {
        let (notifier, spy) = makeNotifier()
        notifier.accountDidUpdate(
            makeAccount(),
            old: makeState([makeLimit(percent: 89)]),
            new: makeState([makeLimit(percent: 90)]))
        XCTAssertEqual(spy.posted.count, 1)
    }

    func testStayingAboveThresholdDoesNotRepost() {
        let (notifier, spy) = makeNotifier()
        notifier.accountDidUpdate(
            makeAccount(),
            old: makeState([makeLimit(percent: 92)]),
            new: makeState([makeLimit(percent: 93)]))
        XCTAssertTrue(spy.posted.isEmpty)
    }

    func testFirstSampleAboveThresholdStaysQuiet() {
        // No previous sample (first fetch after launch): alerting here would
        // re-notify an already-hot limit on every app start.
        let (notifier, spy) = makeNotifier()
        notifier.accountDidUpdate(
            makeAccount(), old: nil, new: makeState([makeLimit(percent: 95)]))
        XCTAssertTrue(spy.posted.isEmpty)
    }

    func testDroppingBelowThresholdRearmsTheAlert() {
        let (notifier, spy) = makeNotifier()
        let account = makeAccount()
        notifier.accountDidUpdate(
            account,
            old: makeState([makeLimit(percent: 80)]),
            new: makeState([makeLimit(percent: 92)]))
        notifier.accountDidUpdate(
            account,
            old: makeState([makeLimit(percent: 92)]),
            new: makeState([makeLimit(percent: 85)]))
        notifier.accountDidUpdate(
            account,
            old: makeState([makeLimit(percent: 85)]),
            new: makeState([makeLimit(percent: 91)]))
        XCTAssertEqual(spy.posted.count, 2)
    }

    // MARK: Sign-in expired

    func testReauthFlipPostsOnce() {
        let (notifier, spy) = makeNotifier()
        let account = makeAccount()
        notifier.accountDidUpdate(
            account, old: makeState(), new: makeState(needsReauth: true))
        XCTAssertEqual(spy.posted.count, 1)
        XCTAssertTrue(spy.posted[0].body.contains("Sign-in expired"))

        // Subsequent polls in the broken state must not nag.
        notifier.accountDidUpdate(
            account, old: makeState(needsReauth: true), new: makeState(needsReauth: true))
        XCTAssertEqual(spy.posted.count, 1)
    }

    func testFirstSampleNeedingReauthPosts() {
        // Deliberate asymmetry with the threshold rule: display state isn't
        // persisted across launches, so a first fetch discovering a dead
        // sign-in is genuinely new information for the user.
        let (notifier, spy) = makeNotifier()
        notifier.accountDidUpdate(
            makeAccount(), old: nil, new: makeState(needsReauth: true))
        XCTAssertEqual(spy.posted.count, 1)
    }

    // MARK: Reset scheduling

    func testHotLimitSchedulesResetAlert() {
        let (notifier, spy) = makeNotifier()
        notifier.accountDidUpdate(
            makeAccount(),
            old: makeState([makeLimit(percent: 92)]),
            new: makeState([makeLimit(percent: 92, resetsAt: Self.resetDate)]))
        XCTAssertEqual(spy.scheduled.count, 1)
        let request = spy.scheduled[0]
        XCTAssertEqual(request.identifier, Self.resetID)
        XCTAssertEqual(request.fireDate, Self.resetDate)
        XCTAssertEqual(request.title, "Work")
        XCTAssertEqual(request.body, "Session limit has reset")
        XCTAssertTrue(spy.posted.isEmpty)
    }

    func testUnchangedResetWindowIsNotRescheduled() {
        let (notifier, spy) = makeNotifier()
        let account = makeAccount()
        let state = makeState([makeLimit(percent: 92, resetsAt: Self.resetDate)])
        notifier.accountDidUpdate(account, old: state, new: state)
        notifier.accountDidUpdate(account, old: state, new: state)
        XCTAssertEqual(spy.scheduled.count, 1)
        XCTAssertTrue(spy.removedIdentifiers.isEmpty)
        XCTAssertEqual(Array(spy.pending.keys), [Self.resetID])
    }

    func testShiftedResetWindowReplacesStaleRequest() {
        let (notifier, spy) = makeNotifier()
        let account = makeAccount()
        let shifted = Self.resetDate.addingTimeInterval(18_000)
        notifier.accountDidUpdate(
            account,
            old: makeState([makeLimit(percent: 92)]),
            new: makeState([makeLimit(percent: 92, resetsAt: Self.resetDate)]))
        notifier.accountDidUpdate(
            account,
            old: makeState([makeLimit(percent: 92, resetsAt: Self.resetDate)]),
            new: makeState([makeLimit(percent: 92, resetsAt: shifted)]))
        XCTAssertEqual(spy.removedIdentifiers, [Self.resetID])
        XCTAssertEqual(Array(spy.pending.keys), ["reset|acct-a|session||2000018000"])
        XCTAssertEqual(spy.scheduled.count, 2)
    }

    func testCoolingDownCancelsPendingResetAlert() {
        let (notifier, spy) = makeNotifier()
        let account = makeAccount()
        notifier.accountDidUpdate(
            account,
            old: makeState([makeLimit(percent: 92)]),
            new: makeState([makeLimit(percent: 92, resetsAt: Self.resetDate)]))
        notifier.accountDidUpdate(
            account,
            old: makeState([makeLimit(percent: 92, resetsAt: Self.resetDate)]),
            new: makeState([makeLimit(percent: 40, resetsAt: Self.resetDate)]))
        XCTAssertEqual(spy.removedIdentifiers, [Self.resetID])
        XCTAssertTrue(spy.pending.isEmpty)
    }

    func testColdLimitWithResetTimeIsNotScheduled() {
        let (notifier, spy) = makeNotifier()
        notifier.accountDidUpdate(
            makeAccount(), old: nil,
            new: makeState([makeLimit(percent: 50, resetsAt: Self.resetDate)]))
        XCTAssertTrue(spy.scheduled.isEmpty)
    }

    func testPastOrMissingResetTimeIsNotScheduled() {
        let (notifier, spy) = makeNotifier()
        let past = Date(timeIntervalSince1970: 1_000)
        notifier.accountDidUpdate(
            makeAccount(),
            old: makeState([makeLimit(percent: 95), makeLimit(id: "weekly", percent: 95)]),
            new: makeState([
                makeLimit(percent: 95, resetsAt: past),
                makeLimit(id: "weekly", percent: 95, resetsAt: nil),
            ]))
        XCTAssertTrue(spy.scheduled.isEmpty)
    }

    func testReconciliationIsScopedToTheUpdatedAccount() {
        let (notifier, spy) = makeNotifier()
        notifier.accountDidUpdate(
            makeAccount(),
            old: makeState([makeLimit(percent: 92)]),
            new: makeState([makeLimit(percent: 92, resetsAt: Self.resetDate)]))

        // Account B reports no hot limits; reconciling it must not treat
        // account A's pending request as stale.
        notifier.accountDidUpdate(
            makeAccount(id: "acct-b", label: "Personal"), old: nil, new: makeState())
        XCTAssertEqual(Array(spy.pending.keys), [Self.resetID])
        XCTAssertTrue(spy.removedIdentifiers.isEmpty)
    }

    // MARK: Master switch

    func testDisabledNotifierPostsAndSchedulesNothing() {
        let (notifier, spy) = makeNotifier(enabled: false)
        notifier.accountDidUpdate(
            makeAccount(),
            old: makeState([makeLimit(percent: 85)]),
            new: makeState(
                [makeLimit(percent: 95, resetsAt: Self.resetDate)], needsReauth: true))
        XCTAssertTrue(spy.posted.isEmpty)
        XCTAssertTrue(spy.scheduled.isEmpty)
        XCTAssertEqual(spy.authorizationRequests, 0)
    }

    func testEnablingRequestsAuthorizationOnce() {
        let (notifier, spy) = makeNotifier(enabled: false)
        XCTAssertEqual(spy.authorizationRequests, 0)
        notifier.isEnabled = true
        XCTAssertEqual(spy.authorizationRequests, 1)
        notifier.isEnabled = true  // no-op write must not re-request
        XCTAssertEqual(spy.authorizationRequests, 1)
    }

    func testDisablingCancelsScheduledResetAlerts() {
        let (notifier, spy) = makeNotifier()
        notifier.accountDidUpdate(
            makeAccount(),
            old: makeState([makeLimit(percent: 92)]),
            new: makeState([makeLimit(percent: 92, resetsAt: Self.resetDate)]))
        XCTAssertEqual(spy.pending.count, 1)

        notifier.isEnabled = false
        XCTAssertEqual(spy.removeAllCount, 1)
        XCTAssertTrue(spy.pending.isEmpty)
    }

    // MARK: Switch suggestions

    /// Two Claude accounts, "Work" burning and "Personal" badged — the shape
    /// `groupsDidUpdate` is meant to act on.
    private func switchFixture() -> (
        accounts: [AccountMeta], badges: [String: BestAccount.Badge]
    ) {
        let work = makeAccount(id: "acct-a", label: "Work")
        let personal = makeAccount(id: "acct-b", label: "Personal")
        return ([work, personal], [personal.id: BestAccount.Badge()])
    }

    func testGroupUpdatePostsSwitchSuggestionWithTargetInTheIdentifier() throws {
        let (notifier, spy) = makeNotifier()
        let (accounts, badges) = switchFixture()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        notifier.groupsDidUpdate(
            accounts: accounts, badges: badges, sessionBurnRates: ["acct-a": 24], now: now)

        XCTAssertEqual(spy.posted.count, 1)
        let request = try XCTUnwrap(spy.posted.first)
        XCTAssertEqual(request.title, "Switch to Personal")
        XCTAssertEqual(request.body, "more session headroom right now")
        // Delivered immediately, and the target account id is recoverable from
        // the identifier for a future action button (PR #16).
        XCTAssertNil(request.fireDate)
        XCTAssertEqual(request.identifier, "switch|claude|acct-b|1700000000")
    }

    func testGroupUpdateDoesNotRepostAnUnchangedRecommendation() {
        let (notifier, spy) = makeNotifier()
        let (accounts, badges) = switchFixture()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        notifier.groupsDidUpdate(
            accounts: accounts, badges: badges, sessionBurnRates: ["acct-a": 24], now: now)
        // An hour later, same situation: the notifier keeps the pure
        // function's state across cycles, so the edge trigger holds.
        notifier.groupsDidUpdate(
            accounts: accounts, badges: badges, sessionBurnRates: ["acct-a": 24],
            now: now.addingTimeInterval(3600))
        XCTAssertEqual(spy.posted.count, 1)
    }

    func testSwitchSuggestionsRequireTheMasterToggle() {
        let (notifier, spy) = makeNotifier(enabled: false)
        let (accounts, badges) = switchFixture()
        XCTAssertTrue(notifier.suggestsSwitches)

        notifier.groupsDidUpdate(
            accounts: accounts, badges: badges, sessionBurnRates: ["acct-a": 24])
        XCTAssertTrue(spy.posted.isEmpty)
    }

    func testSwitchSuggestionsToggleSilencesThemImmediately() {
        let (notifier, spy) = makeNotifier()
        let (accounts, badges) = switchFixture()
        notifier.suggestsSwitches = false

        notifier.groupsDidUpdate(
            accounts: accounts, badges: badges, sessionBurnRates: ["acct-a": 24])
        XCTAssertTrue(spy.posted.isEmpty)

        // Threshold and reauth alerts are unaffected: only the advisory half
        // is off.
        notifier.accountDidUpdate(
            makeAccount(),
            old: makeState([makeLimit(percent: 80)]),
            new: makeState([makeLimit(percent: 95)]))
        XCTAssertEqual(spy.posted.count, 1)
    }

    func testTogglingSuggestionsBackOnForgetsThePreviousAdvice() {
        let (notifier, spy) = makeNotifier()
        let (accounts, badges) = switchFixture()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        notifier.groupsDidUpdate(
            accounts: accounts, badges: badges, sessionBurnRates: ["acct-a": 24], now: now)
        XCTAssertEqual(spy.posted.count, 1)

        // Off and on again: the memory is cleared, so the current
        // recommendation is delivered rather than swallowed by a stale edge.
        notifier.suggestsSwitches = false
        notifier.suggestsSwitches = true
        notifier.groupsDidUpdate(
            accounts: accounts, badges: badges, sessionBurnRates: ["acct-a": 24],
            now: now.addingTimeInterval(60))
        XCTAssertEqual(spy.posted.count, 2)
    }

    func testSuggestionsSettingDefaultsOnAndPersistsIndependently() {
        let defaults = makeDefaults()
        let first = UsageNotifier(scheduler: SchedulerSpy(), defaults: defaults)
        XCTAssertTrue(first.suggestsSwitches)
        first.suggestsSwitches = false

        // Relaunch: the opt-out survives, and it is its own key — the master
        // toggle is untouched.
        let second = UsageNotifier(scheduler: SchedulerSpy(), defaults: defaults)
        XCTAssertFalse(second.suggestsSwitches)
        XCTAssertFalse(second.isEnabled)
    }

    func testEnabledStatePersistsWithoutReprompting() {
        let defaults = makeDefaults()
        let firstSpy = SchedulerSpy()
        let first = UsageNotifier(scheduler: firstSpy, defaults: defaults)
        first.isEnabled = true

        // Relaunch: same defaults, fresh notifier. The saved value must be
        // restored without triggering another authorization prompt.
        let secondSpy = SchedulerSpy()
        let second = UsageNotifier(scheduler: secondSpy, defaults: defaults)
        XCTAssertTrue(second.isEnabled)
        XCTAssertEqual(secondSpy.authorizationRequests, 0)
    }
}
