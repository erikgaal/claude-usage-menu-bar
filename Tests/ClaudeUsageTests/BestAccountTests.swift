import XCTest

@testable import ClaudeUsage

/// Exercises the pure ranking behind the "Best" badge (`BestAccount`).
/// Everything runs on handcrafted fixtures — no `AccountStore`, whose init
/// touches UserDefaults/Keychain and starts the network poll loop.
@MainActor
final class BestAccountTests: XCTestCase {

    /// Fixed reset time (2033-05-18T03:33:20Z). The ranking never reads it,
    /// but realistic fixtures keep the tests honest about the shape of data.
    private static let resetDate = Date(timeIntervalSince1970: 2_000_000_000)

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

    /// Runs the ranking over (account, state) pairs; a nil state models an
    /// account the store hasn't heard from at all.
    private func winners(_ pairs: [(AccountMeta, AccountDisplayState?)]) -> Set<String> {
        var states: [String: AccountDisplayState] = [:]
        for (account, state) in pairs {
            states[account.id] = state
        }
        return BestAccount.winners(accounts: pairs.map(\.0), states: states)
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
}
