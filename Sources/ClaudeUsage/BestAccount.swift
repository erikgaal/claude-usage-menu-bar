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
    /// Floor for the *weekly* leg (issue #21), in pooled quota units of a
    /// weekly window — one full Pro week = 1.0. Deliberately four times the
    /// session floor: a weekly window carries ~34 session windows' worth of
    /// budget, so a point of weekly is worth far more than a point of
    /// session, but weekly at-risk values are also naturally large (a
    /// multi-day horizon times pooled pace, capped by headroom) and the
    /// weekly rate fit is coarse (12-hour lookback). 0.20 units ≈ a fifth of
    /// a plan's weekly allowance — call it a day and a half of budget — which
    /// is the smallest amount worth overriding the shorter session clock and
    /// the headroom ranking for.
    static let weeklyAtRiskFloor = 0.20
    /// Anti-flap margin for the weekly leg, in the same weekly units. Twice
    /// the session margin in nominal units because the weekly leg's inputs
    /// wobble more in absolute terms — the horizon is days rather than hours,
    /// so a small relative error in the pooled weekly pace moves at-risk by a
    /// lot — yet still small next to the multi-unit gaps real reset asymmetry
    /// produces (issue #21's live data: 3.45 vs 0.95 units). Inclusive, like
    /// `margin`.
    static let weeklyAtRiskMargin = 0.10
    /// How much earlier one account's reset must fall before a leg treats it
    /// as the nearer deadline (v5). Resets closer together than this are
    /// effectively simultaneous — two windows expiring 10 minutes apart offer
    /// no meaningful "go here first" advice — and are judged on at-risk size
    /// instead, via `atRiskMargin`/`weeklyAtRiskMargin`. Unlike those, this
    /// needs no anti-flap slack of its own: reset timestamps are fixed points,
    /// not refitted estimates, so the ordering they induce doesn't wobble
    /// between polls.
    static let deadlineMargin: TimeInterval = 30 * 60

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

    /// Capacity about to vanish at a window reset (issue #19 for the session
    /// window, issue #21 for weekly-scoped ones).
    struct ExpiringCapacity: Equatable {
        /// Percentage points that expire unused unless burned first.
        let points: Double
        /// When the window resets.
        let resetsAt: Date
        /// Which window expires: nil for the session window (the v3 wording,
        /// unchanged), the limit's display name ("Weekly", "Fable") when the
        /// weekly leg decided, so the tooltip can name it.
        let scopeName: String?

        init(points: Double, resetsAt: Date, scopeName: String? = nil) {
            self.points = points
            self.resetsAt = resetsAt
            self.scopeName = scopeName
        }
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
        /// How long the session window runs, when the limit states it — the
        /// length of the *replacement* window the next reset opens, which is
        /// what decides whether letting this one lapse costs anything (see
        /// `attachAtRisk`). Nil when the provider names no duration.
        let sessionWindowSeconds: TimeInterval?
        /// Raw session burn rate from history (%/hour); nil when unknown.
        let burnRate: Double?
        /// The account's plan multiplier as supplied (Pro ×1, Max ×5/×20),
        /// with its provenance; nil = not set. Whether it actually weighted
        /// the pool is the group's `quotaWeighting` — one unknown anywhere
        /// forces the whole group onto equal weights.
        let quota: Quota?
        let eligibility: Eligibility
        let pace: PaceSignal
        /// Capacity that expires unused at this account's session reset
        /// unless the user burns it first, in pooled quota units (one full
        /// Pro window = 1.0) — see `atRiskCapacity(...)`. Nil for vetoed
        /// candidates: they don't take part in the expiring-first ranking.
        /// Zeroed when `sessionRefills` is true.
        var atRiskUnits: Double?
        /// Whether a fresh session window arrives in time to spend the same
        /// quota anyway, which makes this session's expiry costless (v5) —
        /// see `attachAtRisk`. When true, `atRiskUnits` is held at zero and
        /// the account cannot win the session leg.
        var sessionRefills: Bool = false
        /// The same at-risk expressed in this account's own window percent
        /// (units × 100 ÷ effective multiplier), for display.
        var atRiskPercent: Double?
        /// Weekly leg (issue #21). The fastest-filling of this account's
        /// non-session windows, in %/hour — the rate that fed the pooled
        /// weekly pace; nil when no weekly history was supplied.
        let weeklyBurnRate: Double?
        /// The non-session window with the most at risk, and its inputs.
        /// All nil for vetoed candidates (they never rank) and for accounts
        /// with no weekly-scoped window at all.
        var weeklyName: String?
        var weeklyPercent: Double?
        var weeklyResetsAt: Date?
        /// Capacity that expires unused at `weeklyResetsAt` unless the user
        /// burns this account first, in pooled quota units of a *weekly*
        /// window (one full Pro week = 1.0). Never comparable with
        /// `atRiskUnits` — different window sizes, incompatible units — which
        /// is why the two legs are strictly prioritized rather than ranked
        /// against each other.
        var weeklyAtRiskUnits: Double?
        /// The same weekly at-risk in the account's own window percent.
        var weeklyAtRiskPercent: Double?
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
        /// Which leg produced it — the only place the two are distinguished,
        /// since their numbers live in incompatible units.
        enum Leg: Equatable {
            /// Session window (v3): capacity expiring in hours.
            case session
            /// Weekly-scoped window (v4, issue #21): capacity expiring in
            /// days. Only reached when the session leg stood down.
            case weekly
        }

        let leg: Leg
        let badgedID: String
        /// The badged account's at-risk capacity, in pooled quota units.
        let atRiskUnits: Double
        /// Lead over the at-risk capacity of the nearest rival sharing this
        /// deadline, in units — the comparison that decided the award only
        /// when `deadlineLeadSeconds` is nil. Nil when no other qualifying
        /// account resets at effectively the same time.
        let atRiskGapUnits: Double?
        /// How much earlier the badged account's window resets than the next
        /// qualifying rival's (v5), in seconds. Non-nil means the deadline
        /// decided the award outright and size never came into it; nil means
        /// there was no later-resetting rival to lead.
        let deadlineLeadSeconds: TimeInterval?
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

    /// An account's plan multiplier plus its provenance, so the debug view
    /// can distinguish "Max 5× (auto)" from a hand-picked plan. The math
    /// treats both identically; precedence (manual wins over detected) is
    /// resolved by the store before the data gets here.
    struct Quota: Equatable {
        let multiplier: Double
        let source: Source

        enum Source: Equatable {
            /// Chosen by the user in the account's Plan menu.
            case manual
            /// Detected from the provider's profile endpoint.
            case detected
        }
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
        /// v3/v4: burn the expiring window first (issues #19 and #21) —
        /// `ExpiringAward.leg` says which clock ran out first.
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
        /// Pooled weekly demand (issue #21): the same sum over the group's
        /// weekly-scoped windows, in quota units of a weekly window per hour.
        /// Each member contributes its fastest-filling non-session window;
        /// summing its windows instead would double-count, since model-scoped
        /// usage also lands in the overall weekly window.
        let weeklyAggregatePace: Double
        /// Whether the pool ran on real plan multipliers or assumed equal
        /// quotas because at least one plan is unknown.
        let quotaWeighting: QuotaWeighting
        /// Set when the group got as far as ranking but the *session*
        /// expiring-first leg stood down; nil when it decided (or when the
        /// group never ranked at all — too small / all vetoed).
        let capacityFallback: CapacityFallback?
        /// The same for the weekly leg — nil when the weekly leg decided, or
        /// when it was never consulted because the session leg decided first.
        let weeklyCapacityFallback: CapacityFallback?
        let decision: Decision
    }

    // MARK: - Evaluation

    /// Full evaluation, one trace per provider (in panel order). Per
    /// provider — comparing across providers is meaningless, a Claude
    /// session % and a Codex session % aren't interchangeable — the primary
    /// objective is maximizing total capacity: badge the account whose
    /// capacity would otherwise expire unused (issue #19 for the session
    /// window, issue #21 for weekly-scoped ones).
    ///
    /// Three strictly prioritized legs, never a numeric comparison between
    /// them: the session leg first, then the weekly leg, then the v2 behavior
    /// wholesale (most 5-hour-session headroom wins, subject to the vetoes and
    /// the anti-flapping margin, with the pace override possibly moving the
    /// badge to a runner-up projected to outlast the winner). Session and
    /// weekly at-risk are measured in percents of differently sized windows,
    /// and the API never exposes the ratio between them, so any arithmetic
    /// across the two would be meaningless — priority is the only honest
    /// combination.
    ///
    /// Through v4 the session leg's priority was justified as "the shorter
    /// clock wins": capacity expiring in hours beats capacity expiring in
    /// days. That confused urgency with scarcity. A session window is
    /// throughput drawn from the weekly budget and reissued every few hours,
    /// so letting one lapse normally costs nothing, while weekly quota unspent
    /// at the weekly reset is gone for good — the shorter clock governs the
    /// *less* scarce resource. v5 keeps the ordering but narrows the session
    /// leg to the cases where a session window really is lost capacity, so it
    /// no longer pre-empts the weekly leg on capacity that was never at stake;
    /// `refillsBeforeWeeklyReset` is where that is decided.
    ///
    /// `weeklyBurnRates` is keyed by account id and then by limit id, since
    /// an account can have several weekly-scoped windows (`weekly_all`,
    /// model-scoped ones like Fable, a Codex secondary window).
    static func evaluate(
        accounts: [AccountMeta],
        states: [String: AccountDisplayState],
        sessionProjections: [String: Date] = [:],
        sessionBurnRates: [String: Double] = [:],
        weeklyBurnRates: [String: [String: Double]] = [:],
        quotas: [String: Quota] = [:],
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
            // member's plan is known (and sane), whether hand-picked or
            // detected. One unknown anywhere and the whole group runs on
            // equal weights — silently mixing known and unknown weights is
            // worse than assuming equality.
            let allKnown = members.allSatisfy { (quotas[$0.id]?.multiplier ?? 0) > 0 }
            let weighting: QuotaWeighting = allKnown ? .quotaWeighted : .equalWeightsAssumed
            var effectiveMultipliers: [String: Double] = [:]
            for member in members {
                effectiveMultipliers[member.id] =
                    allKnown ? quotas[member.id]!.multiplier : 1
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
            // The weekly-scoped windows each member is being measured on, and
            // the same pooled demand computed over them (issue #21). A member
            // contributes its fastest-filling weekly window: its windows all
            // measure the same week from different angles, so summing them
            // would double-count model-scoped usage, which also lands in the
            // overall weekly window.
            var windowsByAccount: [String: [LimitStatus]] = [:]
            var weeklyRate: [String: Double] = [:]
            for member in members {
                let windows = weeklyWindows(in: states[member.id]?.limits ?? [])
                windowsByAccount[member.id] = windows
                let rates = weeklyBurnRates[member.id] ?? [:]
                let fastest = windows.compactMap { rates[$0.id] }.max()
                if let fastest { weeklyRate[member.id] = fastest }
            }
            let weeklyAggregatePace = members.reduce(0.0) {
                $0 + max(0, weeklyRate[$1.id] ?? 0)
                    * (effectiveMultipliers[$1.id] ?? 1) / 100
            }
            var candidates = members.map { account in
                candidateTrace(
                    account: account, state: states[account.id],
                    projection: sessionProjections[account.id],
                    burnRate: sessionBurnRates[account.id],
                    weeklyBurnRate: weeklyRate[account.id],
                    quota: quotas[account.id], now: now)
            }
            attachAtRisk(
                to: &candidates, windows: windowsByAccount,
                aggregatePace: aggregatePace,
                effectiveMultipliers: effectiveMultipliers, now: now)
            attachWeeklyAtRisk(
                to: &candidates, windows: windowsByAccount,
                aggregatePace: weeklyAggregatePace,
                effectiveMultipliers: effectiveMultipliers, now: now)
            let (decision, fallback, weeklyFallback) = decision(
                for: candidates, groupSize: members.count,
                aggregatePace: aggregatePace, weeklyAggregatePace: weeklyAggregatePace)
            return GroupTrace(
                provider: provider,
                candidates: candidates,
                aggregatePace: aggregatePace,
                weeklyAggregatePace: weeklyAggregatePace,
                quotaWeighting: weighting,
                capacityFallback: fallback,
                weeklyCapacityFallback: weeklyFallback,
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
        weeklyBurnRates: [String: [String: Double]] = [:],
        quotas: [String: Quota] = [:],
        now: Date = Date()
    ) -> [String: Badge] {
        var result: [String: Badge] = [:]
        for trace in evaluate(
            accounts: accounts, states: states,
            sessionProjections: sessionProjections,
            sessionBurnRates: sessionBurnRates,
            weeklyBurnRates: weeklyBurnRates,
            quotas: quotas, now: now) {
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
        weeklyBurnRate: Double?,
        quota: Quota?,
        now: Date
    ) -> CandidateTrace {
        let session = state.flatMap { sessionLimit(in: $0.limits) }
        let pace = paceSignal(
            projection: projection, sessionReset: session?.resetsAt, now: now)

        let eligibility: Eligibility
        if state?.needsReauth == true {
            eligibility = .vetoedNeedsReauth
        } else if let state, session != nil {
            // Week-scoped windows only, from the same classifier the weekly
            // leg uses: a spent five-hour sub-limit doesn't mean the week is
            // gone, which is the whole premise of this veto.
            if let spent = weeklyWindows(in: state.limits).first(where: {
                $0.percent >= weeklyExhaustedPercent
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
            sessionWindowSeconds: session?.windowSeconds,
            burnRate: burnRate,
            quota: quota,
            eligibility: eligibility,
            pace: pace,
            atRiskUnits: nil,
            atRiskPercent: nil,
            weeklyBurnRate: weeklyBurnRate,
            weeklyName: nil,
            weeklyPercent: nil,
            weeklyResetsAt: nil,
            weeklyAtRiskUnits: nil,
            weeklyAtRiskPercent: nil)
    }

    /// Computes each eligible candidate's at-risk capacity in place, in
    /// pooled quota units (headroom% × multiplier ÷ 100). The coverage term
    /// is the *other* eligible accounts' combined session headroom in the
    /// same units — the capacity that could absorb the group's demand
    /// instead. The own-percent mirror is stored alongside for display.
    ///
    /// A session window that lapses is usually not a loss at all (v5), which
    /// `sessionRefills` decides — see `refillsBeforeWeeklyReset`.
    private static func attachAtRisk(
        to candidates: inout [CandidateTrace], windows: [String: [LimitStatus]],
        aggregatePace: Double, effectiveMultipliers: [String: Double], now: Date
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
            let refills = refillsBeforeWeeklyReset(
                sessionResetsAt: candidates[index].sessionResetsAt,
                sessionWindowSeconds: candidates[index].sessionWindowSeconds,
                weeklyWindows: windows[candidates[index].accountID] ?? [])
            let units =
                refills
                ? 0
                : atRiskCapacity(
                    headroom: headroomUnits,
                    resetsAt: candidates[index].sessionResetsAt,
                    aggregatePace: aggregatePace,
                    coverage: totalHeadroom - headroomUnits,
                    now: now)
            candidates[index].sessionRefills = refills
            candidates[index].atRiskUnits = units
            candidates[index].atRiskPercent = units * 100 / multiplier
        }
    }

    /// Whether a whole fresh session window opens before this account's
    /// earliest weekly reset — in which case the current session window
    /// expiring costs nothing and must not win the session leg (v5).
    ///
    /// The session leg was written as if an expiring session window were lost
    /// capacity. It generally isn't: **a session window is throughput, not
    /// stock.** Its allowance is drawn from the weekly budget and replaced
    /// every `windowSeconds`, so declining to spend one leaves the quota
    /// untouched and spendable in the next. The only capacity that truly
    /// vanishes is weekly quota unspent at the weekly reset — which is the
    /// weekly leg's business.
    ///
    /// So an expiring session window is a real loss in exactly one shape the
    /// clock can see: when the weekly reset lands so soon after it that the
    /// replacement window is cut short, making this one the last full chance
    /// to spend that week's remainder. Concretely — session resetting at `S`
    /// with length `L`, earliest weekly reset at `W` — the successor window
    /// runs `[S, S+L]` and only fits when `W > S + L`.
    ///
    /// Deliberate consequences:
    ///
    /// - The session leg now fires rarely: only in the run-up to a weekly
    ///   reset, or for an account with no weekly window at all (nothing
    ///   bounds its sessions, so every one of them is throughput that is
    ///   genuinely gone). That is the point — before v5 the leg claimed the
    ///   verdict on capacity that was never scarce, and because it is tried
    ///   first it did so ahead of the weekly leg's real losses.
    /// - The mirror case is not modelled: an account can also be
    ///   session-*throughput*-bound, holding more weekly headroom than the
    ///   remaining session windows before `W` can physically deliver, and
    ///   then every window really does matter. Detecting it needs the ratio
    ///   between a session window's allowance and a week's, which the API
    ///   never states. Erring this way keeps the leg quiet instead of letting
    ///   it speak on a guess.
    private static func refillsBeforeWeeklyReset(
        sessionResetsAt: Date?, sessionWindowSeconds: TimeInterval?,
        weeklyWindows: [LimitStatus]
    ) -> Bool {
        guard let sessionResetsAt else { return false }
        // No stated length: assume the standard five-hour window rather than
        // give up on the gate, since the successor's length is the whole
        // question and every provider seen so far uses it.
        let length = sessionWindowSeconds ?? 5 * 3600
        // No weekly window bounds this account: sessions are the only budget
        // it has, so a lapsed one is capacity that never comes back.
        guard let earliestWeeklyReset = weeklyWindows.compactMap(\.resetsAt).min() else {
            return false
        }
        return earliestWeeklyReset > sessionResetsAt.addingTimeInterval(length)
    }

    /// The weekly-leg mirror of `attachAtRisk` (issue #21): the same
    /// `atRiskCapacity` formula, applied to each eligible candidate's
    /// weekly-scoped windows instead of its session window, in pooled quota
    /// units of a weekly window (one full Pro week = 1.0).
    ///
    /// One rule governs both sides of the formula: **an account's weekly
    /// capacity is bounded by its tightest weekly window.** Model-scoped usage
    /// also lands in the overall weekly window, so whichever window runs out
    /// first limits both how much of the week's demand an account can absorb
    /// on someone else's behalf (its `coverage` contribution) and how much of
    /// its own headroom prioritizing it can save (its at-risk). Both therefore
    /// use each account's *minimum* headroom.
    ///
    /// Its consequences, both acknowledged:
    ///
    /// - The account still keeps the window with the largest at-risk, since
    ///   resets differ: capacity behind an earlier reset expires sooner. Only
    ///   the clock varies — the amount is the same bound for every window — so
    ///   this no longer compares incommensurable budgets, it picks a deadline.
    /// - A roomy overall weekly window sitting behind a spent model-scoped one
    ///   is understated: the account could do plenty of non-Fable work the
    ///   Fable window can't constrain. That direction is deliberate — this leg
    ///   stays quiet rather than promising capacity that a cap forbids.
    private static func attachWeeklyAtRisk(
        to candidates: inout [CandidateTrace], windows: [String: [LimitStatus]],
        aggregatePace: Double, effectiveMultipliers: [String: Double], now: Date
    ) {
        func headroomUnits(_ limit: LimitStatus, multiplier: Double) -> Double {
            max(0, 100 - limit.percent) * multiplier / 100
        }

        // Each eligible account's absorbable weekly capacity: its tightest
        // window's headroom. Vetoed accounts are excluded here, so they
        // neither rank nor count as coverage.
        let eligible = candidates.indices.filter { candidates[$0].eligibility == .eligible }
        var absorbable: [Int: Double] = [:]
        for index in eligible {
            let accountID = candidates[index].accountID
            let multiplier = effectiveMultipliers[accountID] ?? 1
            absorbable[index] =
                (windows[accountID] ?? [])
                .map { headroomUnits($0, multiplier: multiplier) }
                .min() ?? 0
        }
        let totalAbsorbable = absorbable.values.reduce(0, +)

        for index in eligible {
            let accountID = candidates[index].accountID
            let multiplier = effectiveMultipliers[accountID] ?? 1
            let coverage = totalAbsorbable - (absorbable[index] ?? 0)
            // Every window is evaluated on the account's *binding* headroom,
            // not its own: model-scoped usage also lands in the overall weekly
            // window, so the tightest window caps what prioritizing this
            // account can actually save — the same argument that makes
            // `absorbable` a minimum, applied in the same direction. Without
            // the cap an account with a spare model window behind a nearly
            // spent overall weekly window (Fable 20%, Weekly 90%) reported
            // Fable's whole headroom as savable and could win the leg on
            // capacity the weekly cap forbids it to spend.
            //
            // Windows are still scanned one by one, because only the reset
            // clock varies between them and capacity behind an earlier reset
            // expires sooner — which is exactly what this leg looks for.
            let binding = absorbable[index] ?? 0
            var best: (units: Double, window: LimitStatus)?
            for window in windows[accountID] ?? [] {
                let units = atRiskCapacity(
                    headroom: binding,
                    resetsAt: window.resetsAt,
                    aggregatePace: aggregatePace,
                    coverage: coverage,
                    now: now)
                if best == nil || units > best!.units { best = (units, window) }
            }
            // No weekly-scoped window at all: nothing for this leg to say.
            guard let best else { continue }
            candidates[index].weeklyName = best.window.name
            candidates[index].weeklyPercent = best.window.percent
            candidates[index].weeklyResetsAt = best.window.resetsAt
            candidates[index].weeklyAtRiskUnits = best.units
            candidates[index].weeklyAtRiskPercent = best.units * 100 / multiplier
        }
    }

    /// Capacity that will vanish unused at this account's next reset of the
    /// window under consideration unless the user burns this account first
    /// (issue #19). Window-agnostic: both legs use it, the session leg over
    /// session windows and the weekly leg over weekly-scoped ones — the
    /// caller is responsible for keeping every argument in one window's
    /// units. All quantities are in pooled quota units (one full Pro window
    /// = 1.0) so that different plan tiers pool honestly; with equal weights
    /// the math degrades to plain percents ÷ 100.
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

    /// One leg's ranking input for a single candidate, already reduced to
    /// that window's own units so `expiringVerdict` never has to know which
    /// leg it is serving.
    private struct RiskEntry {
        let accountID: String
        /// At-risk capacity in pooled quota units of this leg's window.
        let units: Double
        /// The same, in the account's own window percent (for the tooltip).
        let percent: Double
        /// When this leg's window resets.
        let resetsAt: Date?
        /// The window's display name; nil for the session window, which the
        /// v3 tooltip never named.
        let scopeName: String?
    }

    /// The group verdict over already-traced candidates: the session
    /// expiring-first leg (v3) when it has a confident signal, then the
    /// weekly leg (v4, issue #21), then the v2 ranking wholesale — with each
    /// leg's fallback reason preserved for the debug view.
    ///
    /// The legs are strictly ordered, never numerically compared: the session
    /// leg is tried first because it speaks to the nearer deadline, and a leg
    /// is consulted only when every leg before it stood down. What keeps that
    /// ordering honest is that the session leg now stands down whenever the
    /// window it is looking at simply refills (v5, see `attachAtRisk`) — so it
    /// pre-empts the weekly leg only when a session window really is the last
    /// chance to spend the week.
    private static func decision(
        for candidates: [CandidateTrace], groupSize: Int,
        aggregatePace: Double, weeklyAggregatePace: Double
    ) -> (Decision, CapacityFallback?, CapacityFallback?) {
        guard groupSize >= 2 else { return (.groupTooSmall, nil, nil) }

        // Eligible candidates, best (lowest session percent) first. Vetoed
        // accounts dropped out here, so no leg can resurrect them.
        let ranked = candidates
            .filter { $0.eligibility == .eligible }
            .sorted { ($0.sessionPercent ?? 100) < ($1.sessionPercent ?? 100) }
        guard let winner = ranked.first else { return (.allVetoed, nil, nil) }

        // Leg 1 — session (v3, issue #19). Gated hard: a confident "this will
        // vanish in the next few hours" beats everything else.
        let session = expiringVerdict(
            entries: ranked.map {
                RiskEntry(
                    accountID: $0.accountID, units: $0.atRiskUnits ?? 0,
                    percent: $0.atRiskPercent ?? 0, resetsAt: $0.sessionResetsAt,
                    scopeName: nil)
            },
            pace: aggregatePace, floor: atRiskFloor, margin: atRiskMargin, leg: .session)
        if let award = session.award { return (.expiringFirst(award), nil, nil) }

        // Leg 2 — weekly (v4, issue #21). Reached only because the session
        // leg stood down, and judged entirely in weekly units.
        let weekly = expiringVerdict(
            entries: ranked.map {
                RiskEntry(
                    accountID: $0.accountID, units: $0.weeklyAtRiskUnits ?? 0,
                    percent: $0.weeklyAtRiskPercent ?? 0, resetsAt: $0.weeklyResetsAt,
                    scopeName: $0.weeklyName)
            },
            pace: weeklyAggregatePace, floor: weeklyAtRiskFloor,
            margin: weeklyAtRiskMargin, leg: .weekly)
        if let award = weekly.award {
            return (.expiringFirst(award), session.fallback, nil)
        }
        let fallback = session.fallback
        let weeklyFallback = weekly.fallback

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
                fallback, weeklyFallback
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
            fallback, weeklyFallback
        )
    }

    /// One expiring-capacity leg's verdict over its own units: either an
    /// award, or the reason the leg stood down. Exactly one of the two is
    /// non-nil. `entries` arrive in headroom order, which ties fall back to.
    ///
    /// **Size qualifies; the clock ranks** (v5). Through v4 the leader was
    /// simply whoever had the most at risk, and `resetsAt` was read only to
    /// fill in the tooltip — so an account with more capacity expiring days
    /// from now outranked one with slightly less expiring tonight, and the
    /// badge said "use it before its reset" about the window resetting last.
    /// The nearer deadline wins instead: a larger pile behind a later reset is
    /// still there to be worked through once the closer one has passed, and
    /// the reverse is not true. `floor` still decides which entries are worth
    /// acting on at all, and size only settles rivals whose resets land within
    /// `deadlineMargin` of each other.
    ///
    /// Ranking on a fixed timestamp rather than a refitted estimate also makes
    /// the verdict steadier between polls than the size ordering it replaces.
    private static func expiringVerdict(
        entries: [RiskEntry], pace: Double, floor: Double, margin: Double,
        leg: ExpiringAward.Leg
    ) -> (award: ExpiringAward?, fallback: CapacityFallback?) {
        guard pace > 0 else { return (nil, .noAggregatePace) }
        guard !entries.isEmpty else { return (nil, .belowFloor(topAtRiskUnits: 0)) }

        // Only entries with a meaningful amount expiring get a say. A missing
        // reset can't be ranked on a deadline and is unreachable anyway —
        // positive at-risk implies a live future reset.
        let qualified = entries.filter { $0.units >= floor && $0.resetsAt != nil }
        guard !qualified.isEmpty else {
            return (nil, .belowFloor(topAtRiskUnits: entries.map(\.units).max() ?? 0))
        }

        // The earliest deadline, and everyone effectively sharing it.
        let earliest = qualified.compactMap(\.resetsAt).min()!
        let deadline = earliest.addingTimeInterval(deadlineMargin)
        let contenders = qualified
            .filter { $0.resetsAt! <= deadline }
            .sorted { $0.units > $1.units }
        let leader = contenders[0]

        // Same-deadline rivals are separated on size, under the leg's own
        // anti-flap margin — the v4 comparison, now scoped to the only case
        // where the clock has nothing to say.
        if contenders.count >= 2 {
            let gap = leader.units - contenders[1].units
            if gap < margin {
                return (
                    nil,
                    .atRiskTooClose(
                        leaderID: leader.accountID, runnerUpID: contenders[1].accountID,
                        gapUnits: gap)
                )
            }
        }

        let nextDeadline = qualified.compactMap(\.resetsAt).filter { $0 > deadline }.min()
        return (
            ExpiringAward(
                leg: leg,
                badgedID: leader.accountID,
                atRiskUnits: leader.units,
                atRiskGapUnits: contenders.count >= 2
                    ? leader.units - contenders[1].units : nil,
                deadlineLeadSeconds: nextDeadline.map {
                    $0.timeIntervalSince(leader.resetsAt!)
                },
                badge: Badge(
                    expiring: ExpiringCapacity(
                        // The tooltip speaks the account's own percent.
                        points: leader.percent, resetsAt: leader.resetsAt!,
                        scopeName: leader.scopeName))),
            nil
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

    /// The short "session" window among an account's limits. The stated
    /// duration decides when there is one — Codex sends
    /// `limit_window_seconds`, Claude's kinds name their windows — and both
    /// builders sort the session slot first, so the first sub-day window is
    /// it. Limits that state no duration fall back to the name match ("Session"
    /// from both providers) and then to the front of the list.
    static func sessionLimit(in limits: [LimitStatus]) -> LimitStatus? {
        let stated = limits.first {
            guard let seconds = $0.windowSeconds else { return false }
            return seconds < LimitStatus.multiDayThreshold
        }
        return stated ?? limits.first { $0.name == "Session" } ?? limits.first
    }

    /// The week-scoped windows: the overall weekly window, model-scoped 7-day
    /// windows (Fable, Opus…), Codex's secondary window. These are what the
    /// weekly leg (issue #21) and the exhaustion veto operate on.
    ///
    /// Length decides, not "everything that isn't the session slot". Codex
    /// labels an account's additional per-model limits "<name> 5h" and
    /// "<name> 7d" (`CodexProvider.buildLimits`), so the exclusion rule let a
    /// five-hour window into the weekly leg — where a %/hour pace is ~34× the
    /// same usage measured on a seven-day window, enough for one such window
    /// to swamp the pooled weekly demand, and where its hours-away reset got
    /// reported as a week's worth of capacity expiring. A limit that states no
    /// duration keeps the old exclusion behavior, since nothing better is
    /// known about it.
    static func weeklyWindows(in limits: [LimitStatus]) -> [LimitStatus] {
        let session = sessionLimit(in: limits)
        return limits.filter { limit in
            guard limit.id != session?.id else { return false }
            guard let seconds = limit.windowSeconds else { return true }
            return seconds >= LimitStatus.multiDayThreshold
        }
    }
}
