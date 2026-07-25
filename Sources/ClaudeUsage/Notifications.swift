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

    private let scheduler: NotificationScheduling
    private let defaults: UserDefaults

    /// User toggle from the panel footer. Enabling requests system
    /// authorization (the OS only prompts the first time); disabling drops
    /// any scheduled reset alerts so nothing fires while off.
    @Published var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            defaults.set(isEnabled, forKey: Self.defaultsKey)
            if isEnabled {
                scheduler.requestAuthorization()
            } else {
                scheduler.removeAllPending()
            }
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
