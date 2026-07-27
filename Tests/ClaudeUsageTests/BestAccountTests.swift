import XCTest

@testable import ClaudeUsage

/// Exercises the pure ranking behind the "Best" badge (`BestAccount`).
/// Everything runs on handcrafted fixtures — no `AccountStore`, whose init
/// touches UserDefaults/Keychain and starts the network poll loop.
@MainActor
final class BestAccountTests: XCTestCase {

    /// Fixed reset time (2033-05-18T03:33:20Z). The v1 ranking never read
    /// it; the v2 pace override does — a projection landing at/after it
    /// counts as outlasting the window.
    private static let resetDate = Date(timeIntervalSince1970: 2_000_000_000)
    /// Fixed "now", four hours before the session resets — a realistic spot
    /// inside a 5-hour window — so projections relative to both are stable.
    private static let now = resetDate.addingTimeInterval(-4 * 3600)

    // MARK: Fixtures

    private func makeAccount(_ id: String, provider: ProviderID = .claude) -> AccountMeta {
        AccountMeta(
            id: id, email: "\(id)@example.com", organizationName: nil,
            provider: provider, label: id)
    }

    private func makeLimit(
        id: String, name: String, percent: Double, sortOrder: Int
    ) -> LimitStatus {
        LimitStatus(
            id: id, name: name, percent: percent, resetsAt: Self.resetDate,
            isActive: false, sortOrder: sortOrder)
    }

    /// Claude-shaped state: a "Session" window plus a week-scoped window,
    /// with production-style ids (they embed a "|").
    private func makeState(
        session: Double, weekly: Double = 50, needsReauth: Bool = false
    ) -> AccountDisplayState {
        makeState(
            limits: [
                makeLimit(id: "session|", name: "Session", percent: session, sortOrder: 0),
                makeLimit(id: "weekly_all|", name: "Weekly", percent: weekly, sortOrder: 1),
            ],
            needsReauth: needsReauth)
    }

    private func makeState(
        limits: [LimitStatus], needsReauth: Bool = false
    ) -> AccountDisplayState {
        var state = AccountDisplayState()
        state.limits = limits
        state.needsReauth = needsReauth
        return state
    }

    /// Claude-shaped state whose session window resets `resetIn` seconds
    /// after the fixed `now` (negative = already reset), for the v3
    /// expiring-capacity fixtures.
    private func makeState(
        session: Double, resetIn: TimeInterval, needsReauth: Bool = false
    ) -> AccountDisplayState {
        makeState(
            limits: [
                LimitStatus(
                    id: "session|", name: "Session", percent: session,
                    resetsAt: Self.now.addingTimeInterval(resetIn),
                    isActive: false, sortOrder: 0),
                makeLimit(id: "weekly_all|", name: "Weekly", percent: 50, sortOrder: 1),
            ],
            needsReauth: needsReauth)
    }

    /// One weekly-scoped window for the v4 fixtures (issue #21): display
    /// name — also the base of the limit id, the way the providers build them
    /// — percent, and when it resets relative to `now` (nil = the API
    /// reported no deadline).
    private struct Weekly {
        var name: String = "Weekly"
        var percent: Double
        var resetIn: TimeInterval?
        /// What the provider said the window's length is. Nil — the default,
        /// so the older fixtures keep exercising the no-duration fallback —
        /// means "unstated", which the classifier treats as week-scoped.
        /// Set it to a sub-day value to build a short window that is *not*
        /// the session slot, the shape Codex's per-model extra limits have.
        var windowSeconds: TimeInterval?
    }

    /// Claude-shaped state with an explicit set of weekly-scoped windows, for
    /// the weekly-leg fixtures. The session window resets `sessionResetIn`
    /// seconds after the fixed `now`.
    private func makeState(
        session: Double, sessionResetIn: TimeInterval? = 4 * 3600,
        sessionWindowSeconds: TimeInterval? = nil,
        weekly: [Weekly], needsReauth: Bool = false
    ) -> AccountDisplayState {
        var limits = [
            LimitStatus(
                id: "session|", name: "Session", percent: session,
                resetsAt: sessionResetIn.map { Self.now.addingTimeInterval($0) },
                isActive: false, sortOrder: 0, windowSeconds: sessionWindowSeconds)
        ]
        for (index, window) in weekly.enumerated() {
            limits.append(
                LimitStatus(
                    id: "\(window.name)|", name: window.name, percent: window.percent,
                    resetsAt: window.resetIn.map { Self.now.addingTimeInterval($0) },
                    isActive: false, sortOrder: index + 1,
                    windowSeconds: window.windowSeconds))
        }
        return makeState(limits: limits, needsReauth: needsReauth)
    }

    /// Weekly burn rates keyed by window name, mapped onto the limit ids
    /// `makeState(session:weekly:)` builds — the store keys them per limit
    /// because an account can have several weekly-scoped windows.
    private func rates(byWindow: [String: Double]) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: byWindow.map { ("\($0.key)|", $0.value) })
    }

    /// Claude-shaped state whose session window has no reset timestamp — an
    /// idle window the API reports without a deadline.
    private func makeIdleSessionState(session: Double) -> AccountDisplayState {
        makeState(limits: [
            LimitStatus(
                id: "session|", name: "Session", percent: session,
                resetsAt: nil, isActive: false, sortOrder: 0),
            makeLimit(id: "weekly_all|", name: "Weekly", percent: 50, sortOrder: 1),
        ])
    }

    /// Runs the ranking over (account, state) pairs; a nil state models an
    /// account the store hasn't heard from at all.
    private func winners(
        _ pairs: [(AccountMeta, AccountDisplayState?)],
        projections: [String: Date] = [:],
        rates: [String: Double] = [:],
        weeklyRates: [String: [String: Double]] = [:],
        multipliers: [String: Double] = [:],
        detected: [String: Double] = [:]
    ) -> Set<String> {
        Set(
            badges(
                pairs, projections: projections, rates: rates,
                weeklyRates: weeklyRates,
                multipliers: multipliers, detected: detected
            ).keys)
    }

    /// Same run, but keeping the full verdicts for tooltip assertions.
    private func badges(
        _ pairs: [(AccountMeta, AccountDisplayState?)],
        projections: [String: Date] = [:],
        rates: [String: Double] = [:],
        weeklyRates: [String: [String: Double]] = [:],
        multipliers: [String: Double] = [:],
        detected: [String: Double] = [:]
    ) -> [String: BestAccount.Badge] {
        var states: [String: AccountDisplayState] = [:]
        for (account, state) in pairs {
            states[account.id] = state
        }
        return BestAccount.winners(
            accounts: pairs.map(\.0), states: states,
            sessionProjections: projections, sessionBurnRates: rates,
            weeklyBurnRates: weeklyRates,
            quotas: quotas(manual: multipliers, detected: detected), now: Self.now)
    }

    /// Builds the quota input the way `AccountStore` does: manual choices
    /// win over detected tiers.
    private func quotas(
        manual: [String: Double], detected: [String: Double]
    ) -> [String: BestAccount.Quota] {
        var quotas: [String: BestAccount.Quota] = [:]
        for (id, multiplier) in detected {
            quotas[id] = BestAccount.Quota(multiplier: multiplier, source: .detected)
        }
        for (id, multiplier) in manual {
            quotas[id] = BestAccount.Quota(multiplier: multiplier, source: .manual)
        }
        return quotas
    }

    // MARK: Group size

    func testSingleAccountIsNeverBadged() {
        // With nothing to compare against, "best" is meaningless.
        XCTAssertTrue(winners([(makeAccount("a"), makeState(session: 5))]).isEmpty)
    }

    func testLoneAccountOfAnotherProviderIsNotBadged() {
        // The lone Codex account has by far the most headroom, but there is
        // no second Codex account to beat — only same-provider comparisons
        // are meaningful, so only the Claude pair produces a badge.
        let result = winners([
            (makeAccount("claude-a"), makeState(session: 30)),
            (makeAccount("claude-b"), makeState(session: 80)),
            (makeAccount("codex", provider: .codex), makeState(session: 1)),
        ])
        XCTAssertEqual(result, ["claude-a"])
    }

    // MARK: Ranking

    func testWinnerHasLowestSessionPercent() {
        let result = winners([
            (makeAccount("a"), makeState(session: 55)),
            (makeAccount("b"), makeState(session: 20)),
            (makeAccount("c"), makeState(session: 90)),
        ])
        XCTAssertEqual(result, ["b"])
    }

    func testExactMarginShowsBadge() {
        // 50 − 40 is exactly the 10-point margin; the margin is inclusive.
        let result = winners([
            (makeAccount("a"), makeState(session: 40)),
            (makeAccount("b"), makeState(session: 50)),
        ])
        XCTAssertEqual(result, ["a"])
    }

    func testJustUnderMarginShowsNoBadge() {
        // 9.9 points apart: too close to call, so stay quiet.
        let result = winners([
            (makeAccount("a"), makeState(session: 40.1)),
            (makeAccount("b"), makeState(session: 50)),
        ])
        XCTAssertTrue(result.isEmpty)
    }

    func testMarginComparesWinnerToRunnerUpNotWorst() {
        // a beats c by plenty, but b trails a by only 5 points — the badge
        // must stay off. Measuring against the worst account instead of the
        // runner-up would wrongly show it.
        let result = winners([
            (makeAccount("a"), makeState(session: 40)),
            (makeAccount("b"), makeState(session: 45)),
            (makeAccount("c"), makeState(session: 95)),
        ])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: Vetoes

    func testNeedsReauthVetoes() {
        // a has the most session headroom on paper, but a dead sign-in makes
        // it unusable; b wins as the sole eligible account.
        let result = winners([
            (makeAccount("a"), makeState(session: 0, needsReauth: true)),
            (makeAccount("b"), makeState(session: 90)),
        ])
        XCTAssertEqual(result, ["b"])
    }

    func testNoDataVetoes() {
        // An account that hasn't produced limits yet can't be recommended.
        let result = winners([
            (makeAccount("a"), makeState(limits: [])),
            (makeAccount("b"), makeState(session: 90)),
        ])
        XCTAssertEqual(result, ["b"])
    }

    func testMissingStateVetoes() {
        // No display state at all (never fetched) — same as no data.
        let result = winners([
            (makeAccount("a"), nil),
            (makeAccount("b"), makeState(session: 90)),
        ])
        XCTAssertEqual(result, ["b"])
    }

    func testExhaustedWeeklyWindowVetoes() {
        // Session headroom is a mirage when the week is spent; 99.5 is the
        // inclusive exhaustion threshold.
        let result = winners([
            (makeAccount("a"), makeState(session: 5, weekly: 99.5)),
            (makeAccount("b"), makeState(session: 90, weekly: 0)),
        ])
        XCTAssertEqual(result, ["b"])
    }

    func testAlmostExhaustedWeeklyDoesNotVeto() {
        // Just under the threshold the account is still usable — it wins on
        // session headroom as usual.
        let result = winners([
            (makeAccount("a"), makeState(session: 5, weekly: 99.4)),
            (makeAccount("b"), makeState(session: 90, weekly: 0)),
        ])
        XCTAssertEqual(result, ["a"])
    }

    func testExhaustedModelScopedWindowVetoes() {
        // Every non-session window is week-scoped, including per-model rows
        // like Claude's Fable limit — any of them at the cap vetoes.
        let a = makeState(limits: [
            makeLimit(id: "session|", name: "Session", percent: 5, sortOrder: 0),
            makeLimit(id: "weekly_all|", name: "Weekly", percent: 40, sortOrder: 1),
            makeLimit(id: "weekly_model|Fable", name: "Fable", percent: 99.6, sortOrder: 2),
        ])
        let result = winners([
            (makeAccount("a"), a),
            (makeAccount("b"), makeState(session: 90)),
        ])
        XCTAssertEqual(result, ["b"])
    }

    func testExhaustedSessionDoesNotVeto() {
        // The exhaustion veto is for week-scoped windows only. A full session
        // window keeps a eligible as runner-up, so the 5-point race is too
        // close and nothing is badged. If the session wrongly vetoed, b would
        // win outright as sole survivor.
        let result = winners([
            (makeAccount("a"), makeState(session: 100)),
            (makeAccount("b"), makeState(session: 95)),
        ])
        XCTAssertTrue(result.isEmpty)
    }

    func testSoleSurvivorIsBadgedOutright() {
        // With every rival vetoed there is no close call to flap on — the
        // survivor is badged even with poor headroom and no margin to anyone.
        let result = winners([
            (makeAccount("a"), makeState(session: 90)),
            (makeAccount("b"), makeState(session: 2, needsReauth: true)),
            (makeAccount("c"), makeState(session: 1, weekly: 100)),
        ])
        XCTAssertEqual(result, ["a"])
    }

    func testAllVetoedShowsNoBadge() {
        let result = winners([
            (makeAccount("a"), makeState(session: 10, needsReauth: true)),
            (makeAccount("b"), nil),
        ])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: Session-limit identification

    func testRankingUsesSessionRowNotFirstRow() {
        // Weekly sorted first: comparing first rows would pick a (10 vs 90),
        // but the "Session" rows say b has far more session headroom.
        let a = makeState(limits: [
            makeLimit(id: "w", name: "Weekly", percent: 10, sortOrder: 0),
            makeLimit(id: "s", name: "Session", percent: 80, sortOrder: 1),
        ])
        let b = makeState(limits: [
            makeLimit(id: "w", name: "Weekly", percent: 90, sortOrder: 0),
            makeLimit(id: "s", name: "Session", percent: 20, sortOrder: 1),
        ])
        let result = winners([(makeAccount("a"), a), (makeAccount("b"), b)])
        XCTAssertEqual(result, ["b"])
    }

    func testSessionLimitPrefersNameMatch() {
        let limits = [
            makeLimit(id: "w", name: "Weekly", percent: 60, sortOrder: 0),
            makeLimit(id: "s", name: "Session", percent: 30, sortOrder: 1),
        ]
        XCTAssertEqual(BestAccount.sessionLimit(in: limits)?.id, "s")
    }

    func testSessionLimitFallsBackToFirstLimit() {
        // Codex emits "Window" when the API omits the window length; the
        // first row is the session slot in every provider's builder.
        let limits = [
            makeLimit(id: "primary|Window", name: "Window", percent: 30, sortOrder: 0),
            makeLimit(id: "secondary|Weekly", name: "Weekly", percent: 60, sortOrder: 1),
        ]
        XCTAssertEqual(BestAccount.sessionLimit(in: limits)?.id, "primary|Window")
    }

    func testSessionLimitOfEmptyLimitsIsNil() {
        XCTAssertNil(BestAccount.sessionLimit(in: []))
    }

    // MARK: Provider independence

    func testEachProviderGetsItsOwnWinner() {
        let result = winners([
            (makeAccount("claude-a"), makeState(session: 20)),
            (makeAccount("claude-b"), makeState(session: 70)),
            (makeAccount("codex-a", provider: .codex), makeState(session: 85)),
            (makeAccount("codex-b", provider: .codex), makeState(session: 40)),
        ])
        XCTAssertEqual(result, ["claude-a", "codex-b"])
    }

    func testProvidersDoNotCrossCompare() {
        // The Claude pair is 5 points apart — no badge — and that verdict
        // must not change because Codex percents sit far above and below;
        // the Codex pair still resolves on its own.
        let result = winners([
            (makeAccount("claude-a"), makeState(session: 40)),
            (makeAccount("claude-b"), makeState(session: 45)),
            (makeAccount("codex-a", provider: .codex), makeState(session: 1)),
            (makeAccount("codex-b", provider: .codex), makeState(session: 99)),
        ])
        XCTAssertEqual(result, ["codex-a"])
    }

    // MARK: Pace override (v2)

    /// A projection `interval` seconds after the fixed "now".
    private func projection(_ interval: TimeInterval) -> Date {
        Self.now.addingTimeInterval(interval)
    }

    func testRunnerUpOutlastingWinnerTakesBadge() {
        // a has the most headroom, but at its pace it dies in 30 minutes
        // while b lasts two hours — the badge follows the longer-lasting
        // account, and the tooltip carries b's projection.
        let result = badges(
            [
                (makeAccount("a"), makeState(session: 40)),
                (makeAccount("b"), makeState(session: 55)),
            ],
            projections: ["a": projection(1800), "b": projection(2 * 3600)])
        XCTAssertEqual(Set(result.keys), ["b"])
        XCTAssertEqual(result["b"]?.projectedExhaustion, projection(2 * 3600))
    }

    func testWinnerKeepsBadgeAndTooltipWhenPaceAgrees() {
        // The headroom winner also lasts longer: no override, and its own
        // projection feeds the tooltip.
        let result = badges(
            [
                (makeAccount("a"), makeState(session: 40)),
                (makeAccount("b"), makeState(session: 55)),
            ],
            projections: ["a": projection(3 * 3600), "b": projection(3600)])
        XCTAssertEqual(Set(result.keys), ["a"])
        XCTAssertEqual(result["a"]?.projectedExhaustion, projection(3 * 3600))
    }

    func testOverrideAtExactMarginMoves() {
        // b outlasts a by exactly 30 minutes — the override margin is
        // inclusive, like the v1 headroom margin.
        let result = badges(
            [
                (makeAccount("a"), makeState(session: 40)),
                (makeAccount("b"), makeState(session: 55)),
            ],
            projections: ["a": projection(3600), "b": projection(3600 + 1800)])
        XCTAssertEqual(Set(result.keys), ["b"])
    }

    func testJustUnderOverrideMarginStaysWithHeadroomWinner() {
        // 29m59s of extra runway is forecast noise, not a reason to move.
        let result = badges(
            [
                (makeAccount("a"), makeState(session: 40)),
                (makeAccount("b"), makeState(session: 55)),
            ],
            projections: ["a": projection(3600), "b": projection(3600 + 1799)])
        XCTAssertEqual(Set(result.keys), ["a"])
        XCTAssertEqual(result["a"]?.projectedExhaustion, projection(3600))
    }

    func testWinnerWithoutProjectionKeepsBadge() {
        // a is idle (no projection) while b is projected five hours out. Nil
        // means "not currently burning" — no pace signal — never "exhausts
        // immediately"; reading it that way would hand b the badge here.
        let result = badges(
            [
                (makeAccount("a"), makeState(session: 40)),
                (makeAccount("b"), makeState(session: 55)),
            ],
            projections: ["b": projection(5 * 3600)])
        XCTAssertEqual(Set(result.keys), ["a"])
        XCTAssertNil(result["a"]?.projectedExhaustion)
    }

    func testRunnerUpWithoutProjectionKeepsV1Winner() {
        // a is dying fast, but idle b offers no pace signal to compare
        // against — the headroom verdict stands, tooltip still time-based.
        let result = badges(
            [
                (makeAccount("a"), makeState(session: 40)),
                (makeAccount("b"), makeState(session: 55)),
            ],
            projections: ["a": projection(1800)])
        XCTAssertEqual(Set(result.keys), ["a"])
        XCTAssertEqual(result["a"]?.projectedExhaustion, projection(1800))
    }

    func testNoProjectionsIsPureV1() {
        let result = badges([
            (makeAccount("a"), makeState(session: 40)),
            (makeAccount("b"), makeState(session: 55)),
        ])
        XCTAssertEqual(Set(result.keys), ["a"])
        XCTAssertNil(result["a"]?.projectedExhaustion)
    }

    func testOverrideNeverResurrectsVetoedAccount() {
        // b would outlast everyone, but its sign-in is dead — vetoed accounts
        // drop out before the pace comparison. The eligible runner-up c has
        // no projection, so a keeps the badge.
        let result = badges(
            [
                (makeAccount("a"), makeState(session: 40)),
                (makeAccount("b"), makeState(session: 55, needsReauth: true)),
                (makeAccount("c"), makeState(session: 70)),
            ],
            projections: ["a": projection(1800), "b": projection(6 * 3600)])
        XCTAssertEqual(Set(result.keys), ["a"])
    }

    func testOverrideRespectsWeeklyVeto() {
        // Same shape with the weekly-exhaustion veto: b's long runway is a
        // mirage when its week is spent.
        let result = badges(
            [
                (makeAccount("a"), makeState(session: 40)),
                (makeAccount("b"), makeState(session: 55, weekly: 99.5)),
                (makeAccount("c"), makeState(session: 70)),
            ],
            projections: ["a": projection(1800), "b": projection(6 * 3600)])
        XCTAssertEqual(Set(result.keys), ["a"])
    }

    func testOverrideDoesNotCrossProviders() {
        // Codex's loser has by far the longest runway, but each provider's
        // override weighs only its own candidates: the Claude runner-up is
        // 20 minutes of extra runway short of an override, while the Codex
        // pair does flip on pace.
        let result = winners(
            [
                (makeAccount("claude-a"), makeState(session: 20)),
                (makeAccount("claude-b"), makeState(session: 70)),
                (makeAccount("codex-c", provider: .codex), makeState(session: 10)),
                (makeAccount("codex-d", provider: .codex), makeState(session: 90)),
            ],
            projections: [
                "claude-a": projection(1800),
                "claude-b": projection(1800 + 600),
                "codex-c": projection(3600),
                "codex-d": projection(3 * 3600),
            ])
        XCTAssertEqual(result, ["claude-a", "codex-d"])
    }

    func testSingleAccountWithProjectionStillNotBadged() {
        // The group-size rule survives v2: pace data doesn't make a lone
        // account comparable to nothing.
        let result = badges(
            [(makeAccount("a"), makeState(session: 5))],
            projections: ["a": projection(3600)])
        XCTAssertTrue(result.isEmpty)
    }

    func testPastProjectionIsNoSignal() {
        // a's projection is 10 minutes ago: stale history, not "already
        // dead" — a truly exhausted session shows in its percent, which the
        // ranking already sees. With no usable signal on a the override
        // can't fire, and the tooltip stays static.
        let result = badges(
            [
                (makeAccount("a"), makeState(session: 40)),
                (makeAccount("b"), makeState(session: 55)),
            ],
            projections: ["a": projection(-600), "b": projection(2 * 3600)])
        XCTAssertEqual(Set(result.keys), ["a"])
        XCTAssertNil(result["a"]?.projectedExhaustion)
    }

    func testProjectionBeyondResetCountsAsOutlastingTheWindow() {
        // b's projected exhaustion lands after its session resets — at the
        // current pace it never runs out this window, which beats a's
        // 30-minute runway. There's no honest duration to show for "outlasts
        // the window", so the tooltip stays static.
        let result = badges(
            [
                (makeAccount("a"), makeState(session: 40)),
                (makeAccount("b"), makeState(session: 55)),
            ],
            projections: [
                "a": projection(1800),
                "b": Self.resetDate.addingTimeInterval(3600),
            ])
        XCTAssertEqual(Set(result.keys), ["b"])
        XCTAssertNil(result["b"]?.projectedExhaustion)
    }

    func testWinnerProjectionBeyondResetKeepsBadgeWithStaticTooltip() {
        // The winner outlasts its whole window; the runner-up dying sooner is
        // no reason to move, and the post-reset date is not shown.
        let result = badges(
            [
                (makeAccount("a"), makeState(session: 40)),
                (makeAccount("b"), makeState(session: 55)),
            ],
            projections: [
                "a": Self.resetDate.addingTimeInterval(3600),
                "b": projection(1800),
            ])
        XCTAssertEqual(Set(result.keys), ["a"])
        XCTAssertNil(result["a"]?.projectedExhaustion)
    }

    func testBothProjectionsBeyondResetKeepV1Winner() {
        // Neither account runs out this window: pace has nothing to add, so
        // the headroom verdict stands with the static tooltip.
        let result = badges(
            [
                (makeAccount("a"), makeState(session: 40)),
                (makeAccount("b"), makeState(session: 55)),
            ],
            projections: [
                "a": Self.resetDate.addingTimeInterval(3600),
                "b": Self.resetDate.addingTimeInterval(2 * 3600),
            ])
        XCTAssertEqual(Set(result.keys), ["a"])
        XCTAssertNil(result["a"]?.projectedExhaustion)
    }

    // MARK: Evaluation trace (debug view)

    /// Full traces over the same fixture shape the `winners` helper uses.
    private func traces(
        _ pairs: [(AccountMeta, AccountDisplayState?)],
        projections: [String: Date] = [:],
        rates: [String: Double] = [:],
        weeklyRates: [String: [String: Double]] = [:],
        multipliers: [String: Double] = [:],
        detected: [String: Double] = [:]
    ) -> [BestAccount.GroupTrace] {
        var states: [String: AccountDisplayState] = [:]
        for (account, state) in pairs {
            states[account.id] = state
        }
        return BestAccount.evaluate(
            accounts: pairs.map(\.0), states: states,
            sessionProjections: projections, sessionBurnRates: rates,
            weeklyBurnRates: weeklyRates,
            quotas: quotas(manual: multipliers, detected: detected), now: Self.now)
    }

    private func candidate(
        _ id: String, in trace: BestAccount.GroupTrace
    ) -> BestAccount.CandidateTrace? {
        trace.candidates.first { $0.accountID == id }
    }

    private func award(
        of trace: BestAccount.GroupTrace,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> BestAccount.Award {
        guard case .badged(let award) = trace.decision else {
            XCTFail("expected a badge, got \(trace.decision)", file: file, line: line)
            throw XCTSkip("no award to inspect")
        }
        return award
    }

    private func expiringAward(
        of trace: BestAccount.GroupTrace,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> BestAccount.ExpiringAward {
        guard case .expiringFirst(let award) = trace.decision else {
            XCTFail("expected an expiring-first badge, got \(trace.decision)",
                file: file, line: line)
            throw XCTSkip("no expiring award to inspect")
        }
        return award
    }

    func testTraceRecordsEachVetoReason() throws {
        // Every veto kind side by side; a survives as the sole eligible
        // account, and the trace still lists everyone with a reason.
        let trace = try XCTUnwrap(
            traces([
                (makeAccount("a"), makeState(session: 40)),
                (makeAccount("b"), makeState(session: 5, needsReauth: true)),
                (makeAccount("c"), makeState(limits: [])),
                (makeAccount("d"), nil),
                (makeAccount("e"), makeState(session: 10, weekly: 99.8)),
            ]).first)
        XCTAssertEqual(candidate("a", in: trace)?.eligibility, .eligible)
        XCTAssertEqual(candidate("a", in: trace)?.sessionPercent, 40)
        XCTAssertEqual(candidate("a", in: trace)?.sessionName, "Session")
        XCTAssertEqual(candidate("b", in: trace)?.eligibility, .vetoedNeedsReauth)
        XCTAssertEqual(candidate("c", in: trace)?.eligibility, .vetoedNoData)
        XCTAssertEqual(candidate("d", in: trace)?.eligibility, .vetoedNoData)
        XCTAssertEqual(
            candidate("e", in: trace)?.eligibility,
            .vetoedWeeklyExhausted(limitName: "Weekly", percent: 99.8))

        let award = try award(of: trace)
        XCTAssertEqual(award.badgedID, "a")
        XCTAssertNil(award.headroomGap)
        XCTAssertEqual(award.paceComparison, .soleCandidate)
        XCTAssertFalse(award.overrideApplied)
    }

    func testTraceMarginNumbersMatchBadgedDecision() throws {
        let trace = try XCTUnwrap(
            traces([
                (makeAccount("a"), makeState(session: 40)),
                (makeAccount("b"), makeState(session: 55)),
            ]).first)
        let award = try award(of: trace)
        XCTAssertEqual(award.headroomWinnerID, "a")
        XCTAssertEqual(award.headroomGap, 15)
        XCTAssertEqual(award.paceComparison, .missingSignal)
        XCTAssertEqual(award.badgedID, "a")
        XCTAssertFalse(award.overrideApplied)
        XCTAssertNil(award.badge.projectedExhaustion)
    }

    func testTraceMarginTooCloseCarriesNumbers() throws {
        let trace = try XCTUnwrap(
            traces([
                (makeAccount("a"), makeState(session: 40)),
                (makeAccount("b"), makeState(session: 45)),
            ]).first)
        XCTAssertEqual(
            trace.decision, .marginTooClose(winnerID: "a", runnerUpID: "b", gap: 5))
    }

    func testTraceOverrideAppliedCarriesDelta() throws {
        // b outlasts a by two hours: the delta, the moved badge, and the
        // tooltip payload all live in the award.
        let trace = try XCTUnwrap(
            traces(
                [
                    (makeAccount("a"), makeState(session: 40)),
                    (makeAccount("b"), makeState(session: 55)),
                ],
                projections: ["a": projection(3600), "b": projection(3 * 3600)]
            ).first)
        let award = try award(of: trace)
        XCTAssertEqual(award.headroomWinnerID, "a")
        XCTAssertEqual(award.paceComparison, .delta(2 * 3600))
        XCTAssertTrue(award.overrideApplied)
        XCTAssertEqual(award.badgedID, "b")
        XCTAssertEqual(award.badge.projectedExhaustion, projection(3 * 3600))
    }

    func testTraceOverrideWithheldCarriesDelta() throws {
        // 15 minutes of extra runway is under the margin: the trace still
        // records the exact delta the decision was made on.
        let trace = try XCTUnwrap(
            traces(
                [
                    (makeAccount("a"), makeState(session: 40)),
                    (makeAccount("b"), makeState(session: 55)),
                ],
                projections: ["a": projection(3600), "b": projection(3600 + 900)]
            ).first)
        let award = try award(of: trace)
        XCTAssertEqual(award.paceComparison, .delta(900))
        XCTAssertFalse(award.overrideApplied)
        XCTAssertEqual(award.badgedID, "a")
        XCTAssertEqual(award.badge.projectedExhaustion, projection(3600))
    }

    func testTraceRunnerUpBeyondResetComparison() throws {
        let trace = try XCTUnwrap(
            traces(
                [
                    (makeAccount("a"), makeState(session: 40)),
                    (makeAccount("b"), makeState(session: 55)),
                ],
                projections: [
                    "a": projection(1800),
                    "b": Self.resetDate.addingTimeInterval(3600),
                ]
            ).first)
        XCTAssertEqual(candidate("b", in: trace)?.pace, .beyondReset)
        let award = try award(of: trace)
        XCTAssertEqual(award.paceComparison, .runnerUpOutlastsWindow)
        XCTAssertTrue(award.overrideApplied)
        XCTAssertEqual(award.badgedID, "b")
        XCTAssertNil(award.badge.projectedExhaustion)
    }

    func testTraceWinnerBeyondResetComparison() throws {
        let trace = try XCTUnwrap(
            traces(
                [
                    (makeAccount("a"), makeState(session: 40)),
                    (makeAccount("b"), makeState(session: 55)),
                ],
                projections: [
                    "a": Self.resetDate.addingTimeInterval(3600),
                    "b": projection(1800),
                ]
            ).first)
        let award = try award(of: trace)
        XCTAssertEqual(award.paceComparison, .winnerOutlastsWindow)
        XCTAssertFalse(award.overrideApplied)
        XCTAssertEqual(award.badgedID, "a")
        XCTAssertNil(award.badge.projectedExhaustion)
    }

    func testTraceGroupTooSmall() throws {
        let trace = try XCTUnwrap(
            traces([(makeAccount("a"), makeState(session: 5))]).first)
        XCTAssertEqual(trace.decision, .groupTooSmall)
        // The lone account is still fully traced for the debug view.
        XCTAssertEqual(candidate("a", in: trace)?.sessionPercent, 5)
    }

    func testTraceAllVetoed() throws {
        let trace = try XCTUnwrap(
            traces([
                (makeAccount("a"), makeState(session: 10, needsReauth: true)),
                (makeAccount("b"), nil),
            ]).first)
        XCTAssertEqual(trace.decision, .allVetoed)
    }

    func testTracePaceSignalKinds() throws {
        // All four signal kinds side by side: a real projection, a stale
        // (past) one, none at all, and one landing past the session reset.
        let trace = try XCTUnwrap(
            traces(
                [
                    (makeAccount("a"), makeState(session: 10)),
                    (makeAccount("b"), makeState(session: 30)),
                    (makeAccount("c"), makeState(session: 50)),
                    (makeAccount("d"), makeState(session: 70)),
                ],
                projections: [
                    "a": projection(3600),
                    "b": projection(-600),
                    "d": Self.resetDate.addingTimeInterval(10),
                ]
            ).first)
        XCTAssertEqual(candidate("a", in: trace)?.pace, .projected(projection(3600)))
        XCTAssertEqual(candidate("b", in: trace)?.pace, .stale)
        XCTAssertEqual(candidate("c", in: trace)?.pace, .noProjection)
        XCTAssertEqual(candidate("d", in: trace)?.pace, .beyondReset)
    }

    /// Fixture spread shared by the derivation and zero-pace property
    /// tests: v1/v2 shapes plus one v3 (expiring-first) shape.
    private func derivationFixtures() -> [(
        pairs: [(AccountMeta, AccountDisplayState?)],
        projections: [String: Date],
        rates: [String: Double]
    )] {
        [
            // plain v1 winner
            ([
                (makeAccount("a"), makeState(session: 40)),
                (makeAccount("b"), makeState(session: 55)),
            ], [:], [:]),
            // pace override applied
            ([
                (makeAccount("a"), makeState(session: 40)),
                (makeAccount("b"), makeState(session: 55)),
            ], ["a": projection(1800), "b": projection(2 * 3600)], [:]),
            // margin too close: no badge
            ([
                (makeAccount("a"), makeState(session: 40)),
                (makeAccount("b"), makeState(session: 45)),
            ], [:], [:]),
            // two providers, vetoes, and a beyond-reset runner-up
            ([
                (makeAccount("a"), makeState(session: 40)),
                (makeAccount("b"), makeState(session: 55)),
                (makeAccount("c"), makeState(session: 5, needsReauth: true)),
                (makeAccount("x", provider: .codex), makeState(session: 10)),
                (makeAccount("y", provider: .codex), makeState(session: 90)),
            ], [
                "a": projection(1800),
                "b": Self.resetDate.addingTimeInterval(3600),
                "x": projection(3600),
            ], [:]),
            // lone account: no badge
            ([(makeAccount("a"), makeState(session: 5))], ["a": projection(3600)], [:]),
            // all vetoed: no badge
            ([
                (makeAccount("a"), makeState(session: 10, needsReauth: true)),
                (makeAccount("b"), nil),
            ], [:], [:]),
            // v3 expiring-first: issue #19's worked example
            ([
                (makeAccount("work"), makeState(session: 60, resetIn: 3600)),
                (makeAccount("personal"), makeState(session: 30, resetIn: 4 * 3600)),
            ], [:], ["work": 35, "personal": 25]),
        ]
    }

    func testWinnersMatchTraceDerivationAcrossFixtures() {
        // Property-style check: for a spread of fixture shapes, the badge
        // map `winners` returns is exactly the set of badge-awarding
        // decisions in the traces — the debug view and the badge can never
        // disagree.
        for (pairs, projections, rates) in derivationFixtures() {
            var derived: [String: BestAccount.Badge] = [:]
            for trace in traces(pairs, projections: projections, rates: rates) {
                switch trace.decision {
                case .badged(let award):
                    derived[award.badgedID] = award.badge
                case .expiringFirst(let award):
                    derived[award.badgedID] = award.badge
                case .groupTooSmall, .allVetoed, .marginTooClose:
                    break
                }
            }
            XCTAssertEqual(
                badges(pairs, projections: projections, rates: rates), derived,
                "winners must be exactly the traces' badge-awarding decisions")
        }
    }

    // MARK: Expiring-capacity ranking (v3, issue #19)

    func testIssue19WorkedExampleBadgesWork() {
        // The issue's flagship example: Work at 60% (40 points of headroom)
        // resets in 1 h, Personal at 30% (70 points) resets in 4 h, combined
        // pace 60%/h. Headroom favours Personal, but Work's 40 points vanish
        // at 1:00 while Personal's will be needed anyway — badge Work, and
        // say why in the tooltip payload.
        let result = badges(
            [
                (makeAccount("work"), makeState(session: 60, resetIn: 3600)),
                (makeAccount("personal"), makeState(session: 30, resetIn: 4 * 3600)),
            ],
            rates: ["work": 35, "personal": 25])
        XCTAssertEqual(Set(result.keys), ["work"])
        XCTAssertEqual(
            result["work"]?.expiring,
            BestAccount.ExpiringCapacity(
                points: 40, resetsAt: Self.now.addingTimeInterval(3600)))
        XCTAssertNil(result["work"]?.projectedExhaustion)
    }

    func testAtRiskCapsAtHeadroom() throws {
        // a's reset is an hour out with 60%/h of group demand — more than
        // its 40 points of headroom, so headroom is the binding cap.
        let trace = try XCTUnwrap(
            traces(
                [
                    (makeAccount("a"), makeState(session: 60, resetIn: 3600)),
                    (makeAccount("b"), makeState(session: 10, resetIn: 4 * 3600)),
                ],
                rates: ["a": 35, "b": 25]
            ).first)
        XCTAssertEqual(candidate("a", in: trace)?.atRiskPercent, 40)
        // b is the reserve: the demand its reset leaves uncovered lands on
        // it regardless, so nothing of b's is at risk.
        XCTAssertEqual(candidate("b", in: trace)?.atRiskPercent, 0)
    }

    func testAtRiskCapsAtDemandBeforeReset() throws {
        // Only half an hour to a's reset: 60%/h can consume 30 points at
        // most, well under a's 80 points of headroom — demand is the cap.
        let trace = try XCTUnwrap(
            traces(
                [
                    (makeAccount("a"), makeState(session: 20, resetIn: 1800)),
                    (makeAccount("b"), makeState(session: 10, resetIn: 4 * 3600)),
                ],
                rates: ["a": 60]
            ).first)
        XCTAssertEqual(candidate("a", in: trace)?.atRiskPercent, 30)
        let result = badges(
            [
                (makeAccount("a"), makeState(session: 20, resetIn: 1800)),
                (makeAccount("b"), makeState(session: 10, resetIn: 4 * 3600)),
            ],
            rates: ["a": 60])
        XCTAssertEqual(result["a"]?.expiring?.points, 30)
    }

    func testIdleOrExpiredWindowsHaveNothingAtRisk() throws {
        // a's window has no deadline, b's has already reset: neither has
        // anything expiring, so the live account c carries all the risk.
        let trace = try XCTUnwrap(
            traces(
                [
                    (makeAccount("a"), makeIdleSessionState(session: 10)),
                    (makeAccount("b"), makeState(session: 20, resetIn: -600)),
                    (makeAccount("c"), makeState(session: 60, resetIn: 3600)),
                ],
                rates: ["a": 20, "b": 20, "c": 20]
            ).first)
        XCTAssertEqual(candidate("a", in: trace)?.atRiskPercent, 0)
        XCTAssertEqual(candidate("b", in: trace)?.atRiskPercent, 0)
        XCTAssertEqual(candidate("c", in: trace)?.atRiskPercent, 40)
        guard case .expiringFirst(let award) = trace.decision else {
            return XCTFail("expected expiring-first, got \(trace.decision)")
        }
        XCTAssertEqual(award.badgedID, "c")
    }

    func testAtRiskFloorBoundary() {
        // 10%/h against a 30-minute reset puts exactly 5 points at risk —
        // the inclusive floor — so expiring-first fires for a even though b
        // has far more headroom.
        let atFloor = badges(
            [
                (makeAccount("a"), makeState(session: 20, resetIn: 1800)),
                (makeAccount("b"), makeIdleSessionState(session: 10)),
            ],
            rates: ["a": 10])
        XCTAssertEqual(Set(atFloor.keys), ["a"])
        XCTAssertEqual(atFloor["a"]?.expiring?.points, 5)

        // A minute less runway (≈4.8 points at risk) drops under the floor:
        // v2 wholesale takes over and badges b on headroom instead.
        let underFloor = badges(
            [
                (makeAccount("a"), makeState(session: 20, resetIn: 1740)),
                (makeAccount("b"), makeIdleSessionState(session: 10)),
            ],
            rates: ["a": 10])
        XCTAssertEqual(Set(underFloor.keys), ["b"])
        XCTAssertNil(underFloor["b"]?.expiring)
    }

    func testAtRiskMarginBoundary() throws {
        // At 10%/h of pooled demand, a has 10 points at risk (1 h to reset)
        // and b has 5 (30 min): a gap of exactly 0.05 units — inclusive —
        // moves the badge to a.
        let atMargin = badges(
            [
                (makeAccount("a"), makeState(session: 30, resetIn: 3600)),
                (makeAccount("b"), makeState(session: 40, resetIn: 1800)),
            ],
            rates: ["a": 10])
        XCTAssertEqual(Set(atMargin.keys), ["a"])
        XCTAssertEqual(
            try XCTUnwrap(atMargin["a"]?.expiring?.points), 10, accuracy: 1e-9)

        // Stretching b's reset to 33 min lifts its at-risk to 5.5 points:
        // the gap (0.045 units) is under the margin, so v2 decides — a
        // still wins, but on headroom, with no expiring payload.
        let underMargin = badges(
            [
                (makeAccount("a"), makeState(session: 30, resetIn: 3600)),
                (makeAccount("b"), makeState(session: 40, resetIn: 1980)),
            ],
            rates: ["a": 10])
        XCTAssertEqual(Set(underMargin.keys), ["a"])
        XCTAssertNil(underMargin["a"]?.expiring)
    }

    func testExpiringFirstNeverBadgesVetoedAccounts() throws {
        // b's window expires soonest with plenty of headroom, but its
        // sign-in is dead: it must not be badged, must not rank, and must
        // not count as coverage — a's at-risk is 10 (60 of demand minus
        // c's 30 points of cover), not the 40 it would be if b's 90 points
        // wrongly counted.
        let pairs: [(AccountMeta, AccountDisplayState?)] = [
            (makeAccount("a"), makeState(session: 60, resetIn: 3600)),
            (makeAccount("b"), makeState(session: 10, resetIn: 1800, needsReauth: true)),
            (makeAccount("c"), makeState(session: 70, resetIn: 4 * 3600)),
        ]
        let rates = ["a": 30.0, "b": 20.0, "c": 10.0]
        let trace = try XCTUnwrap(traces(pairs, rates: rates).first)
        XCTAssertNil(candidate("b", in: trace)?.atRiskPercent)
        XCTAssertEqual(
            try XCTUnwrap(candidate("a", in: trace)?.atRiskPercent), 10, accuracy: 1e-9)
        let result = badges(pairs, rates: rates)
        XCTAssertEqual(Set(result.keys), ["a"])
        XCTAssertEqual(
            try XCTUnwrap(result["a"]?.expiring?.points), 10, accuracy: 1e-9)
    }

    func testZeroAggregatePaceMatchesV2AcrossFixtures() {
        // The fallback proof, property-style: zeroed (and clamped-negative)
        // burn rates must reproduce the no-rates verdict bit for bit on
        // every fixture shape — v3 with no demand signal IS v2.
        for (pairs, projections, _) in derivationFixtures() {
            let baseline = badges(pairs, projections: projections)
            let zeroed = Dictionary(
                uniqueKeysWithValues: pairs.enumerated().map { index, pair in
                    (pair.0.id, index.isMultiple(of: 2) ? 0.0 : -3.0)
                })
            XCTAssertEqual(
                badges(pairs, projections: projections, rates: zeroed), baseline,
                "zero aggregate pace must fall back to v2 wholesale")
        }
    }

    func testTraceExpiringFirstPathContents() throws {
        // The debug view's numbers for the worked example: the aggregate,
        // both at-risk values, the award with its gap, and no fallback.
        let trace = try XCTUnwrap(
            traces(
                [
                    (makeAccount("work"), makeState(session: 60, resetIn: 3600)),
                    (makeAccount("personal"), makeState(session: 30, resetIn: 4 * 3600)),
                ],
                rates: ["work": 35, "personal": 25]
            ).first)
        // 60 pp/h at equal weights pools to 0.60 units/h; Work's 40 pp at
        // risk is 0.40 units.
        XCTAssertEqual(trace.aggregatePace, 0.6, accuracy: 1e-12)
        XCTAssertEqual(trace.quotaWeighting, .equalWeightsAssumed)
        XCTAssertEqual(candidate("work", in: trace)?.atRiskPercent, 40)
        XCTAssertEqual(try XCTUnwrap(candidate("work", in: trace)?.atRiskUnits), 0.4, accuracy: 1e-12)
        XCTAssertEqual(candidate("personal", in: trace)?.atRiskPercent, 0)
        XCTAssertNil(trace.capacityFallback)
        guard case .expiringFirst(let award) = trace.decision else {
            return XCTFail("expected expiring-first, got \(trace.decision)")
        }
        XCTAssertEqual(award.badgedID, "work")
        XCTAssertEqual(award.atRiskUnits, 0.4, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(award.atRiskGapUnits), 0.4, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(award.badge.expiring?.points), 40, accuracy: 1e-9)
        XCTAssertEqual(
            award.badge.expiring?.resetsAt, Self.now.addingTimeInterval(3600))
    }

    func testTraceFallbackReasons() throws {
        // No rates at all: no demand signal, v2 decides.
        let noPace = try XCTUnwrap(
            traces([
                (makeAccount("a"), makeState(session: 40)),
                (makeAccount("b"), makeState(session: 55)),
            ]).first)
        XCTAssertEqual(noPace.aggregatePace, 0)
        XCTAssertEqual(noPace.capacityFallback, .noAggregatePace)
        guard case .badged = noPace.decision else {
            return XCTFail("expected a v2 badge, got \(noPace.decision)")
        }

        // Pace flows but both windows are idle: nothing at stake.
        let idle = try XCTUnwrap(
            traces(
                [
                    (makeAccount("a"), makeIdleSessionState(session: 40)),
                    (makeAccount("b"), makeIdleSessionState(session: 55)),
                ],
                rates: ["a": 30, "b": 30]
            ).first)
        XCTAssertEqual(idle.capacityFallback, .belowFloor(topAtRiskUnits: 0))

        // Both accounts have real but near-equal at-risk: the strategies
        // tie, and the trace records who was compared and by how much.
        let close = try XCTUnwrap(
            traces(
                [
                    (makeAccount("a"), makeState(session: 30, resetIn: 2700)),
                    (makeAccount("b"), makeState(session: 40, resetIn: 1980)),
                ],
                rates: ["a": 10, "b": 10]
            ).first)
        guard case .atRiskTooClose(let leaderID, let runnerUpID, let gapUnits) =
            close.capacityFallback
        else {
            return XCTFail("expected atRiskTooClose, got \(String(describing: close.capacityFallback))")
        }
        XCTAssertEqual(leaderID, "a")
        XCTAssertEqual(runnerUpID, "b")
        // 4 pp at equal weights = 0.04 units.
        XCTAssertEqual(gapUnits, 0.04, accuracy: 1e-9)
        guard case .badged(let award) = close.decision else {
            return XCTFail("expected a v2 badge, got \(close.decision)")
        }
        XCTAssertEqual(award.badgedID, "a")
    }

    // MARK: Quota-weighted shared pool

    func testUnitConversionMixedTiers() throws {
        // Hand-computed mixed-tier example. Work is Max 20× at 60% session
        // (40% headroom = 8.0 units), resets in 1 h; Personal is Pro at 30%
        // (70% headroom = 0.7 units), resets in 4 h. Rates: Work 30 pp/h ×20
        // = 6.0 units/h, Personal 10 pp/h ×1 = 0.1 → pool 6.1 units/h.
        // Work: demand 6.1, savable min(8, 6.1) = 6.1, coverage 0.7 →
        // inevitable 5.4 → at-risk 0.7 units = 3.5% of its own window.
        // Personal: savable 0.7, all inevitable → 0. Badge Work.
        let pairs: [(AccountMeta, AccountDisplayState?)] = [
            (makeAccount("work"), makeState(session: 60, resetIn: 3600)),
            (makeAccount("personal"), makeState(session: 30, resetIn: 4 * 3600)),
        ]
        let rates = ["work": 30.0, "personal": 10.0]
        let mults = ["work": 20.0, "personal": 1.0]
        let trace = try XCTUnwrap(traces(pairs, rates: rates, multipliers: mults).first)
        XCTAssertEqual(trace.quotaWeighting, .quotaWeighted)
        XCTAssertEqual(trace.aggregatePace, 6.1, accuracy: 1e-12)
        XCTAssertEqual(
            try XCTUnwrap(candidate("work", in: trace)?.atRiskUnits), 0.7, accuracy: 1e-9)
        XCTAssertEqual(
            try XCTUnwrap(candidate("work", in: trace)?.atRiskPercent), 3.5, accuracy: 1e-9)
        XCTAssertEqual(
            try XCTUnwrap(candidate("personal", in: trace)?.atRiskUnits), 0, accuracy: 1e-9)
        let result = badges(pairs, rates: rates, multipliers: mults)
        XCTAssertEqual(Set(result.keys), ["work"])
        XCTAssertEqual(try XCTUnwrap(result["work"]?.expiring?.points), 3.5, accuracy: 1e-9)
    }

    func testPoolStabilityAcrossAccountSizes() throws {
        // The same absolute workload must pool identically whether it shows
        // up as a fast percent-burn on a small account or a slow one on a
        // big account: 60 pp/h on Pro == 3 pp/h on Max 20× == 0.6 units/h.
        let pairs: [(AccountMeta, AccountDisplayState?)] = [
            (makeAccount("big"), makeState(session: 60, resetIn: 3600)),
            (makeAccount("small"), makeState(session: 30, resetIn: 4 * 3600)),
        ]
        let mults = ["big": 20.0, "small": 1.0]
        let onSmall = try XCTUnwrap(
            traces(pairs, rates: ["small": 60], multipliers: mults).first)
        let onBig = try XCTUnwrap(
            traces(pairs, rates: ["big": 3], multipliers: mults).first)
        XCTAssertEqual(onSmall.aggregatePace, 0.6, accuracy: 1e-12)
        XCTAssertEqual(onBig.aggregatePace, onSmall.aggregatePace)
    }

    func testUnknownMultiplierFallsBackToEqualWeights() {
        // Honesty rule, property-style: setting every multiplier except the
        // first account's must reproduce the all-unknown verdict bit for
        // bit — silently mixing known and unknown weights is worse than
        // assuming equality.
        for (pairs, projections, rates) in derivationFixtures() {
            let baseline = badges(pairs, projections: projections, rates: rates)
            var partial: [String: Double] = [:]
            for (account, _) in pairs.dropFirst() { partial[account.id] = 20 }
            XCTAssertEqual(
                badges(pairs, projections: projections, rates: rates, multipliers: partial),
                baseline,
                "one unknown plan must force the whole group onto equal weights")
        }
    }

    func testUnknownMultiplierIsAnnotatedInTrace() throws {
        // The debug view must be able to say "plans not set — assuming
        // equal quotas" whenever the honesty rule downgraded the pool.
        let pairs: [(AccountMeta, AccountDisplayState?)] = [
            (makeAccount("work"), makeState(session: 60, resetIn: 3600)),
            (makeAccount("personal"), makeState(session: 30, resetIn: 4 * 3600)),
        ]
        let rates = ["work": 35.0, "personal": 25.0]
        let partial = try XCTUnwrap(
            traces(pairs, rates: rates, multipliers: ["work": 20]).first)
        XCTAssertEqual(partial.quotaWeighting, .equalWeightsAssumed)
        // The supplied multiplier is still visible per account…
        XCTAssertEqual(
            candidate("work", in: partial)?.quota,
            BestAccount.Quota(multiplier: 20, source: .manual))
        XCTAssertNil(candidate("personal", in: partial)?.quota)
        // …but the math ran unweighted: identical to no multipliers at all.
        let unweighted = try XCTUnwrap(traces(pairs, rates: rates).first)
        XCTAssertEqual(partial.aggregatePace, unweighted.aggregatePace)
        XCTAssertEqual(partial.decision, unweighted.decision)
    }

    func testAllKnownVersusAllUnknownBoundary() throws {
        // All-known ×1 runs the weighted pool (same numbers as equal
        // weights, different annotation); all-unknown assumes equality.
        let pairs: [(AccountMeta, AccountDisplayState?)] = [
            (makeAccount("work"), makeState(session: 60, resetIn: 3600)),
            (makeAccount("personal"), makeState(session: 30, resetIn: 4 * 3600)),
        ]
        let rates = ["work": 35.0, "personal": 25.0]
        let known = try XCTUnwrap(
            traces(pairs, rates: rates, multipliers: ["work": 1, "personal": 1]).first)
        let unknown = try XCTUnwrap(traces(pairs, rates: rates).first)
        XCTAssertEqual(known.quotaWeighting, .quotaWeighted)
        XCTAssertEqual(unknown.quotaWeighting, .equalWeightsAssumed)
        XCTAssertEqual(known.decision, unknown.decision)
    }

    func testAtRiskFloorBoundaryInUnits() {
        // On a Max 20× account, a quarter percent of window is 0.05 units —
        // exactly the floor, so expiring-first fires even though the
        // percent numbers look negligible; a whisker less falls back to v2
        // (which badges idle b on headroom, 10% vs 20% session... margin 10).
        let mults = ["a": 20.0, "b": 20.0]
        let atFloor = badges(
            [
                // 1 pp/h × 20 = 0.2 units/h; 15 min to reset → 0.05 units.
                (makeAccount("a"), makeState(session: 20, resetIn: 900)),
                (makeAccount("b"), makeIdleSessionState(session: 10)),
            ],
            rates: ["a": 1], multipliers: mults)
        XCTAssertEqual(Set(atFloor.keys), ["a"])
        XCTAssertNotNil(atFloor["a"]?.expiring)

        let underFloor = badges(
            [
                (makeAccount("a"), makeState(session: 20, resetIn: 840)),
                (makeAccount("b"), makeIdleSessionState(session: 10)),
            ],
            rates: ["a": 1], multipliers: mults)
        XCTAssertEqual(Set(underFloor.keys), ["b"])
        XCTAssertNil(underFloor["b"]?.expiring)
    }

    func testAtRiskMarginBoundaryAcrossTiers() {
        // Mixed tiers, demand from a third idle account: a (Pro) has
        // 0.10 units at risk (30 min × 0.2 units/h), b (Max 5×) has 0.05 —
        // a gap of exactly 0.05 units moves the badge to a...
        let mults = ["a": 1.0, "b": 5.0, "c": 1.0]
        let atMargin = badges(
            [
                (makeAccount("a"), makeState(session: 50, resetIn: 1800)),
                // 0.05 units before b's reset is 1% of its ×5 window.
                (makeAccount("b"), makeState(session: 60, resetIn: 900)),
                (makeAccount("c"), makeIdleSessionState(session: 0)),
            ],
            rates: ["c": 20], multipliers: mults)
        XCTAssertEqual(Set(atMargin.keys), ["a"])
        XCTAssertEqual(atMargin["a"]?.expiring?.points, 10)

        // …while stretching b's reset to 18 min (0.06 units) shrinks the
        // gap to 0.04: under the margin, v2 decides (idle c wins on
        // headroom), with the tie recorded in the trace.
        let underMargin = badges(
            [
                (makeAccount("a"), makeState(session: 50, resetIn: 1800)),
                (makeAccount("b"), makeState(session: 60, resetIn: 1080)),
                (makeAccount("c"), makeIdleSessionState(session: 0)),
            ],
            rates: ["c": 20], multipliers: mults)
        XCTAssertEqual(Set(underMargin.keys), ["c"])
        XCTAssertNil(underMargin["c"]?.expiring)
    }

    // MARK: Detected plan tiers

    func testDetectedMultipliersWeightThePool() throws {
        // The mixed-tier example again, but every multiplier came from the
        // profile endpoint instead of the Plan menu: detection counts as
        // "known", so the pool is fully weighted and the verdict matches
        // the manual-picker run exactly.
        let pairs: [(AccountMeta, AccountDisplayState?)] = [
            (makeAccount("work"), makeState(session: 60, resetIn: 3600)),
            (makeAccount("personal"), makeState(session: 30, resetIn: 4 * 3600)),
        ]
        let rates = ["work": 30.0, "personal": 10.0]
        let tiers = ["work": 20.0, "personal": 1.0]
        let trace = try XCTUnwrap(traces(pairs, rates: rates, detected: tiers).first)
        XCTAssertEqual(trace.quotaWeighting, .quotaWeighted)
        XCTAssertEqual(
            candidate("work", in: trace)?.quota,
            BestAccount.Quota(multiplier: 20, source: .detected))
        XCTAssertEqual(
            badges(pairs, rates: rates, detected: tiers),
            badges(pairs, rates: rates, multipliers: tiers),
            "detected and manual multipliers must weight the pool identically")
    }

    // MARK: Weekly-aware expiring capacity (v4, issue #21)

    /// The issue's live pair of Max 5× seats: session windows resetting ten
    /// minutes apart (nothing to exploit there) while the weekly windows reset
    /// 2.6 days apart. Weekly rates of 0.6 and 0.4 pp/h pool to 0.05 units/h,
    /// so Work's 69 pp of weekly headroom (3.45 units) is entirely savable and
    /// entirely at risk, against 0.95 units for Alt.
    private func liveScenario(
        workSession: Double, altSession: Double
    ) -> [(AccountMeta, AccountDisplayState?)] {
        [
            (
                makeAccount("work"),
                makeState(
                    session: workSession, sessionResetIn: 3 * 3600 + 54 * 60,
                    weekly: [Weekly(percent: 31, resetIn: 3 * 86400)])
            ),
            (
                makeAccount("alt"),
                makeState(
                    session: altSession, sessionResetIn: 3 * 3600 + 44 * 60,
                    weekly: [Weekly(percent: 15, resetIn: 5 * 86400 + 15 * 3600)])
            ),
        ]
    }

    private var liveScenarioRates: [String: [String: Double]] {
        [
            "work": rates(byWindow: ["Weekly": 0.6]),
            "alt": rates(byWindow: ["Weekly": 0.4]),
        ]
    }

    private var liveScenarioMultipliers: [String: Double] {
        ["work": 5, "alt": 5]
    }

    func testIssue21LiveScenarioBadgesWorkOnWeeklyLeg() throws {
        // With no session burn-rate signal the session leg stands down, and
        // the weekly leg badges the account whose week expires in 3 days.
        let pairs = liveScenario(workSession: 5, altSession: 23)
        let result = badges(
            pairs, weeklyRates: liveScenarioRates, multipliers: liveScenarioMultipliers)
        XCTAssertEqual(Set(result.keys), ["work"])
        let expiring = try XCTUnwrap(result["work"]?.expiring)
        XCTAssertEqual(expiring.points, 69, accuracy: 1e-9)
        XCTAssertEqual(expiring.resetsAt, Self.now.addingTimeInterval(3 * 86400))
        // The tooltip must name the window: "69% of weekly", not "69%".
        XCTAssertEqual(expiring.scopeName, "Weekly")
        XCTAssertNil(result["work"]?.projectedExhaustion)
    }

    func testIssue21InvertedSessionsStillBadgeWork() {
        // The case the session-only logic got wrong: flip the session
        // percents and v2 headroom favours Alt (5% vs 23%, well over the
        // 10-point margin) — but Work still holds the capacity that expires
        // first, so the weekly leg must keep the badge on Work.
        let pairs = liveScenario(workSession: 23, altSession: 5)
        XCTAssertEqual(
            winners(pairs), ["alt"],
            "without weekly rates the old session-headroom ranking badges Alt")
        XCTAssertEqual(
            winners(
                pairs, weeklyRates: liveScenarioRates,
                multipliers: liveScenarioMultipliers),
            ["work"])
    }

    func testWeeklyAtRiskCapsAtHeadroom() throws {
        // a's week resets in 10 h with 0.06 units/h of pooled weekly demand:
        // 0.6 units of demand against 0.4 units of headroom, so headroom is
        // the binding cap. b is the reserve — the demand its own reset leaves
        // uncovered lands on it regardless, so nothing of b's is at risk.
        let trace = try XCTUnwrap(
            traces(
                [
                    (
                        makeAccount("a"),
                        makeState(session: 40, weekly: [Weekly(percent: 60, resetIn: 10 * 3600)])
                    ),
                    (
                        makeAccount("b"),
                        makeState(session: 10, weekly: [Weekly(percent: 20, resetIn: 100 * 3600)])
                    ),
                ],
                weeklyRates: [
                    "a": rates(byWindow: ["Weekly": 4]),
                    "b": rates(byWindow: ["Weekly": 2]),
                ]
            ).first)
        XCTAssertEqual(trace.weeklyAggregatePace, 0.06, accuracy: 1e-12)
        XCTAssertEqual(candidate("a", in: trace)?.weeklyAtRiskPercent, 40)
        XCTAssertEqual(candidate("a", in: trace)?.weeklyAtRiskUnits, 0.4)
        XCTAssertEqual(candidate("b", in: trace)?.weeklyAtRiskUnits, 0)
    }

    func testWeeklyAtRiskCapsAtDemandBeforeReset() throws {
        // Ten hours to a's weekly reset at 0.03 units/h consumes 0.3 units at
        // most, well under a's 0.8 units of weekly headroom — demand is the
        // cap, and the tooltip speaks that number.
        let pairs: [(AccountMeta, AccountDisplayState?)] = [
            (
                makeAccount("a"),
                makeState(session: 40, weekly: [Weekly(percent: 20, resetIn: 10 * 3600)])
            ),
            (
                makeAccount("b"),
                makeState(session: 10, weekly: [Weekly(percent: 20, resetIn: nil)])
            ),
        ]
        let weekly = ["a": rates(byWindow: ["Weekly": 3])]
        let trace = try XCTUnwrap(traces(pairs, weeklyRates: weekly).first)
        XCTAssertEqual(candidate("a", in: trace)?.weeklyAtRiskPercent, 30)
        let result = badges(pairs, weeklyRates: weekly)
        XCTAssertEqual(Set(result.keys), ["a"])
        XCTAssertEqual(result["a"]?.expiring?.points, 30)
    }

    func testIdleOrExpiredWeeklyWindowsHaveNothingAtRisk() throws {
        // a's week has no deadline, b's has already reset: neither has
        // anything expiring, so the live account c carries all the risk.
        let trace = try XCTUnwrap(
            traces(
                [
                    (
                        makeAccount("a"),
                        makeState(session: 10, weekly: [Weekly(percent: 40, resetIn: nil)])
                    ),
                    (
                        makeAccount("b"),
                        makeState(session: 20, weekly: [Weekly(percent: 30, resetIn: -600)])
                    ),
                    (
                        makeAccount("c"),
                        makeState(session: 30, weekly: [Weekly(percent: 50, resetIn: 50 * 3600)])
                    ),
                ],
                weeklyRates: [
                    "a": rates(byWindow: ["Weekly": 1]),
                    "b": rates(byWindow: ["Weekly": 0.5]),
                    "c": rates(byWindow: ["Weekly": 0.5]),
                ]
            ).first)
        XCTAssertEqual(candidate("a", in: trace)?.weeklyAtRiskUnits, 0)
        XCTAssertEqual(candidate("b", in: trace)?.weeklyAtRiskUnits, 0)
        XCTAssertEqual(candidate("c", in: trace)?.weeklyAtRiskPercent, 50)
        let award = try expiringAward(of: trace)
        XCTAssertEqual(award.leg, .weekly)
        XCTAssertEqual(award.badgedID, "c")
    }

    func testZeroWeeklyPaceStandsDown() throws {
        // Weekly rates that are absent, zero or a negative regression slope
        // all mean "no weekly demand": the leg stands down and v2 badges the
        // session-headroom winner.
        let pairs = liveScenario(workSession: 23, altSession: 5)
        for weekly in [
            [:],
            ["work": rates(byWindow: ["Weekly": 0]), "alt": rates(byWindow: ["Weekly": 0])],
            ["work": rates(byWindow: ["Weekly": -3]), "alt": rates(byWindow: ["Weekly": -1])],
        ] as [[String: [String: Double]]] {
            let trace = try XCTUnwrap(
                traces(pairs, weeklyRates: weekly, multipliers: liveScenarioMultipliers).first)
            XCTAssertEqual(trace.weeklyAggregatePace, 0)
            XCTAssertEqual(trace.weeklyCapacityFallback, .noAggregatePace)
            guard case .badged(let award) = trace.decision else {
                return XCTFail("expected a v2 badge, got \(trace.decision)")
            }
            XCTAssertEqual(award.badgedID, "alt")
        }
    }

    func testWeeklyAtRiskFloorBoundary() {
        // 0.5 pp/h of weekly demand against a 100-hour reset puts 0.5 units of
        // demand in play; a can absorb 0.2 units of it (80% spent) and b's
        // untouched week covers the rest, so exactly 0.20 units are at risk —
        // the inclusive floor — and the weekly leg fires for a even though b
        // has far more session headroom.
        let atFloor = badges(
            [
                (
                    makeAccount("a"),
                    makeState(session: 40, weekly: [Weekly(percent: 80, resetIn: 100 * 3600)])
                ),
                (
                    makeAccount("b"),
                    makeState(session: 10, weekly: [Weekly(percent: 0, resetIn: nil)])
                ),
            ],
            weeklyRates: ["a": rates(byWindow: ["Weekly": 0.5])])
        XCTAssertEqual(Set(atFloor.keys), ["a"])
        XCTAssertEqual(atFloor["a"]?.expiring?.points, 20)

        // Half a point more of a's week spent (0.195 units at risk) drops
        // under the floor: v2 takes over and badges b on session headroom.
        let underFloor = badges(
            [
                (
                    makeAccount("a"),
                    makeState(session: 40, weekly: [Weekly(percent: 80.5, resetIn: 100 * 3600)])
                ),
                (
                    makeAccount("b"),
                    makeState(session: 10, weekly: [Weekly(percent: 0, resetIn: nil)])
                ),
            ],
            weeklyRates: ["a": rates(byWindow: ["Weekly": 0.5])])
        XCTAssertEqual(Set(underFloor.keys), ["b"])
        XCTAssertNil(underFloor["b"]?.expiring)
    }

    func testWeeklyAtRiskMarginBoundary() {
        // Two Max 5× accounts, both 90% through the week, 0.005 units/h of
        // pooled weekly demand: a's reset is 50 h out (0.25 units at risk),
        // b's 30 h out (0.15) — a gap of exactly 0.10 units, the inclusive
        // margin, so the weekly leg fires for a.
        let mults = ["a": 5.0, "b": 5.0]
        let weekly = ["a": rates(byWindow: ["Weekly": 0.1])]
        let atMargin = badges(
            [
                (
                    makeAccount("a"),
                    makeState(session: 40, weekly: [Weekly(percent: 90, resetIn: 50 * 3600)])
                ),
                (
                    makeAccount("b"),
                    makeState(session: 10, weekly: [Weekly(percent: 90, resetIn: 30 * 3600)])
                ),
            ],
            weeklyRates: weekly, multipliers: mults)
        XCTAssertEqual(Set(atMargin.keys), ["a"])
        XCTAssertEqual(atMargin["a"]?.expiring?.points, 5)

        // Stretching b's reset to 32 h lifts its at-risk to 0.16 units: the
        // gap (0.09) is under the margin, so v2 decides and badges b.
        let underMargin = badges(
            [
                (
                    makeAccount("a"),
                    makeState(session: 40, weekly: [Weekly(percent: 90, resetIn: 50 * 3600)])
                ),
                (
                    makeAccount("b"),
                    makeState(session: 10, weekly: [Weekly(percent: 90, resetIn: 32 * 3600)])
                ),
            ],
            weeklyRates: weekly, multipliers: mults)
        XCTAssertEqual(Set(underMargin.keys), ["b"])
        XCTAssertNil(underMargin["b"]?.expiring)
    }

    func testSessionLegDecidesBeforeWeeklyLegEvenWhenWeeklyIsLarger() throws {
        // Strict priority, the whole point of v4: issue #19's worked example
        // puts 0.40 units at risk on work's session window, while personal
        // has twice that — 0.80 units — at risk on its weekly window. The
        // shorter clock wins outright; the numbers are never compared, which
        // they couldn't honestly be (a session percent and a weekly percent
        // measure differently sized windows).
        let pairs: [(AccountMeta, AccountDisplayState?)] = [
            (
                makeAccount("work"),
                makeState(
                    session: 60, sessionResetIn: 3600,
                    weekly: [Weekly(percent: 10, resetIn: 200 * 3600)])
            ),
            (
                makeAccount("personal"),
                makeState(
                    session: 30, sessionResetIn: 4 * 3600,
                    weekly: [Weekly(percent: 20, resetIn: 20 * 3600)])
            ),
        ]
        let trace = try XCTUnwrap(
            traces(
                pairs, rates: ["work": 35, "personal": 25],
                weeklyRates: ["personal": rates(byWindow: ["Weekly": 4.25])]
            ).first)
        // Both legs are traced; only the session one decided.
        XCTAssertEqual(candidate("work", in: trace)?.atRiskUnits, 0.4)
        XCTAssertEqual(
            try XCTUnwrap(candidate("personal", in: trace)?.weeklyAtRiskUnits), 0.8,
            accuracy: 1e-9)
        XCTAssertNil(trace.capacityFallback)
        XCTAssertNil(
            trace.weeklyCapacityFallback,
            "the weekly leg must not even be consulted once the session leg decides")
        let award = try expiringAward(of: trace)
        XCTAssertEqual(award.leg, .session)
        XCTAssertEqual(award.badgedID, "work")
        XCTAssertEqual(award.atRiskUnits, 0.4)
        // Session tooltips are unchanged — no window name.
        XCTAssertNil(award.badge.expiring?.scopeName)
        XCTAssertEqual(Set(
            badges(
                pairs, rates: ["work": 35, "personal": 25],
                weeklyRates: ["personal": rates(byWindow: ["Weekly": 4.25])]
            ).keys), ["work"])
    }

    func testWeeklyLegPicksTheWindowWithMostAtRisk() throws {
        // a's overall week has 100 hours of runway (nothing at risk once b's
        // week is counted as cover), but its Fable window resets in 40 hours
        // with 0.4 units at risk. The account is ranked — and the tooltip
        // named — on the window with the most to lose.
        let pairs: [(AccountMeta, AccountDisplayState?)] = [
            (
                makeAccount("a"),
                makeState(
                    session: 40,
                    weekly: [
                        Weekly(percent: 50, resetIn: 100 * 3600),
                        Weekly(name: "Fable", percent: 30, resetIn: 40 * 3600),
                    ])
            ),
            (
                makeAccount("b"),
                makeState(
                    session: 10,
                    weekly: [
                        Weekly(percent: 40, resetIn: nil),
                        Weekly(name: "Fable", percent: 50, resetIn: nil),
                    ])
            ),
        ]
        let weekly = [
            "a": rates(byWindow: ["Weekly": 0.3, "Fable": 0.8]),
            "b": rates(byWindow: ["Weekly": 0.2]),
        ]
        let trace = try XCTUnwrap(traces(pairs, weeklyRates: weekly).first)
        // The pool takes each member's fastest weekly window: 0.8 + 0.2.
        XCTAssertEqual(trace.weeklyAggregatePace, 0.01, accuracy: 1e-12)
        XCTAssertEqual(candidate("a", in: trace)?.weeklyBurnRate, 0.8)
        XCTAssertEqual(candidate("a", in: trace)?.weeklyName, "Fable")
        XCTAssertEqual(candidate("a", in: trace)?.weeklyPercent, 30)
        XCTAssertEqual(
            candidate("a", in: trace)?.weeklyResetsAt, Self.now.addingTimeInterval(40 * 3600))
        XCTAssertEqual(
            try XCTUnwrap(candidate("a", in: trace)?.weeklyAtRiskUnits), 0.4, accuracy: 1e-9)
        let result = badges(pairs, weeklyRates: weekly)
        XCTAssertEqual(Set(result.keys), ["a"])
        XCTAssertEqual(result["a"]?.expiring?.scopeName, "Fable")
        XCTAssertEqual(try XCTUnwrap(result["a"]?.expiring?.points), 40, accuracy: 1e-9)
    }

    // MARK: Which windows the weekly leg speaks for

    /// A Codex account's per-model extra limits arrive as "<name> 5h" and
    /// "<name> 7d" (`CodexProvider.buildLimits`). The five-hour one is neither
    /// the session slot nor week-scoped, so it must stay out of this leg
    /// entirely: a %/hour pace on a five-hour window is ~34× the same usage
    /// measured over a week, so letting it in swamps the pooled weekly demand.
    func testShortExtraWindowStaysOutOfTheWeeklyLeg() throws {
        let pairs: [(AccountMeta, AccountDisplayState?)] = [
            (
                makeAccount("a"),
                makeState(
                    session: 40, sessionWindowSeconds: 5 * 3600,
                    weekly: [
                        Weekly(percent: 50, resetIn: 72 * 3600, windowSeconds: 7 * 86400),
                        Weekly(
                            name: "Gpt 5 Pro 5h", percent: 30, resetIn: 4 * 3600,
                            windowSeconds: 5 * 3600),
                    ])
            ),
            (
                makeAccount("b"),
                makeState(
                    session: 10, sessionWindowSeconds: 5 * 3600,
                    weekly: [Weekly(percent: 20, resetIn: 200 * 3600, windowSeconds: 7 * 86400)])
            ),
        ]
        // Only the seven-day window is week-scoped; the five-hour extra window
        // and the session slot are both excluded.
        let limits = try XCTUnwrap(pairs.first?.1?.limits)
        XCTAssertEqual(BestAccount.weeklyWindows(in: limits).map(\.name), ["Weekly"])
        XCTAssertEqual(BestAccount.sessionLimit(in: limits)?.id, "session|")

        let weekly = [
            "a": rates(byWindow: ["Weekly": 0.5, "Gpt 5 Pro 5h": 12]),
            "b": rates(byWindow: ["Weekly": 0.5]),
        ]
        let trace = try XCTUnwrap(traces(pairs, weeklyRates: weekly).first)
        // The pool is 0.5 + 0.5 %/h, not 12 + 0.5: the fast short window is
        // not part of the week's demand.
        XCTAssertEqual(trace.weeklyAggregatePace, 0.01, accuracy: 1e-12)
        XCTAssertEqual(candidate("a", in: trace)?.weeklyBurnRate, 0.5)
        XCTAssertEqual(candidate("a", in: trace)?.weeklyName, "Weekly")
        XCTAssertEqual(
            candidate("a", in: trace)?.weeklyResetsAt, Self.now.addingTimeInterval(72 * 3600))
    }

    /// The exhaustion veto exists because a spent *week* makes session
    /// headroom a mirage. A spent five-hour sub-limit doesn't, so it must not
    /// veto the account — while a spent seven-day window still does.
    func testExhaustedShortExtraWindowDoesNotVeto() throws {
        func state(shortPercent: Double, weeklyPercent: Double) -> AccountDisplayState {
            makeState(
                session: 20, sessionWindowSeconds: 5 * 3600,
                weekly: [
                    Weekly(percent: weeklyPercent, resetIn: 72 * 3600, windowSeconds: 7 * 86400),
                    Weekly(
                        name: "Gpt 5 Pro 5h", percent: shortPercent, resetIn: 4 * 3600,
                        windowSeconds: 5 * 3600),
                ])
        }
        let pairs: [(AccountMeta, AccountDisplayState?)] = [
            (makeAccount("short-spent"), state(shortPercent: 99.9, weeklyPercent: 40)),
            (makeAccount("week-spent"), state(shortPercent: 10, weeklyPercent: 99.9)),
        ]
        let trace = try XCTUnwrap(traces(pairs).first)
        XCTAssertEqual(candidate("short-spent", in: trace)?.eligibility, .eligible)
        XCTAssertEqual(
            candidate("week-spent", in: trace)?.eligibility,
            .vetoedWeeklyExhausted(limitName: "Weekly", percent: 99.9))
    }

    /// The stated duration outranks the name and the list order, so a short
    /// window that neither is called "Session" nor comes first is still found.
    func testSessionLimitPrefersAStatedDurationOverTheName() {
        let stated = [
            LimitStatus(
                id: "weekly_all|", name: "Weekly", percent: 10, resetsAt: nil,
                isActive: false, sortOrder: 0, windowSeconds: 7 * 86400),
            LimitStatus(
                id: "primary|", name: "Primary", percent: 20, resetsAt: nil,
                isActive: false, sortOrder: 1, windowSeconds: 5 * 3600),
        ]
        XCTAssertEqual(BestAccount.sessionLimit(in: stated)?.id, "primary|")
        XCTAssertEqual(BestAccount.weeklyWindows(in: stated).map(\.name), ["Weekly"])

        // With no sub-day window stated anywhere, the name match still rules.
        let unstated = [
            makeLimit(id: "weekly_all|", name: "Weekly", percent: 10, sortOrder: 0),
            makeLimit(id: "session|", name: "Session", percent: 20, sortOrder: 1),
        ]
        XCTAssertEqual(BestAccount.sessionLimit(in: unstated)?.id, "session|")
    }

    /// An account's weekly capacity is bounded by its tightest window, because
    /// model-scoped usage also lands in the overall weekly window. A spare
    /// Fable window behind a nearly spent overall week is therefore not
    /// savable capacity — scoring it as such would badge the account on
    /// capacity the weekly cap forbids it to spend.
    func testWeeklyAtRiskIsBoundedByTheTightestWindow() throws {
        let pairs: [(AccountMeta, AccountDisplayState?)] = [
            (
                makeAccount("a"),
                makeState(
                    session: 40,
                    weekly: [
                        Weekly(percent: 90, resetIn: 72 * 3600),
                        Weekly(name: "Fable", percent: 20, resetIn: 72 * 3600),
                    ])
            ),
            (
                makeAccount("b"),
                makeState(session: 10, weekly: [Weekly(percent: 10, resetIn: 200 * 3600)])
            ),
        ]
        let weekly = [
            "a": rates(byWindow: ["Weekly": 0.5]),
            "b": rates(byWindow: ["Weekly": 0.5]),
        ]
        let trace = try XCTUnwrap(traces(pairs, weeklyRates: weekly).first)
        // Bounded by the overall weekly window's 10 points, not Fable's 80.
        XCTAssertEqual(
            try XCTUnwrap(candidate("a", in: trace)?.weeklyAtRiskUnits), 0.1, accuracy: 1e-9)
        XCTAssertEqual(
            try XCTUnwrap(candidate("a", in: trace)?.weeklyAtRiskPercent), 10, accuracy: 1e-9)
        XCTAssertEqual(candidate("a", in: trace)?.weeklyName, "Weekly")

        // 0.1 units is under `weeklyAtRiskFloor`, so the leg stands down and
        // the v2 headroom ranking decides — where b's session headroom wins.
        // Scoring Fable's 0.72 units instead would have cleared the floor and
        // badged a with "≈72% of Fable expires at reset".
        guard case .belowFloor(let top) = try XCTUnwrap(trace.weeklyCapacityFallback) else {
            return XCTFail("expected the weekly leg to stand down below its floor")
        }
        XCTAssertEqual(top, 0.1, accuracy: 1e-9)
        XCTAssertEqual(winners(pairs, weeklyRates: weekly), ["b"])
    }

    func testWeeklyLegNeverBadgesVetoedAccounts() throws {
        // b's week expires soonest with almost all of it unspent, but its
        // sign-in is dead: it must not be badged, must not rank, and must not
        // count as coverage — a's at-risk is 0.30 units (0.36 of demand minus
        // c's 0.30 of cover), not the 0.36 it would be if b's 0.95 wrongly
        // counted. b's burn rate still feeds the pool: that demand has to
        // land on a usable account somewhere.
        let pairs: [(AccountMeta, AccountDisplayState?)] = [
            (
                makeAccount("a"),
                makeState(session: 60, weekly: [Weekly(percent: 50, resetIn: 60 * 3600)])
            ),
            (
                makeAccount("b"),
                makeState(
                    session: 10, weekly: [Weekly(percent: 5, resetIn: 10 * 3600)],
                    needsReauth: true)
            ),
            (
                makeAccount("c"),
                makeState(session: 70, weekly: [Weekly(percent: 70, resetIn: nil)])
            ),
        ]
        let weekly = [
            "a": rates(byWindow: ["Weekly": 0.2]),
            "b": rates(byWindow: ["Weekly": 0.3]),
            "c": rates(byWindow: ["Weekly": 0.1]),
        ]
        let trace = try XCTUnwrap(traces(pairs, weeklyRates: weekly).first)
        XCTAssertEqual(trace.weeklyAggregatePace, 0.006, accuracy: 1e-12)
        XCTAssertNil(candidate("b", in: trace)?.weeklyAtRiskUnits)
        XCTAssertNil(candidate("b", in: trace)?.weeklyName)
        XCTAssertEqual(
            try XCTUnwrap(candidate("a", in: trace)?.weeklyAtRiskUnits), 0.3, accuracy: 1e-9)
        XCTAssertEqual(Set(badges(pairs, weeklyRates: weekly).keys), ["a"])
    }

    func testWeeklyLegRespectsTheWeeklyExhaustionVeto() {
        // a's overall week is barely touched and resets in 40 hours, but its
        // Fable window is spent: the veto takes it out of the running before
        // either leg looks at it, so the badge falls to b as the only
        // eligible account (a sole candidate has nothing at risk by
        // definition — all the demand lands on it regardless).
        let result = badges(
            [
                (
                    makeAccount("a"),
                    makeState(
                        session: 20,
                        weekly: [
                            Weekly(percent: 20, resetIn: 40 * 3600),
                            Weekly(name: "Fable", percent: 99.8, resetIn: 40 * 3600),
                        ])
                ),
                (
                    makeAccount("b"),
                    makeState(session: 70, weekly: [Weekly(percent: 60, resetIn: 100 * 3600)])
                ),
            ],
            weeklyRates: [
                "a": rates(byWindow: ["Weekly": 1]),
                "b": rates(byWindow: ["Weekly": 1]),
            ])
        XCTAssertEqual(Set(result.keys), ["b"])
        XCTAssertNil(result["b"]?.expiring)
    }

    func testWeeklyLegDoesNotCrossProviders() throws {
        // Identical weekly shapes on both providers, weekly history only for
        // the Claude pair: the Codex pair must see no weekly demand at all
        // and fall back to v2, and the Claude pool must not include it.
        let pairs: [(AccountMeta, AccountDisplayState?)] = [
            (
                makeAccount("claude-a"),
                makeState(session: 40, weekly: [Weekly(percent: 80, resetIn: 100 * 3600)])
            ),
            (
                makeAccount("claude-b"),
                makeState(session: 10, weekly: [Weekly(percent: 0, resetIn: nil)])
            ),
            (
                makeAccount("codex-a", provider: .codex),
                makeState(session: 40, weekly: [Weekly(percent: 80, resetIn: 100 * 3600)])
            ),
            (
                makeAccount("codex-b", provider: .codex),
                makeState(session: 10, weekly: [Weekly(percent: 0, resetIn: nil)])
            ),
        ]
        let weekly = ["claude-a": rates(byWindow: ["Weekly": 0.5])]
        XCTAssertEqual(
            winners(pairs, weeklyRates: weekly), ["claude-a", "codex-b"],
            "Claude decides on its weekly leg, Codex on session headroom")
        let groups = traces(pairs, weeklyRates: weekly)
        XCTAssertEqual(try XCTUnwrap(groups.first).weeklyAggregatePace, 0.005, accuracy: 1e-12)
        let codex = try XCTUnwrap(groups.first { $0.provider == .codex })
        XCTAssertEqual(codex.weeklyAggregatePace, 0)
        XCTAssertEqual(codex.weeklyCapacityFallback, .noAggregatePace)
    }

    func testWeeklyLegRespectsGroupSize() throws {
        // A lone account's expiring week is not advice: there is no second
        // account of that provider to move work to.
        let trace = try XCTUnwrap(
            traces(
                [liveScenario(workSession: 5, altSession: 23)[0]],
                weeklyRates: liveScenarioRates, multipliers: liveScenarioMultipliers
            ).first)
        XCTAssertEqual(trace.decision, .groupTooSmall)
        XCTAssertNil(trace.weeklyCapacityFallback)
        XCTAssertTrue(
            winners(
                [liveScenario(workSession: 5, altSession: 23)[0]],
                weeklyRates: liveScenarioRates, multipliers: liveScenarioMultipliers
            ).isEmpty)
    }

    func testNoWeeklyRatesLeavesTheOlderLegsInCharge() {
        // Regression proof, part one: with no weekly history supplied — the
        // state of every v3-era fixture, and of mock mode — the weekly leg
        // contributes nothing. No verdict comes from it, and it always
        // reports the same stand-down reason.
        for (pairs, projections, rates) in derivationFixtures() {
            for trace in traces(pairs, projections: projections, rates: rates) {
                XCTAssertEqual(trace.weeklyAggregatePace, 0)
                if case .expiringFirst(let award) = trace.decision {
                    XCTAssertEqual(award.leg, .session)
                }
                switch trace.decision {
                case .groupTooSmall, .allVetoed:
                    XCTAssertNil(trace.weeklyCapacityFallback)
                case .expiringFirst:
                    XCTAssertNil(trace.weeklyCapacityFallback)
                case .badged, .marginTooClose:
                    XCTAssertEqual(trace.weeklyCapacityFallback, .noAggregatePace)
                }
            }
        }
    }

    func testZeroWeeklyPaceMatchesNoWeeklyDataAcrossFixtures() {
        // Regression proof, part two, property-style: zeroed and
        // clamped-negative weekly rates on every window must reproduce the
        // no-weekly-data verdicts bit for bit — badges and decisions alike.
        for (pairs, projections, sessionRates) in derivationFixtures() {
            let baseline = badges(pairs, projections: projections, rates: sessionRates)
            var weekly: [String: [String: Double]] = [:]
            for (index, pair) in pairs.enumerated() {
                weekly[pair.0.id] = rates(
                    byWindow: ["Weekly": index.isMultiple(of: 2) ? 0 : -4])
            }
            XCTAssertEqual(
                badges(pairs, projections: projections, rates: sessionRates, weeklyRates: weekly),
                baseline,
                "no weekly demand must leave the v3/v2 verdict untouched")
            XCTAssertEqual(
                traces(pairs, projections: projections, rates: sessionRates, weeklyRates: weekly)
                    .map(\.decision),
                traces(pairs, projections: projections, rates: sessionRates).map(\.decision))
        }
    }

    func testTraceWeeklyLegContents() throws {
        // The debug view's numbers for a weekly-leg verdict: both pooled
        // paces, both at-risk values with the window they came from, the
        // session leg's stand-down reason, and no weekly fallback.
        let trace = try XCTUnwrap(
            traces(
                liveScenario(workSession: 5, altSession: 23),
                weeklyRates: liveScenarioRates, multipliers: liveScenarioMultipliers
            ).first)
        XCTAssertEqual(trace.aggregatePace, 0)
        XCTAssertEqual(trace.weeklyAggregatePace, 0.05, accuracy: 1e-12)
        XCTAssertEqual(trace.quotaWeighting, .quotaWeighted)
        XCTAssertEqual(candidate("work", in: trace)?.weeklyBurnRate, 0.6)
        XCTAssertEqual(candidate("work", in: trace)?.weeklyName, "Weekly")
        XCTAssertEqual(candidate("work", in: trace)?.weeklyPercent, 31)
        XCTAssertEqual(
            candidate("work", in: trace)?.weeklyResetsAt, Self.now.addingTimeInterval(3 * 86400))
        XCTAssertEqual(
            try XCTUnwrap(candidate("work", in: trace)?.weeklyAtRiskUnits), 3.45, accuracy: 1e-9)
        XCTAssertEqual(
            try XCTUnwrap(candidate("work", in: trace)?.weeklyAtRiskPercent), 69, accuracy: 1e-9)
        XCTAssertEqual(
            try XCTUnwrap(candidate("alt", in: trace)?.weeklyAtRiskUnits), 0.95, accuracy: 1e-9)
        // Session at-risk is still traced (all zero: no session pace).
        XCTAssertEqual(candidate("work", in: trace)?.atRiskUnits, 0)
        XCTAssertEqual(trace.capacityFallback, .noAggregatePace)
        XCTAssertNil(trace.weeklyCapacityFallback)
        let award = try expiringAward(of: trace)
        XCTAssertEqual(award.leg, .weekly)
        XCTAssertEqual(award.badgedID, "work")
        XCTAssertEqual(award.atRiskUnits, 3.45, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(award.atRiskGapUnits), 2.5, accuracy: 1e-9)
        XCTAssertEqual(award.badge.expiring?.scopeName, "Weekly")
    }

    func testTraceBothLegsStandDown() throws {
        // Demand on both clocks, nothing meaningful expiring on either: idle
        // session windows (no deadline) and weekly windows with almost no
        // headroom left. Each leg records its own reason and v2 decides.
        let trace = try XCTUnwrap(
            traces(
                [
                    (
                        makeAccount("a"),
                        makeState(
                            session: 40, sessionResetIn: nil,
                            weekly: [Weekly(percent: 95, resetIn: 100 * 3600)])
                    ),
                    (
                        makeAccount("b"),
                        makeState(
                            session: 10, sessionResetIn: nil,
                            weekly: [Weekly(percent: 90, resetIn: nil)])
                    ),
                ],
                rates: ["a": 30, "b": 30],
                weeklyRates: [
                    "a": rates(byWindow: ["Weekly": 1]),
                    "b": rates(byWindow: ["Weekly": 1]),
                ]
            ).first)
        XCTAssertEqual(trace.aggregatePace, 0.6, accuracy: 1e-12)
        XCTAssertEqual(trace.weeklyAggregatePace, 0.02, accuracy: 1e-12)
        XCTAssertEqual(trace.capacityFallback, .belowFloor(topAtRiskUnits: 0))
        XCTAssertEqual(trace.weeklyCapacityFallback, .belowFloor(topAtRiskUnits: 0))
        let award = try award(of: trace)
        XCTAssertEqual(award.badgedID, "b")
        XCTAssertNil(award.badge.expiring)
    }

    func testWinnersMatchTraceDerivationAcrossWeeklyFixtures() {
        // The derivation invariant again, over weekly-leg shapes: the badge
        // map is exactly the badge-awarding decisions in the traces, so the
        // debug popover can never disagree with the badge.
        let fixtures: [(
            pairs: [(AccountMeta, AccountDisplayState?)],
            rates: [String: Double],
            weekly: [String: [String: Double]],
            multipliers: [String: Double]
        )] = [
            // the issue's live scenario, both session orders
            (liveScenario(workSession: 5, altSession: 23), [:], liveScenarioRates,
                liveScenarioMultipliers),
            (liveScenario(workSession: 23, altSession: 5), [:], liveScenarioRates,
                liveScenarioMultipliers),
            // session leg wins the race, weekly leg never consulted
            ([
                (
                    makeAccount("work"),
                    makeState(
                        session: 60, sessionResetIn: 3600,
                        weekly: [Weekly(percent: 10, resetIn: 200 * 3600)])
                ),
                (
                    makeAccount("personal"),
                    makeState(
                        session: 30, sessionResetIn: 4 * 3600,
                        weekly: [Weekly(percent: 20, resetIn: 20 * 3600)])
                ),
            ], ["work": 35, "personal": 25],
                ["personal": rates(byWindow: ["Weekly": 4.25])], [:]),
            // both legs stand down: v2 decides
            ([
                (
                    makeAccount("a"),
                    makeState(
                        session: 40, sessionResetIn: nil,
                        weekly: [Weekly(percent: 95, resetIn: 100 * 3600)])
                ),
                (
                    makeAccount("b"),
                    makeState(
                        session: 10, sessionResetIn: nil,
                        weekly: [Weekly(percent: 90, resetIn: nil)])
                ),
            ], ["a": 30, "b": 30],
                ["a": rates(byWindow: ["Weekly": 1]), "b": rates(byWindow: ["Weekly": 1])], [:]),
        ]
        for (pairs, rates, weekly, multipliers) in fixtures {
            var derived: [String: BestAccount.Badge] = [:]
            for trace in traces(
                pairs, rates: rates, weeklyRates: weekly, multipliers: multipliers) {
                switch trace.decision {
                case .badged(let award):
                    derived[award.badgedID] = award.badge
                case .expiringFirst(let award):
                    derived[award.badgedID] = award.badge
                case .groupTooSmall, .allVetoed, .marginTooClose:
                    break
                }
            }
            XCTAssertEqual(
                badges(pairs, rates: rates, weeklyRates: weekly, multipliers: multipliers),
                derived,
                "winners must be exactly the traces' badge-awarding decisions")
        }
    }

    #if DEBUG
        func testMockFixturesKeepBothExpiringLegsStoodDown() {
            // Screenshot mode never writes history, so neither expiring leg
            // has a demand signal: the README screenshots keep showing the v2
            // badge exactly as before.
            for trace in BestAccount.evaluate(accounts: Mock.accounts, states: Mock.states) {
                XCTAssertEqual(trace.aggregatePace, 0)
                XCTAssertEqual(trace.weeklyAggregatePace, 0)
                if case .expiringFirst = trace.decision {
                    XCTFail("mock mode must not reach an expiring-first verdict")
                }
            }
            XCTAssertEqual(
                Set(BestAccount.winners(accounts: Mock.accounts, states: Mock.states).keys),
                ["mock-work"])
        }
    #endif

    func testManualAndDetectedMixCountsAsFullyKnown() throws {
        // One account hand-picked, the other auto-detected: every account
        // has an effective multiplier, so the honesty rule is satisfied —
        // and the trace records each source for the debug view.
        let trace = try XCTUnwrap(
            traces(
                [
                    (makeAccount("work"), makeState(session: 60, resetIn: 3600)),
                    (makeAccount("personal"), makeState(session: 30, resetIn: 4 * 3600)),
                ],
                rates: ["work": 30, "personal": 10],
                multipliers: ["work": 20],
                detected: ["personal": 1]
            ).first)
        XCTAssertEqual(trace.quotaWeighting, .quotaWeighted)
        XCTAssertEqual(candidate("work", in: trace)?.quota?.source, .manual)
        XCTAssertEqual(candidate("personal", in: trace)?.quota?.source, .detected)
    }
}
