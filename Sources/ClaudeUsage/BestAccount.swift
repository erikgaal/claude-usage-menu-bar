import Foundation

/// Pure ranking logic behind the "Best" badge (issue #4). Free of
/// `AccountStore` so it can be unit-tested against handcrafted fixtures —
/// the store's init touches UserDefaults/Keychain and starts the poll loop,
/// which tests must never do. Pace data arrives the same way: the store
/// queries its history store and passes plain projections in, so no history
/// reads happen here.
///
/// The whole evaluation is captured as data (`evaluate`, one `GroupTrace`
/// per provider); `winners` is derived from those traces, so the debug
/// popover and the real badge decision can never drift apart.
enum BestAccount {
    /// Winner-vs-runner-up margin, in percentage points of session usage,
    /// required before the "Best" badge shows. Near-ties give no useful
    /// advice, and a badge that hops between accounts on every poll would
    /// train the user to ignore it.
    static let margin = 10.0
    /// A weekly-scoped window at or above this is treated as exhausted.
    /// Slightly under 100 because percents arrive as floats and the API can
    /// hover just below the cap while requests are already being rejected.
    static let weeklyExhaustedPercent = 99.5
    /// How much longer the runner-up's projected session must last than the
    /// headroom winner's before pace overrides headroom (issue #4 v2).
    /// Headroom is a snapshot — an account at 40% burning 30%/h is a worse
    /// bet than one at 55% burning 3%/h — but projections wobble with every
    /// poll, so small differences must not move the badge. Inclusive, like
    /// `margin`.
    static let overrideMargin: TimeInterval = 30 * 60

    // MARK: - Badge

    /// What the badge needs to know beyond the winner's identity.
    struct Badge: Equatable {
        /// When the badged account's session is projected to run out — drives
        /// the "≈2h 10m of session left" tooltip. Nil (keep the static v1
        /// tooltip) when there is no usable pace signal: no projection, a
        /// stale one already in the past, or one landing after the session
        /// resets anyway.
        let projectedExhaustion: Date?
    }

    // MARK: - Trace model

    /// Why an account is in or out of the running. Reasons are data, not
    /// display strings — the debug view maps them to text.
    enum Eligibility: Equatable {
        case eligible
        /// Dead sign-in: unusable no matter the headroom.
        case vetoedNeedsReauth
        /// No display state or no limits yet: nothing to rank.
        case vetoedNoData
        /// A week-scoped window at the cap: session headroom is a mirage
        /// when the week is already spent.
        case vetoedWeeklyExhausted(limitName: String, percent: Double)
    }

    /// A candidate's pace signal, derived from its session projection.
    enum PaceSignal: Equatable {
        /// No projection recorded — idle account or history too thin.
        case noProjection
        /// The projection is already in the past: stale history, discarded —
        /// it must not read as "exhausts immediately", since a truly spent
        /// session shows up in its percent, which the ranking already sees.
        case stale
        /// Projected exhaustion lands at/after the session reset: at the
        /// current pace the account outlasts its whole window. Beats any
        /// pre-reset projection, but is not a date worth showing.
        case beyondReset
        /// Real, future, pre-reset projected exhaustion.
        case projected(Date)
    }

    /// One account's evaluation within its provider group.
    struct CandidateTrace: Equatable {
        let accountID: String
        /// Display label at evaluation time, for the debug view.
        let label: String
        let sessionName: String?
        let sessionPercent: Double?
        let eligibility: Eligibility
        let pace: PaceSignal
    }

    /// How the pace-override leg compared the headroom winner to its
    /// runner-up.
    enum PaceComparison: Equatable {
        /// Sole eligible account: nothing to compare against.
        case soleCandidate
        /// Winner and/or runner-up carries no usable pace signal — a missing
        /// projection means "not currently burning", never "exhausts
        /// immediately", so the headroom verdict stands.
        case missingSignal
        /// The winner outlasts its whole window: pace can't demote it.
        case winnerOutlastsWindow
        /// The runner-up survives its whole window while the winner runs
        /// out — the strongest possible override.
        case runnerUpOutlastsWindow
        /// Both projections are real dates: runner-up minus winner, in
        /// seconds. The override fires at `overrideMargin` and above.
        case delta(TimeInterval)
    }

    /// A badge was awarded: how headroom and pace each contributed.
    struct Award: Equatable {
        /// The v1 verdict: most session headroom among eligible accounts.
        let headroomWinnerID: String
        /// Headroom lead over the eligible runner-up in percentage points;
        /// nil when the winner is the sole eligible account.
        let headroomGap: Double?
        let paceComparison: PaceComparison
        /// Who wears the badge after the pace-override step.
        let badgedID: String
        /// Tooltip payload for the badged account.
        let badge: Badge

        /// True when pace moved the badge off the headroom winner.
        var overrideApplied: Bool { badgedID != headroomWinnerID }
    }

    /// A provider group's verdict.
    enum Decision: Equatable {
        /// Fewer than two accounts of this provider: "best" is meaningless
        /// with nothing to compare against.
        case groupTooSmall
        /// Two or more accounts, but none survived the vetoes.
        case allVetoed
        /// The winner-vs-runner-up gap is under `margin`: too close to call,
        /// stay quiet rather than flap.
        case marginTooClose(winnerID: String, runnerUpID: String, gap: Double)
        case badged(Award)
    }

    /// Everything the badge logic saw and decided for one provider.
    struct GroupTrace: Equatable {
        let provider: ProviderID
        /// All of the provider's accounts, in panel order.
        let candidates: [CandidateTrace]
        let decision: Decision
    }

    // MARK: - Evaluation

    /// Full evaluation, one trace per provider (in panel order). Per
    /// provider — comparing across providers is meaningless, a Claude
    /// session % and a Codex session % aren't interchangeable — the eligible
    /// account with the most 5-hour-session headroom wins, subject to the
    /// vetoes and the anti-flapping margin; the pace override may then move
    /// the badge to a runner-up projected to outlast the winner by at least
    /// `overrideMargin`.
    static func evaluate(
        accounts: [AccountMeta],
        states: [String: AccountDisplayState],
        sessionProjections: [String: Date] = [:],
        now: Date = Date()
    ) -> [GroupTrace] {
        // Group by provider, preserving panel order for groups and members.
        var order: [ProviderID] = []
        var groups: [ProviderID: [AccountMeta]] = [:]
        for account in accounts {
            if groups[account.provider] == nil { order.append(account.provider) }
            groups[account.provider, default: []].append(account)
        }

        return order.map { provider in
            let members = groups[provider] ?? []
            let candidates = members.map { account in
                candidateTrace(
                    account: account, state: states[account.id],
                    projection: sessionProjections[account.id], now: now)
            }
            return GroupTrace(
                provider: provider,
                candidates: candidates,
                decision: decision(for: candidates, groupSize: members.count))
        }
    }

    /// Accounts to badge as the current "best bet", keyed by account id —
    /// derived entirely from `evaluate`, so it always agrees with the trace
    /// the debug view shows.
    static func winners(
        accounts: [AccountMeta],
        states: [String: AccountDisplayState],
        sessionProjections: [String: Date] = [:],
        now: Date = Date()
    ) -> [String: Badge] {
        var result: [String: Badge] = [:]
        for trace in evaluate(
            accounts: accounts, states: states,
            sessionProjections: sessionProjections, now: now) {
            if case .badged(let award) = trace.decision {
                result[award.badgedID] = award.badge
            }
        }
        return result
    }

    // MARK: - Steps

    /// One account's inputs: session slot, veto status, and pace signal.
    /// Veto precedence matches v1's guards: reauth, then missing data, then
    /// the weekly-exhaustion check. The pace signal is computed even for
    /// vetoed accounts — the decision ignores it, but the debug view shows
    /// it.
    private static func candidateTrace(
        account: AccountMeta,
        state: AccountDisplayState?,
        projection: Date?,
        now: Date
    ) -> CandidateTrace {
        let session = state.flatMap { sessionLimit(in: $0.limits) }
        let pace = paceSignal(
            projection: projection, sessionReset: session?.resetsAt, now: now)

        let eligibility: Eligibility
        if state?.needsReauth == true {
            eligibility = .vetoedNeedsReauth
        } else if let state, let session {
            if let spent = state.limits.first(where: {
                $0.id != session.id && $0.percent >= weeklyExhaustedPercent
            }) {
                eligibility = .vetoedWeeklyExhausted(
                    limitName: spent.name, percent: spent.percent)
            } else {
                eligibility = .eligible
            }
        } else {
            eligibility = .vetoedNoData
        }

        return CandidateTrace(
            accountID: account.id,
            label: account.displayLabel,
            sessionName: session?.name,
            sessionPercent: session?.percent,
            eligibility: eligibility,
            pace: pace)
    }

    /// The group verdict over already-traced candidates.
    private static func decision(
        for candidates: [CandidateTrace], groupSize: Int
    ) -> Decision {
        guard groupSize >= 2 else { return .groupTooSmall }

        // Eligible candidates, best (lowest session percent) first. Vetoed
        // accounts dropped out here, so the pace override below can never
        // resurrect them.
        let ranked = candidates
            .filter { $0.eligibility == .eligible }
            .sorted { ($0.sessionPercent ?? 100) < ($1.sessionPercent ?? 100) }
        guard let winner = ranked.first else { return .allVetoed }

        let runnerUp = ranked.count >= 2 ? ranked[1] : nil
        let gap = runnerUp.flatMap { candidate -> Double? in
            guard let winnerPercent = winner.sessionPercent,
                let runnerUpPercent = candidate.sessionPercent
            else { return nil }
            return runnerUpPercent - winnerPercent
        }
        if let runnerUp, let gap, gap < margin {
            // Too close to call — stay quiet rather than flap.
            return .marginTooClose(
                winnerID: winner.accountID, runnerUpID: runnerUp.accountID, gap: gap)
        }

        // Pace override: only the headroom winner and its runner-up are
        // weighed — both eligible by construction — and only when both
        // carry a pace signal.
        let comparison = paceComparison(winner: winner.pace, runnerUp: runnerUp?.pace)
        let badged: CandidateTrace = {
            guard let runnerUp else { return winner }
            switch comparison {
            case .runnerUpOutlastsWindow:
                return runnerUp
            case .delta(let delta) where delta >= overrideMargin:
                return runnerUp
            default:
                return winner
            }
        }()

        return .badged(
            Award(
                headroomWinnerID: winner.accountID,
                headroomGap: gap,
                paceComparison: comparison,
                badgedID: badged.accountID,
                badge: badge(for: badged)))
    }

    /// A candidate's pace signal from its raw projection.
    private static func paceSignal(
        projection: Date?, sessionReset: Date?, now: Date
    ) -> PaceSignal {
        guard let projection else { return .noProjection }
        guard projection > now else { return .stale }
        if let sessionReset, projection >= sessionReset { return .beyondReset }
        return .projected(projection)
    }

    /// The pace-override comparison between the headroom winner and its
    /// runner-up, as data for both the decision and the debug view.
    private static func paceComparison(
        winner: PaceSignal, runnerUp: PaceSignal?
    ) -> PaceComparison {
        guard let runnerUp else { return .soleCandidate }
        switch (winner, runnerUp) {
        case (.projected(let winnerDate), .projected(let runnerUpDate)):
            return .delta(runnerUpDate.timeIntervalSince(winnerDate))
        case (.beyondReset, .projected), (.beyondReset, .beyondReset):
            return .winnerOutlastsWindow
        case (.projected, .beyondReset):
            return .runnerUpOutlastsWindow
        default:
            return .missingSignal
        }
    }

    /// The tooltip payload for the badged account: real dates only — the
    /// "outlasts the window" case has no honest duration to show.
    private static func badge(for candidate: CandidateTrace) -> Badge {
        if case .projected(let date) = candidate.pace {
            return Badge(projectedExhaustion: date)
        }
        return Badge(projectedExhaustion: nil)
    }

    /// The 5-hour session window among an account's limits. Both providers
    /// label their short window "Session" (Claude from kind `session`, Codex
    /// from a primary window of ≤ 24h), so match by name and fall back to
    /// the front of the list — both builders sort the session slot first.
    /// Everything else (weekly, per-model 7-day, Codex secondary/extra
    /// windows) is week-scoped, which is what the veto above relies on.
    static func sessionLimit(in limits: [LimitStatus]) -> LimitStatus? {
        limits.first { $0.name == "Session" } ?? limits.first
    }
}
