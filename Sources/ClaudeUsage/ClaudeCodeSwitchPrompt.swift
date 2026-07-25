import AppKit
import Foundation

/// One-time explainer shown before the first Claude Code account switch.
///
/// Every switch costs the user one login-keychain password prompt, and it is
/// worth being blunt about why, because the obvious reading — "the app is
/// asking for permission once" — is wrong. Writing Claude Code's Keychain item
/// from a third-party-signed binary resets that item's *partition list* to this
/// app's team, evicting the `apple-tool:` entry that `/usr/bin/security` reads
/// under. Claude Code reads its credentials by shelling out to `security`, so
/// its next read is unauthorized and macOS asks for the password to restore it.
/// The partition list is separate from the item's ACL, so no amount of access
/// control on our side avoids this; see `ClaudeCodeStore.writeCredentials` for
/// the approaches that were tried and why each failed.
///
/// So the honest framing is a recurring cost, disclosed once, rather than a
/// one-off authorization. Shown a single time because a modal before every
/// switch would be worse than the prompt it explains — the user needs to
/// understand the pattern, not be reminded of it.
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
            The next time Claude Code runs, macOS will ask for your login \
            keychain password. This happens after every switch — updating the \
            credentials from another app costs Claude Code its silent access, \
            and only your password gives it back. Choose "Always Allow" to \
            settle it until the next switch.

            This changes the account used by the claude command, the Claude \
            Code desktop app, and the IDE extensions. Sessions you already \
            have open switch over within about 30 seconds; there's no need to \
            restart them.
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
