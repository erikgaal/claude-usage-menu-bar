import AppKit
import Foundation

/// One-time explainer shown before the first Claude Code account switch.
///
/// There is no keychain dialog to warn about — `SecurityCLI` is what keeps the
/// feature silent — so this exists for the other surprise: the switch is
/// system-wide. It moves the `claude` command, the desktop app and the IDE
/// extensions together, including sessions running in terminals the user isn't
/// looking at. That is the whole point of the feature, and also the thing worth
/// stating once before it happens rather than after.
@MainActor
enum ClaudeCodeSwitchPrompt {
    private static let acknowledgedKey = "acknowledgedClaudeCodeKeychainPrompt"

    static var hasAcknowledged: Bool {
        UserDefaults.standard.bool(forKey: acknowledgedKey)
    }

    /// Presents the explainer unless it's already been accepted. Returns
    /// whether the switch should go ahead.
    ///
    /// Consent alone doesn't record acknowledgement — `recordAcknowledged()`
    /// does, once a switch has actually completed. A switch that fails before
    /// reaching the Keychain (a busy lock, say) never shows the authorization
    /// dialog this explains, so spending the explainer on it would leave the
    /// next attempt's prompt unexplained — the one thing this exists to avoid.
    static func confirm(switchingTo account: AccountMeta) -> Bool {
        guard !hasAcknowledged else { return true }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Switch Claude Code to \(account.email)?"
        alert.informativeText = """
            This changes the account used by the claude command, the Claude \
            Code desktop app, and the IDE extensions — everywhere on this Mac, \
            not just here.

            Sessions you already have open switch over within about 30 \
            seconds; there's no need to restart them.
            """
        alert.addButton(withTitle: "Switch Account")
        alert.addButton(withTitle: "Cancel")

        // The menu bar panel closes as soon as the alert takes focus, and an
        // accessory app isn't frontmost, so without this the dialog can appear
        // behind whatever the user was working in.
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Called once a switch has gone through, so later ones skip the explainer.
    static func recordAcknowledged() {
        UserDefaults.standard.set(true, forKey: acknowledgedKey)
    }
}
