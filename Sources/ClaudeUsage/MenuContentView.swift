import SwiftUI

struct MenuContentView: View {
    @ObservedObject var store: AccountStore
    @ObservedObject var updateChecker: UpdateChecker

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
            if let release = updateChecker.availableRelease {
                Button {
                    NSWorkspace.shared.open(release.url)
                } label: {
                    Label(
                        "Update available — v\(release.version)",
                        systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tint)
                .help("Open the release page")
            }
            HStack {
                Text("Launch at login")
                Spacer()
                Toggle("", isOn: launchAtLoginBinding)
                    .labelsHidden()
                    .toggleStyle(.checkbox)
            }
            NotificationsToggleRow(notifier: store.notifier)
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

/// Own view observing the notifier directly — AccountStore doesn't republish
/// its nested ObservableObject, so binding through `store` would leave the
/// checkbox stale. Toggling drives authorization/cancellation via the
/// notifier's own didSet.
private struct NotificationsToggleRow: View {
    @ObservedObject var notifier: UsageNotifier

    var body: some View {
        HStack {
            Text("Enable notifications")
            Spacer()
            Toggle("", isOn: $notifier.isEnabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
        }
        .help(
            "Alerts when a limit passes \(Int(UsageNotifier.thresholdPercent))%, "
                + "when it resets, and when sign-in expires")
    }
}

// MARK: - Account section

struct AccountSection: View {
    @ObservedObject var store: AccountStore
    let account: AccountMeta

    @State private var isRenaming = false
    @State private var draftName = ""
    @State private var showsBestDetails = false
    @FocusState private var renameFocused: Bool

    private var state: AccountDisplayState {
        store.states[account.id] ?? AccountDisplayState()
    }

    /// Whether this account has same-provider company — the only case where
    /// the best-account hint (and its debug breakdown) means anything.
    private var hasProviderPeers: Bool {
        store.accounts.filter { $0.provider == account.provider }.count >= 2
    }

    /// The account's plan multiplier, read live from the store (the section
    /// holds an immutable `account` snapshot) and written through it.
    private var quotaMultiplierBinding: Binding<Double?> {
        Binding(
            get: {
                store.accounts.first { $0.id == account.id }?.quotaMultiplier
            },
            set: { store.setQuotaMultiplier(account, to: $0) }
        )
    }

    private var storedAccount: AccountMeta? {
        store.accounts.first { $0.id == account.id }
    }

    /// Label for the picker's nil (no manual override) entry: the weight
    /// detection settled on, or a plain statement that it didn't.
    private var autoWeightLabel: String {
        guard let detected = storedAccount?.detectedQuotaMultiplier else {
            return "Auto — not detected"
        }
        return "Auto — \(Self.planName(for: detected)) (detected)"
    }

    /// The raw `rate_limit_tier` the API reported, for the informational row.
    private var detectedTierText: String {
        storedAccount?.detectedRateLimitTier ?? "none"
    }

    /// Plan-name hint for a weight — a hint, not a definition: several
    /// subscriptions can share one weight (e.g. Max 5× and a Team seat).
    static func planName(for multiplier: Double) -> String {
        switch multiplier {
        case 1: return "Pro (×1)"
        case 5: return "Max 5× (×5)"
        case 20: return "Max 20× (×20)"
        default: return "×\(Int(multiplier))"
        }
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
            // The weight scales this account's window against the others
            // when pooling burn rates behind the "Best" badge. Asking for a
            // relative weight rather than a plan name keeps the user out of
            // "is my Team premium seat a Max 5×?" territory: only the ratio
            // between their own accounts matters. Claude only — Codex tier
            // ratios aren't known, so those accounts stay unweighted.
            if account.provider == .claude {
                Picker("Quota weight", selection: quotaMultiplierBinding) {
                    // No manual override: the detected weight, or none.
                    Text(autoWeightLabel).tag(Optional<Double>.none)
                    Text("×1 — Pro").tag(Optional(1.0))
                    Text("×5 — Max 5× or Team seat").tag(Optional(5.0))
                    Text("×20 — Max 20×").tag(Optional(20.0))
                    Divider()
                    // Non-interactive: shows exactly what the server said,
                    // so an unrecognized plan can still be weighted knowingly.
                    Text("API reports: \(detectedTierText)")
                }
                .help(
                    "How big this account's session window is relative to your "
                        + "others (one full Pro window = ×1). Used to pool burn "
                        + "rates across differently-sized subscriptions — getting "
                        + "the ratio between your accounts right is what matters, "
                        + "not identifying the plan exactly.")
            }
            if hasProviderPeers {
                Button("Best-account details…") { showsBestDetails = true }
            }
            Divider()
            // Order matters beyond the panel: it also sets the menu bar
            // summary order, so surface reordering right where accounts live.
            Button("Move Up") { store.moveAccount(account, by: -1) }
                .disabled(store.accounts.first?.id == account.id)
            Button("Move Down") { store.moveAccount(account, by: 1) }
                .disabled(store.accounts.last?.id == account.id)
            Divider()
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
            if let badge = store.bestBadges[account.id] {
                BestBadge(badge: badge)
                    .onTapGesture { showsBestDetails = true }
            }
        }
        .popover(isPresented: $showsBestDetails, arrowEdge: .bottom) {
            if let trace = store.bestAccountTrace(for: account.provider) {
                BestAccountDebugView(trace: trace)
            }
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
                        Text(captionText(for: group, resetsAt: resetsAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, LimitRow.labelWidth + LimitRow.spacing)
                    }
                }
            }
        }
    }

    // MARK: Pace projection

    /// The reset countdown, extended with a burn-rate projection when one is
    /// worth surfacing — most of the time this is just the plain reset line,
    /// because silence beats a noisy forecast.
    private func captionText(for group: ResetGroup, resetsAt: Date) -> String {
        let reset = Self.resetText(resetsAt, rowCount: group.rows.count)
        guard let pace = paceText(for: group, resetsAt: resetsAt) else { return reset }
        return "\(reset) · \(pace)"
    }

    private func paceText(for group: ResetGroup, resetsAt: Date) -> String? {
        Self.paceText(
            rows: group.rows, resetsAt: resetsAt, accountID: account.id, history: .shared)
    }

    /// The projection worth showing for a reset group, if any: the limit that
    /// runs out soonest — and only when it lands *before* the window resets on
    /// its own, since running out after the reset is a non-event. Static with
    /// an injected store so tests can drive the gates with synthetic history.
    static func paceText(
        rows: [LimitStatus], resetsAt: Date, accountID: String, history: UsageHistoryStore
    ) -> String? {
        var soonest: (limit: LimitStatus, at: Date)?
        for limit in rows {
            // Low-utilization slopes extrapolate to noise; don't project them.
            guard limit.percent >= 25,
                let projected = history.projectedExhaustion(
                    accountID: accountID, limitID: limit.id),
                projected < resetsAt
            else { continue }
            if soonest == nil || projected < soonest!.at {
                soonest = (limit, projected)
            }
        }
        guard let soonest else { return nil }
        // With several bars sharing the line, name the one that runs out.
        let prefix = rows.count > 1 ? "\(soonest.limit.name) " : ""
        return "\(prefix)on pace to run out \(exhaustionTimeText(soonest.at))"
    }

    /// "14:00" when the projection lands today, "Thu 14:00" otherwise —
    /// enough precision for a heads-up without pretending it's exact.
    static func exhaustionTimeText(_ date: Date) -> String {
        let formatter = Calendar.current.isDateInToday(date)
            ? Self.timeFormatter : Self.weekdayTimeFormatter
        return formatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("jm")
        return formatter
    }()

    private static let weekdayTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEjm")
        return formatter
    }()

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

/// Quiet "use this one" capsule for the same-provider account with the most
/// session headroom (see `AccountStore.bestBadges`). Styled as a hint, not an
/// alarm: small type, soft tint, no icon. When the ranking has a pace
/// projection for the badged account the tooltip becomes time-based;
/// otherwise it keeps the static v1 text.
struct BestBadge: View {
    let badge: BestAccount.Badge

    var body: some View {
        Text("Best")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.green)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.green.opacity(0.15)))
            .help(tooltip)
    }

    private var tooltip: String {
        // Expiring-first (v3): explain what is about to vanish and when.
        if let expiring = badge.expiring {
            let untilReset = AccountSection.durationText(until: expiring.resetsAt)
            return "≈\(Int(expiring.points.rounded()))% expires at reset in "
                + "\(untilReset) — use this first"
        }
        guard let projected = badge.projectedExhaustion else {
            return "Most session headroom right now"
        }
        let left = AccountSection.durationText(until: projected)
        return "≈\(left) of session left at current pace"
    }
}

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
