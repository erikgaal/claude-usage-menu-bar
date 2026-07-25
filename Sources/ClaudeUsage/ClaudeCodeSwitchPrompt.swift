import AppKit
import Foundation

/// One-time explainer shown before the first Claude Code account switch.
///
/// Switching reads Claude Code's own Keychain item, and reading is the single
/// operation macOS gates behind an authorization dialog — writing is granted to
/// every application, so it passes silently. Without this warning the user's
/// first experience of the feature is an unexplained keychain password prompt
/// naming an app they didn't expect, which is precisely the kind of thing to
/// explain before it appears rather than after.
///
/// Shown once: the underlying authorization is itself one-time, provided the
/// user picks "Always Allow". Later switches go through without ceremony,
/// which is the point of the feature.
@MainActor
enum ClaudeCodeSwitchPrompt {
    private static let acknowledgedKey = "acknowledgedClaudeCodeKeychainPrompt"

    static var hasAcknowledged: Bool {
        UserDefaults.standard.bool(forKey: acknowledgedKey)
    }

    /// Presents the explainer unless it's already been accepted. Returns
    /// whether the switch should go ahead.
    static func confirm(switchingTo account: AccountMeta) -> Bool {
        guard !hasAcknowledged else { return true }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Switch Claude Code to \(account.email)?"
        alert.informativeText = """
            macOS will ask for permission to use Claude Code's keychain item. \
            Choose "Always Allow" — with plain "Allow" it asks again every time.

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
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        UserDefaults.standard.set(true, forKey: acknowledgedKey)
        return true
    }
}
