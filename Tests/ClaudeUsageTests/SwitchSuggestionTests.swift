import XCTest

@testable import ClaudeUsage

/// Detection tests for the switch suggestions (issue #24). Everything here
/// runs against the pure function: fixtures in, optional recommendation plus
/// updated memory out, with `now` supplied so the anti-spam clocks are exact
/// rather than approximate.
final class SwitchSuggestionTests: XCTestCase {

    /// Fixed clock (2023-11-14T22:13:20Z) for every fixture.
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: Fixtures

    private func makeAccount(
        id: String, label: String, provider: ProviderID = .claude
    ) -> AccountMeta {
        AccountMeta(
            id: id, email: "\(id)@example.com", organizationName: nil,
            provider: provider, label: label)
    }

    /// Two Claude accounts: "Work" (burned) and "Personal" (badged).
    private var work: AccountMeta { makeAccount(id: "acct-work", label: "Work") }
    private var personal: AccountMeta { makeAccount(id: "acct-personal", label: "Personal") }

    private func evaluate(
        accounts: [AccountMeta]? = nil,
        badges: [String: BestAccount.Badge],
        rates: [String: Double],
        state: [ProviderID: SwitchSuggestion.GroupState] = [:],
        now: Date = SwitchSuggestionTests.now
    ) -> SwitchSuggestion.Outcome {
        SwitchSuggestion.evaluate(
            accounts: accounts ?? [work, personal], badges: badges,
            sessionBurnRates: rates, state: state, now: now)
    }

    /// The single suggestion the fixtures are built to produce.
    private func onlySuggestion(
        _ outcome: SwitchSuggestion.Outcome,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> SwitchSuggestion.Suggestion {
        XCTAssertEqual(outcome.suggestions.count, 1, file: file, line: line)
        return try XCTUnwrap(outcome.suggestions.first, file: file, line: line)
    }

    // MARK: Trigger

    func testBurningOneAccountWhileAnotherIsBadgedSuggestsTheSwitch() throws {
        let outcome = evaluate(
            badges: [personal.id: BestAccount.Badge()],
            rates: [work.id: 24])
        let suggestion = try onlySuggestion(outcome)
        XCTAssertEqual(suggestion.provider, .claude)
        XCTAssertEqual(suggestion.fromAccountID, work.id)
        XCTAssertEqual(suggestion.fromLabel, "Work")
        XCTAssertEqual(suggestion.toAccountID, personal.id)
        XCTAssertEqual(suggestion.toLabel, "Personal")
        XCTAssertEqual(suggestion.title, "Switch to Personal")
        // …and the memory the caller must carry forward is populated.
        let group = try XCTUnwrap(outcome.state[.claude])
        XCTAssertEqual(group.lastPair, SwitchSuggestion.Pair(from: work.id, to: personal.id))
        XCTAssertEqual(group.lastNotifiedAt, Self.now)
    }

    func testFastestBurnerIsTreatedAsCurrent() throws {
        // Three accounts, two of them genuinely in use: the recommendation is
        // aimed at the one consuming quota quickest, not the first in order.
        let other = makeAccount(id: "acct-other", label: "Side")
        let outcome = evaluate(
            accounts: [work, other, personal],
            badges: [personal.id: BestAccount.Badge()],
            rates: [work.id: 9, other.id: 31])
        let suggestion = try onlySuggestion(outcome)
        XCTAssertEqual(suggestion.fromAccountID, other.id)
        XCTAssertEqual(suggestion.fromLabel, "Side")
    }

    func testBurnRateAtTheFloorStillCountsAsBurning() throws {
        let outcome = evaluate(
            badges: [personal.id: BestAccount.Badge()],
            rates: [work.id: SwitchSuggestion.activeBurnRateFloor])
        XCTAssertEqual(try onlySuggestion(outcome).fromAccountID, work.id)
    }

    // MARK: Silence

    func testNothingBurningStaysSilent() {
        // Regression jitter on flat usage, plus a negative slope: not work.
        let outcome = evaluate(
            badges: [personal.id: BestAccount.Badge()],
            rates: [work.id: 0.4, personal.id: -0.2])
        XCTAssertTrue(outcome.suggestions.isEmpty)
        XCTAssertNil(outcome.state[.claude]?.lastNotifiedAt)
    }

    func testGroupWithoutABadgeStaysSilent() {
        // The ranking declined to badge anyone (too close to call, all vetoed,
        // …) — there is nothing to recommend.
        let outcome = evaluate(badges: [:], rates: [work.id: 24])
        XCTAssertTrue(outcome.suggestions.isEmpty)
    }

    func testBadgedAccountBeingTheBurningOneStaysSilent() {
        let outcome = evaluate(
            badges: [work.id: BestAccount.Badge()],
            rates: [work.id: 24])
        XCTAssertTrue(outcome.suggestions.isEmpty)
    }

    func testBadgeInAnotherProviderGroupIsNotBorrowed() {
        // A Codex badge says nothing about which Claude account to use.
        let codex = makeAccount(id: "acct-codex", label: "Codex", provider: .codex)
        let outcome = evaluate(
            accounts: [work, personal, codex],
            badges: [codex.id: BestAccount.Badge()],
            rates: [work.id: 24])
        XCTAssertTrue(outcome.suggestions.isEmpty)
    }

    // MARK: Copy — the four badge payloads

    func testExpiringSessionCapacityBody() throws {
        let badge = BestAccount.Badge(
            expiring: BestAccount.ExpiringCapacity(
                points: 32, resetsAt: Self.now.addingTimeInterval(70 * 60)))
        let suggestion = try onlySuggestion(
            evaluate(badges: [personal.id: badge], rates: [work.id: 24]))
        XCTAssertEqual(suggestion.body, "≈32% of its session expires in 1h 10m")
        XCTAssertEqual(
            suggestion.reason,
            .expiringSession(points: 32, resetsAt: Self.now.addingTimeInterval(70 * 60)))
    }

    func testExpiringWeeklyCapacityBodyNamesTheWeek() throws {
        let badge = BestAccount.Badge(
            expiring: BestAccount.ExpiringCapacity(
                points: 69, resetsAt: Self.now.addingTimeInterval(3 * 86400 + 4 * 3600),
                scopeName: "Weekly"))
        let suggestion = try onlySuggestion(
            evaluate(badges: [personal.id: badge], rates: [work.id: 24]))
        XCTAssertEqual(suggestion.body, "≈69% of its weekly expires in 3d 4h")
    }

    func testExpiringModelScopedCapacityBodyNamesTheScope() throws {
        // The weekly leg can award on a model-scoped window; the copy must say
        // which, or "31% expires in 3d" reads as the whole week.
        let badge = BestAccount.Badge(
            expiring: BestAccount.ExpiringCapacity(
                points: 31, resetsAt: Self.now.addingTimeInterval(3 * 86400 + 4 * 3600),
                scopeName: "Fable"))
        let suggestion = try onlySuggestion(
            evaluate(badges: [personal.id: badge], rates: [work.id: 24]))
        XCTAssertEqual(suggestion.body, "≈31% of its Fable expires in 3d 4h")
        XCTAssertEqual(
            suggestion.reason,
            .expiringScope(
                points: 31, resetsAt: Self.now.addingTimeInterval(3 * 86400 + 4 * 3600),
                scopeName: "Fable"))
    }

    func testPaceProjectionBody() throws {
        let badge = BestAccount.Badge(
            projectedExhaustion: Self.now.addingTimeInterval(2 * 3600 + 10 * 60))
        let suggestion = try onlySuggestion(
            evaluate(badges: [personal.id: badge], rates: [work.id: 24]))
        XCTAssertEqual(suggestion.body, "≈2h 10m of session left at current pace")
    }

    func testStaticBadgeBody() throws {
        let suggestion = try onlySuggestion(
            evaluate(badges: [personal.id: BestAccount.Badge()], rates: [work.id: 24]))
        XCTAssertEqual(suggestion.body, "more session headroom right now")
        XCTAssertEqual(suggestion.reason, .headroom)
    }

    func testExpiringPayloadOutranksAPaceProjectionInTheCopy() throws {
        // Mirrors the tooltip's precedence: an expiring-first badge explains
        // what vanishes, never the pace date.
        let badge = BestAccount.Badge(
            projectedExhaustion: Self.now.addingTimeInterval(3600),
            expiring: BestAccount.ExpiringCapacity(
                points: 40, resetsAt: Self.now.addingTimeInterval(1800)))
        let suggestion = try onlySuggestion(
            evaluate(badges: [personal.id: badge], rates: [work.id: 24]))
        XCTAssertEqual(suggestion.body, "≈40% of its session expires in 30m")
    }

    // MARK: Anti-spam — edge trigger

    func testUnchangedPairDoesNotRenotify() {
        let badges = [personal.id: BestAccount.Badge()]
        let first = evaluate(badges: badges, rates: [work.id: 24])
        XCTAssertEqual(first.suggestions.count, 1)

        // Later cycles with the same situation: silent, however long we wait
        // (well past both the cooldown and the repeat-suppression window).
        var state = first.state
        for elapsed in [300.0, 3600.0, 6 * 3600.0, 48 * 3600.0] {
            let next = evaluate(
                badges: badges, rates: [work.id: 24], state: state,
                now: Self.now.addingTimeInterval(elapsed))
            XCTAssertTrue(next.suggestions.isEmpty, "re-notified after \(elapsed)s")
            state = next.state
        }
    }

    func testChangedPairNotifiesOnceTheCooldownHasElapsed() throws {
        let first = evaluate(
            badges: [personal.id: BestAccount.Badge()], rates: [work.id: 24])
        XCTAssertEqual(first.suggestions.count, 1)

        // A third account starts burning faster: new pair, same target.
        let other = makeAccount(id: "acct-other", label: "Side")
        let second = evaluate(
            accounts: [work, other, personal],
            badges: [personal.id: BestAccount.Badge()],
            rates: [work.id: 24, other.id: 40],
            state: first.state,
            now: Self.now.addingTimeInterval(SwitchSuggestion.cooldown))
        XCTAssertEqual(try onlySuggestion(second).fromAccountID, other.id)
    }

    func testChangedPairIsHeldBackByTheCooldown() {
        let first = evaluate(
            badges: [personal.id: BestAccount.Badge()], rates: [work.id: 24])
        let other = makeAccount(id: "acct-other", label: "Side")

        // One second short of the cooldown: the new pair waits.
        let second = evaluate(
            accounts: [work, other, personal],
            badges: [personal.id: BestAccount.Badge()],
            rates: [work.id: 24, other.id: 40],
            state: first.state,
            now: Self.now.addingTimeInterval(SwitchSuggestion.cooldown - 1))
        XCTAssertTrue(second.suggestions.isEmpty)
        // Held back, not consumed: the pair is still un-notified, so the very
        // next cycle past the boundary delivers it.
        XCTAssertEqual(
            second.state[.claude]?.lastPair,
            SwitchSuggestion.Pair(from: work.id, to: personal.id))
        let third = evaluate(
            accounts: [work, other, personal],
            badges: [personal.id: BestAccount.Badge()],
            rates: [work.id: 24, other.id: 40],
            state: second.state,
            now: Self.now.addingTimeInterval(SwitchSuggestion.cooldown))
        XCTAssertEqual(third.suggestions.count, 1)
    }

    // MARK: Anti-spam — long repeat suppression

    func testPairFlippingAwayAndBackIsSuppressedForHours() {
        let other = makeAccount(id: "acct-other", label: "Side")
        let accounts = [work, other, personal]
        let badges = [personal.id: BestAccount.Badge()]

        // Work → Personal is notified…
        let first = evaluate(
            accounts: accounts, badges: badges, rates: [work.id: 24])
        XCTAssertEqual(first.suggestions.count, 1)
        // …then the pair flips to Side → Personal a cooldown later…
        let second = evaluate(
            accounts: accounts, badges: badges, rates: [work.id: 24, other.id: 40],
            state: first.state, now: Self.now.addingTimeInterval(SwitchSuggestion.cooldown))
        XCTAssertEqual(second.suggestions.count, 1)
        // …and back to Work → Personal, cooldown satisfied but the pair itself
        // was notified only an hour ago.
        let third = evaluate(
            accounts: accounts, badges: badges, rates: [work.id: 24],
            state: second.state,
            now: Self.now.addingTimeInterval(2 * SwitchSuggestion.cooldown))
        XCTAssertTrue(third.suggestions.isEmpty)
    }

    func testRepeatedPairFiresAgainOnceTheSuppressionWindowHasPassed() {
        let other = makeAccount(id: "acct-other", label: "Side")
        let accounts = [work, other, personal]
        let badges = [personal.id: BestAccount.Badge()]

        let first = evaluate(accounts: accounts, badges: badges, rates: [work.id: 24])
        let second = evaluate(
            accounts: accounts, badges: badges, rates: [work.id: 24, other.id: 40],
            state: first.state, now: Self.now.addingTimeInterval(SwitchSuggestion.cooldown))
        XCTAssertEqual(second.suggestions.count, 1)

        // Exactly at the window (inclusive) the original pair is eligible
        // again: the edge has since moved to the other pair, and this is a
        // genuinely new stretch of work.
        let third = evaluate(
            accounts: accounts, badges: badges, rates: [work.id: 24],
            state: second.state,
            now: Self.now.addingTimeInterval(SwitchSuggestion.repeatSuppression))
        XCTAssertEqual(third.suggestions.count, 1)
    }

    func testResolvedSituationRearmsTheEdgeButKeepsTheRepeatWindow() {
        let badges = [personal.id: BestAccount.Badge()]
        let first = evaluate(badges: badges, rates: [work.id: 24])
        XCTAssertEqual(first.suggestions.count, 1)

        // The user stops working: the recommendation disappears and the edge
        // trigger re-arms…
        let idle = evaluate(
            badges: badges, rates: [:], state: first.state,
            now: Self.now.addingTimeInterval(600))
        XCTAssertTrue(idle.suggestions.isEmpty)
        XCTAssertNil(idle.state[.claude]?.lastPair)

        // …but resuming the same work shortly after must not re-notify: the
        // per-pair window still holds.
        let resumed = evaluate(
            badges: badges, rates: [work.id: 24], state: idle.state,
            now: Self.now.addingTimeInterval(3600))
        XCTAssertTrue(resumed.suggestions.isEmpty)

        // Hours later, the same advice is worth hearing again.
        let laterToday = evaluate(
            badges: badges, rates: [work.id: 24], state: resumed.state,
            now: Self.now.addingTimeInterval(SwitchSuggestion.repeatSuppression))
        XCTAssertEqual(laterToday.suggestions.count, 1)
    }

    // MARK: Provider independence

    func testProviderGroupsKeepSeparateCooldowns() throws {
        let codexWork = makeAccount(id: "codex-work", label: "Codex work", provider: .codex)
        let codexAlt = makeAccount(id: "codex-alt", label: "Codex alt", provider: .codex)
        let accounts = [work, personal, codexWork, codexAlt]

        // A Claude suggestion fires…
        let first = evaluate(
            accounts: accounts, badges: [personal.id: BestAccount.Badge()],
            rates: [work.id: 24])
        XCTAssertEqual(try onlySuggestion(first).provider, .claude)

        // …and a Codex one immediately after is not blocked by the Claude
        // group's cooldown.
        let second = evaluate(
            accounts: accounts,
            badges: [personal.id: BestAccount.Badge(), codexAlt.id: BestAccount.Badge()],
            rates: [work.id: 24, codexWork.id: 18],
            state: first.state, now: Self.now.addingTimeInterval(60))
        XCTAssertEqual(try onlySuggestion(second).provider, .codex)
        XCTAssertEqual(second.state[.claude]?.lastNotifiedAt, Self.now)
        XCTAssertEqual(
            second.state[.codex]?.lastNotifiedAt, Self.now.addingTimeInterval(60))
    }

    func testBothProviderGroupsCanSuggestInOneCycle() {
        let codexWork = makeAccount(id: "codex-work", label: "Codex work", provider: .codex)
        let codexAlt = makeAccount(id: "codex-alt", label: "Codex alt", provider: .codex)
        let outcome = evaluate(
            accounts: [work, personal, codexWork, codexAlt],
            badges: [personal.id: BestAccount.Badge(), codexAlt.id: BestAccount.Badge()],
            rates: [work.id: 24, codexWork.id: 18])
        // Panel order, one per group.
        XCTAssertEqual(outcome.suggestions.map(\.provider), [.claude, .codex])
    }

    // MARK: Mock mode

    #if DEBUG
        func testMockDataProducesNoSuggestions() {
            // Second line of defence behind `SystemNotificationScheduler`'s
            // `center` guard: mock mode records no history, so no account ever
            // reads as burning and detection itself stays silent on the
            // screenshot fixtures.
            let badges = BestAccount.winners(accounts: Mock.accounts, states: Mock.states)
            let outcome = SwitchSuggestion.evaluate(
                accounts: Mock.accounts, badges: badges, sessionBurnRates: [:],
                state: [:], now: Self.now)
            XCTAssertTrue(outcome.suggestions.isEmpty)
        }
    #endif

    // MARK: Duration wording

    func testDurationTextMatchesTheTooltipVocabulary() {
        XCTAssertEqual(SwitchSuggestion.durationText(seconds: 0), "moments")
        XCTAssertEqual(SwitchSuggestion.durationText(seconds: -60), "moments")
        XCTAssertEqual(SwitchSuggestion.durationText(seconds: 90), "1m")
        XCTAssertEqual(SwitchSuggestion.durationText(seconds: 70 * 60), "1h 10m")
        XCTAssertEqual(SwitchSuggestion.durationText(seconds: 3 * 86400 + 4 * 3600), "3d 4h")
    }
}
