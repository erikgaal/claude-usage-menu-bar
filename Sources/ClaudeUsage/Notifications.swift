import Combine
import Foundation

// UNUserNotificationCenter is thread-safe but predates Sendable annotations;
// its completion handlers run on a background queue by design.
@preconcurrency import UserNotifications

// MARK: - Scheduling seam

/// The slice of notification-center behavior `UsageNotifier` needs, in plain
/// values (identifier, title/body, fire date) so tests can substitute a
/// trivial spy. Tests must never reach the real center: the `swift test`
/// host *has* a bundle identifier, so the un-bundled guard below wouldn't
/// protect them, and the real center would prompt from the test runner.
@MainActor
protocol NotificationScheduling {
    /// Ask the system for permission; the OS only prompts the first time.
    func requestAuthorization()
    /// Queue a banner. `fireDate` nil → deliver immediately.
    func add(identifier: String, title: String, body: String, fireDate: Date?)
    /// Identifiers of scheduled-but-undelivered requests. The completion is
    /// invoked on the main actor (the real center reports on a background
    /// queue; the production wrapper hops back).
    func pendingIdentifiers(completion: @escaping @MainActor ([String]) -> Void)
    func removePending(identifiers: [String])
    func removeAllPending()
}

/// Production scheduler wrapping `UNUserNotificationCenter`.
@MainActor
final class SystemNotificationScheduler: NotificationScheduling {
    /// `UNUserNotificationCenter.current()` traps when the process has no
    /// bundle identity — the bare `swift build` binary, `swift run`, and the
    /// screenshot harness — so every access goes through this guard. Mock
    /// mode also lands here: fake data must never produce real notifications.
    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        #if DEBUG
            if Mock.isEnabled { return nil }
        #endif
        return UNUserNotificationCenter.current()
    }

    func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func add(identifier: String, title: String, body: String, fireDate: Date?) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = fireDate.map {
            UNTimeIntervalNotificationTrigger(
                timeInterval: max(1, $0.timeIntervalSinceNow), repeats: false)
        }
        center.add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }

    func pendingIdentifiers(completion: @escaping @MainActor ([String]) -> Void) {
        guard let center else {
            completion([])
            return
        }
        center.getPendingNotificationRequests { requests in
            let identifiers = requests.map(\.identifier)
            Task { @MainActor in completion(identifiers) }
        }
    }

    func removePending(identifiers: [String]) {
        center?.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeAllPending() {
        center?.removeAllPendingNotificationRequests()
    }
}

// MARK: - Notifier

/// Local-notification manager: alerts when a limit crosses the usage
/// threshold, when a hot limit's window resets, and when an account's
/// sign-in expires.
///
/// `AccountStore.refresh` hands it the state it's about to commit (old vs
/// new) once per poll; all event detection lives here so the store stays a
/// plain fetch-and-store loop.
@MainActor
final class UsageNotifier: ObservableObject {
    /// Alert when a limit reaches this percent. Fixed for v1; making it
    /// user-configurable only needs a settings control, not new diff logic.
    static let thresholdPercent: Double = 90

    private static let defaultsKey = "notificationsEnabled"
    private static let switchSuggestionsKey = "switchSuggestionsEnabled"

    private let scheduler: NotificationScheduling
    private let defaults: UserDefaults

    /// Per-provider notification memory behind the switch suggestions
    /// (issue #24). In memory only — see `SwitchSuggestion.GroupState` for the
    /// reasoning and the relaunch consequence.
    private var switchState: [ProviderID: SwitchSuggestion.GroupState] = [:]

    /// User toggle from the panel footer. Enabling requests system
    /// authorization (the OS only prompts the first time); disabling drops
    /// any scheduled reset alerts so nothing fires while off.
    @Published var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            defaults.set(isEnabled, forKey: Self.defaultsKey)
            // Either direction forgets what we suggested: the advice is only
            // meaningful next to the situation it described, and a user who
            // just turned notifications back on should hear the current
            // recommendation rather than be silenced by a stale edge.
            switchState.removeAll()
            if isEnabled {
                scheduler.requestAuthorization()
            } else {
                scheduler.removeAllPending()
            }
        }
    }

    /// The advisory half of the feature: "Suggest account switches" in the
    /// panel footer, gated by `isEnabled` (limit alerts are urgent, switch
    /// advice is not, and the issue expects one without the other to be
    /// possible). Defaults to on, so enabling notifications delivers the whole
    /// feature; opting out is one click and is remembered under its own key.
    /// Toggling clears the notification memory, so switching it off stops
    /// suggestions on the very next cycle and switching it on doesn't inherit
    /// a stale edge.
    @Published var suggestsSwitches: Bool {
        didSet {
            guard oldValue != suggestsSwitches else { return }
            defaults.set(suggestsSwitches, forKey: Self.switchSuggestionsKey)
            switchState.removeAll()
        }
    }

    /// Production configuration. A separate overload because a default
    /// argument of `SystemNotificationScheduler()` would be evaluated in a
    /// nonisolated context (rejected pre-SE-0411 with tools 5.9).
    convenience init() {
        self.init(scheduler: SystemNotificationScheduler(), defaults: .standard)
    }

    /// Injection point for tests: a spy scheduler (never the real center)
    /// and an isolated defaults suite.
    init(scheduler: NotificationScheduling, defaults: UserDefaults) {
        self.scheduler = scheduler
        self.defaults = defaults
        // Assigning in init doesn't trip didSet, so restoring the saved value
        // never re-prompts for authorization at launch.
        isEnabled = defaults.bool(forKey: Self.defaultsKey)
        // Absent key → on: `bool(forKey:)` alone would default the advisory
        // alerts off and leave the feature invisible to anyone who never opens
        // the footer.
        suggestsSwitches =
            defaults.object(forKey: Self.switchSuggestionsKey) as? Bool ?? true
    }

    // MARK: - Event detection

    /// Called by `AccountStore.refresh` just before it commits `new`, so
    /// `old` is the previous poll's snapshot (nil on the first fetch).
    func accountDidUpdate(
        _ account: AccountMeta, old: AccountDisplayState?, new: AccountDisplayState
    ) {
        guard isEnabled else { return }

        // Sign-in expired: only on the false→true flip, not on every poll
        // that keeps failing while the account waits for the user.
        if new.needsReauth, old?.needsReauth != true {
            post(
                title: account.displayLabel,
                body: "Sign-in expired — open the menu to sign in again.")
        }

        // Threshold: edge-detect against the previous sample so a limit
        // parked above the threshold alerts once per crossing, not once per
        // poll. With no previous sample (first fetch after launch) we stay
        // quiet — an already-hot limit would otherwise re-alert on every
        // app start.
        let previousPercent = Dictionary(
            (old?.limits ?? []).map { ($0.id, $0.percent) },
            uniquingKeysWith: { first, _ in first })
        for limit in new.limits {
            guard let previous = previousPercent[limit.id],
                previous < Self.thresholdPercent,
                limit.percent >= Self.thresholdPercent
            else { continue }
            post(
                title: account.displayLabel,
                body: "\(limit.name) limit at \(Int(limit.percent.rounded()))%")
        }

        rescheduleResetAlerts(for: account, limits: new.limits)
    }

    // MARK: - Switch suggestions

    /// Called by `AccountStore` once per *completed* refresh cycle with the
    /// cross-account picture the panel would show: every account, the badges
    /// the ranking awarded, and each account's session burn rate. Unlike
    /// `accountDidUpdate` this is deliberately group-level — "you're burning
    /// the wrong account" is a comparison, so evaluating it per account would
    /// judge half-refreshed data and could post twice for one cycle.
    ///
    /// The decision itself is `SwitchSuggestion.evaluate` (pure); this method
    /// owns only the toggles, the notification memory, and the posting.
    func groupsDidUpdate(
        accounts: [AccountMeta],
        badges: [String: BestAccount.Badge],
        sessionBurnRates: [String: Double],
        now: Date = Date()
    ) {
        guard isEnabled, suggestsSwitches else { return }
        let outcome = SwitchSuggestion.evaluate(
            accounts: accounts, badges: badges, sessionBurnRates: sessionBurnRates,
            state: switchState, now: now)
        switchState = outcome.state
        for suggestion in outcome.suggestions {
            scheduler.add(
                identifier: Self.switchIdentifier(for: suggestion, now: now),
                title: suggestion.title, body: suggestion.body, fireDate: nil)
        }
    }

    /// "switch|<provider>|<toAccountID>|<unixSeconds>" — the target account is
    /// encoded in the identifier so PR #16's account switching can later hang
    /// an action button off this notification and know which account to switch
    /// to, without the `NotificationScheduling` seam having to carry a
    /// `userInfo` payload today. The timestamp keeps successive suggestions
    /// distinct (identifiers are the center's replace key) while leaving the
    /// prefix stable and parseable.
    private static func switchIdentifier(
        for suggestion: SwitchSuggestion.Suggestion, now: Date
    ) -> String {
        "switch|\(suggestion.provider.rawValue)|\(suggestion.toAccountID)|"
            + "\(Int(now.timeIntervalSince1970))"
    }

    // MARK: - Reset scheduling

    /// Reconciles pending reset alerts with the latest snapshot: one pending
    /// notification per limit at/above the threshold, delivered at its
    /// `resetsAt`. The identifier embeds the reset timestamp, so an unchanged
    /// window is a no-op (same id already pending) while a shifted window
    /// cancels the stale request and schedules the new time instead of
    /// stacking a second alert. Limits that dropped back below the threshold
    /// lose their pending alert the same way.
    private func rescheduleResetAlerts(for account: AccountMeta, limits: [LimitStatus]) {
        var desired: [String: LimitStatus] = [:]
        for limit in limits {
            guard limit.percent >= Self.thresholdPercent,
                let resetsAt = limit.resetsAt, resetsAt.timeIntervalSinceNow > 1
            else { continue }
            desired[Self.resetIdentifier(account: account, limit: limit, resetsAt: resetsAt)] =
                limit
        }

        // Only this account's requests are reconciled here, so concurrent
        // per-account refreshes never cancel each other's alerts.
        let accountPrefix = "reset|\(account.id)|"
        let title = account.displayLabel
        let scheduler = self.scheduler
        scheduler.pendingIdentifiers { pendingIDs in
            let existing = Set(pendingIDs.filter { $0.hasPrefix(accountPrefix) })
            let stale = existing.subtracting(desired.keys)
            if !stale.isEmpty {
                scheduler.removePending(identifiers: Array(stale))
            }
            for (identifier, limit) in desired where !existing.contains(identifier) {
                guard let resetsAt = limit.resetsAt else { continue }
                scheduler.add(
                    identifier: identifier, title: title,
                    body: "\(limit.name) limit has reset", fireDate: resetsAt)
            }
        }
    }

    /// "reset|account|limit|unixSeconds" — deterministic so rescheduling the
    /// same window replaces itself, and prefix-matchable per account (account
    /// ids are UUIDs, so the prefix stays unambiguous even though limit ids
    /// can themselves contain "|"). Whole seconds absorb any sub-second
    /// jitter in the server's reset time.
    private static func resetIdentifier(
        account: AccountMeta, limit: LimitStatus, resetsAt: Date
    ) -> String {
        "reset|\(account.id)|\(limit.id)|\(Int(resetsAt.timeIntervalSince1970))"
    }

    // MARK: - Posting

    /// Fires a banner immediately (nil fire date). Random identifiers: these
    /// are one-shot events, unlike reset alerts there is nothing to replace.
    private func post(title: String, body: String) {
        scheduler.add(identifier: UUID().uuidString, title: title, body: body, fireDate: nil)
    }
}
