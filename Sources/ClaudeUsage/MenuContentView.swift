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

            // Sign-in feedback belongs here too: an expired account's "Sign in
            // again" button starts the same flow from this panel.
            AddAccountStatus(store: store)

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
            Text("Add each subscription you want to track in Settings.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            OpenSettingsButton {
                Label("Add an account…", systemImage: "plus")
            }
            .buttonStyle(.link)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: Footer

    /// The panel's own controls only: news (an available update), the way into
    /// Settings, and Quit. Everything configurable lives in the settings
    /// window (see `SettingsView`).
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
                OpenSettingsButton {
                    Label("Settings…", systemImage: "gearshape")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.primary)
                .keyboardShortcut(",", modifiers: .command)
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
}

/// Opens the settings window, with the activation an accessory app needs:
/// with no Dock icon the app isn't frontmost while the panel is open, so the
/// window would otherwise appear behind whatever is. Activating on both sides
/// of the open covers either ordering AppKit picks.
struct OpenSettingsButton<Label: View>: View {
    @Environment(\.openSettings) private var openSettings
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            label()
        }
    }
}

// MARK: - Account section

struct AccountSection: View {
    @ObservedObject var store: AccountStore
    let account: AccountMeta

    @State private var showsBestDetails = false

    private var state: AccountDisplayState {
        store.states[account.id] ?? AccountDisplayState()
    }

    /// Whether this account has same-provider company — the only case where
    /// the best-account hint (and its debug breakdown) means anything.
    private var hasProviderPeers: Bool {
        store.accounts.filter { $0.provider == account.provider }.count >= 2
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
        // Inspection only — naming, weighting, reordering and removing an
        // account all live in the settings window now.
        .contextMenu {
            if hasProviderPeers {
                Button("Best-account details…") { showsBestDetails = true }
            }
            OpenSettingsButton { Text("Account Settings…") }
        }
    }

    private var titleRow: some View {
        HStack(spacing: 8) {
            ProviderBadge(provider: account.provider)
            Text(account.displayLabel)
                .font(.system(size: 14, weight: .bold))
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
                    trendSection(for: group)
                }
            }
        }
    }

    // MARK: Trend charts

    /// Collapsible trend charts for a reset group's multi-day windows — the
    /// only ones where a week of recorded history and an end-of-window
    /// projection say anything (see `LimitStatus.isMultiDay`). Session groups
    /// get nothing here, so the panel stays as short as it is today.
    ///
    /// Collapsed by default and remembered per limit: three accounts' charts
    /// unfurled at once would make the panel taller than most screens, but a
    /// chart the user opened is one they want to keep seeing.
    @ViewBuilder
    private func trendSection(for group: ResetGroup) -> some View {
        let chartable = group.rows.filter(\.isMultiDay)
        if let first = chartable.first {
            let key = "\(account.id)|\(first.id)"
            let isExpanded = store.isTrendExpanded(key)
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    store.toggleTrend(key)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                        Text(chartable.count > 1 ? "Trends" : "\(first.name) trend")
                            .font(.caption)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.leading, LimitRow.labelWidth + LimitRow.spacing)
                .help("Recorded usage across this window, and where the current pace lands")

                if isExpanded {
                    ForEach(chartable) { limit in
                        if let trend = store.trend(for: limit, accountID: account.id) {
                            UsageTrendChart(
                                limit: limit, trend: trend, showsTitle: chartable.count > 1)
                        } else {
                            Text("\(limit.name): nothing recorded in this window yet.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
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
                let projected = history.projectedExhaustion(for: limit, accountID: accountID),
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

    /// Delegates to the one formatter in the app (`SwitchSuggestion` owns it,
    /// since detection can't read the clock) so tooltips, the debug popover
    /// and the switch notifications word a duration identically.
    static func durationText(until date: Date) -> String {
        SwitchSuggestion.durationText(seconds: date.timeIntervalSinceNow)
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
        // Expiring-first (v3/v4): explain what is about to vanish and when.
        if let expiring = badge.expiring {
            let untilReset = AccountSection.durationText(until: expiring.resetsAt)
            // The weekly leg (v4) names the window, since "31% expires in 3d"
            // would otherwise read as a session figure. "Weekly" reads better
            // lowercased inside the sentence; model-scoped windows keep their
            // proper name ("of Fable").
            if let scope = expiring.scopeName {
                let name = scope == "Weekly" ? "weekly" : scope
                return "≈\(Int(expiring.points.rounded()))% of \(name) expires at reset in "
                    + "\(untilReset) — use this first"
            }
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
