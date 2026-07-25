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
    private static let claudeCodeProfilesKey = "claudeCodeProfiles"

    /// What we captured from Claude Code the last time an account was the one
    /// signed in, so switching back restores it rather than replacing it with
    /// the minimum we can synthesize. Token material is stripped out, so this
    /// holds no secrets and belongs in UserDefaults rather than the Keychain.
    struct ClaudeCodeProfile: Codable {
        /// Credential payload minus tokens: `subscriptionType`, `scopes`, and
        /// whatever Anthropic adds that we don't model.
        var credentialExtras: Data?
        /// The account's `oauthAccount` record — `seatTier`, billing, org and
        /// rate-limit tiers. We can't derive these, and Claude Code only
        /// refetches them lazily.
        var identity: Data?
    }

    private let claudeCodeStore = ClaudeCodeStore()
    private var claudeCodeProfiles: [String: ClaudeCodeProfile] = [:]
    private var claudeCodeSwitchTask: Task<Void, Never>?

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
        loadClaudeCodeProfiles()
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
        claudeCodeProfiles[account.id] = nil
        persistClaudeCodeProfiles()
        if claudeCodeActiveID == account.id { claudeCodeActiveID = nil }
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

        Task { await self.refresh(account: meta, force: true) }
    }

    // MARK: - Claude Code sign-in

    /// Accounts this can switch between: Claude subscriptions we hold tokens
    /// for. Codex accounts aren't Claude Code sign-ins.
    var claudeCodeSwitchableAccounts: [AccountMeta] {
        accounts.filter { $0.provider == .claude }
    }

    var isSwitchingClaudeCode: Bool { claudeCodeSwitchTask != nil }

    /// Cheap enough to call on every panel open — it reads `~/.claude.json`
    /// and never touches the Keychain.
    func refreshClaudeCodeActive() {
        guard managesClaudeCodeSignIn else {
            claudeCodeActiveID = nil
            return
        }
        claudeCodeActiveID = claudeCodeStore.currentAccountID()
    }

    /// Points Claude Code — and the desktop app and IDE extensions, which
    /// share its credential store — at this account. Running `claude` sessions
    /// pick the change up within ~30s when their credential cache next lapses;
    /// they don't need restarting.
    func useForClaudeCode(_ account: AccountMeta) {
        guard managesClaudeCodeSignIn, account.provider == .claude,
            claudeCodeSwitchTask == nil, account.id != claudeCodeActiveID
        else { return }

        claudeCodeError = nil
        claudeCodeSwitchTask = Task {
            await performClaudeCodeSwitch(to: account)
            claudeCodeSwitchTask = nil
        }
    }

    private func performClaudeCodeSwitch(to account: AccountMeta) async {
        do {
            // Get the target's tokens ready before taking the lock: this chain
            // isn't shared with Claude Code yet, so refreshing it here is safe,
            // and it keeps a network round trip out of the critical section.
            let tokens = try await validTokens(for: account)
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
            if let outgoing = result.harvestedAccountID {
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
            await refresh(account: account, force: true)
        } catch {
            claudeCodeError = error.localizedDescription
        }
    }

    private func loadClaudeCodeProfiles() {
        guard let data = UserDefaults.standard.data(forKey: Self.claudeCodeProfilesKey),
            let decoded = try? JSONDecoder().decode(
                [String: ClaudeCodeProfile].self, from: data)
        else { return }
        claudeCodeProfiles = decoded
    }

    private func persistClaudeCodeProfiles() {
        if let data = try? JSONEncoder().encode(claudeCodeProfiles) {
            UserDefaults.standard.set(data, forKey: Self.claudeCodeProfilesKey)
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

    /// Whether our mirrored copy can still be used as-is.
    ///
    /// Rotation invalidates the *refresh* token, not the access token already
    /// issued, so a copy Claude Code has since rotated past is still perfectly
    /// good for reading usage until it expires. Leaning on that keeps us off
    /// Claude Code's Keychain item — and off its authorization prompt — on all
    /// but roughly one poll per token lifetime, instead of every five minutes.
    private func hasUsableToken(for accountID: String) -> Bool {
        guard let tokens = tokenVault[accountID] else { return false }
        return tokens.expiresAt.timeIntervalSinceNow > 120
    }

    private func validTokens(for account: AccountMeta) async throws -> StoredTokens {
        loadVaultIfNeeded()

        // While we manage sign-in, Claude Code's own store owns the signed-in
        // account's token chain — both sides hold the same chain, refresh
        // tokens are single-use, and an uncoordinated refresh here would sign
        // the CLI out. Reading through it also picks up rotations Claude Code
        // has already done, which would otherwise have left our copy dead.
        if managesClaudeCodeSignIn, account.id == claudeCodeActiveID,
            !hasUsableToken(for: account.id)
        {
            let provider = Providers.provider(for: account.provider)
            if let tokens = try? await claudeCodeStore.activeAccessToken(refresh: {
                try await provider.refresh(tokens: $0)
            }) {
                tokenVault[account.id] = tokens
                persistVault()
                return tokens
            }
            // Unreadable (authorization declined, or the format moved on):
            // fall through to our own copy rather than stop reporting usage.
        }

        guard var tokens = tokenVault[account.id] else {
            throw UsageError.unauthorized
        }

        if tokens.expiresAt.timeIntervalSinceNow < 120 {
            guard !tokens.refreshToken.isEmpty else { throw UsageError.unauthorized }
            do {
                let provider = Providers.provider(for: account.provider)
                tokens = try await provider.refresh(tokens: tokens)
                tokenVault[account.id] = tokens
                persistVault()
            } catch {
                throw UsageError.unauthorized
            }
        }
        return tokens
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
