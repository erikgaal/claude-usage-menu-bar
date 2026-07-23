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
                ForEach(store.accounts) { account in
                    AccountSection(store: store, account: account)
                    Divider()
                }
            }

            if store.isAddingAccount {
                addAccountBanner
                Divider()
            }
            if let error = store.addAccountError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                Divider()
            }

            addButtons
            Divider()
            footer
        }
        .frame(width: 340)
        .onAppear { store.refreshIfStale() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Usage")
                .font(.headline)
            Spacer()
            if let updated = store.lastUpdatedOverall {
                (Text("Updated ") + Text(updated, style: .relative) + Text(" ago"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button {
                store.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No accounts yet")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Add each subscription you want to track.")
                .font(.caption)
                .foregroundStyle(.tertiary)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: Footer

    private var addButtons: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(ProviderID.allCases, id: \.self) { providerID in
                Button {
                    store.beginAddAccount(provider: providerID)
                } label: {
                    Label(
                        "Add \(providerID.displayName) account",
                        systemImage: "plus.app")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.primary)
                .disabled(store.isAddingAccount)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Launch at login")
                Spacer()
                Toggle("", isOn: launchAtLoginBinding)
                    .labelsHidden()
                    .toggleStyle(.checkbox)
            }
            HStack {
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { store.launchAtLogin },
            set: { store.setLaunchAtLogin($0) }
        )
    }
}

// MARK: - Account section

struct AccountSection: View {
    @ObservedObject var store: AccountStore
    let account: AccountMeta

    @State private var isRenaming = false
    @State private var draftName = ""
    @FocusState private var renameFocused: Bool

    private var state: AccountDisplayState {
        store.states[account.id] ?? AccountDisplayState()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            titleRow

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
                limitGroups
                if let credits = state.credits, credits.isMeaningful {
                    CreditsRow(credits: credits)
                }
                if let error = state.error {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Rename…") { startRenaming() }
            Button("Remove Account", role: .destructive) {
                store.removeAccount(account)
            }
        }
    }

    private var titleRow: some View {
        HStack(spacing: 8) {
            ProviderBadge(provider: account.provider)
            if isRenaming {
                TextField(
                    "Name", text: $draftName,
                    onCommit: {
                        store.rename(account, to: draftName)
                        isRenaming = false
                    }
                )
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 130)
                .focused($renameFocused)
                .onExitCommand { isRenaming = false }
            } else {
                Text(account.displayLabel)
                    .font(.system(size: 14, weight: .bold))
                    .onTapGesture(count: 2) { startRenaming() }
                    .help("Double-click to rename")
            }
            Text(account.email)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    private func startRenaming() {
        draftName = account.label ?? ""
        isRenaming = true
        renameFocused = true
    }

    // MARK: Limits with grouped reset lines

    private struct ResetGroup: Identifiable {
        let id: Int
        let rows: [LimitStatus]
        let resetsAt: Date?
    }

    /// Consecutive limits whose reset times match (within 5 minutes) share one
    /// reset line; rows without a reset time fold into the surrounding group.
    private var resetGroups: [ResetGroup] {
        var groups: [ResetGroup] = []
        var current: [LimitStatus] = []
        var currentReset: Date?

        for limit in state.limits {
            if let reset = limit.resetsAt {
                if let existing = currentReset,
                    abs(existing.timeIntervalSince(reset)) > 300 {
                    groups.append(
                        ResetGroup(id: groups.count, rows: current, resetsAt: existing))
                    current = []
                    currentReset = nil
                }
                current.append(limit)
                if currentReset == nil { currentReset = reset }
            } else {
                current.append(limit)
            }
        }
        if !current.isEmpty {
            groups.append(ResetGroup(id: groups.count, rows: current, resetsAt: currentReset))
        }
        return groups
    }

    private var limitGroups: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(resetGroups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(group.rows) { limit in
                        LimitRow(limit: limit)
                    }
                    if let resetsAt = group.resetsAt {
                        Text(Self.resetText(resetsAt, rowCount: group.rows.count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, LimitRow.labelWidth + LimitRow.spacing)
                    }
                }
            }
        }
    }

    static func resetText(_ date: Date, rowCount: Int) -> String {
        let prefix: String
        switch rowCount {
        case ...1: prefix = "resets in"
        case 2: prefix = "both reset in"
        default: prefix = "all reset in"
        }
        return "\(prefix) \(durationText(until: date))"
    }

    static func durationText(until date: Date) -> String {
        let seconds = date.timeIntervalSinceNow
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

// MARK: - Building blocks

struct ProviderBadge: View {
    let provider: ProviderID

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(background)
            .frame(width: 20, height: 20)
            .overlay(
                Text(letter)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            )
    }

    private var letter: String {
        switch provider {
        case .claude: return "C"
        case .codex: return "X"
        }
    }

    private var background: Color {
        switch provider {
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.20)
        case .codex: return Color(red: 0.17, green: 0.35, blue: 0.75)
        }
    }
}

struct LimitRow: View {
    static let labelWidth: CGFloat = 64
    static let spacing: CGFloat = 10
    /// Width of the trailing value column, shared with `CreditsRow` so every
    /// bar spans the same width (wide enough for a currency amount).
    static let valueWidth: CGFloat = 60

    let limit: LimitStatus

    var body: some View {
        HStack(spacing: Self.spacing) {
            Text(limit.name)
                .font(.callout)
                .lineLimit(1)
                .frame(width: Self.labelWidth, alignment: .leading)
            UsageBar(percent: limit.percent, color: barColor)
            Text("\(Int(limit.percent.rounded()))%")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(barColor)
                .frame(width: Self.valueWidth, alignment: .trailing)
        }
    }

    private var barColor: Color {
        switch limit.percent {
        case 90...: return .red
        case 70..<90: return .orange
        default: return .green
        }
    }
}

/// Extra-usage ("credits") spend. When a cap is set the bar fills used/cap;
/// with no cap there's no denominator, so the bar stays on its empty track and
/// the caption explains why, while the amount spent is always shown.
struct CreditsRow: View {
    let credits: CreditsStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: LimitRow.spacing) {
                Text("Credits")
                    .font(.callout)
                    .lineLimit(1)
                    .frame(width: LimitRow.labelWidth, alignment: .leading)
                UsageBar(percent: credits.fillPercent, color: barColor)
                Text(credits.usedText)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundStyle(credits.hasCap ? barColor : .primary)
                    .frame(width: LimitRow.valueWidth, alignment: .trailing)
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, LimitRow.labelWidth + LimitRow.spacing)
        }
    }

    private var caption: String {
        guard let limitText = credits.limitText else {
            return "extra usage · no spend limit"
        }
        return "extra usage · \(Int(credits.fillPercent.rounded()))% of \(limitText)"
    }

    private var barColor: Color {
        guard credits.hasCap else { return .secondary }
        switch credits.fillPercent {
        case 90...: return .red
        case 70..<90: return .orange
        default: return .green
        }
    }
}

struct UsageBar: View {
    let percent: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.15))
                Capsule()
                    .fill(color)
                    .frame(
                        width: max(
                            5, geometry.size.width * min(max(percent, 0), 100) / 100))
            }
        }
        .frame(height: 5)
    }
}
