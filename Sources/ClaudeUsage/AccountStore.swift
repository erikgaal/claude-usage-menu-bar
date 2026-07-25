import Foundation
import ServiceManagement
import SwiftUI

@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var accounts: [AccountMeta] = []
    @Published private(set) var states: [String: AccountDisplayState] = [:]
    @Published private(set) var isAddingAccount = false
    @Published private(set) var pendingProvider: ProviderID?
    @Published var addAccountError: String?
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    /// Local-notification manager; `refresh` feeds it old/new state diffs.
    let notifier = UsageNotifier()

    /// Opt-in. While on, the app owns Claude Code's sign-in: it can point the
    /// CLI at any Claude account here, and it defers to Claude Code's own
    /// credential store for the account that's signed in.
    @Published var managesClaudeCodeSignIn: Bool = UserDefaults.standard.bool(
        forKey: AccountStore.claudeCodeEnabledKey)
    {
        didSet {
            UserDefaults.standard.set(managesClaudeCodeSignIn, forKey: Self.claudeCodeEnabledKey)
            refreshClaudeCodeActive()
        }
    }
    /// Which account Claude Code is currently signed in as, when it's one we
    /// know about. Read from `~/.claude.json`, so keeping it current costs
    /// nothing and never prompts for Keychain access.
    @Published private(set) var claudeCodeActiveID: String?
    @Published var claudeCodeError: String?

    private static let claudeCodeEnabledKey = "managesClaudeCodeSignIn"
    /// Profiles live in the Keychain, beside the token vault.
    private static let claudeCodeProfilesAccount = "claude-code-profiles"
    /// Earlier builds of this feature kept them in UserDefaults; see
    /// `loadClaudeCodeProfilesIfNeeded`.
    private static let legacyClaudeCodeProfilesKey = "claudeCodeProfiles"

    /// What we captured from Claude Code the last time an account was the one
    /// signed in, so switching back restores it rather than replacing it with
    /// the minimum we can synthesize.
    ///
    /// Kept in the Keychain rather than UserDefaults. The known tokens are
    /// stripped before capture, but `credentialExtras` is deliberately
    /// forward-compatible — it preserves fields this app has never heard of —
    /// and "whatever Anthropic adds to a credential payload next" is not a
    /// safe thing to promise about in a plaintext plist.
    struct ClaudeCodeProfile: Codable {
        /// The account's OAuth block minus tokens: `subscriptionType`,
        /// `scopes`, and whatever Anthropic adds that we don't model.
        var credentialExtras: Data?
        /// The account's `oauthAccount` record — `seatTier`, billing, org and
        /// rate-limit tiers. We can't derive these, and Claude Code only
        /// refetches them lazily.
        var identity: Data?
    }

    private let claudeCodeStore = ClaudeCodeStore()
    private var claudeCodeProfiles: [String: ClaudeCodeProfile] = [:]
    private var claudeCodeProfilesLoaded = false

    private let defaultsKey = "accounts"
    /// Background poll cadence. The panel also refreshes on open when stale.
    private let pollInterval: TimeInterval = 300
    /// Consider data stale (worth refreshing on panel open) after this long.
    private let staleAfter: TimeInterval = 120
    /// Per-account backoff deadlines set by 429 responses.
    private var cooldownUntil: [String: Date] = [:]
    private var refreshLoop: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?

    /// All accounts' tokens, read from a single Keychain item once per launch.
    private var tokenVault: [String: StoredTokens] = [:]
    private var vaultLoaded = false

    init() {
        #if DEBUG
            if Mock.isEnabled {
                accounts = Mock.accounts
                states = Mock.states
                vaultLoaded = true
                return
            }
        #endif
        loadAccounts()
        refreshClaudeCodeActive()
        startRefreshLoop()
    }

    // MARK: - Menu bar summary

    /// One number per account (its most-used limit), e.g. "21 · 35%".
    var menuBarText: String {
        guard !accounts.isEmpty else { return "" }
        let parts = accounts.map { account -> String in
            guard let state = states[account.id] else { return "…" }
            if state.needsReauth { return "!" }
            guard let top = state.limits.map(\.percent).max() else {
                return state.error == nil ? "…" : "!"
            }
            return String(Int(top.rounded()))
        }
        return parts.joined(separator: "·") + "%"
    }

    var worstPercent: Double {
        accounts.compactMap { states[$0.id]?.limits.map(\.percent).max() }.max() ?? 0
    }

    var lastUpdatedOverall: Date? {
        accounts.compactMap { states[$0.id]?.lastUpdated }.max()
    }

    // MARK: - Best-account hint

    /// Accounts to badge as the current "best bet" — the same-provider
    /// account with the most session headroom. The ranking itself lives in
    /// `BestAccount` (a pure function) so it can be unit-tested without
    /// spinning up a store.
    var bestAccountIDs: Set<String> {
        BestAccount.winners(accounts: accounts, states: states)
    }

    // MARK: - Account management

    func beginAddAccount(provider providerID: ProviderID) {
        guard !isAddingAccount else { return }
        isAddingAccount = true
        pendingProvider = providerID
        addAccountError = nil
        loginTask = Task {
            do {
                let result = try await Providers.provider(for: providerID).login()
                try storeLogin(result, provider: providerID)
            } catch is CancellationError {
                // user cancelled — nothing to report
            } catch {
                addAccountError = error.localizedDescription
            }
            isAddingAccount = false
            pendingProvider = nil
        }
    }

    func cancelAddAccount() {
        loginTask?.cancel()
    }

    func rename(_ account: AccountMeta, to label: String) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        accounts[index].label = trimmed.isEmpty ? nil : trimmed
        persistAccounts()
    }

    /// Moves an account up (negative offset) or down (positive) in the list.
    /// Array order is the single source of truth — it drives the panel, the
    /// menu bar summary, and the persisted JSON — so this is the whole change.
    func moveAccount(_ account: AccountMeta, by offset: Int) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        let destination = index + offset
        guard accounts.indices.contains(destination), destination != index else { return }
        let moved = accounts.remove(at: index)
        accounts.insert(moved, at: destination)
        persistAccounts()
    }

    func removeAccount(_ account: AccountMeta) {
        accounts.removeAll { $0.id == account.id }
        states[account.id] = nil
        loadVaultIfNeeded()
        tokenVault[account.id] = nil
        persistVault()
        Keychain.delete(account: account.id)  // legacy per-account item, if any
        UsageHistoryStore.shared.removeHistory(accountID: account.id)
        loadClaudeCodeProfilesIfNeeded()
        claudeCodeProfiles[account.id] = nil
        persistClaudeCodeProfiles()
        // Recompute rather than blank it: the account is gone from `accounts`,
        // so this settles to nil if it was the active one and stays correct if
        // it wasn't. Claude Code is of course still signed in as it.
        refreshClaudeCodeActive()
        persistAccounts()
    }

    /// Re-run the browser login for an account whose refresh token died.
    func reauthenticate(_ account: AccountMeta) {
        beginAddAccount(provider: account.provider)
    }

    private func storeLogin(_ result: LoginResult, provider: ProviderID) throws {
        loadVaultIfNeeded()
        tokenVault[result.accountID] = result.tokens
        persistVault()

        // Keep the user-chosen label when re-authenticating an existing account.
        let existingLabel = accounts.first(where: { $0.id == result.accountID })?.label
        let meta = AccountMeta(
            id: result.accountID,
            email: result.email,
            organizationName: result.organizationName,
            provider: provider,
            label: existingLabel
        )
        if let index = accounts.firstIndex(where: { $0.id == meta.id }) {
            accounts[index] = meta
        } else {
            accounts.append(meta)
        }
        var state = states[meta.id] ?? AccountDisplayState()
        state.needsReauth = false
        state.error = nil
        states[meta.id] = state
        persistAccounts()
        // Claude Code may already be signed in as the account just added, and
        // `claudeCodeActiveID` only counts accounts we hold — so this is the
        // moment that becomes true.
        refreshClaudeCodeActive()

        Task { await self.refresh(account: meta, force: true) }
    }

    // MARK: - Claude Code sign-in

    /// Published rather than derived from a task handle: the context menu's
    /// disabled state reads this, and a plain stored property gives SwiftUI
    /// nothing to re-render on when a switch starts or finishes.
    @Published private(set) var isSwitchingClaudeCode = false

    /// Cheap enough to call on every panel open — it reads `~/.claude.json`
    /// and never touches the Keychain.
    ///
    /// Filtered to accounts we hold, so this really does mean what its
    /// declaration says. Claude Code may well be signed in as an account the
    /// user never added here; that isn't a chain we share, and every consumer
    /// — the badge, the switch guard, `TokenSource` — wants nil for it.
    func refreshClaudeCodeActive() {
        guard managesClaudeCodeSignIn, let active = claudeCodeStore.currentAccountID(),
            accounts.contains(where: { $0.id == active })
        else {
            claudeCodeActiveID = nil
            return
        }
        claudeCodeActiveID = active
    }

    /// Points Claude Code — and the desktop app and IDE extensions, which
    /// share its credential store — at this account. Running `claude` sessions
    /// pick the change up within ~30s when their credential cache next lapses;
    /// they don't need restarting.
    func useForClaudeCode(_ account: AccountMeta) {
        guard managesClaudeCodeSignIn, account.provider == .claude,
            !isSwitchingClaudeCode, account.id != claudeCodeActiveID
        else { return }

        claudeCodeError = nil
        isSwitchingClaudeCode = true
        Task {
            await performClaudeCodeSwitch(to: account)
            isSwitchingClaudeCode = false
        }
    }

    private func performClaudeCodeSwitch(to account: AccountMeta) async {
        do {
            // Get the target's tokens ready before taking the lock: this chain
            // isn't shared with Claude Code yet, so refreshing it here is safe,
            // and it keeps a network round trip out of the critical section.
            let tokens = try await validTokens(for: account)
            loadClaudeCodeProfilesIfNeeded()
            let profile = claudeCodeProfiles[account.id]

            // Prefer the account's own record if we've ever captured it;
            // otherwise the minimal block, which Claude Code fills in for
            // itself on its next profile fetch.
            let identity: Data
            if let captured = profile?.identity,
                let block = try? JSONSerialization.jsonObject(with: captured) as? [String: Any]
            {
                identity = try JSONSerialization.data(
                    withJSONObject: ClaudeCodeSession.identityForRestore(block))
            } else {
                identity = try JSONSerialization.data(
                    withJSONObject: ClaudeCodeSession.oauthAccount(for: account))
            }

            let result = try await claudeCodeStore.switchAccount(
                to: account.id,
                knownCurrentID: claudeCodeActiveID,
                tokens: tokens,
                extras: profile?.credentialExtras,
                oauthAccount: identity)

            // Fold the outgoing account's salvaged state back in. Its tokens
            // may have been rotated by Claude Code since we last looked, which
            // would have left our copy dead.
            //
            // Only for accounts we actually hold: Claude Code may have been
            // signed in as one the user never added here, and filing a
            // stranger's refresh token in the vault would retain a credential
            // that no menu can select and `removeAccount` can never clear.
            if let outgoing = result.harvestedAccountID,
                accounts.contains(where: { $0.id == outgoing })
            {
                if let harvested = result.harvestedTokens {
                    loadVaultIfNeeded()
                    tokenVault[outgoing] = harvested
                    persistVault()
                    states[outgoing]?.needsReauth = false
                    states[outgoing]?.error = nil
                }
                if result.harvestedExtras != nil || result.harvestedIdentity != nil {
                    claudeCodeProfiles[outgoing] = ClaudeCodeProfile(
                        credentialExtras: result.harvestedExtras
                            ?? claudeCodeProfiles[outgoing]?.credentialExtras,
                        identity: result.harvestedIdentity
                            ?? claudeCodeProfiles[outgoing]?.identity)
                    persistClaudeCodeProfiles()
                }
            }

            claudeCodeActiveID = account.id
            ClaudeCodeSwitchPrompt.recordAcknowledged()
            await refresh(account: account, force: true)
        } catch {
            claudeCodeError = error.localizedDescription
        }
    }

    /// Lazy for the same reason `loadVaultIfNeeded` is: nothing should touch
    /// the Keychain just because the app launched. Every site that mutates
    /// `claudeCodeProfiles` must call this first, or it would persist an empty
    /// dictionary over the stored one.
    private func loadClaudeCodeProfilesIfNeeded() {
        guard !claudeCodeProfilesLoaded else { return }
        claudeCodeProfilesLoaded = true

        // Profiles used to live in UserDefaults. They're re-captured on the
        // next switch and Claude Code refetches what it needs, so the old copy
        // is purged rather than migrated — leaving credential-adjacent fields
        // sitting in a plaintext plist is the thing being fixed.
        UserDefaults.standard.removeObject(forKey: Self.legacyClaudeCodeProfilesKey)

        guard let data = Keychain.load(account: Self.claudeCodeProfilesAccount),
            let decoded = try? JSONDecoder().decode(
                [String: ClaudeCodeProfile].self, from: data)
        else { return }
        claudeCodeProfiles = decoded
    }

    private func persistClaudeCodeProfiles() {
        if let data = try? JSONEncoder().encode(claudeCodeProfiles) {
            try? Keychain.save(data, account: Self.claudeCodeProfilesAccount)
        }
    }

    // MARK: - Refresh

    /// Manual refresh: retries everything, ignoring cooldowns and reauth state.
    func refreshNow() {
        Task { await refreshAll(force: true) }
    }

    /// Called when the panel opens: refresh only what's stale, respecting
    /// cooldowns, so opening the menu never causes a request burst.
    func refreshIfStale() {
        refreshClaudeCodeActive()
        Task {
            await withTaskGroup(of: Void.self) { group in
                for account in accounts {
                    let updated = states[account.id]?.lastUpdated
                    guard updated == nil
                        || Date().timeIntervalSince(updated!) > staleAfter
                    else { continue }
                    group.addTask { await self.refresh(account: account, force: false) }
                }
            }
        }
    }

    private func startRefreshLoop() {
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAll(force: false)
                let interval = self?.pollInterval ?? 300
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            }
        }
    }

    private func refreshAll(force: Bool) async {
        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                group.addTask { await self.refresh(account: account, force: force) }
            }
        }
    }

    private func refresh(account: AccountMeta, force: Bool) async {
        if !force {
            // Don't hammer the token endpoint for accounts that need the user,
            // and honor 429 backoff deadlines.
            if states[account.id]?.needsReauth == true { return }
            if let cooldown = cooldownUntil[account.id], cooldown > Date() { return }
        }

        var state = states[account.id] ?? AccountDisplayState()
        do {
            let provider = Providers.provider(for: account.provider)
            let token = try await validAccessToken(for: account)
            let snapshot = try await provider.fetchUsage(
                accessToken: token, accountID: account.id)
            state.limits = snapshot.limits
            state.credits = snapshot.credits
            state.lastUpdated = Date()
            UsageHistoryStore.shared.record(snapshot.limits, accountID: account.id)
            state.error = nil
            state.needsReauth = false
            cooldownUntil[account.id] = nil
        } catch UsageError.unauthorized {
            state.error = "Sign-in expired"
            state.needsReauth = true
        } catch UsageError.rateLimited(let until) {
            cooldownUntil[account.id] = until
            state.error = UsageError.rateLimited(until: until).localizedDescription
        } catch {
            state.error = error.localizedDescription
        }
        notifier.accountDidUpdate(account, old: states[account.id], new: state)
        states[account.id] = state
    }

    private func validAccessToken(for account: AccountMeta) async throws -> String {
        try await validTokens(for: account).accessToken
    }

    /// Dispatches on `TokenSource`, which is where the one rule that must not
    /// bend lives: only the side that owns a chain may refresh it. Each branch
    /// returns or throws, so the shared-chain case can't reach the refresh
    /// below by falling through.
    private func validTokens(for account: AccountMeta) async throws -> StoredTokens {
        loadVaultIfNeeded()

        switch TokenSource.of(
            accountID: account.id,
            vault: tokenVault,
            claudeCodeManages: managesClaudeCodeSignIn,
            claudeCodeActiveID: claudeCodeActiveID)
        {
        case .mirrored(let tokens):
            return tokens
        case .claudeCode:
            return try await tokensThroughClaudeCode(for: account)
        case .ownRefresh(let tokens):
            return try await refreshOwnChain(tokens, for: account)
        case .unauthorized:
            throw UsageError.unauthorized
        }
    }

    /// Reads the signed-in account's tokens from Claude Code's store, letting
    /// *it* do any refresh under its own lock. Reading through also picks up
    /// rotations Claude Code has already done, which would otherwise have left
    /// our copy dead.
    ///
    /// Throws rather than falling back on our mirrored copy. Reaching here
    /// means that copy needs refreshing too, and refreshing it would rotate
    /// the shared chain and sign the CLI out — the exact failure this whole
    /// arrangement exists to prevent. One stale poll is much the cheaper loss,
    /// and `.claudeCodeUnreadable` keeps it out of the reauth machinery.
    private func tokensThroughClaudeCode(
        for account: AccountMeta
    ) async throws -> StoredTokens {
        let provider = Providers.provider(for: account.provider)
        do {
            let tokens = try await claudeCodeStore.activeAccessToken(
                refresh: { try await provider.refresh(tokens: $0) })
            tokenVault[account.id] = tokens
            persistVault()
            return tokens
        } catch {
            // Authorization declined, the lock held by a running `claude`
            // session, or the format moved on — all transient enough to retry
            // on the next poll, none worth rotating the chain over.
            throw UsageError.claudeCodeUnreadable
        }
    }

    private func refreshOwnChain(
        _ tokens: StoredTokens, for account: AccountMeta
    ) async throws -> StoredTokens {
        do {
            let provider = Providers.provider(for: account.provider)
            let refreshed = try await provider.refresh(tokens: tokens)
            tokenVault[account.id] = refreshed
            persistVault()
            return refreshed
        } catch {
            throw UsageError.unauthorized
        }
    }

    // MARK: - Token vault

    /// Loads the consolidated Keychain item once per launch, migrating any
    /// legacy per-account items into it (one final round of prompts).
    private func loadVaultIfNeeded() {
        guard !vaultLoaded else { return }
        vaultLoaded = true

        if let data = Keychain.load(account: Keychain.vaultAccount),
            let decoded = try? JSONDecoder().decode([String: StoredTokens].self, from: data) {
            tokenVault = decoded
        }

        var migrated = false
        for account in accounts where tokenVault[account.id] == nil {
            if let data = Keychain.load(account: account.id),
                let tokens = try? JSONDecoder().decode(StoredTokens.self, from: data) {
                tokenVault[account.id] = tokens
                Keychain.delete(account: account.id)
                migrated = true
            }
        }
        if migrated { persistVault() }
    }

    private func persistVault() {
        if let data = try? JSONEncoder().encode(tokenVault) {
            try? Keychain.save(data, account: Keychain.vaultAccount)
        }
    }

    // MARK: - Launch at login

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Fails when not running from a proper .app bundle; reflect reality.
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Persistence

    private func loadAccounts() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
            let decoded = try? JSONDecoder().decode([AccountMeta].self, from: data)
        else { return }
        accounts = decoded
    }

    private func persistAccounts() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
