import Foundation

/// Pure ranking logic behind the "Best" badge (issue #4, expiring-capacity
/// v3 from issue #19). Free of `AccountStore` so it can be unit-tested
/// against handcrafted fixtures — the store's init touches
/// UserDefaults/Keychain and starts the poll loop, which tests must never
/// do. Pace data arrives the same way: the store queries its history store
/// and passes plain projections and burn rates in, so no history reads
/// happen here.
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
    /// The expiring-first path (issue #19) only acts when at least this much
    /// capacity is at risk of expiring unused, in pooled quota units — one
    /// full Pro session window is 1.0, so 0.05 is five Pro-percent points
    /// (or a quarter-point of a Max 20× window). Below it nothing meaningful
    /// is at stake and the v2 headroom ranking gives better advice.
    static let atRiskFloor = 0.05
    /// Anti-flap margin for the expiring-first path, in the same pooled
    /// quota units: the leader must beat the runner-up by at least this much
    /// or the verdict falls back to v2. At-risk numbers wobble with every
    /// poll (pace refits, the reset clock ticks down), and near-ties mean
    /// the strategies are equivalent anyway. Inclusive, like `margin`.
    static let atRiskMargin = 0.05

    // MARK: - Badge

    /// What the badge needs to know beyond the winner's identity. At most
    /// one of the payloads is set: `expiring` for an expiring-first (v3)
    /// badge, `projectedExhaustion` for a pace-aware (v2) one; both nil
    /// keeps the static v1 tooltip.
    struct Badge: Equatable {
        /// When the badged account's session is projected to run out — drives
        /// the "≈2h 10m of session left" tooltip. Nil (keep the static v1
        /// tooltip) when there is no usable pace signal: no projection, a
        /// stale one already in the past, or one landing after the session
        /// resets anyway.
        let projectedExhaustion: Date?
        /// The expiring-first payload: how much capacity is about to vanish
        /// and when — drives the "≈32% expires at reset in 1h 10m" tooltip.
        let expiring: ExpiringCapacity?

        init(projectedExhaustion: Date? = nil, expiring: ExpiringCapacity? = nil) {
            self.projectedExhaustion = projectedExhaustion
            self.expiring = expiring
        }
    }

    /// Capacity about to vanish at a session reset (issue #19).
    struct ExpiringCapacity: Equatable {
        /// Percentage points that expire unused unless burned first.
        let points: Double
        /// When the session window resets.
        let resetsAt: Date
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
        /// When the session window resets, straight from the limit.
        let sessionResetsAt: Date?
        /// Raw session burn rate from history (%/hour); nil when unknown.
        let burnRate: Double?
        /// The account's plan multiplier as supplied (Pro ×1, Max ×5/×20);
        /// nil = not set. Whether it actually weighted the pool is the
        /// group's `quotaWeighting` — one unknown anywhere forces the whole
        /// group onto equal weights.
        let quotaMultiplier: Double?
        let eligibility: Eligibility
        let pace: PaceSignal
        /// Capacity that expires unused at this account's session reset
        /// unless the user burns it first, in pooled quota units (one full
        /// Pro window = 1.0) — see `atRiskCapacity(...)`. Nil for vetoed
        /// candidates: they don't take part in the expiring-first ranking.
        var atRiskUnits: Double?
        /// The same at-risk expressed in this account's own window percent
        /// (units × 100 ÷ effective multiplier), for display.
        var atRiskPercent: Double?
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

    /// A badge was awarded on the v2 path: how headroom and pace each
    /// contributed.
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

    /// A badge was awarded on the expiring-first path (issue #19).
    struct ExpiringAward: Equatable {
        let badgedID: String
        /// The badged account's at-risk capacity, in pooled quota units.
        let atRiskUnits: Double
        /// Lead over the runner-up's at-risk capacity, in units; nil when
        /// the badged account is the sole eligible candidate (unreachable
        /// today — a sole account has zero at-risk, see `atRiskCapacity` —
        /// but kept honest rather than force-unwrapped).
        let atRiskGapUnits: Double?
        /// Tooltip payload for the badged account.
        let badge: Badge
    }

    /// Why the expiring-first path stood down and left the verdict to v2.
    enum CapacityFallback: Equatable {
        /// No burn-rate history anywhere in the group: no demand signal.
        case noAggregatePace
        /// The largest at-risk capacity is under `atRiskFloor`: nothing
        /// meaningful is at stake (idle day, aligned resets, ample time).
        case belowFloor(topAtRiskUnits: Double)
        /// The top two at-risk values are within `atRiskMargin` of each
        /// other: the strategies tie, so the steadier v2 verdict applies.
        case atRiskTooClose(leaderID: String, runnerUpID: String, gapUnits: Double)
    }

    /// How the group's shared burn pool was weighted (issue #20 amendment).
    /// Percents aren't commensurable across plan tiers — 10%/h on a Max 20×
    /// is vastly more real usage than 10%/h on Pro — so pooled math runs in
    /// quota units whenever it honestly can.
    enum QuotaWeighting: Equatable {
        /// Every account in the group has a known plan multiplier: rates
        /// and headroom are pooled in comparable quota units.
        case quotaWeighted
        /// At least one account's plan is unknown (or invalid). Mixing
        /// known and unknown weights would silently distort the pool, so
        /// the whole group uses equal weights — exactly the unweighted
        /// math. The debug view surfaces this.
        case equalWeightsAssumed
    }

    /// A provider group's verdict.
    enum Decision: Equatable {
        /// Fewer than two accounts of this provider: "best" is meaningless
        /// with nothing to compare against.
        case groupTooSmall
        /// Two or more accounts, but none survived the vetoes.
        case allVetoed
        /// v2 fallback: the winner-vs-runner-up gap is under `margin` — too
        /// close to call, stay quiet rather than flap.
        case marginTooClose(winnerID: String, runnerUpID: String, gap: Double)
        /// v2 fallback: headroom ranking (with the pace override) decided.
        case badged(Award)
        /// v3: burn the expiring window first (issue #19).
        case expiringFirst(ExpiringAward)
    }

    /// Everything the badge logic saw and decided for one provider.
    struct GroupTrace: Equatable {
        let provider: ProviderID
        /// All of the provider's accounts, in panel order.
        let candidates: [CandidateTrace]
        /// Pooled demand: the sum of the group's session burn rates in
        /// quota units per hour (rate %/h × multiplier ÷ 100, negatives
        /// clamped to zero) — the total consumption that could be
        /// redirected between the group's accounts. Zero means no history
        /// signal anywhere.
        let aggregatePace: Double
        /// Whether the pool ran on real plan multipliers or assumed equal
        /// quotas because at least one plan is unknown.
        let quotaWeighting: QuotaWeighting
        /// Set when the group got as far as ranking but the expiring-first
        /// path stood down; nil when it decided (or when the group never
        /// ranked at all — too small / all vetoed).
        let capacityFallback: CapacityFallback?
        let decision: Decision
    }

    // MARK: - Evaluation

    /// Full evaluation, one trace per provider (in panel order). Per
    /// provider — comparing across providers is meaningless, a Claude
    /// session % and a Codex session % aren't interchangeable — the primary
    /// objective is maximizing total daily capacity: badge the account whose
    /// session capacity would otherwise expire unused (issue #19). When no
    /// meaningful capacity is at risk, the v2 behavior applies wholesale:
    /// most 5-hour-session headroom wins, subject to the vetoes and the
    /// anti-flapping margin, with the pace override possibly moving the
    /// badge to a runner-up projected to outlast the winner.
    static func evaluate(
        accounts: [AccountMeta],
        states: [String: AccountDisplayState],
        sessionProjections: [String: Date] = [:],
        sessionBurnRates: [String: Double] = [:],
        quotaMultipliers: [String: Double] = [:],
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
            // Honesty rule: the weighted pool applies only when every
            // member's plan is known (and sane). One unknown anywhere and
            // the whole group runs on equal weights — silently mixing known
            // and unknown weights is worse than assuming equality.
            let allKnown = members.allSatisfy { (quotaMultipliers[$0.id] ?? 0) > 0 }
            let weighting: QuotaWeighting = allKnown ? .quotaWeighted : .equalWeightsAssumed
            var effectiveMultipliers: [String: Double] = [:]
            for member in members {
                effectiveMultipliers[member.id] =
                    allKnown ? quotaMultipliers[member.id]! : 1
            }
            // Pooled demand in quota units per hour (one full Pro window =
            // 1.0). Demand is demand no matter which account currently
            // absorbs it (even a vetoed account's traffic gets redirected
            // somewhere usable), so every member's rate counts. Negative
            // slopes are regression jitter on flat usage, clamped to zero.
            let aggregatePace = members.reduce(0.0) {
                $0 + max(0, sessionBurnRates[$1.id] ?? 0)
                    * (effectiveMultipliers[$1.id] ?? 1) / 100
            }
            var candidates = members.map { account in
                candidateTrace(
                    account: account, state: states[account.id],
                    projection: sessionProjections[account.id],
                    burnRate: sessionBurnRates[account.id],
                    quotaMultiplier: quotaMultipliers[account.id], now: now)
            }
            attachAtRisk(
                to: &candidates, aggregatePace: aggregatePace,
                effectiveMultipliers: effectiveMultipliers, now: now)
            let (decision, fallback) = decision(
                for: candidates, groupSize: members.count, aggregatePace: aggregatePace)
            return GroupTrace(
                provider: provider,
                candidates: candidates,
                aggregatePace: aggregatePace,
                quotaWeighting: weighting,
                capacityFallback: fallback,
                decision: decision)
        }
    }

    /// Accounts to badge as the current "best bet", keyed by account id —
    /// derived entirely from `evaluate`, so it always agrees with the trace
    /// the debug view shows.
    static func winners(
        accounts: [AccountMeta],
        states: [String: AccountDisplayState],
        sessionProjections: [String: Date] = [:],
        sessionBurnRates: [String: Double] = [:],
        quotaMultipliers: [String: Double] = [:],
        now: Date = Date()
    ) -> [String: Badge] {
        var result: [String: Badge] = [:]
        for trace in evaluate(
            accounts: accounts, states: states,
            sessionProjections: sessionProjections,
            sessionBurnRates: sessionBurnRates,
            quotaMultipliers: quotaMultipliers, now: now) {
            switch trace.decision {
            case .badged(let award):
                result[award.badgedID] = award.badge
            case .expiringFirst(let award):
                result[award.badgedID] = award.badge
            case .groupTooSmall, .allVetoed, .marginTooClose:
                break
            }
        }
        return result
    }

    // MARK: - Steps

    /// One account's inputs: session slot, veto status, and pace signal.
    /// Veto precedence matches v1's guards: reauth, then missing data, then
    /// the weekly-exhaustion check. The pace signal is computed even for
    /// vetoed accounts — the decision ignores it, but the debug view shows
    /// it. At-risk capacity is attached afterwards: it needs the whole
    /// group's aggregate pace and eligible headroom.
    private static func candidateTrace(
        account: AccountMeta,
        state: AccountDisplayState?,
        projection: Date?,
        burnRate: Double?,
        quotaMultiplier: Double?,
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
            sessionResetsAt: session?.resetsAt,
            burnRate: burnRate,
            quotaMultiplier: quotaMultiplier,
            eligibility: eligibility,
            pace: pace,
            atRiskUnits: nil,
            atRiskPercent: nil)
    }

    /// Computes each eligible candidate's at-risk capacity in place, in
    /// pooled quota units (headroom% × multiplier ÷ 100). The coverage term
    /// is the *other* eligible accounts' combined session headroom in the
    /// same units — the capacity that could absorb the group's demand
    /// instead. The own-percent mirror is stored alongside for display.
    private static func attachAtRisk(
        to candidates: inout [CandidateTrace], aggregatePace: Double,
        effectiveMultipliers: [String: Double], now: Date
    ) {
        let eligible: [(index: Int, headroomUnits: Double)] = candidates.indices.compactMap {
            index in
            guard candidates[index].eligibility == .eligible,
                let percent = candidates[index].sessionPercent
            else { return nil }
            let multiplier = effectiveMultipliers[candidates[index].accountID] ?? 1
            return (index, max(0, 100 - percent) * multiplier / 100)
        }
        let totalHeadroom = eligible.reduce(0.0) { $0 + $1.headroomUnits }
        for (index, headroomUnits) in eligible {
            let multiplier = effectiveMultipliers[candidates[index].accountID] ?? 1
            let units = atRiskCapacity(
                headroom: headroomUnits,
                resetsAt: candidates[index].sessionResetsAt,
                aggregatePace: aggregatePace,
                coverage: totalHeadroom - headroomUnits,
                now: now)
            candidates[index].atRiskUnits = units
            candidates[index].atRiskPercent = units * 100 / multiplier
        }
    }

    /// Capacity that will vanish unused at this account's session reset
    /// unless the user burns this account first (issue #19). All quantities
    /// are in pooled quota units (one full Pro window = 1.0) so that
    /// different plan tiers pool honestly; with equal weights the math
    /// degrades to plain percents ÷ 100.
    ///
    /// Of the group's demand before the reset (`aggregatePace × hours`),
    /// this account can absorb at most its own headroom — that much is
    /// savable by prioritizing it: `savable = min(headroom, demand)`, the
    /// formula from issue #19. But demand the *other* eligible accounts
    /// cannot absorb (`demand − coverage`) lands on this account no matter
    /// what the user does, so it was never at risk of expiring:
    /// `at-risk = savable − inevitable`. Without the subtraction the raw
    /// formula grows with time-to-reset and ranks the account the issue's
    /// own worked example calls the reserve *above* the expiring one.
    ///
    /// Consequences worth knowing: a sole eligible account always scores 0
    /// (all demand lands on it anyway — nothing is redirectable), and other
    /// windows' refreshes are deliberately not modelled (they only add
    /// coverage, so at-risk is slightly overestimated, erring toward showing
    /// the hint). An idle or already-reset window (nil/past `resetsAt`) has
    /// nothing expiring: 0.
    private static func atRiskCapacity(
        headroom: Double, resetsAt: Date?, aggregatePace: Double,
        coverage: Double, now: Date
    ) -> Double {
        guard let resetsAt, resetsAt > now, aggregatePace > 0 else { return 0 }
        let demand = aggregatePace * resetsAt.timeIntervalSince(now) / 3600
        let savable = min(headroom, demand)
        let inevitable = min(headroom, max(0, demand - coverage))
        return savable - inevitable
    }

    /// The group verdict over already-traced candidates: the expiring-first
    /// path (v3) when it has a confident signal, the v2 ranking wholesale
    /// otherwise — with the fallback reason preserved for the debug view.
    private static func decision(
        for candidates: [CandidateTrace], groupSize: Int, aggregatePace: Double
    ) -> (Decision, CapacityFallback?) {
        guard groupSize >= 2 else { return (.groupTooSmall, nil) }

        // Eligible candidates, best (lowest session percent) first. Vetoed
        // accounts dropped out here, so neither path can resurrect them.
        let ranked = candidates
            .filter { $0.eligibility == .eligible }
            .sorted { ($0.sessionPercent ?? 100) < ($1.sessionPercent ?? 100) }
        guard let winner = ranked.first else { return (.allVetoed, nil) }

        // v3: burn expiring windows first (issue #19). Gated hard — a
        // confident "this will vanish" beats headroom, anything less falls
        // back to v2 wholesale.
        let fallback: CapacityFallback
        if aggregatePace <= 0 {
            fallback = .noAggregatePace
        } else {
            // Largest at-risk first; ties keep the headroom order.
            let byRisk = ranked.sorted {
                ($0.atRiskUnits ?? 0) > ($1.atRiskUnits ?? 0)
            }
            let leader = byRisk[0]
            let leaderRisk = leader.atRiskUnits ?? 0
            let runnerUpRisk = byRisk.count >= 2 ? (byRisk[1].atRiskUnits ?? 0) : nil
            if leaderRisk < atRiskFloor {
                fallback = .belowFloor(topAtRiskUnits: leaderRisk)
            } else if let runnerUpRisk, leaderRisk - runnerUpRisk < atRiskMargin {
                fallback = .atRiskTooClose(
                    leaderID: leader.accountID,
                    runnerUpID: byRisk[1].accountID,
                    gapUnits: leaderRisk - runnerUpRisk)
            } else if let resetsAt = leader.sessionResetsAt {
                let award = ExpiringAward(
                    badgedID: leader.accountID,
                    atRiskUnits: leaderRisk,
                    atRiskGapUnits: runnerUpRisk.map { leaderRisk - $0 },
                    badge: Badge(
                        expiring: ExpiringCapacity(
                            // The tooltip speaks the account's own percent.
                            points: leader.atRiskPercent ?? 0, resetsAt: resetsAt)))
                return (.expiringFirst(award), nil)
            } else {
                // Unreachable: positive at-risk implies a live future reset.
                fallback = .belowFloor(topAtRiskUnits: leaderRisk)
            }
        }

        // v2 wholesale (unchanged): headroom ranking plus the pace override.
        let runnerUp = ranked.count >= 2 ? ranked[1] : nil
        let gap = runnerUp.flatMap { candidate -> Double? in
            guard let winnerPercent = winner.sessionPercent,
                let runnerUpPercent = candidate.sessionPercent
            else { return nil }
            return runnerUpPercent - winnerPercent
        }
        if let runnerUp, let gap, gap < margin {
            // Too close to call — stay quiet rather than flap.
            return (
                .marginTooClose(
                    winnerID: winner.accountID, runnerUpID: runnerUp.accountID, gap: gap),
                fallback
            )
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

        return (
            .badged(
                Award(
                    headroomWinnerID: winner.accountID,
                    headroomGap: gap,
                    paceComparison: comparison,
                    badgedID: badged.accountID,
                    badge: badge(for: badged))),
            fallback
        )
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

    /// The v2 tooltip payload for the badged account: real dates only — the
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
