import XCTest

@testable import ClaudeUsage

final class AppInfoTests: XCTestCase {

    // MARK: Version text

    func testVersionAndBuildAreCombined() {
        XCTAssertEqual(AppInfo.versionText(version: "1.1.0", build: "2"), "1.1.0 (2)")
    }

    func testBuildIsOmittedWhenItAddsNothing() {
        // A build number equal to the version, or absent/blank, is noise.
        XCTAssertEqual(AppInfo.versionText(version: "1.1.0", build: "1.1.0"), "1.1.0")
        XCTAssertEqual(AppInfo.versionText(version: "1.1.0", build: nil), "1.1.0")
        XCTAssertEqual(AppInfo.versionText(version: "1.1.0", build: ""), "1.1.0")
    }

    func testUnbundledRunSaysDevBuild() {
        // `swift run` and the bare `swift build` binary have no Info.plist, so
        // there is no version to show — and none to invent.
        XCTAssertEqual(AppInfo.versionText(version: nil, build: "2"), "dev build")
        XCTAssertEqual(AppInfo.versionText(version: nil, build: nil), "dev build")
    }

    // MARK: Repository

    /// Both URLs are built from the one slug; this pins the shapes GitHub
    /// expects, so the About link and the update check can't diverge.
    func testBothRepositoryURLsComeFromTheSameSlug() {
        XCTAssertEqual(
            AppInfo.repositoryURL.absoluteString,
            "https://github.com/erikgaal/claude-usage-menu-bar")
        XCTAssertEqual(
            AppInfo.latestReleaseAPI.absoluteString,
            "https://api.github.com/repos/erikgaal/claude-usage-menu-bar/releases/latest")
    }
}
