import Foundation

/// Pure detection behind the "a better account is available" notification
/// (issue #24). Written in the same style as `BestAccount`: everything it
/// needs arrives as plain values — accounts, the badges the ranking already
/// awarded, session burn rates, the per-group notification memory, and `now` —
/// so no history store, no UserDefaults and no clock is touched inside the
/// decision, and the whole thing is unit-testable against handcrafted
/// fixtures.
///
/// It does not rank anything: `BestAccount` already decided who deserves the
/// badge, and re-deriving that here would let the notification and the panel
/// tell different stories. This function only answers the follow-up question
/// — *is the user burning the wrong account right now, and have we said so
/// recently?* — and renders the copy, which mirrors the badge tooltip
/// (`BestBadge.tooltip`) case for case.
enum SwitchSuggestion {

    // MARK: - Tuning constants

    /// Minimum session burn rate (percentage points per hour) for an account
    /// to count as "in use". Purely a jitter filter: the history store fits a
    /// regression over recent samples, so a flat, idle window still yields a
    /// small non-zero slope (and rounding of the provider's integer-ish
    /// percents adds more). At 1 pp/h an account would need ~100 hours to
    /// spend one session window — an order of magnitude below any real
    /// working pace (10–30 pp/h burns a five-hour window as intended), so
    /// nothing that matters is excluded and noise cannot fake activity.
    /// Inclusive: a rate exactly at the floor counts as burning.
    static let activeBurnRateFloor = 1.0

    /// Minimum spacing between switch notifications for one provider group,
    /// regardless of how the recommendation changes. Matched to the issue's
    /// ~30 minutes and to the app's own rhythm: the poll loop runs every 5
    /// minutes, so this caps a group at one banner per six polls, and it
    /// equals `BestAccount.overrideMargin` — the pace difference the ranking
    /// itself considers meaningful. Advice this fine-grained is not worth
    /// interrupting anyone more often. Elapsed time is compared inclusively:
    /// a suggestion exactly 30 minutes after the last one may fire.
    static let cooldown: TimeInterval = 30 * 60

    /// How long the *same* `(from, to)` pair stays suppressed after being
    /// notified, even if the recommendation flips away and back in between
    /// (which the edge trigger alone would let through). Four hours is a
    /// little under one session window (five hours), so at most one reminder
    /// per pair per session's worth of work: long enough that a flapping
    /// ranking cannot nag, short enough that a genuinely new stretch of work
    /// hours later still gets told. Inclusive, like `cooldown`: at exactly
    /// four hours the pair is eligible again.
    static let repeatSuppression: TimeInterval = 4 * 3600

    // MARK: - Model

    /// A recommendation's identity: who is being burned and who should be
    /// used instead. The anti-spam gates are all keyed on this, because it is
    /// exactly what the notification says — a new pair is new advice, an
    /// unchanged pair is a repeat.
    struct Pair: Hashable {
        /// Account id currently being burned.
        let from: String
        /// Account id the badge recommends.
        let to: String
    }

    /// Why the switch is worth making, taken straight from the badge payload
    /// so the wording can't diverge from the tooltip. Data, not display
    /// strings; `body(for:now:)` renders it.
    enum Reason: Equatable {
        /// Expiring-first (v3): session capacity vanishing at the reset.
        case expiringSession(points: Double, resetsAt: Date)
        /// Expiring-first (v4): capacity vanishing in a weekly-scoped window,
        /// named so "≈69% expires in 3d" can't read as a session figure.
        case expiringScope(points: Double, resetsAt: Date, scopeName: String)
        /// Pace-aware (v2): how much session the target has left at the
        /// group's current pace.
        case pace(exhaustsAt: Date)
        /// Static (v1): a badge with no payload — headroom only.
        case headroom
    }

    /// One provider group's recommendation, with the copy already rendered
    /// (rendering needs `now`, which only this function has).
    struct Suggestion: Equatable {
        let provider: ProviderID
        /// The account being burned.
        let fromAccountID: String
        let fromLabel: String
        /// The badged account to switch to. Also encoded into the
        /// notification identifier, so a future action button can act on it.
        let toAccountID: String
        let toLabel: String
        let reason: Reason
        /// "Switch to Personal".
        let title: String
        /// The reason, worded like the badge tooltip.
        let body: String

        var pair: Pair { Pair(from: fromAccountID, to: toAccountID) }
    }

    /// What one provider group remembers about its own notifications.
    ///
    /// Deliberately *not* persisted — `UsageNotifier` keeps this in memory for
    /// the lifetime of the process. Consequence, accepted: after a relaunch
    /// the first refresh cycle can repeat advice given shortly before quitting.
    /// That is the better failure direction — a launch is user-initiated and
    /// usually starts a fresh stretch of work, where the advice is worth
    /// hearing again — and it avoids persisting timestamps that would go stale
    /// across days and silence a genuinely new situation. Nothing here is
    /// worth a UserDefaults schema.
    struct GroupState: Equatable {
        /// The pair of the most recent notification for this group — the edge
        /// trigger. Cleared when the situation resolves (nothing burning, no
        /// badge, or the user is already on the badged account), which re-arms
        /// the edge so a genuinely new stretch of work can be told again.
        var lastPair: Pair?
        /// When this group last notified, whatever the pair — the cooldown
        /// clock.
        var lastNotifiedAt: Date?
        /// When each pair was last notified — the long repeat-suppression
        /// clock. Pruned to the suppression window on every write, so it stays
        /// bounded.
        var pairsNotifiedAt: [Pair: Date] = [:]

        init(
            lastPair: Pair? = nil, lastNotifiedAt: Date? = nil,
            pairsNotifiedAt: [Pair: Date] = [:]
        ) {
            self.lastPair = lastPair
            self.lastNotifiedAt = lastNotifiedAt
            self.pairsNotifiedAt = pairsNotifiedAt
        }
    }

    /// Everything one evaluation produced: the banners to post (at most one
    /// per provider group) and the state to carry into the next cycle. The
    /// caller stores `state` verbatim — the gates are all expressed in it, so
    /// dropping it would disable the anti-spam.
    struct Outcome: Equatable {
        let suggestions: [Suggestion]
        let state: [ProviderID: GroupState]
    }

    // MARK: - Detection

    /// Per provider group: should we tell the user to switch, and may we?
    ///
    /// Three trigger conditions, all from issue #24 — something is actively
    /// burning (above `activeBurnRateFloor`), the group has a badge, and the
    /// badged account is not the one being burned — then three anti-spam
    /// gates: the edge trigger on the pair, the group cooldown, and the long
    /// per-pair repeat suppression. Groups are visited in panel order, and a
    /// group that yields nothing still updates its state (the edge re-arms).
    static func evaluate(
        accounts: [AccountMeta],
        badges: [String: BestAccount.Badge],
        sessionBurnRates: [String: Double],
        state: [ProviderID: GroupState],
        now: Date
    ) -> Outcome {
        // Group by provider, preserving panel order (as `BestAccount` does),
        // so a multi-group cycle posts in a stable, predictable order.
        var order: [ProviderID] = []
        var groups: [ProviderID: [AccountMeta]] = [:]
        for account in accounts {
            if groups[account.provider] == nil { order.append(account.provider) }
            groups[account.provider, default: []].append(account)
        }

        var newState = state
        var suggestions: [Suggestion] = []
        for provider in order {
            var group = newState[provider] ?? GroupState()
            defer { newState[provider] = group }

            guard
                let candidate = recommendation(
                    provider: provider, members: groups[provider] ?? [],
                    badges: badges, sessionBurnRates: sessionBurnRates, now: now)
            else {
                // Nothing to say: idle, no badge, or already on the best
                // account. Re-arm the edge trigger.
                group.lastPair = nil
                continue
            }

            // Edge trigger: the same advice we already gave, still true, is
            // not news. Absolute — while this stays the last notified pair it
            // never repeats, no matter how many cycles pass.
            if group.lastPair == candidate.pair { continue }
            // Group cooldown: at most one banner per group per window, even
            // when the pair keeps changing.
            if let last = group.lastNotifiedAt,
                now.timeIntervalSince(last) < cooldown { continue }
            // Long repeat suppression: this exact pair was notified recently
            // and has since flipped away and back.
            if let previous = group.pairsNotifiedAt[candidate.pair],
                now.timeIntervalSince(previous) < repeatSuppression { continue }

            suggestions.append(candidate)
            group.lastPair = candidate.pair
            group.lastNotifiedAt = now
            group.pairsNotifiedAt[candidate.pair] = now
            group.pairsNotifiedAt = group.pairsNotifiedAt.filter {
                now.timeIntervalSince($0.value) < repeatSuppression
            }
        }
        return Outcome(suggestions: suggestions, state: newState)
    }

    /// One group's raw recommendation, before any anti-spam gate: nil unless
    /// something is burning, the group carries a badge, and the two differ.
    private static func recommendation(
        provider: ProviderID,
        members: [AccountMeta],
        badges: [String: BestAccount.Badge],
        sessionBurnRates: [String: Double],
        now: Date
    ) -> Suggestion? {
        // "Current" = the fastest burner above the jitter floor. Fastest
        // rather than "most recently active": with two accounts genuinely in
        // use, the one consuming quota quickest is the one whose traffic is
        // worth redirecting. Panel order breaks exact ties (strict `>`).
        var current: (account: AccountMeta, rate: Double)?
        for member in members {
            guard let rate = sessionBurnRates[member.id], rate >= activeBurnRateFloor
            else { continue }
            if current == nil || rate > current!.rate { current = (member, rate) }
        }
        guard let current else { return nil }

        // The group's badge, if any — `BestAccount.winners` awards at most one
        // per provider, so the first member holding one is it.
        guard let badged = members.first(where: { badges[$0.id] != nil }),
            let badge = badges[badged.id]
        else { return nil }
        // Already doing the right thing: silence.
        guard badged.id != current.account.id else { return nil }

        let reason = reason(for: badge)
        return Suggestion(
            provider: provider,
            fromAccountID: current.account.id,
            fromLabel: current.account.displayLabel,
            toAccountID: badged.id,
            toLabel: badged.displayLabel,
            reason: reason,
            title: "Switch to \(badged.displayLabel)",
            body: body(for: reason, now: now))
    }

    // MARK: - Copy

    /// The badge payload's reason, in the same precedence the tooltip uses:
    /// an expiring-capacity payload wins, then a pace projection, then the
    /// static v1 case.
    static func reason(for badge: BestAccount.Badge) -> Reason {
        if let expiring = badge.expiring {
            if let scope = expiring.scopeName {
                return .expiringScope(
                    points: expiring.points, resetsAt: expiring.resetsAt, scopeName: scope)
            }
            return .expiringSession(points: expiring.points, resetsAt: expiring.resetsAt)
        }
        if let projected = badge.projectedExhaustion {
            return .pace(exhaustsAt: projected)
        }
        return .headroom
    }

    /// The notification body — the badge tooltip's sentences, reworded for a
    /// banner whose title already names the target ("its session" rather than
    /// the tooltip's bare "session", since the banner talks about the *other*
    /// account).
    static func body(for reason: Reason, now: Date) -> String {
        switch reason {
        case .expiringSession(let points, let resetsAt):
            return "≈\(percentText(points)) of its session expires in "
                + durationText(seconds: resetsAt.timeIntervalSince(now))
        case .expiringScope(let points, let resetsAt, let scopeName):
            // "Weekly" reads better lowercased inside the sentence, exactly as
            // in the tooltip; model-scoped windows keep their proper name
            // ("of its Fable").
            let name = scopeName == "Weekly" ? "weekly" : scopeName
            return "≈\(percentText(points)) of its \(name) expires in "
                + durationText(seconds: resetsAt.timeIntervalSince(now))
        case .pace(let exhaustsAt):
            return "≈\(durationText(seconds: exhaustsAt.timeIntervalSince(now))) "
                + "of session left at current pace"
        case .headroom:
            return "more session headroom right now"
        }
    }

    private static func percentText(_ points: Double) -> String {
        "\(Int(points.rounded()))%"
    }

    /// Coarse duration text: "3d 4h", "1h 10m", "12m", "moments". The single
    /// implementation in the app — `AccountSection.durationText(until:)`
    /// delegates here — so a notification and the badge tooltip can never
    /// word the same interval differently. Takes seconds rather than a date
    /// because this side of the app never reads the clock itself.
    static func durationText(seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "moments" }
        let totalMinutes = Int(seconds / 60)
        let days = totalMinutes / (60 * 24)
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}
