import AppKit
import SwiftUI

@main
struct ClaudeUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AccountStore()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var store: AccountStore

    var body: some View {
        let text = store.menuBarText
        if text.isEmpty {
            Image(systemName: "gauge.with.needle")
        } else {
            HStack(spacing: 3) {
                Image(systemName: symbolName)
                Text(text)
                    .monospacedDigit()
            }
        }
    }

    private var symbolName: String {
        switch store.worstPercent {
        case 90...: return "gauge.with.needle.fill"
        default: return "gauge.with.needle"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only app: no Dock icon, no app switcher entry.
        NSApp.setActivationPolicy(.accessory)
    }
}
