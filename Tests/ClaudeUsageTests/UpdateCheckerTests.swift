import XCTest

@testable import ClaudeUsage

@MainActor
final class UpdateCheckerTests: XCTestCase {

    private static let releaseURL = URL(
        string: "https://github.com/erikgaal/claude-usage-menu-bar/releases/tag/v1.2.0")!

    // MARK: Fixtures

    /// Checker on an isolated defaults suite via the designated initializer:
    /// no check loop, no network, no Bundle.main — only the injected pieces.
    private func makeChecker(
        currentVersion: String? = "1.1.0", defaults: UserDefaults? = nil
    ) -> (UpdateChecker, UserDefaults) {
        let defaults = defaults ?? makeDefaults()
        return (UpdateChecker(currentVersion: currentVersion, defaults: defaults), defaults)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "UpdateCheckerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func seedCachedRelease(_ version: String, in defaults: UserDefaults) {
        let release = UpdateChecker.Release(version: version, url: Self.releaseURL)
        defaults.set(
            try! JSONEncoder().encode(release), forKey: UpdateChecker.DefaultsKey.cachedRelease)
    }

    private func latestReleaseJSON(tag: String, htmlURL: String? = nil) -> Data {
        let url = htmlURL ?? "https://github.com/erikgaal/claude-usage-menu-bar/releases/tag/\(tag)"
        return Data(#"{"tag_name": "\#(tag)", "html_url": "\#(url)"}"#.utf8)
    }

    // MARK: Version comparison

    func testComparisonIsNumericNotLexicographic() {
        // Lexicographically "1.10.0" < "1.9.0"; component-wise it's newer.
        XCTAssertTrue(UpdateChecker.isVersion("1.10.0", newerThan: "1.9.0"))
        XCTAssertFalse(UpdateChecker.isVersion("1.9.0", newerThan: "1.10.0"))
        XCTAssertTrue(UpdateChecker.isVersion("2.0.0", newerThan: "1.99.99"))
    }

    func testEqualVersionsAreNotNewer() {
        XCTAssertFalse(UpdateChecker.isVersion("1.2.0", newerThan: "1.2.0"))
    }

    func testMissingComponentsCountAsZero() {
        // "1.2" and "1.2.0" are the same version, in both directions.
        XCTAssertFalse(UpdateChecker.isVersion("1.2", newerThan: "1.2.0"))
        XCTAssertFalse(UpdateChecker.isVersion("1.2.0", newerThan: "1.2"))
        XCTAssertTrue(UpdateChecker.isVersion("1.2.1", newerThan: "1.2"))
        XCTAssertTrue(UpdateChecker.isVersion("1.2", newerThan: "1.1.9"))
    }

    func testNonNumericComponentsCountAsZero() {
        // Deliberate policy pin: pre-release suffixes aren't parsed, the
        // whole component falls back to 0, erring toward not nagging.
        // "1.2.0-beta" → [1, 2, 0]: newer than 1.1.0, not newer than 1.2.0.
        XCTAssertTrue(UpdateChecker.isVersion("1.2.0-beta", newerThan: "1.1.0"))
        XCTAssertFalse(UpdateChecker.isVersion("1.2.0-beta", newerThan: "1.2.0"))
        // A garbage tag can never look newer than a real version.
        XCTAssertFalse(UpdateChecker.isVersion("nightly", newerThan: "0.0.1"))
    }

    func testLeadingVIsStrippedFromTags() {
        XCTAssertEqual(UpdateChecker.version(fromTag: "v1.2.0"), "1.2.0")
        XCTAssertEqual(UpdateChecker.version(fromTag: "1.2.0"), "1.2.0")
    }

    // MARK: Payload decoding

    func testRealisticLatestReleasePayloadDecodes() throws {
        // Trimmed-down but realistic `releases/latest` shape: the fields we
        // ignore must not break decoding.
        let payload = Data(
            #"""
            {
              "url": "https://api.github.com/repos/erikgaal/claude-usage-menu-bar/releases/223344",
              "html_url": "https://github.com/erikgaal/claude-usage-menu-bar/releases/tag/v1.2.0",
              "id": 223344,
              "tag_name": "v1.2.0",
              "target_commitish": "main",
              "name": "v1.2.0",
              "draft": false,
              "prerelease": false,
              "created_at": "2026-07-01T10:00:00Z",
              "published_at": "2026-07-01T10:05:00Z",
              "assets": [
                {
                  "name": "Claude-Usage-1.2.0.zip",
                  "browser_download_url": "https://github.com/erikgaal/claude-usage-menu-bar/releases/download/v1.2.0/Claude-Usage-1.2.0.zip"
                }
              ],
              "body": "## Changes\n- Update check"
            }
            """#.utf8)
        let release = try JSONDecoder().decode(LatestRelease.self, from: payload)
        XCTAssertEqual(release.tagName, "v1.2.0")
        XCTAssertEqual(
            release.htmlURL,
            "https://github.com/erikgaal/claude-usage-menu-bar/releases/tag/v1.2.0")
    }

    func testMalformedPayloadIsIgnoredWithoutSideEffects() {
        let (checker, defaults) = makeChecker()
        checker.ingest(
            latestReleaseBody: Data(#"{"tag_name": 42}"#.utf8), etag: "\"abc123\"")
        XCTAssertNil(checker.availableRelease)
        // Persisting the ETag for a body we couldn't parse would suppress
        // future 200s (304 forever) with nothing cached to show for it.
        XCTAssertNil(defaults.string(forKey: UpdateChecker.DefaultsKey.etag))
        XCTAssertNil(defaults.data(forKey: UpdateChecker.DefaultsKey.cachedRelease))
    }

    // MARK: Ingesting a 200

    func testNewerReleasePublishesAndPersists() {
        let (checker, defaults) = makeChecker(currentVersion: "1.1.0")
        checker.ingest(latestReleaseBody: latestReleaseJSON(tag: "v1.2.0"), etag: "\"abc123\"")

        XCTAssertEqual(checker.availableRelease?.version, "1.2.0")
        XCTAssertEqual(
            checker.availableRelease?.url.absoluteString,
            "https://github.com/erikgaal/claude-usage-menu-bar/releases/tag/v1.2.0")
        XCTAssertEqual(defaults.string(forKey: UpdateChecker.DefaultsKey.etag), "\"abc123\"")

        // "Relaunch": a fresh checker on the same defaults must surface the
        // cached release without any network involvement.
        let (relaunched, _) = makeChecker(currentVersion: "1.1.0", defaults: defaults)
        XCTAssertEqual(relaunched.availableRelease, checker.availableRelease)
    }

    func testOlderOrEqualReleaseStaysQuiet() {
        let (checker, _) = makeChecker(currentVersion: "1.1.0")
        checker.ingest(latestReleaseBody: latestReleaseJSON(tag: "v1.1.0"), etag: nil)
        XCTAssertNil(checker.availableRelease)
        checker.ingest(latestReleaseBody: latestReleaseJSON(tag: "v1.0.3"), etag: nil)
        XCTAssertNil(checker.availableRelease)
    }

    func testLatestFallingBehindClearsPreviouslyAvailable() {
        // A newer release was published, then yanked: the next 200 reports a
        // tag that is no longer newer, and the row must disappear.
        let (checker, _) = makeChecker(currentVersion: "1.1.0")
        checker.ingest(latestReleaseBody: latestReleaseJSON(tag: "v1.2.0"), etag: nil)
        XCTAssertNotNil(checker.availableRelease)
        checker.ingest(latestReleaseBody: latestReleaseJSON(tag: "v1.1.0"), etag: nil)
        XCTAssertNil(checker.availableRelease)
    }

    func testUnparseableHTMLURLIsIgnored() {
        let (checker, defaults) = makeChecker(currentVersion: "1.1.0")
        checker.ingest(
            latestReleaseBody: latestReleaseJSON(tag: "v1.2.0", htmlURL: ""), etag: "\"abc123\"")
        XCTAssertNil(checker.availableRelease)
        XCTAssertNil(defaults.string(forKey: UpdateChecker.DefaultsKey.etag))
    }

    // MARK: Persisted release across launches

    func testCachedNewerReleaseSurfacesAtInit() {
        // The 304 path: after a relaunch the first check answers "not
        // modified", so the update row must come from the persisted release.
        let defaults = makeDefaults()
        seedCachedRelease("1.2.0", in: defaults)
        let (checker, _) = makeChecker(currentVersion: "1.1.0", defaults: defaults)
        XCTAssertEqual(
            checker.availableRelease,
            UpdateChecker.Release(version: "1.2.0", url: Self.releaseURL))
    }

    func testCachedOlderOrEqualReleaseStaysQuietAtInit() {
        // The user updated the app: the stale cache must not resurrect a row.
        let older = makeDefaults()
        seedCachedRelease("1.0.0", in: older)
        XCTAssertNil(makeChecker(currentVersion: "1.1.0", defaults: older).0.availableRelease)

        let equal = makeDefaults()
        seedCachedRelease("1.1.0", in: equal)
        XCTAssertNil(makeChecker(currentVersion: "1.1.0", defaults: equal).0.availableRelease)
    }

    func testCorruptCacheIsIgnoredAtInit() {
        let defaults = makeDefaults()
        defaults.set(
            Data("not json".utf8), forKey: UpdateChecker.DefaultsKey.cachedRelease)
        XCTAssertNil(makeChecker(currentVersion: "1.1.0", defaults: defaults).0.availableRelease)
    }

    // MARK: Dev builds

    func testDevBuildNeverSurfacesAnUpdate() {
        // No bundle version (swift run): even a cached newer release must
        // stay invisible — dev builds never nag.
        let defaults = makeDefaults()
        seedCachedRelease("99.0.0", in: defaults)
        let (checker, _) = makeChecker(currentVersion: nil, defaults: defaults)
        XCTAssertNil(checker.availableRelease)

        checker.ingest(latestReleaseBody: latestReleaseJSON(tag: "v99.0.0"), etag: nil)
        XCTAssertNil(checker.availableRelease)
    }
}
