import Foundation

/// Pure ranking logic behind the "Best" badge (issue #4). Free of
/// `AccountStore` so it can be unit-tested against handcrafted fixtures —
/// the store's init touches UserDefaults/Keychain and starts the poll loop,
/// which tests must never do.
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

    /// Accounts to badge as the current "best bet": per provider — comparing
    /// across providers is meaningless, a Claude session % and a Codex
    /// session % aren't interchangeable — and only when the user tracks two
    /// or more of that provider's accounts, the eligible account with the
    /// most 5-hour-session headroom. Vetoes and the anti-flapping margin are
    /// deliberately strict: a wrong or twitchy hint is worse than none.
    static func winners(
        accounts: [AccountMeta], states: [String: AccountDisplayState]
    ) -> Set<String> {
        var result: Set<String> = []
        for providerAccounts in Dictionary(grouping: accounts, by: \.provider).values
        where providerAccounts.count >= 2 {
            // Session usage per eligible account, best (lowest) first.
            // Vetoed accounts — needs reauth, no data yet, or an exhausted
            // weekly window (session headroom is a mirage when the week is
            // already spent) — drop out entirely.
            let candidates: [(id: String, sessionPercent: Double)] = providerAccounts
                .compactMap { account in
                    guard let state = states[account.id],
                        !state.needsReauth,
                        let session = sessionLimit(in: state.limits)
                    else { return nil }
                    let weeklySpent = state.limits.contains {
                        $0.id != session.id && $0.percent >= weeklyExhaustedPercent
                    }
                    return weeklySpent ? nil : (account.id, session.percent)
                }
                .sorted { $0.sessionPercent < $1.sessionPercent }
            guard let winner = candidates.first else { continue }
            if candidates.count >= 2,
                candidates[1].sessionPercent - winner.sessionPercent < margin {
                continue  // too close to call — stay quiet rather than flap
            }
            result.insert(winner.id)
        }
        return result
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
