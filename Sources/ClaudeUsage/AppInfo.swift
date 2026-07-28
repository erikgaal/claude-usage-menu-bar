import Foundation

/// Who and what this build is, for the About rows in settings — and the one
/// place the repository is named, so the update check and the source link
/// can't drift apart.
enum AppInfo {
    static let author = "Erik Gaal"
    static let repositorySlug = "erikgaal/claude-usage-menu-bar"

    /// The human-facing repository page, for the source link.
    static let repositoryURL = URL(string: "https://github.com/\(repositorySlug)")!

    /// GitHub's latest-release endpoint for this repository (see
    /// `UpdateChecker`).
    static let latestReleaseAPI = URL(
        string: "https://api.github.com/repos/\(repositorySlug)/releases/latest")!

    /// "1.1.0 (2)" for a bundled build, or a plain statement for dev runs:
    /// `swift run` and the bare `swift build` binary have no Info.plist, so
    /// there is no version to report (the same guard the update check uses).
    static var versionText: String {
        versionText(
            version: UpdateChecker.bundleVersion,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    }

    /// The composition on its own, so it can be tested without a bundle: the
    /// build number is a suffix, and only when it adds something.
    static func versionText(version: String?, build: String?) -> String {
        guard let version else { return "dev build" }
        guard let build, !build.isEmpty, build != version else { return version }
        return "\(version) (\(build))"
    }
}
