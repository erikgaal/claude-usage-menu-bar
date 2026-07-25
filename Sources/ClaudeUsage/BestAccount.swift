import Foundation

/// Pure ranking logic behind the "Best" badge (issue #4). Free of
/// `AccountStore` so it can be unit-tested against handcrafted fixtures —
/// the store's init touches UserDefaults/Keychain and starts the poll loop,
/// which tests must never do. Pace data arrives the same way: the store
/// queries its history store and passes plain projections in, so no history
/// reads happen here.
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

    /// What the badge needs to know beyond the winner's identity.
    struct Badge: Equatable {
        /// When the badged account's session is projected to run out — drives
        /// the "≈2h 10m of session left" tooltip. Nil (keep the static v1
        /// tooltip) when there is no usable pace signal: no projection, a
        /// stale one already in the past, or one landing after the session
        /// resets anyway.
        let projectedExhaustion: Date?
    }

    /// Accounts to badge as the current "best bet", keyed by account id: per
    /// provider — comparing across providers is meaningless, a Claude session
    /// % and a Codex session % aren't interchangeable — and only when the
    /// user tracks two or more of that provider's accounts, the eligible
    /// account with the most 5-hour-session headroom. Vetoes and the
    /// anti-flapping margin are deliberately strict: a wrong or twitchy hint
    /// is worse than none.
    ///
    /// Pace override (v2): when the headroom winner *and* its runner-up both
    /// have session projections and the runner-up is projected to outlast the
    /// winner by at least `overrideMargin`, the badge moves to the
    /// longer-lasting account. A missing projection means "not currently
    /// burning" — it provides no pace signal and must never read as
    /// "exhausts immediately" or auto-win; without both signals the headroom
    /// verdict stands unchanged.
    static func winners(
        accounts: [AccountMeta],
        states: [String: AccountDisplayState],
        sessionProjections: [String: Date] = [:],
        now: Date = Date()
    ) -> [String: Badge] {
        var result: [String: Badge] = [:]
        for providerAccounts in Dictionary(grouping: accounts, by: \.provider).values
        where providerAccounts.count >= 2 {
            // Session usage per eligible account, best (lowest) first.
            // Vetoed accounts — needs reauth, no data yet, or an exhausted
            // weekly window (session headroom is a mirage when the week is
            // already spent) — drop out entirely, so the pace override below
            // can never resurrect them.
            let candidates: [(id: String, sessionPercent: Double, horizon: Date?)] =
                providerAccounts
                .compactMap { account in
                    guard let state = states[account.id],
                        !state.needsReauth,
                        let session = sessionLimit(in: state.limits)
                    else { return nil }
                    let weeklySpent = state.limits.contains {
                        $0.id != session.id && $0.percent >= weeklyExhaustedPercent
                    }
                    guard !weeklySpent else { return nil }
                    let horizon = horizon(
                        projection: sessionProjections[account.id],
                        sessionReset: session.resetsAt,
                        now: now)
                    return (account.id, session.percent, horizon)
                }
                .sorted { $0.sessionPercent < $1.sessionPercent }
            guard var winner = candidates.first else { continue }
            if candidates.count >= 2,
                candidates[1].sessionPercent - winner.sessionPercent < margin {
                continue  // too close to call — stay quiet rather than flap
            }
            // Pace override: only the headroom winner and its runner-up are
            // weighed — both eligible by construction — and only when both
            // carry a pace signal.
            if candidates.count >= 2,
                let winnerHorizon = winner.horizon,
                let runnerUpHorizon = candidates[1].horizon,
                runnerUpHorizon.timeIntervalSince(winnerHorizon) >= overrideMargin {
                winner = candidates[1]
            }
            result[winner.id] = Badge(projectedExhaustion: tooltipDate(for: winner.horizon))
        }
        return result
    }

    /// One candidate's pace signal. Nil when there is no projection or it is
    /// already in the past — stale history must not read as "exhausts
    /// immediately"; a truly spent session shows up in its percent, which the
    /// headroom ranking already sees. `.distantFuture` when the projection
    /// lands at/after the session reset: at the current pace the account
    /// outlasts its whole window, which beats any pre-reset projection but is
    /// not a date worth showing.
    private static func horizon(
        projection: Date?, sessionReset: Date?, now: Date
    ) -> Date? {
        guard let projection, projection > now else { return nil }
        if let sessionReset, projection >= sessionReset { return .distantFuture }
        return projection
    }

    /// The projection surfaced in the tooltip: real dates only — the
    /// "outlasts the window" sentinel would render as an absurd duration.
    private static func tooltipDate(for horizon: Date?) -> Date? {
        horizon == .distantFuture ? nil : horizon
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
