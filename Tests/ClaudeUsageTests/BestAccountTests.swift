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
        rates: [String: Double] = [:]
    ) -> Set<String> {
        Set(badges(pairs, projections: projections, rates: rates).keys)
    }

    /// Same run, but keeping the full verdicts for tooltip assertions.
    private func badges(
        _ pairs: [(AccountMeta, AccountDisplayState?)],
        projections: [String: Date] = [:],
        rates: [String: Double] = [:]
    ) -> [String: BestAccount.Badge] {
        var states: [String: AccountDisplayState] = [:]
        for (account, state) in pairs {
            states[account.id] = state
        }
        return BestAccount.winners(
            accounts: pairs.map(\.0), states: states,
            sessionProjections: projections, sessionBurnRates: rates, now: Self.now)
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
        rates: [String: Double] = [:]
    ) -> [BestAccount.GroupTrace] {
        var states: [String: AccountDisplayState] = [:]
        for (account, state) in pairs {
            states[account.id] = state
        }
        return BestAccount.evaluate(
            accounts: pairs.map(\.0), states: states,
            sessionProjections: projections, sessionBurnRates: rates, now: Self.now)
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
        XCTAssertEqual(candidate("a", in: trace)?.atRiskCapacity, 40)
        // b is the reserve: the demand its reset leaves uncovered lands on
        // it regardless, so nothing of b's is at risk.
        XCTAssertEqual(candidate("b", in: trace)?.atRiskCapacity, 0)
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
        XCTAssertEqual(candidate("a", in: trace)?.atRiskCapacity, 30)
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
        XCTAssertEqual(candidate("a", in: trace)?.atRiskCapacity, 0)
        XCTAssertEqual(candidate("b", in: trace)?.atRiskCapacity, 0)
        XCTAssertEqual(candidate("c", in: trace)?.atRiskCapacity, 40)
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

    func testAtRiskMarginBoundary() {
        // a has 15 points at risk (45 min × 20%/h), b has 10 (30 min):
        // a gap of exactly 5 — inclusive — moves the badge to a.
        let atMargin = badges(
            [
                (makeAccount("a"), makeState(session: 30, resetIn: 2700)),
                (makeAccount("b"), makeState(session: 40, resetIn: 1800)),
            ],
            rates: ["a": 10, "b": 10])
        XCTAssertEqual(Set(atMargin.keys), ["a"])
        XCTAssertEqual(atMargin["a"]?.expiring?.points, 15)

        // Stretching b's reset to 33 min lifts its at-risk to 11: the gap
        // (4) is under the margin, so v2 decides — a still wins, but on
        // headroom, with no expiring payload.
        let underMargin = badges(
            [
                (makeAccount("a"), makeState(session: 30, resetIn: 2700)),
                (makeAccount("b"), makeState(session: 40, resetIn: 1980)),
            ],
            rates: ["a": 10, "b": 10])
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
        XCTAssertNil(candidate("b", in: trace)?.atRiskCapacity)
        XCTAssertEqual(candidate("a", in: trace)?.atRiskCapacity, 10)
        let result = badges(pairs, rates: rates)
        XCTAssertEqual(Set(result.keys), ["a"])
        XCTAssertEqual(result["a"]?.expiring?.points, 10)
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
        XCTAssertEqual(trace.aggregatePace, 60)
        XCTAssertEqual(candidate("work", in: trace)?.atRiskCapacity, 40)
        XCTAssertEqual(candidate("personal", in: trace)?.atRiskCapacity, 0)
        XCTAssertNil(trace.capacityFallback)
        XCTAssertEqual(
            trace.decision,
            .expiringFirst(
                BestAccount.ExpiringAward(
                    badgedID: "work", atRisk: 40, atRiskGap: 40,
                    badge: BestAccount.Badge(
                        expiring: BestAccount.ExpiringCapacity(
                            points: 40, resetsAt: Self.now.addingTimeInterval(3600))))))
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
        XCTAssertEqual(idle.capacityFallback, .belowFloor(topAtRisk: 0))

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
        guard case .atRiskTooClose(let leaderID, let runnerUpID, let gap) =
            close.capacityFallback
        else {
            return XCTFail("expected atRiskTooClose, got \(String(describing: close.capacityFallback))")
        }
        XCTAssertEqual(leaderID, "a")
        XCTAssertEqual(runnerUpID, "b")
        XCTAssertEqual(gap, 4, accuracy: 1e-9)
        guard case .badged(let award) = close.decision else {
            return XCTFail("expected a v2 badge, got \(close.decision)")
        }
        XCTAssertEqual(award.badgedID, "a")
    }
}
