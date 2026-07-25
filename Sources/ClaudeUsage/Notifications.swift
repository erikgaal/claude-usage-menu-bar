import Combine
import Foundation

// UNUserNotificationCenter is thread-safe but predates Sendable annotations;
// its completion handlers run on a background queue by design.
@preconcurrency import UserNotifications

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

    /// User toggle from the panel footer. Enabling requests system
    /// authorization (the OS only prompts the first time); disabling drops
    /// any scheduled reset alerts so nothing fires while off.
    @Published var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.defaultsKey)
            guard let center else { return }
            if isEnabled {
                center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
            } else {
                center.removeAllPendingNotificationRequests()
            }
        }
    }

    init() {
        // Assigning in init doesn't trip didSet, so restoring the saved value
        // never re-prompts for authorization at launch.
        isEnabled = UserDefaults.standard.bool(forKey: Self.defaultsKey)
    }

    /// `UNUserNotificationCenter.current()` traps when the process has no
    /// bundle identity — the bare `swift build` binary, `swift run`, and the
    /// screenshot harness — so every notification-center access goes through
    /// this guard. Mock mode also lands here: fake data must never produce
    /// real notifications.
    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        #if DEBUG
            if Mock.isEnabled { return nil }
        #endif
        return UNUserNotificationCenter.current()
    }

    // MARK: - Event detection

    /// Called by `AccountStore.refresh` just before it commits `new`, so
    /// `old` is the previous poll's snapshot (nil on the first fetch).
    func accountDidUpdate(
        _ account: AccountMeta, old: AccountDisplayState?, new: AccountDisplayState
    ) {
        guard isEnabled, let center else { return }

        // Sign-in expired: only on the false→true flip, not on every poll
        // that keeps failing while the account waits for the user.
        if new.needsReauth, old?.needsReauth != true {
            post(
                title: account.displayLabel,
                body: "Sign-in expired — open the menu to sign in again.",
                center: center)
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
                body: "\(limit.name) limit at \(Int(limit.percent.rounded()))%",
                center: center)
        }

        rescheduleResetAlerts(for: account, limits: new.limits, center: center)
    }

    // MARK: - Reset scheduling

    /// Reconciles pending reset alerts with the latest snapshot: one pending
    /// notification per limit at/above the threshold, delivered at its
    /// `resetsAt`. The identifier embeds the reset timestamp, so an unchanged
    /// window is a no-op (same id already pending) while a shifted window
    /// cancels the stale request and schedules the new time instead of
    /// stacking a second alert. Limits that dropped back below the threshold
    /// lose their pending alert the same way.
    private func rescheduleResetAlerts(
        for account: AccountMeta, limits: [LimitStatus], center: UNUserNotificationCenter
    ) {
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
        center.getPendingNotificationRequests { pending in
            let existing = Set(
                pending.map(\.identifier).filter { $0.hasPrefix(accountPrefix) })
            let stale = existing.subtracting(desired.keys)
            if !stale.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: Array(stale))
            }
            for (identifier, limit) in desired where !existing.contains(identifier) {
                guard let resetsAt = limit.resetsAt else { continue }
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = "\(limit.name) limit has reset"
                content.sound = .default
                let trigger = UNTimeIntervalNotificationTrigger(
                    timeInterval: max(1, resetsAt.timeIntervalSinceNow), repeats: false)
                center.add(
                    UNNotificationRequest(
                        identifier: identifier, content: content, trigger: trigger))
            }
        }
    }

    /// "reset|account|limit|unixSeconds" — deterministic so rescheduling the
    /// same window replaces itself, and prefix-matchable per account. Whole
    /// seconds absorb any sub-second jitter in the server's reset time.
    private static func resetIdentifier(
        account: AccountMeta, limit: LimitStatus, resetsAt: Date
    ) -> String {
        "reset|\(account.id)|\(limit.id)|\(Int(resetsAt.timeIntervalSince1970))"
    }

    // MARK: - Posting

    /// Fires a banner immediately (nil trigger). Random identifiers: these
    /// are one-shot events, unlike reset alerts there is nothing to replace.
    private func post(title: String, body: String, center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(
            UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
