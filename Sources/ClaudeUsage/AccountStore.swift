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
    let notifier: UsageNotifier

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

    /// Resolves the provider implementation for an account; injectable so
    /// tests can substitute canned responses for the real network clients.
    private let providerFactory: (ProviderID) -> any UsageProvider
    /// Token-vault storage: the real Keychain in production, in-memory fakes
    /// in tests.
    private let keychain: any KeychainStoring
    /// Backing store for the persisted account list.
    private let defaults: UserDefaults
    /// Burn-rate history sink fed by every successful refresh.
    private let history: UsageHistoryStore

    /// Production wiring, used by the app (and by mock mode, which returns
    /// early with fake data before touching any of these dependencies).
    convenience init() {
        self.init(
            providerFactory: Providers.provider(for:),
            keychain: SystemKeychain(),
            defaults: .standard,
            history: .shared,
            notifier: UsageNotifier(),
            startsRefreshLoop: true
        )
    }

    /// Injection point for tests: every effectful dependency is a parameter,
    /// and `startsRefreshLoop: false` keeps the infinite polling task from
    /// starting so tests drive each refresh explicitly.
    init(
        providerFactory: @escaping (ProviderID) -> any UsageProvider,
        keychain: any KeychainStoring,
        defaults: UserDefaults,
        history: UsageHistoryStore,
        notifier: UsageNotifier,
        startsRefreshLoop: Bool
    ) {
        self.providerFactory = providerFactory
        self.keychain = keychain
        self.defaults = defaults
        self.history = history
        self.notifier = notifier
        #if DEBUG
            if Mock.isEnabled {
                accounts = Mock.accounts
                states = Mock.states
                vaultLoaded = true
                return
            }
        #endif
        loadAccounts()
        if startsRefreshLoop { startRefreshLoop() }
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
                let result = try await providerFactory(providerID).login()
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
        keychain.delete(account: account.id)  // legacy per-account item, if any
        history.removeHistory(accountID: account.id)
        persistAccounts()
    }

    /// Re-run the browser login for an account whose refresh token died.
    func reauthenticate(_ account: AccountMeta) {
        beginAddAccount(provider: account.provider)
    }

    func storeLogin(_ result: LoginResult, provider: ProviderID) throws {
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

    // MARK: - Refresh

    /// Manual refresh: retries everything, ignoring cooldowns and reauth state.
    func refreshNow() {
        Task { await refreshAll(force: true) }
    }

    /// Called when the panel opens: refresh only what's stale, respecting
    /// cooldowns, so opening the menu never causes a request burst.
    func refreshIfStale() {
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

    func refresh(account: AccountMeta, force: Bool) async {
        if !force {
            // Don't hammer the token endpoint for accounts that need the user,
            // and honor 429 backoff deadlines.
            if states[account.id]?.needsReauth == true { return }
            if let cooldown = cooldownUntil[account.id], cooldown > Date() { return }
        }

        var state = states[account.id] ?? AccountDisplayState()
        do {
            let provider = providerFactory(account.provider)
            let token = try await validAccessToken(for: account)
            let snapshot = try await provider.fetchUsage(
                accessToken: token, accountID: account.id)
            state.limits = snapshot.limits
            state.credits = snapshot.credits
            state.lastUpdated = Date()
            history.record(snapshot.limits, accountID: account.id)
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
        loadVaultIfNeeded()
        guard var tokens = tokenVault[account.id] else {
            throw UsageError.unauthorized
        }

        if tokens.expiresAt.timeIntervalSinceNow < 120 {
            guard !tokens.refreshToken.isEmpty else { throw UsageError.unauthorized }
            do {
                let provider = providerFactory(account.provider)
                tokens = try await provider.refresh(tokens: tokens)
                tokenVault[account.id] = tokens
                persistVault()
            } catch {
                throw UsageError.unauthorized
            }
        }
        return tokens.accessToken
    }

    // MARK: - Token vault

    /// Loads the consolidated Keychain item once per launch, migrating any
    /// legacy per-account items into it (one final round of prompts).
    private func loadVaultIfNeeded() {
        guard !vaultLoaded else { return }
        vaultLoaded = true

        if let data = keychain.load(account: Keychain.vaultAccount),
            let decoded = try? JSONDecoder().decode([String: StoredTokens].self, from: data) {
            tokenVault = decoded
        }

        var migrated = false
        for account in accounts where tokenVault[account.id] == nil {
            if let data = keychain.load(account: account.id),
                let tokens = try? JSONDecoder().decode(StoredTokens.self, from: data) {
                tokenVault[account.id] = tokens
                keychain.delete(account: account.id)
                migrated = true
            }
        }
        if migrated { persistVault() }
    }

    private func persistVault() {
        if let data = try? JSONEncoder().encode(tokenVault) {
            try? keychain.save(data, account: Keychain.vaultAccount)
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
        guard let data = defaults.data(forKey: defaultsKey),
            let decoded = try? JSONDecoder().decode([AccountMeta].self, from: data)
        else { return }
        accounts = decoded
    }

    private func persistAccounts() {
        if let data = try? JSONEncoder().encode(accounts) {
            defaults.set(data, forKey: defaultsKey)
        }
    }
}
