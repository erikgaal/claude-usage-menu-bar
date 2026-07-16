import SwiftUI

struct MenuContentView: View {
    @ObservedObject var store: AccountStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if store.accounts.isEmpty && !store.isAddingAccount {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(store.accounts) { account in
                        AccountSection(store: store, account: account)
                    }
                }
                .padding(12)
            }

            if store.isAddingAccount {
                addAccountBanner
            }
            if let error = store.addAccountError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }

            Divider()
            footer
        }
        .frame(width: 340)
    }

    private var header: some View {
        HStack {
            Image(systemName: "gauge.with.needle")
                .foregroundStyle(.secondary)
            Text("Claude Usage")
                .font(.headline)
            Spacer()
            Button {
                store.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No accounts yet")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Add each Claude subscription you want to track.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var addAccountBanner: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    "Waiting for \(store.pendingProvider?.displayName ?? "") sign-in in your browser…"
                )
                .font(.caption)
                Text("For a second account, use a private window or log out first.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { store.cancelAddAccount() }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(ProviderID.allCases, id: \.self) { providerID in
                Button {
                    store.beginAddAccount(provider: providerID)
                } label: {
                    Label(
                        Providers.provider(for: providerID).accountKind,
                        systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(store.isAddingAccount)
            }

            Toggle("Launch at login", isOn: launchAtLoginBinding)
                .toggleStyle(.checkbox)
                .font(.callout)

            HStack {
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("q")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { store.launchAtLogin },
            set: { store.setLaunchAtLogin($0) }
        )
    }
}

struct AccountSection: View {
    @ObservedObject var store: AccountStore
    let account: AccountMeta

    private var state: AccountDisplayState {
        store.states[account.id] ?? AccountDisplayState()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(account.provider.displayName)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color(nsColor: .tertiarySystemFill)))
                    .foregroundStyle(.secondary)
                Text(account.email)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(account.organizationName ?? account.email)
                Spacer()
                if let updated = state.lastUpdated {
                    Text(updated, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                Button {
                    store.removeAccount(account)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("Remove this account")
            }

            if state.needsReauth {
                HStack {
                    Label("Sign-in expired", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Sign in again") { store.reauthenticate(account) }
                        .controlSize(.small)
                }
            } else if let error = state.error, state.limits.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if state.limits.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 6) {
                    ForEach(state.limits) { limit in
                        LimitRow(limit: limit)
                    }
                }
                if let error = state.error {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .quaternarySystemFill))
        )
    }
}

struct LimitRow: View {
    let limit: LimitStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.name)
                    .font(.caption)
                Spacer()
                Text("\(Int(limit.percent.rounded()))%")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(barColor)
            }
            ProgressView(value: min(max(limit.percent, 0), 100), total: 100)
                .progressViewStyle(.linear)
                .tint(barColor)
                .controlSize(.small)
            if let resetsAt = limit.resetsAt {
                Text(resetText(resetsAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var barColor: Color {
        switch limit.percent {
        case 90...: return .red
        case 70..<90: return .orange
        default: return .green
        }
    }

    private func resetText(_ date: Date) -> String {
        let seconds = date.timeIntervalSinceNow
        guard seconds > 0 else { return "resetting…" }
        let totalMinutes = Int(seconds / 60)
        let days = totalMinutes / (60 * 24)
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60
        if days > 0 { return "resets in \(days)d \(hours)h" }
        if hours > 0 { return "resets in \(hours)h \(minutes)m" }
        return "resets in \(minutes)m"
    }
}
