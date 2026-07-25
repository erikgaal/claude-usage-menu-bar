import XCTest

@testable import ClaudeUsage

/// One rule, asserted from every angle: while the app manages Claude Code's
/// sign-in, only Claude Code may refresh the signed-in account's chain.
///
/// Refresh tokens rotate single-use, so a refresh from this side isn't a
/// wasted round trip — it invalidates the copy Claude Code holds and signs the
/// CLI, the desktop app and the IDE extensions out an hour later, far from the
/// cause. `TokenSource` is pure precisely so that rule can be pinned down here
/// rather than left to the control flow in `AccountStore.validTokens`.
final class TokenSourceTests: XCTestCase {

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func tokens(
        expiresIn seconds: TimeInterval, refresh: String = "refresh-xyz"
    ) -> StoredTokens {
        StoredTokens(
            accessToken: "access-abc", refreshToken: refresh,
            expiresAt: Self.now.addingTimeInterval(seconds))
    }

    /// Defaults describe the interesting configuration: we manage sign-in and
    /// the account under test is the one Claude Code is signed in as.
    private func source(
        vault: [String: StoredTokens],
        manages: Bool = true,
        activeID: String? = "acct-1",
        for accountID: String = "acct-1"
    ) -> TokenSource {
        TokenSource.of(
            accountID: accountID, vault: vault, claudeCodeManages: manages,
            claudeCodeActiveID: activeID, now: Self.now)
    }

    // MARK: The chain Claude Code owns

    func testExpiredMirrorOfTheSignedInAccountReadsThroughRatherThanRefreshing() {
        // The regression this file exists for. Our copy is expired and its
        // refresh token is very likely still the live head of the chain —
        // which is exactly what makes refreshing here destructive rather than
        // merely redundant.
        XCTAssertEqual(source(vault: ["acct-1": tokens(expiresIn: -60)]), .claudeCode)
    }

    func testMirrorInsideTheRefreshWindowStillReadsThrough() {
        // Not expired yet, but too close to spend on a request.
        XCTAssertEqual(source(vault: ["acct-1": tokens(expiresIn: 60)]), .claudeCode)
    }

    func testSignedInAccountWithNoMirrorReadsThrough() {
        XCTAssertEqual(source(vault: [:]), .claudeCode)
    }

    func testSignedInAccountIsNeverSentDownTheRefreshPath() {
        // Whatever the vault holds — long expired, on the window boundary,
        // refresh token blanked, absent entirely — the answer for the
        // signed-in account is never `.ownRefresh`.
        let vaults: [[String: StoredTokens]] = [
            [:],
            ["acct-1": tokens(expiresIn: -3600)],
            ["acct-1": tokens(expiresIn: -1, refresh: "")],
            ["acct-1": tokens(expiresIn: TokenSource.refreshWindow)],
        ]
        for vault in vaults {
            XCTAssertEqual(source(vault: vault), .claudeCode, "vault: \(vault)")
        }
    }

    // MARK: Staying off Claude Code's Keychain item

    func testValidMirrorIsUsedWithoutTouchingClaudeCode() {
        // Rotation kills the refresh token, not an access token already
        // issued, so a mirror Claude Code has rotated past is still fine for
        // reading usage. Leaning on that is what keeps the macOS authorization
        // prompt down to roughly one poll per token lifetime.
        let live = tokens(expiresIn: 3600)
        XCTAssertEqual(source(vault: ["acct-1": live]), .mirrored(live))
    }

    // MARK: Chains we own outright

    func testExpiredChainIsRefreshedHereWhenWeDoNotManageSignIn() {
        let stale = tokens(expiresIn: -60)
        XCTAssertEqual(
            source(vault: ["acct-1": stale], manages: false), .ownRefresh(stale))
    }

    func testAnotherAccountBeingSignedInLeavesThisOneOurs() {
        let stale = tokens(expiresIn: -60)
        XCTAssertEqual(
            source(vault: ["acct-1": stale], activeID: "acct-2"), .ownRefresh(stale))
    }

    func testNothingSignedInLeavesEveryChainOurs() {
        let stale = tokens(expiresIn: -60)
        XCTAssertEqual(source(vault: ["acct-1": stale], activeID: nil), .ownRefresh(stale))
    }

    // MARK: Nothing to work with

    func testAccountWithNoTokensIsUnauthorized() {
        XCTAssertEqual(source(vault: [:], manages: false), .unauthorized)
    }

    func testExpiredChainWithNoRefreshTokenIsUnauthorized() {
        XCTAssertEqual(
            source(vault: ["acct-1": tokens(expiresIn: -60, refresh: "")], manages: false),
            .unauthorized)
    }
}
