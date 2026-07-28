import SwiftUI

/// The app's settings window (⌘, from the panel). Everything that configures
/// the app lives here, so the menu bar panel stays a usage display: General
/// holds the two app-wide switches, Accounts holds the account list that used
/// to be split between the panel's footer buttons and a right-click menu on
/// each account row.
struct SettingsView: View {
    @ObservedObject var store: AccountStore

    var body: some View {
        TabView {
            GeneralSettingsView(store: store)
                .tabItem { Label("General", systemImage: "gearshape") }
            AccountsSettingsView(store: store)
                .tabItem { Label("Accounts", systemImage: "person.2") }
        }
        // Fixed width, content-driven height: the standard shape for a macOS
        // settings window, and the Accounts tab grows with the account list.
        .frame(width: 520)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @ObservedObject var store: AccountStore

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: launchAtLoginBinding)
                    .help(
                        "Registers the app as a login item. Only works when running "
                            + "from the bundled .app.")
            }
            NotificationsSection(notifier: store.notifier)
            Section("About") {
                LabeledContent("Version") {
                    // Selectable so it can be pasted into a bug report.
                    Text(AppInfo.versionText)
                        .monospacedDigit()
                        .textSelection(.enabled)
                }
                LabeledContent("Author", value: AppInfo.author)
                LabeledContent("Source") {
                    Link(
                        "github.com/\(AppInfo.repositorySlug)",
                        destination: AppInfo.repositoryURL)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 500)
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { store.launchAtLogin },
            set: { store.setLaunchAtLogin($0) }
        )
    }
}

/// Own view observing the notifier directly — AccountStore doesn't republish
/// its nested ObservableObject, so binding through `store` would leave these
/// checkboxes stale. The master toggle drives authorization/cancellation via
/// the notifier's own didSet; the per-kind ones go through `setEnabled`, which
/// persists and (for reset alerts) cancels what's already queued.
private struct NotificationsSection: View {
    @ObservedObject var notifier: UsageNotifier

    var body: some View {
        Section("Notifications") {
            Toggle("Enable notifications", isOn: $notifier.isEnabled)
                .help("Master switch — nothing below is delivered while this is off")
            ForEach(NotificationKind.allCases) { kind in
                Toggle(kind.title, isOn: binding(for: kind))
                    .help(kind.help)
                    .disabled(!notifier.isEnabled)
                    // Reads as subordinate to the master switch above.
                    .padding(.leading, 18)
            }
        }
    }

    private func binding(for kind: NotificationKind) -> Binding<Bool> {
        Binding(
            get: { notifier.isEnabled(kind) },
            set: { notifier.setEnabled($0, for: kind) }
        )
    }
}

// MARK: - Accounts

struct AccountsSettingsView: View {
    @ObservedObject var store: AccountStore

    /// The row a drag is currently hovering over, highlighted as the position
    /// the dragged account would take.
    @State private var dropTargetID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            accountCard
            AddAccountStatus(store: store, horizontalPadding: 0, showsDividers: false)
            HStack(spacing: 8) {
                Menu {
                    ForEach(ProviderID.allCases, id: \.self) { providerID in
                        Button("Add \(providerID.displayName) account…") {
                            store.beginAddAccount(provider: providerID)
                        }
                    }
                } label: {
                    Label("Add Account", systemImage: "plus")
                }
                .fixedSize()
                .disabled(store.isAddingAccount)
                Spacer()
                Text("Order sets the menu bar's left-to-right order")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(20)
    }

    /// The account list as one inset card, echoing the grouped Form on the
    /// General tab so both tabs read as the same window.
    private var accountCard: some View {
        VStack(spacing: 0) {
            if store.accounts.isEmpty {
                Text("No accounts yet — add each subscription you want to track.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 26)
            } else {
                ForEach(Array(store.accounts.enumerated()), id: \.element.id) { index, account in
                    if index > 0 {
                        Divider().padding(.leading, 12)
                    }
                    row(for: account, at: index)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
    }

    private func row(for account: AccountMeta, at index: Int) -> some View {
        AccountSettingsRow(store: store, account: account)
            .background(
                dropTargetID == account.id ? Color.accentColor.opacity(0.15) : Color.clear)
            // Dragged payload is the account id. A plain string keeps this to
            // public API with no declared UTType; the drop validates the id,
            // so text dragged in from elsewhere is simply refused.
            .draggable(account.id) {
                DragPreview(account: account)
            }
            // Dropping on this row makes `index` the dragged account's new
            // index, so every position — first and last included — is
            // reachable.
            .dropDestination(for: String.self) { items, _ in
                dropTargetID = nil
                guard let draggedID = items.first else { return false }
                return store.moveAccount(id: draggedID, to: index)
            } isTargeted: { isTargeted in
                if isTargeted {
                    dropTargetID = account.id
                } else if dropTargetID == account.id {
                    // Only clear our own highlight: the row being entered may
                    // already have claimed it.
                    dropTargetID = nil
                }
            }
    }
}

/// What follows the cursor while dragging a row: the account, not a snapshot
/// of the whole row (whose text field and menu would look like live controls
/// floating over the window).
private struct DragPreview: View {
    let account: AccountMeta

    var body: some View {
        HStack(spacing: 8) {
            ProviderBadge(provider: account.provider)
            Text(account.displayLabel)
                .font(.callout.weight(.semibold))
            Text(account.email)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// One account: its name on top with the email beneath it, and its two
/// settings — quota weight and position — as trailing controls. Two lines
/// rather than one so a long email never squeezes the name, and the name is
/// an editable label rather than a form field, since reading it is the common
/// case and renaming the rare one.
struct AccountSettingsRow: View {
    /// Shared width for the trailing weight control, so every row's sits in
    /// the same column.
    static let weightColumnWidth: CGFloat = 150

    @ObservedObject var store: AccountStore
    let account: AccountMeta

    @State private var draftName = ""
    @State private var isEditingName = false
    @State private var confirmsRemoval = false
    @State private var isHoveringName = false
    @FocusState private var nameFocused: Bool

    /// The stored account, read live from the store — the row holds an
    /// immutable `account` snapshot, but weights and labels change under it.
    private var storedAccount: AccountMeta? {
        store.accounts.first { $0.id == account.id }
    }

    var body: some View {
        HStack(spacing: 10) {
            // Affordance for the row drag, and a safe place to grab: dragging
            // from the name field or the weight menu hits those controls.
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .frame(width: 12)
                .help("Drag to reorder")

            ProviderBadge(provider: account.provider)

            VStack(alignment: .leading, spacing: 1) {
                nameField
                Text(account.email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // Takes the slack, so a long email truncates rather than pushing
            // the trailing controls out of the window.
            .frame(maxWidth: .infinity, alignment: .leading)

            // One column width for every row, so the weights line up and the
            // rows that can't have one say why rather than leaving a hole.
            if account.provider == .claude {
                weightPicker
            } else {
                Text("—")
                    .foregroundStyle(.tertiary)
                    .frame(width: Self.weightColumnWidth, alignment: .trailing)
                    .help(
                        "Codex tier ratios aren't published, so these accounts stay "
                            + "unweighted in the best-account ranking.")
            }
            removeButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// A label that becomes a field on click. Three permanently bordered
    /// fields made the list read as a form whose loudest element was the part
    /// that changes least — and a live field takes focus the moment the tab
    /// opens, leaving an accidental keystroke one press from a rename.
    @ViewBuilder
    private var nameField: some View {
        if isEditingName {
            TextField(
                "Name", text: $draftName,
                prompt: Text(account.provider.displayName)
            )
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .frame(maxWidth: 180)
            .focused($nameFocused)
            // Commit on Return and on losing focus, rather than per keystroke:
            // a live binding would fight the user mid-word (the store trims and
            // folds empty names back to the provider name).
            .onSubmit { commitName() }
            .onExitCommand { isEditingName = false }
            .onChange(of: nameFocused) { _, focused in
                if !focused { commitName() }
            }
        } else {
            HStack(spacing: 4) {
                Text(storedAccount?.displayLabel ?? account.displayLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "pencil")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .opacity(isHoveringName ? 1 : 0)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(nameFieldFill)
            )
            .contentShape(Rectangle())
            .onHover { isHoveringName = $0 }
            .onTapGesture { startEditing() }
            .help("Click to rename")
        }
    }

    private func startEditing() {
        draftName = storedAccount?.label ?? ""
        isEditingName = true
        nameFocused = true
    }

    /// Only a hover hint now: the field itself is bordered while editing.
    private var nameFieldFill: Color {
        isHoveringName ? Color.primary.opacity(0.07) : .clear
    }

    /// The weight scales this account's window against the others when pooling
    /// burn rates behind the "Best" badge. Asking for a relative weight rather
    /// than a plan name keeps the user out of "is my Team premium seat a Max
    /// 5×?" territory: only the ratio between their own accounts matters.
    /// Claude only — Codex tier ratios aren't known, so those stay unweighted.
    ///
    /// Entry titles stay short because the collapsed button shows the selected
    /// one; the tier the API reported is the menu's last line, where it has the
    /// room the old side column never had.
    private var weightPicker: some View {
        Picker("Quota weight", selection: quotaMultiplierBinding) {
            Text(autoWeightLabel).tag(Optional<Double>.none)
            Text("Pro (×1)").tag(Optional(1.0))
            Text("Max 5× (×5)").tag(Optional(5.0))
            Text("Max 20× (×20)").tag(Optional(20.0))
            if let tier = storedAccount?.detectedRateLimitTier {
                Divider()
                // Non-interactive: exactly what the server said, so an
                // unrecognized plan can still be weighted knowingly.
                Text("API reports: \(tier)")
            }
        }
        .labelsHidden()
        .frame(width: Self.weightColumnWidth, alignment: .trailing)
        .help(
            "How big this account's session window is relative to your others "
                + "(one full Pro window = ×1). Used to pool burn rates across "
                + "differently-sized subscriptions — getting the ratio between "
                + "your accounts right is what matters, not identifying the plan "
                + "exactly.")
    }

    private var removeButton: some View {
        Button {
            confirmsRemoval = true
        } label: {
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Remove this account and its stored sign-in")
        // One click removes stored tokens and recorded history, and the way
        // back is a full browser sign-in — worth a confirmation.
        .confirmationDialog(
            "Remove \(account.displayLabel) (\(account.email))?",
            isPresented: $confirmsRemoval
        ) {
            Button("Remove Account", role: .destructive) {
                store.removeAccount(account)
            }
        } message: {
            Text(
                "Its stored sign-in and recorded usage history are deleted. "
                    + "Adding it back means signing in again.")
        }
    }

    /// The account's plan multiplier, read live from the store and written
    /// back through it.
    private var quotaMultiplierBinding: Binding<Double?> {
        Binding(
            get: { storedAccount?.quotaMultiplier },
            set: { store.setQuotaMultiplier(account, to: $0) }
        )
    }

    /// Label for the picker's nil (no manual override) entry: the weight
    /// detection settled on, or a plain statement that it didn't.
    private var autoWeightLabel: String {
        guard let detected = storedAccount?.detectedQuotaMultiplier else {
            return "Auto"
        }
        return "Auto · \(Self.shortPlanName(for: detected))"
    }

    /// Plan-name hint for a weight — a hint, not a definition: several
    /// subscriptions can share one weight (e.g. Max 5× and a Team seat).
    static func shortPlanName(for multiplier: Double) -> String {
        switch multiplier {
        case 1: return "Pro"
        case 5: return "Max 5×"
        case 20: return "Max 20×"
        default: return "×\(Int(multiplier))"
        }
    }

    private func commitName() {
        isEditingName = false
        let stored = storedAccount?.label ?? ""
        guard draftName != stored else { return }
        store.rename(account, to: draftName)
    }
}

// MARK: - Shared sign-in feedback

/// Progress and errors for an in-flight browser sign-in. Shown in both the
/// settings window (where accounts are added) and the panel (where an expired
/// account's "Sign in again" starts the same flow), so the feedback always
/// appears where the user pressed the button.
struct AddAccountStatus: View {
    @ObservedObject var store: AccountStore
    /// Matches the host's row inset (14 in the panel, 0 inside the accounts
    /// card, which brings its own padding).
    var horizontalPadding: CGFloat = 14
    /// The panel stacks this between dividers; the accounts tab doesn't.
    var showsDividers = true

    var body: some View {
        if store.isAddingAccount {
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
                Spacer(minLength: 0)
                Button("Cancel") { store.cancelAddAccount() }
                    .controlSize(.small)
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 8)
            if showsDividers { Divider() }
        }
        if let error = store.addAccountError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 6)
            if showsDividers { Divider() }
        }
    }
}
