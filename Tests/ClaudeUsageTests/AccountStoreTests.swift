import XCTest

@testable import ClaudeUsage

// MARK: - Fakes

/// In-memory stand-in for the real Keychain: a dictionary, no prompts.
private final class KeychainFake: KeychainStoring {
    var storage: [String: Data] = [:]

    func save(_ data: Data, account: String) throws { storage[account] = data }
    func load(account: String) -> Data? { storage[account] }
    func delete(account: String) { storage[account] = nil }

    /// Decodes the consolidated token vault the way `AccountStore` persists it.
    var vault: [String: StoredTokens] {
        guard let data = storage[Keychain.vaultAccount] else { return [:] }
        return (try? JSONDecoder().decode([String: StoredTokens].self, from: data)) ?? [:]
    }

    func seedVault(_ vault: [String: StoredTokens]) {
        storage[Keychain.vaultAccount] = try! JSONEncoder().encode(vault)
    }
}

/// Canned-response provider. `@unchecked Sendable` because the protocol
/// requires `Sendable`; the lock serializes what little state there is.
private final class ProviderFake: UsageProvider, @unchecked Sendable {
    let id: ProviderID
    let accountKind = "Fake account"

    private let lock = NSLock()
    private var _fetchResultsByAccount: [String: Result<UsageSnapshot, Error>] = [:]
    private var _fetchResult: Result<UsageSnapshot, Error>
    private var _refreshResult: Result<StoredTokens, Error>
    private var _loginResult: Result<LoginResult, Error>
    private var _profileResult: Result<DetectedPlan?, Error>
    private var _fetchCalls: [(accessToken: String, accountID: String)] = []
    private var _refreshCalls: [StoredTokens] = []
    private var _profileCalls: [String] = []

    init(
        id: ProviderID = .claude,
        fetchResult: Result<UsageSnapshot, Error> = .success(UsageSnapshot(limits: [], credits: nil))
    ) {
        self.id = id
        _fetchResult = fetchResult
        _refreshResult = .failure(UsageError.http(0, "token refresh not stubbed"))
        _loginResult = .failure(UsageError.http(0, "login not stubbed"))
        _profileResult = .success(nil)
    }

    var fetchResult: Result<UsageSnapshot, Error> {
        get { lock.withLock { _fetchResult } }
        set { lock.withLock { _fetchResult = newValue } }
    }
    var refreshResult: Result<StoredTokens, Error> {
        get { lock.withLock { _refreshResult } }
        set { lock.withLock { _refreshResult = newValue } }
    }
    var loginResult: Result<LoginResult, Error> {
        get { lock.withLock { _loginResult } }
        set { lock.withLock { _loginResult = newValue } }
    }
    var profileResult: Result<DetectedPlan?, Error> {
        get { lock.withLock { _profileResult } }
        set { lock.withLock { _profileResult = newValue } }
    }
    var fetchCalls: [(accessToken: String, accountID: String)] {
        lock.withLock { _fetchCalls }
    }
    var refreshCalls: [StoredTokens] {
        lock.withLock { _refreshCalls }
    }
    var profileCalls: [String] {
        lock.withLock { _profileCalls }
    }

    func setFetchResult(_ result: Result<UsageSnapshot, Error>, forAccount accountID: String) {
        lock.withLock { _fetchResultsByAccount[accountID] = result }
    }

    func login() async throws -> LoginResult {
        try loginResult.get()
    }

    func refresh(tokens: StoredTokens) async throws -> StoredTokens {
        let result: Result<StoredTokens, Error> = lock.withLock {
            _refreshCalls.append(tokens)
            return _refreshResult
        }
        return try result.get()
    }

    func fetchUsage(accessToken: String, accountID: String) async throws -> UsageSnapshot {
        let result: Result<UsageSnapshot, Error> = lock.withLock {
            _fetchCalls.append((accessToken, accountID))
            return _fetchResultsByAccount[accountID] ?? _fetchResult
        }
        return try result.get()
    }

    func fetchProfile(accessToken: String) async throws -> DetectedPlan? {
        let result: Result<DetectedPlan?, Error> = lock.withLock {
            _profileCalls.append(accessToken)
            return _profileResult
        }
        return try result.get()
    }
}

/// Minimal notification spy: records immediate banners, drops the rest.
/// (Scheduling behavior itself is covered by `UsageNotifierTests`.)
@MainActor
private final class SchedulerSpy: NotificationScheduling {
    private(set) var posted: [(title: String, body: String)] = []

    func requestAuthorization() {}
    func add(identifier: String, title: String, body: String, fireDate: Date?) {
        if fireDate == nil { posted.append((title, body)) }
    }
    func pendingIdentifiers(completion: @escaping @MainActor ([String]) -> Void) {
        completion([])
    }
    func removePending(identifiers: [String]) {}
    func removeAllPending() {}
}

// MARK: - Tests

@MainActor
final class AccountStoreTests: XCTestCase {

    /// A store wired entirely to fakes, plus handles onto each of them.
    private struct Harness {
        let store: AccountStore
        let provider: ProviderFake
        let keychain: KeychainFake
        let defaults: UserDefaults
        let historyDirectory: URL
        let scheduler: SchedulerSpy
    }

    // MARK: Fixtures

    private func makeDefaults() -> UserDefaults {
        let suiteName = "AccountStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func makeHistoryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccountStoreTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Builds a store on isolated fakes with the refresh loop off, so nothing
    /// real is touched and tests drive every refresh explicitly. Accounts and
    /// tokens are seeded through the same persistence formats production uses.
    private func makeHarness(
        provider: ProviderFake = ProviderFake(),
        accounts: [AccountMeta] = [],
        vault: [String: StoredTokens] = [:],
        defaults existingDefaults: UserDefaults? = nil,
        keychain existingKeychain: KeychainFake? = nil,
        notificationsEnabled: Bool = false
    ) -> Harness {
        let defaults = existingDefaults ?? makeDefaults()
        if !accounts.isEmpty {
            defaults.set(try! JSONEncoder().encode(accounts), forKey: "accounts")
        }
        let keychain = existingKeychain ?? KeychainFake()
        if !vault.isEmpty { keychain.seedVault(vault) }
        let scheduler = SchedulerSpy()
        let notifier = UsageNotifier(scheduler: scheduler, defaults: defaults)
        if notificationsEnabled { notifier.isEnabled = true }
        let historyDirectory = makeHistoryDirectory()
        let store = AccountStore(
            providerFactory: { _ in provider },
            keychain: keychain,
            defaults: defaults,
            history: UsageHistoryStore(directory: historyDirectory),
            notifier: notifier,
            startsRefreshLoop: false
        )
        return Harness(
            store: store, provider: provider, keychain: keychain,
            defaults: defaults, historyDirectory: historyDirectory, scheduler: scheduler)
    }

    private func makeAccount(
        id: String = "acct-1", email: String = "user@example.com",
        provider: ProviderID = .claude, label: String? = nil
    ) -> AccountMeta {
        AccountMeta(
            id: id, email: email, organizationName: nil, provider: provider, label: label)
    }

    private func makeTokens(
        access: String = "access-1", refresh: String = "refresh-1",
        expiresAt: Date = Date().addingTimeInterval(3600)
    ) -> StoredTokens {
        StoredTokens(accessToken: access, refreshToken: refresh, expiresAt: expiresAt)
    }

    private func makeSnapshot(
        percents: [Double] = [42], credits: CreditsStatus? = nil
    ) -> UsageSnapshot {
        UsageSnapshot(
            limits: percents.enumerated().map { index, percent in
                LimitStatus(
                    id: "limit-\(index)", name: "Limit \(index)", percent: percent,
                    resetsAt: nil, isActive: index == 0, sortOrder: index)
            },
            credits: credits)
    }

    /// A single "Session" window at `percent`, shaped like the providers
    /// build it, so `BestAccount` and the history store treat it as the
    /// session slot.
    private func makeSessionSnapshot(percent: Double) -> UsageSnapshot {
        UsageSnapshot(
            limits: [
                LimitStatus(
                    id: "session|", name: "Session", percent: percent,
                    resetsAt: nil, isActive: true, sortOrder: 0)
            ],
            credits: nil)
    }

    /// A "Session" window plus one weekly window resetting `weeklyResetIn`
    /// from now — the shape the weekly leg of the best-account hint needs.
    private func makeWeeklySnapshot(
        session: Double, weekly: Double, weeklyResetIn: TimeInterval
    ) -> UsageSnapshot {
        UsageSnapshot(
            limits: [
                LimitStatus(
                    id: "session|", name: "Session", percent: session,
                    resetsAt: nil, isActive: true, sortOrder: 0),
                LimitStatus(
                    id: "weekly_all|", name: "Weekly", percent: weekly,
                    resetsAt: Date().addingTimeInterval(weeklyResetIn),
                    isActive: false, sortOrder: 1),
            ],
            credits: nil)
    }

    /// Seeds a synthetic ramp for one limit into the harness's history
    /// directory: 12 samples five minutes apart, climbing at `ratePerHour`
    /// and ending at `endPercent` right about now. Written through a second
    /// `UsageHistoryStore` over the same directory, which the store's own
    /// history store picks up from disk on first read.
    private func seedSessionRamp(
        directory: URL, account: String, endPercent: Double, ratePerHour: Double,
        limitID: String = "session|", limitName: String = "Session"
    ) {
        let store = UsageHistoryStore(directory: directory)
        let now = Date()
        let interval: TimeInterval = 300
        let count = 12
        for index in 0..<count {
            let stepsBack = Double(count - 1 - index)
            let limit = LimitStatus(
                id: limitID, name: limitName,
                percent: endPercent - ratePerHour * stepsBack * interval / 3600,
                resetsAt: nil, isActive: true, sortOrder: 0)
            store.record(
                [limit], accountID: account,
                at: now.addingTimeInterval(-stepsBack * interval))
        }
    }

    private func makeLogin(
        id: String = "acct-1", email: String = "user@example.com",
        tokens: StoredTokens? = nil
    ) -> LoginResult {
        LoginResult(
            accountID: id, email: email, organizationName: nil,
            tokens: tokens ?? makeTokens())
    }

    private func decodedAccounts(in defaults: UserDefaults) throws -> [AccountMeta] {
        let data = try XCTUnwrap(defaults.data(forKey: "accounts"))
        return try JSONDecoder().decode([AccountMeta].self, from: data)
    }

    /// Waits for a fire-and-forget task (e.g. the refresh `storeLogin` spawns)
    /// to land, so assertions never race the store's background work.
    private func waitFor(
        _ condition: () -> Bool, timeout: TimeInterval = 2,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            await Task.yield()
        }
        XCTAssertTrue(condition(), "condition not met before timeout", file: file, line: line)
    }

    // MARK: Refresh — success

    func testRefreshSuccessStoresSnapshot() async {
        let account = makeAccount()
        let credits = CreditsStatus(
            usedMinor: 120, limitMinor: 500, currency: "GBP", exponent: 2,
            percent: nil, enabled: true)
        let provider = ProviderFake(
            fetchResult: .success(makeSnapshot(percents: [42.5], credits: credits)))
        let harness = makeHarness(
            provider: provider, accounts: [account], vault: [account.id: makeTokens()])

        await harness.store.refresh(account: account, force: false)

        let state = harness.store.states[account.id]
        XCTAssertEqual(state?.limits.map(\.percent), [42.5])
        XCTAssertEqual(state?.credits, credits)
        XCTAssertNotNil(state?.lastUpdated)
        XCTAssertNil(state?.error)
        XCTAssertEqual(state?.needsReauth, false)
        XCTAssertEqual(provider.fetchCalls.map(\.accessToken), ["access-1"])
        XCTAssertEqual(provider.fetchCalls.map(\.accountID), [account.id])
        // A valid token is used as-is; no token refresh round-trip.
        XCTAssertTrue(provider.refreshCalls.isEmpty)
    }

    func testRefreshSuccessRecordsHistory() async {
        let account = makeAccount()
        let harness = makeHarness(
            provider: ProviderFake(fetchResult: .success(makeSnapshot())),
            accounts: [account], vault: [account.id: makeTokens()])

        await harness.store.refresh(account: account, force: false)

        let file = harness.historyDirectory.appendingPathComponent("\(account.id).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testRefreshSuccessClearsPreviousErrorAndCooldown() async {
        let account = makeAccount()
        let provider = ProviderFake(
            fetchResult: .failure(UsageError.rateLimited(until: Date().addingTimeInterval(3600))))
        let harness = makeHarness(
            provider: provider, accounts: [account], vault: [account.id: makeTokens()])

        await harness.store.refresh(account: account, force: false)
        XCTAssertNotNil(harness.store.states[account.id]?.error)

        provider.fetchResult = .success(makeSnapshot())
        await harness.store.refresh(account: account, force: true)
        XCTAssertNil(harness.store.states[account.id]?.error)

        // The 429 cooldown must be gone after a success: a further non-forced
        // refresh reaches the provider again instead of being skipped.
        await harness.store.refresh(account: account, force: false)
        XCTAssertEqual(provider.fetchCalls.count, 3)
    }

    // MARK: Refresh — failures

    func testUnauthorizedMarksNeedsReauthAndSkipsNonForcedRetries() async {
        let account = makeAccount()
        let provider = ProviderFake(fetchResult: .failure(UsageError.unauthorized))
        let harness = makeHarness(
            provider: provider, accounts: [account], vault: [account.id: makeTokens()])

        await harness.store.refresh(account: account, force: false)
        XCTAssertEqual(harness.store.states[account.id]?.needsReauth, true)
        XCTAssertEqual(harness.store.states[account.id]?.error, "Sign-in expired")

        // Background polling must not hammer a dead sign-in…
        await harness.store.refresh(account: account, force: false)
        XCTAssertEqual(provider.fetchCalls.count, 1)

        // …but a manual (forced) refresh retries it.
        await harness.store.refresh(account: account, force: true)
        XCTAssertEqual(provider.fetchCalls.count, 2)
    }

    func testRateLimitedSetsCooldownHonoredByNonForcedRefreshes() async {
        let until = Date().addingTimeInterval(3600)
        let account = makeAccount()
        let provider = ProviderFake(fetchResult: .failure(UsageError.rateLimited(until: until)))
        let harness = makeHarness(
            provider: provider, accounts: [account], vault: [account.id: makeTokens()])

        await harness.store.refresh(account: account, force: false)
        XCTAssertEqual(provider.fetchCalls.count, 1)
        XCTAssertEqual(
            harness.store.states[account.id]?.error,
            UsageError.rateLimited(until: until).localizedDescription)
        XCTAssertEqual(harness.store.states[account.id]?.needsReauth, false)

        // Before the deadline a non-forced refresh is skipped entirely.
        provider.fetchResult = .success(makeSnapshot())
        await harness.store.refresh(account: account, force: false)
        XCTAssertEqual(provider.fetchCalls.count, 1)
        XCTAssertEqual(harness.store.states[account.id]?.limits, [])

        // A forced refresh ignores the cooldown.
        await harness.store.refresh(account: account, force: true)
        XCTAssertEqual(provider.fetchCalls.count, 2)
        XCTAssertEqual(harness.store.states[account.id]?.limits.count, 1)
    }

    func testGenericErrorIsSurfacedAndPreviousDataRetained() async {
        let account = makeAccount()
        let provider = ProviderFake(fetchResult: .success(makeSnapshot(percents: [42])))
        let harness = makeHarness(
            provider: provider, accounts: [account], vault: [account.id: makeTokens()])

        await harness.store.refresh(account: account, force: false)
        let lastUpdated = harness.store.states[account.id]?.lastUpdated
        XCTAssertNotNil(lastUpdated)

        provider.fetchResult = .failure(UsageError.http(500, "boom"))
        await harness.store.refresh(account: account, force: true)

        let state = harness.store.states[account.id]
        XCTAssertEqual(state?.error?.contains("500"), true)
        // The last good data stays on screen behind the error banner.
        XCTAssertEqual(state?.limits.map(\.percent), [42])
        XCTAssertEqual(state?.lastUpdated, lastUpdated)
        XCTAssertEqual(state?.needsReauth, false)

        // A plain HTTP failure sets no cooldown: the next poll retries.
        provider.fetchResult = .success(makeSnapshot())
        await harness.store.refresh(account: account, force: false)
        XCTAssertEqual(provider.fetchCalls.count, 3)
    }

    // MARK: Token handling

    func testExpiredTokenIsRefreshedAndPersisted() async {
        let account = makeAccount()
        let provider = ProviderFake(fetchResult: .success(makeSnapshot()))
        provider.refreshResult = .success(
            makeTokens(
                access: "access-2", refresh: "refresh-2",
                expiresAt: Date().addingTimeInterval(7200)))
        let harness = makeHarness(
            provider: provider, accounts: [account],
            // Expires within the 120 s margin, so a refresh is required.
            vault: [account.id: makeTokens(expiresAt: Date().addingTimeInterval(60))])

        await harness.store.refresh(account: account, force: false)

        XCTAssertEqual(provider.refreshCalls.count, 1)
        XCTAssertEqual(provider.refreshCalls.first?.refreshToken, "refresh-1")
        XCTAssertEqual(provider.fetchCalls.map(\.accessToken), ["access-2"])
        // The rotated tokens are written back to the vault.
        XCTAssertEqual(harness.keychain.vault[account.id]?.accessToken, "access-2")
        XCTAssertEqual(harness.keychain.vault[account.id]?.refreshToken, "refresh-2")
        XCTAssertEqual(harness.store.states[account.id]?.needsReauth, false)
    }

    func testFailedTokenRefreshMarksNeedsReauth() async {
        let account = makeAccount()
        let provider = ProviderFake(fetchResult: .success(makeSnapshot()))
        provider.refreshResult = .failure(UsageError.http(500, "boom"))
        let harness = makeHarness(
            provider: provider, accounts: [account],
            vault: [account.id: makeTokens(expiresAt: Date().addingTimeInterval(60))])

        await harness.store.refresh(account: account, force: false)

        XCTAssertEqual(harness.store.states[account.id]?.needsReauth, true)
        XCTAssertTrue(provider.fetchCalls.isEmpty)
    }

    func testEmptyRefreshTokenMarksNeedsReauthWithoutCallingProvider() async {
        let account = makeAccount()
        let provider = ProviderFake(fetchResult: .success(makeSnapshot()))
        let harness = makeHarness(
            provider: provider, accounts: [account],
            vault: [account.id: makeTokens(refresh: "", expiresAt: Date())])

        await harness.store.refresh(account: account, force: false)

        XCTAssertEqual(harness.store.states[account.id]?.needsReauth, true)
        XCTAssertTrue(provider.refreshCalls.isEmpty)
        XCTAssertTrue(provider.fetchCalls.isEmpty)
    }

    func testMissingTokensMarkNeedsReauth() async {
        let account = makeAccount()
        let provider = ProviderFake(fetchResult: .success(makeSnapshot()))
        let harness = makeHarness(provider: provider, accounts: [account])

        await harness.store.refresh(account: account, force: false)

        XCTAssertEqual(harness.store.states[account.id]?.needsReauth, true)
        XCTAssertTrue(provider.fetchCalls.isEmpty)
    }

    func testLegacyPerAccountTokensMigrateIntoVault() async {
        let account = makeAccount()
        let keychain = KeychainFake()
        // Pre-vault layout: one Keychain item per account, no vault item.
        keychain.storage[account.id] = try! JSONEncoder().encode(
            makeTokens(access: "legacy-access"))
        let provider = ProviderFake(fetchResult: .success(makeSnapshot()))
        let harness = makeHarness(provider: provider, accounts: [account], keychain: keychain)

        await harness.store.refresh(account: account, force: false)

        XCTAssertEqual(provider.fetchCalls.map(\.accessToken), ["legacy-access"])
        XCTAssertEqual(keychain.vault[account.id]?.accessToken, "legacy-access")
        // The legacy item is deleted after migrating into the vault.
        XCTAssertNil(keychain.storage[account.id])
    }

    // MARK: Account management

    func testStoreLoginAppendsAccountAndPersistsTokens() async throws {
        let harness = makeHarness(provider: ProviderFake(fetchResult: .success(makeSnapshot())))

        try harness.store.storeLogin(makeLogin(), provider: .claude)

        XCTAssertEqual(harness.store.accounts.map(\.id), ["acct-1"])
        XCTAssertEqual(harness.store.accounts.first?.email, "user@example.com")
        XCTAssertEqual(harness.keychain.vault["acct-1"]?.accessToken, "access-1")
        XCTAssertEqual(try decodedAccounts(in: harness.defaults).map(\.id), ["acct-1"])

        // storeLogin kicks off an immediate forced refresh.
        await waitFor { harness.store.states["acct-1"]?.lastUpdated != nil }
    }

    func testStoreLoginReplacesExistingAccountAndPreservesLabel() async throws {
        let account = makeAccount(label: "Work")
        let provider = ProviderFake(fetchResult: .failure(UsageError.unauthorized))
        let harness = makeHarness(
            provider: provider, accounts: [account], vault: [account.id: makeTokens()])

        await harness.store.refresh(account: account, force: false)
        XCTAssertEqual(harness.store.states[account.id]?.needsReauth, true)

        provider.fetchResult = .success(makeSnapshot())
        try harness.store.storeLogin(
            makeLogin(id: account.id, email: "new@example.com", tokens: makeTokens(access: "access-2")),
            provider: .claude)

        XCTAssertEqual(harness.store.accounts.count, 1)
        XCTAssertEqual(harness.store.accounts.first?.email, "new@example.com")
        // Re-authenticating must not discard the user-chosen label.
        XCTAssertEqual(harness.store.accounts.first?.label, "Work")
        XCTAssertEqual(harness.store.states[account.id]?.needsReauth, false)
        XCTAssertNil(harness.store.states[account.id]?.error)
        XCTAssertEqual(harness.keychain.vault[account.id]?.accessToken, "access-2")

        await waitFor { harness.store.states[account.id]?.lastUpdated != nil }
    }

    func testBeginAddAccountRunsLoginAndStoresAccount() async {
        let provider = ProviderFake(fetchResult: .success(makeSnapshot()))
        provider.loginResult = .success(makeLogin(id: "acct-9"))
        let harness = makeHarness(provider: provider)

        harness.store.beginAddAccount(provider: .claude)
        XCTAssertTrue(harness.store.isAddingAccount)
        XCTAssertEqual(harness.store.pendingProvider, .claude)

        await waitFor { !harness.store.isAddingAccount }
        XCTAssertEqual(harness.store.accounts.map(\.id), ["acct-9"])
        XCTAssertNil(harness.store.addAccountError)
        XCTAssertNil(harness.store.pendingProvider)
        await waitFor { harness.store.states["acct-9"]?.lastUpdated != nil }
    }

    func testBeginAddAccountSurfacesLoginError() async {
        let provider = ProviderFake()
        provider.loginResult = .failure(UsageError.http(500, "boom"))
        let harness = makeHarness(provider: provider)

        harness.store.beginAddAccount(provider: .claude)
        await waitFor { !harness.store.isAddingAccount }

        XCTAssertNotNil(harness.store.addAccountError)
        XCTAssertTrue(harness.store.accounts.isEmpty)
    }

    func testRemoveAccountClearsStateVaultAndHistory() async throws {
        let first = makeAccount(id: "acct-1")
        let second = makeAccount(id: "acct-2", email: "other@example.com")
        let harness = makeHarness(
            provider: ProviderFake(fetchResult: .success(makeSnapshot())),
            accounts: [first, second],
            vault: [first.id: makeTokens(), second.id: makeTokens(access: "access-2")])

        await harness.store.refresh(account: first, force: false)
        let historyFile = harness.historyDirectory.appendingPathComponent("\(first.id).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: historyFile.path))

        harness.store.removeAccount(first)

        XCTAssertEqual(harness.store.accounts.map(\.id), [second.id])
        XCTAssertNil(harness.store.states[first.id])
        XCTAssertNil(harness.keychain.vault[first.id])
        XCTAssertNotNil(harness.keychain.vault[second.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: historyFile.path))
        XCTAssertEqual(try decodedAccounts(in: harness.defaults).map(\.id), [second.id])
    }

    func testRenameTrimsWhitespaceAndPersists() throws {
        let account = makeAccount()
        let harness = makeHarness(accounts: [account])

        harness.store.rename(account, to: "  Personal  ")

        XCTAssertEqual(harness.store.accounts.first?.label, "Personal")
        XCTAssertEqual(try decodedAccounts(in: harness.defaults).first?.label, "Personal")
    }

    func testRenameToWhitespaceClearsLabel() throws {
        let account = makeAccount(label: "Work")
        let harness = makeHarness(accounts: [account])

        harness.store.rename(account, to: "   ")

        XCTAssertNil(harness.store.accounts.first?.label)
        XCTAssertNil(try decodedAccounts(in: harness.defaults).first?.label)
    }

    func testMoveAccountReordersAndPersists() throws {
        let a = makeAccount(id: "a")
        let b = makeAccount(id: "b")
        let c = makeAccount(id: "c")
        let harness = makeHarness(accounts: [a, b, c])

        harness.store.moveAccount(c, by: -1)
        XCTAssertEqual(harness.store.accounts.map(\.id), ["a", "c", "b"])
        XCTAssertEqual(try decodedAccounts(in: harness.defaults).map(\.id), ["a", "c", "b"])

        harness.store.moveAccount(a, by: 2)
        XCTAssertEqual(harness.store.accounts.map(\.id), ["c", "b", "a"])
    }

    /// The drag-and-drop path: dropping on a row makes that row's index the
    /// dragged account's new index.
    func testMoveAccountToIndexReordersAndPersists() throws {
        let a = makeAccount(id: "a")
        let b = makeAccount(id: "b")
        let c = makeAccount(id: "c")
        let harness = makeHarness(accounts: [a, b, c])

        XCTAssertTrue(harness.store.moveAccount(id: "c", to: 0))
        XCTAssertEqual(harness.store.accounts.map(\.id), ["c", "a", "b"])
        XCTAssertEqual(try decodedAccounts(in: harness.defaults).map(\.id), ["c", "a", "b"])

        // Dragging the top row to the bottom: it lands at the last index.
        XCTAssertTrue(harness.store.moveAccount(id: "c", to: 2))
        XCTAssertEqual(harness.store.accounts.map(\.id), ["a", "b", "c"])
    }

    func testMoveAccountToIndexRefusesUnknownIDsAndNonMoves() throws {
        let a = makeAccount(id: "a")
        let b = makeAccount(id: "b")
        let harness = makeHarness(accounts: [a, b])

        // A foreign drag (text from another app) carries no known account id.
        XCTAssertFalse(harness.store.moveAccount(id: "not-an-account", to: 0))
        XCTAssertFalse(harness.store.moveAccount(id: "a", to: 0))  // already there
        XCTAssertFalse(harness.store.moveAccount(id: "a", to: 2))  // past the end
        XCTAssertFalse(harness.store.moveAccount(id: "a", to: -1))

        XCTAssertEqual(harness.store.accounts.map(\.id), ["a", "b"])
    }

    func testMoveAccountIgnoresOutOfRangeMoves() {
        let a = makeAccount(id: "a")
        let b = makeAccount(id: "b")
        let harness = makeHarness(accounts: [a, b])

        harness.store.moveAccount(a, by: -1)  // already at the top
        harness.store.moveAccount(b, by: 1)  // already at the bottom
        harness.store.moveAccount(a, by: 5)  // offset beyond the array
        harness.store.moveAccount(a, by: 0)  // no-op move

        XCTAssertEqual(harness.store.accounts.map(\.id), ["a", "b"])
    }

    // MARK: Persistence

    func testAccountsSurviveReinstantiationWithSameDefaults() async throws {
        let defaults = makeDefaults()
        let first = makeHarness(
            provider: ProviderFake(fetchResult: .success(makeSnapshot())), defaults: defaults)
        try first.store.storeLogin(makeLogin(), provider: .claude)
        first.store.rename(first.store.accounts[0], to: "Work")
        await waitFor { first.store.states["acct-1"]?.lastUpdated != nil }

        let second = makeHarness(defaults: defaults)
        XCTAssertEqual(second.store.accounts, first.store.accounts)
        XCTAssertEqual(second.store.accounts.first?.label, "Work")
    }

    func testLegacyAccountsDecodeWithClaudeProviderAndNoLabel() {
        // Accounts saved before multi-provider/label/plan support lack
        // those keys.
        let defaults = makeDefaults()
        let legacyJSON = #"[{"id":"legacy","email":"old@example.com"}]"#
        defaults.set(Data(legacyJSON.utf8), forKey: "accounts")

        let harness = makeHarness(defaults: defaults)

        XCTAssertEqual(harness.store.accounts.map(\.id), ["legacy"])
        XCTAssertEqual(harness.store.accounts.first?.provider, .claude)
        XCTAssertNil(harness.store.accounts.first?.label)
        XCTAssertNil(harness.store.accounts.first?.quotaMultiplier)
        XCTAssertNil(harness.store.accounts.first?.detectedRateLimitTier)
        XCTAssertNil(harness.store.accounts.first?.detectedQuotaMultiplier)
        XCTAssertNil(harness.store.accounts.first?.effectiveQuotaMultiplier)
        XCTAssertEqual(harness.store.accounts.first?.displayLabel, "Claude")
    }

    func testQuotaMultiplierPersistsAndRoundTrips() throws {
        // Setting a plan writes it through the same persistence the account
        // list uses; a fresh store over the same defaults sees it, and
        // clearing it back to "not set" round-trips as nil.
        let defaults = makeDefaults()
        let account = makeAccount()
        let harness = makeHarness(accounts: [account], defaults: defaults)

        harness.store.setQuotaMultiplier(account, to: 20)
        XCTAssertEqual(harness.store.accounts.first?.quotaMultiplier, 20)
        XCTAssertEqual(try decodedAccounts(in: defaults).first?.quotaMultiplier, 20)

        let reloaded = makeHarness(defaults: defaults)
        XCTAssertEqual(reloaded.store.accounts.first?.quotaMultiplier, 20)

        reloaded.store.setQuotaMultiplier(account, to: nil)
        XCTAssertNil(reloaded.store.accounts.first?.quotaMultiplier)
        XCTAssertNil(try decodedAccounts(in: defaults).first?.quotaMultiplier)
    }

    // MARK: Plan detection

    func testRefreshDetectsPlanTierOncePerLaunch() async throws {
        let account = makeAccount()
        let provider = ProviderFake(fetchResult: .success(makeSnapshot()))
        provider.profileResult = .success(
            DetectedPlan(rateLimitTier: "default_claude_max_5x", quotaMultiplier: 5))
        let harness = makeHarness(
            provider: provider, accounts: [account], vault: [account.id: makeTokens()])

        await harness.store.refresh(account: account, force: false)
        await waitFor { harness.store.accounts.first?.detectedQuotaMultiplier == 5 }

        XCTAssertEqual(
            harness.store.accounts.first?.detectedRateLimitTier, "default_claude_max_5x")
        // The detection is persisted alongside the account metadata…
        XCTAssertEqual(
            try decodedAccounts(in: harness.defaults).first?.detectedQuotaMultiplier, 5)
        // …and not refetched on the next refresh.
        await harness.store.refresh(account: account, force: true)
        XCTAssertEqual(provider.profileCalls.count, 1)
    }

    func testProfileFailureIsSilentAndNeverAffectsUsage() async {
        let account = makeAccount()
        let provider = ProviderFake(fetchResult: .success(makeSnapshot(percents: [42])))
        provider.profileResult = .failure(UsageError.http(500, "profile boom"))
        let harness = makeHarness(
            provider: provider, accounts: [account], vault: [account.id: makeTokens()],
            notificationsEnabled: true)

        await harness.store.refresh(account: account, force: false)
        await waitFor { provider.profileCalls.count == 1 }

        // Usage is intact, no error surfaced, nothing detected, no alerts.
        let state = harness.store.states[account.id]
        XCTAssertEqual(state?.limits.map(\.percent), [42])
        XCTAssertNil(state?.error)
        XCTAssertNil(harness.store.accounts.first?.detectedQuotaMultiplier)
        XCTAssertTrue(harness.scheduler.posted.isEmpty)

        // Failed detection is not retried this launch (no polling loop).
        await harness.store.refresh(account: account, force: true)
        XCTAssertEqual(provider.profileCalls.count, 1)
    }

    func testUnmappedTierIsStoredForDisplayWithoutAWeight() async throws {
        // A tier we can't map (e.g. a Team premium seat) must still be
        // persisted verbatim: the picker shows "API reports: …" so the user
        // can set the weight knowingly, and the pool stays unweighted until
        // they do.
        let account = makeAccount()
        let provider = ProviderFake(fetchResult: .success(makeSnapshot()))
        provider.profileResult = .success(
            DetectedPlan(rateLimitTier: "default_claude_team_premium", quotaMultiplier: nil))
        let harness = makeHarness(
            provider: provider, accounts: [account], vault: [account.id: makeTokens()])

        await harness.store.refresh(account: account, force: false)
        await waitFor {
            harness.store.accounts.first?.detectedRateLimitTier
                == "default_claude_team_premium"
        }

        XCTAssertNil(harness.store.accounts.first?.detectedQuotaMultiplier)
        XCTAssertNil(harness.store.accounts.first?.effectiveQuotaMultiplier)
        XCTAssertEqual(
            try decodedAccounts(in: harness.defaults).first?.detectedRateLimitTier,
            "default_claude_team_premium")
        // Retained, so the unmappable tier isn't refetched every refresh.
        await harness.store.refresh(account: account, force: true)
        XCTAssertEqual(provider.profileCalls.count, 1)
    }

    func testStoreLoginTriggersPlanDetection() async throws {
        let provider = ProviderFake(fetchResult: .success(makeSnapshot()))
        provider.profileResult = .success(
            DetectedPlan(rateLimitTier: "default_claude_max_20x", quotaMultiplier: 20))
        let harness = makeHarness(provider: provider)

        try harness.store.storeLogin(makeLogin(), provider: .claude)

        await waitFor { harness.store.accounts.first?.detectedQuotaMultiplier == 20 }
        XCTAssertEqual(
            harness.store.accounts.first?.detectedRateLimitTier, "default_claude_max_20x")
    }

    func testManualPlanChoiceOutranksDetectedTier() async {
        let account = makeAccount()
        let provider = ProviderFake(fetchResult: .success(makeSnapshot()))
        provider.profileResult = .success(
            DetectedPlan(rateLimitTier: "default_claude_max_5x", quotaMultiplier: 5))
        let harness = makeHarness(
            provider: provider, accounts: [account], vault: [account.id: makeTokens()])

        await harness.store.refresh(account: account, force: false)
        await waitFor { harness.store.accounts.first?.detectedQuotaMultiplier == 5 }
        XCTAssertEqual(harness.store.accounts.first?.effectiveQuotaMultiplier, 5)

        harness.store.setQuotaMultiplier(account, to: 20)
        XCTAssertEqual(harness.store.accounts.first?.effectiveQuotaMultiplier, 20)

        // Clearing the manual choice falls back to the detected tier.
        harness.store.setQuotaMultiplier(account, to: nil)
        XCTAssertEqual(harness.store.accounts.first?.effectiveQuotaMultiplier, 5)
    }

    // MARK: Menu bar summary

    func testMenuBarTextIsEmptyWithoutAccounts() {
        let harness = makeHarness()
        XCTAssertEqual(harness.store.menuBarText, "")
        XCTAssertEqual(harness.store.worstPercent, 0)
    }

    func testMenuBarTextShowsPlaceholderWhileLoading() {
        let harness = makeHarness(accounts: [makeAccount()])
        XCTAssertEqual(harness.store.menuBarText, "…%")
    }

    func testMenuBarTextJoinsEachAccountsWorstPercent() async {
        let first = makeAccount(id: "acct-1")
        let second = makeAccount(id: "acct-2", email: "other@example.com")
        let provider = ProviderFake()
        provider.setFetchResult(
            .success(makeSnapshot(percents: [72.4, 10])), forAccount: first.id)
        provider.setFetchResult(
            .success(makeSnapshot(percents: [30.6])), forAccount: second.id)
        let harness = makeHarness(
            provider: provider, accounts: [first, second],
            vault: [first.id: makeTokens(), second.id: makeTokens()])

        await harness.store.refresh(account: first, force: false)
        await harness.store.refresh(account: second, force: false)

        XCTAssertEqual(harness.store.menuBarText, "72·31%")
        XCTAssertEqual(harness.store.worstPercent, 72.4)
        XCTAssertNotNil(harness.store.lastUpdatedOverall)
    }

    func testMenuBarTextFlagsReauthAlongsideHealthyAccounts() async {
        let first = makeAccount(id: "acct-1")
        let second = makeAccount(id: "acct-2", email: "other@example.com")
        let provider = ProviderFake()
        provider.setFetchResult(.failure(UsageError.unauthorized), forAccount: first.id)
        provider.setFetchResult(.success(makeSnapshot(percents: [55])), forAccount: second.id)
        let harness = makeHarness(
            provider: provider, accounts: [first, second],
            vault: [first.id: makeTokens(), second.id: makeTokens()])

        await harness.store.refresh(account: first, force: false)
        await harness.store.refresh(account: second, force: false)

        XCTAssertEqual(harness.store.menuBarText, "!·55%")
    }

    func testMenuBarTextShowsBangForFailedAccountWithoutData() async {
        let account = makeAccount()
        let harness = makeHarness(
            provider: ProviderFake(fetchResult: .failure(UsageError.http(500, "boom"))),
            accounts: [account], vault: [account.id: makeTokens()])

        await harness.store.refresh(account: account, force: false)

        XCTAssertEqual(harness.store.menuBarText, "!%")
    }

    // MARK: Best-account hint wiring

    func testBestBadgesArePaceAwareEndToEnd() async throws {
        // Two Claude accounts: acct-1 has more headroom (40% vs 55%) but its
        // synthetic ramp burns 30%/h (≈2 h of runway); acct-2 burns 3%/h
        // (≈15 h). The store must compute projections from its injected
        // history store and hand the badge — and the tooltip date — to the
        // slower burner, even though v1 headroom favours acct-1.
        let fast = makeAccount(id: "acct-1")
        let slow = makeAccount(id: "acct-2", email: "other@example.com")
        let provider = ProviderFake()
        provider.setFetchResult(
            .success(makeSessionSnapshot(percent: 40)), forAccount: fast.id)
        provider.setFetchResult(
            .success(makeSessionSnapshot(percent: 55)), forAccount: slow.id)
        let harness = makeHarness(
            provider: provider, accounts: [fast, slow],
            vault: [fast.id: makeTokens(), slow.id: makeTokens()])
        seedSessionRamp(
            directory: harness.historyDirectory, account: fast.id,
            endPercent: 40, ratePerHour: 30)
        seedSessionRamp(
            directory: harness.historyDirectory, account: slow.id,
            endPercent: 55, ratePerHour: 3)

        await harness.store.refresh(account: fast, force: false)
        await harness.store.refresh(account: slow, force: false)

        let badges = harness.store.bestBadges
        XCTAssertEqual(Set(badges.keys), [slow.id])
        // (100 − 55) / 3%/h = 15 h out; generous slack for slow CI runs.
        let projected = try XCTUnwrap(badges[slow.id]?.projectedExhaustion)
        let expected = Date().addingTimeInterval(15 * 3600)
        XCTAssertEqual(projected.timeIntervalSince(expected), 0, accuracy: 900)
    }

    func testBestBadgesAreWeeklyAwareEndToEnd() async throws {
        // Issue #21's live shape, sessions inverted so the two rankings
        // disagree: acct-1 has 40% of its session gone against acct-2's 5%,
        // so session headroom favours acct-2 — but acct-1's week is 31% spent
        // and resets in 3 days, while acct-2's is 15% spent with 5d15h of
        // runway. Only weekly windows have a history ramp (0.6 and 0.4 pp/h),
        // so the session leg has no demand signal and the weekly leg decides:
        // the store must ask its history store for weekly rates and hand the
        // badge — with the window named — to the account about to waste 69%
        // of its week.
        let work = makeAccount(id: "acct-1")
        let alt = makeAccount(id: "acct-2", email: "other@example.com")
        let provider = ProviderFake()
        provider.setFetchResult(
            .success(
                makeWeeklySnapshot(session: 40, weekly: 31, weeklyResetIn: 72 * 3600)),
            forAccount: work.id)
        provider.setFetchResult(
            .success(
                makeWeeklySnapshot(session: 5, weekly: 15, weeklyResetIn: 135 * 3600)),
            forAccount: alt.id)
        let harness = makeHarness(
            provider: provider, accounts: [work, alt],
            vault: [work.id: makeTokens(), alt.id: makeTokens()])
        seedSessionRamp(
            directory: harness.historyDirectory, account: work.id,
            endPercent: 31, ratePerHour: 0.6,
            limitID: "weekly_all|", limitName: "Weekly")
        seedSessionRamp(
            directory: harness.historyDirectory, account: alt.id,
            endPercent: 15, ratePerHour: 0.4,
            limitID: "weekly_all|", limitName: "Weekly")

        await harness.store.refresh(account: work, force: false)
        await harness.store.refresh(account: alt, force: false)

        let badges = harness.store.bestBadges
        XCTAssertEqual(Set(badges.keys), [work.id])
        let expiring = try XCTUnwrap(badges[work.id]?.expiring)
        XCTAssertEqual(expiring.points, 69, accuracy: 1)
        XCTAssertEqual(expiring.scopeName, "Weekly")
        // …and the trace the debug popover renders shows the weekly pool.
        let trace = try XCTUnwrap(harness.store.bestAccountTrace(for: .claude))
        XCTAssertEqual(trace.aggregatePace, 0)
        XCTAssertEqual(trace.weeklyAggregatePace, 0.01, accuracy: 0.002)
        XCTAssertEqual(trace.capacityFallback, .noAggregatePace)
        XCTAssertNil(trace.weeklyCapacityFallback)
    }

    // MARK: Trend charts

    func testExpandedTrendChartsSurviveARelaunch() {
        let account = makeAccount()
        let harness = makeHarness(accounts: [account])
        let key = "\(account.id)|weekly_all|"

        XCTAssertFalse(harness.store.isTrendExpanded(key))
        harness.store.toggleTrend(key)
        XCTAssertTrue(harness.store.isTrendExpanded(key))

        // A store rebuilt on the same defaults — i.e. the next launch — opens
        // with the same chart showing.
        let relaunched = makeHarness(accounts: [account], defaults: harness.defaults)
        XCTAssertTrue(relaunched.store.isTrendExpanded(key))

        relaunched.store.toggleTrend(key)
        let afterCollapse = makeHarness(accounts: [account], defaults: harness.defaults)
        XCTAssertFalse(afterCollapse.store.isTrendExpanded(key))
    }

    func testTrendReadsRecordedHistoryForTheAccount() async throws {
        let account = makeAccount()
        let weekly = LimitStatus(
            id: "weekly_all|", name: "Weekly", percent: 40,
            resetsAt: Date().addingTimeInterval(3 * 86400), isActive: false, sortOrder: 1,
            windowSeconds: 7 * 86400)
        let provider = ProviderFake(
            fetchResult: .success(UsageSnapshot(limits: [weekly], credits: nil)))
        let harness = makeHarness(
            provider: provider, accounts: [account], vault: [account.id: makeTokens()])

        // No polls yet: nothing recorded inside the window, so no chart.
        XCTAssertNil(harness.store.trend(for: weekly, accountID: account.id))

        await harness.store.refresh(account: account, force: true)
        let trend = try XCTUnwrap(harness.store.trend(for: weekly, accountID: account.id))
        XCTAssertEqual(trend.recorded.count, 1)
        XCTAssertEqual(trend.latest.percent, 40)
        // One sample can be drawn but not fitted, so there's no projection.
        XCTAssertTrue(trend.projected.isEmpty)
    }

    // MARK: Notifier wiring

    func testRefreshFeedsNotifierWithOldAndNewStates() async {
        let account = makeAccount()
        let provider = ProviderFake(fetchResult: .success(makeSnapshot(percents: [85])))
        let harness = makeHarness(
            provider: provider, accounts: [account], vault: [account.id: makeTokens()],
            notificationsEnabled: true)

        // First sample: no previous state, so no threshold alert.
        await harness.store.refresh(account: account, force: false)
        XCTAssertTrue(harness.scheduler.posted.isEmpty)

        // Crossing the threshold between polls posts exactly once — proving
        // the store hands the notifier the previous poll's state as `old`.
        provider.fetchResult = .success(makeSnapshot(percents: [92]))
        await harness.store.refresh(account: account, force: false)
        XCTAssertEqual(harness.scheduler.posted.count, 1)
        XCTAssertEqual(harness.scheduler.posted.first?.body, "Limit 0 limit at 92%")
    }

    /// The pace-aware fixture from `testBestBadgesArePaceAwareEndToEnd`, with
    /// labels: "Work" burns 30%/h at 40% used, "Personal" burns 3%/h at 55%,
    /// so the badge lands on Personal while Work is the account in use.
    private func makeSwitchHarness(notificationsEnabled: Bool = true) -> (
        Harness, AccountMeta, AccountMeta
    ) {
        let work = makeAccount(id: "acct-1", label: "Work")
        let personal = makeAccount(id: "acct-2", email: "other@example.com", label: "Personal")
        let provider = ProviderFake()
        provider.setFetchResult(
            .success(makeSessionSnapshot(percent: 40)), forAccount: work.id)
        provider.setFetchResult(
            .success(makeSessionSnapshot(percent: 55)), forAccount: personal.id)
        let harness = makeHarness(
            provider: provider, accounts: [work, personal],
            vault: [work.id: makeTokens(), personal.id: makeTokens()],
            notificationsEnabled: notificationsEnabled)
        seedSessionRamp(
            directory: harness.historyDirectory, account: work.id,
            endPercent: 40, ratePerHour: 30)
        seedSessionRamp(
            directory: harness.historyDirectory, account: personal.id,
            endPercent: 55, ratePerHour: 3)
        return (harness, work, personal)
    }

    func testCompletedRefreshCycleSuggestsSwitchingOnce() async {
        let (harness, _, _) = makeSwitchHarness()

        await harness.store.refreshAll(force: true)

        // Exactly one banner for the whole cycle — the decision is
        // group-level, not per account.
        XCTAssertEqual(harness.scheduler.posted.count, 1)
        XCTAssertEqual(harness.scheduler.posted.first?.title, "Switch to Personal")
        XCTAssertEqual(
            harness.scheduler.posted.first?.body.hasSuffix("of session left at current pace"),
            true)

        // The next cycle finds the same situation: the edge trigger holds.
        await harness.store.refreshAll(force: true)
        XCTAssertEqual(harness.scheduler.posted.count, 1)
    }

    func testRefreshCycleSuggestsNothingWhileNotificationsAreOff() async {
        let (harness, _, _) = makeSwitchHarness(notificationsEnabled: false)

        await harness.store.refreshAll(force: true)

        XCTAssertTrue(harness.scheduler.posted.isEmpty)
    }

    func testRefreshNotifiesOnSignInExpiry() async {
        let account = makeAccount()
        let harness = makeHarness(
            provider: ProviderFake(fetchResult: .failure(UsageError.unauthorized)),
            accounts: [account], vault: [account.id: makeTokens()],
            notificationsEnabled: true)

        await harness.store.refresh(account: account, force: false)

        XCTAssertEqual(harness.scheduler.posted.count, 1)
        XCTAssertEqual(harness.scheduler.posted.first?.body.contains("Sign-in expired"), true)
    }
}
