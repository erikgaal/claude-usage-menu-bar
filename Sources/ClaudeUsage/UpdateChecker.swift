import Combine
import Foundation

/// Polls GitHub's latest-release endpoint and publishes any release newer
/// than the running build, so the panel can offer a link to the release page.
/// No auto-download/install — the app ships as a zip, so a pointer is enough.
@MainActor
final class UpdateChecker: ObservableObject {
    /// A published release newer than the running build.
    struct Release: Codable {
        /// Semantic version with any leading "v" stripped, e.g. "1.2.0".
        let version: String
        /// The release's `html_url` — the human-facing GitHub release page.
        let url: URL
    }

    @Published private(set) var availableRelease: Release?

    private static let endpoint = URL(
        string: "https://api.github.com/repos/erikgaal/claude-usage-menu-bar/releases/latest")!
    /// Once a day is plenty; combined with ETag caching, 304 responses don't
    /// count against GitHub's unauthenticated rate limit.
    private let checkInterval: TimeInterval = 24 * 60 * 60
    private let etagKey = "updateETag"
    private let cachedReleaseKey = "updateCachedRelease"
    private var checkLoop: Task<Void, Never>?

    init() {
        // Dev builds (`swift run`) have no Info.plist and no .app wrapper, so
        // there is no version to compare against — never check, never nag.
        guard let current = Self.currentVersion else { return }

        // Surface the last-seen release immediately: without this, a relaunch
        // whose first check answers 304 would hide an update we already know
        // about (the ETag matches precisely because nothing new was published).
        publishIfNewer(loadCachedRelease(), than: current)
        startCheckLoop()
    }

    // MARK: - Check loop

    /// Check on launch and roughly daily, same shape as the usage refresh
    /// loop in `AccountStore`.
    private func startCheckLoop() {
        checkLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                let interval = self?.checkInterval ?? 24 * 60 * 60
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            }
        }
    }

    /// One conditional GET. Every failure mode — network, rate limit, parse —
    /// ends the same way: silently. An update hint must never become noise.
    private func check() async {
        guard let current = Self.currentVersion else { return }

        var request = URLRequest(url: Self.endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(
            "claude-usage-menu-bar/\(current) (update check)", forHTTPHeaderField: "User-Agent")
        if let etag = UserDefaults.standard.string(forKey: etagKey) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        request.timeoutInterval = 15

        guard let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse,
            // 304: nothing published since the stored ETag — the cached
            // release (already evaluated at init) is still the latest.
            http.statusCode == 200
        else { return }

        guard let latest = try? JSONDecoder().decode(LatestRelease.self, from: data),
            let url = URL(string: latest.htmlURL)
        else { return }

        // Only remember the ETag once the body parsed, so a truncated or
        // malformed 200 can't poison future conditional requests.
        if let etag = http.value(forHTTPHeaderField: "ETag") {
            UserDefaults.standard.set(etag, forKey: etagKey)
        }

        // Tags are conventionally "v1.2.0"; the bundle version has no prefix.
        var version = latest.tagName
        if version.hasPrefix("v") { version = String(version.dropFirst()) }

        let release = Release(version: version, url: url)
        storeCachedRelease(release)
        publishIfNewer(release, than: current)
    }

    // MARK: - Version comparison

    /// The running build's marketing version, or nil for dev builds. A bare
    /// executable launched via `swift run` has no Info.plist and no .app
    /// wrapper; both checks guard against nagging during development.
    static var currentVersion: String? {
        guard Bundle.main.bundleURL.pathExtension == "app",
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String,
            !version.isEmpty, version != "0.0.0"
        else { return nil }
        return version
    }

    /// Numeric component comparison, so "1.10.0" beats "1.9.0" — a plain
    /// string compare would get that wrong. Missing components count as zero;
    /// non-numeric components (pre-release suffixes) also count as zero, which
    /// errs on the side of not nagging.
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let lhs = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private func publishIfNewer(_ release: Release?, than current: String) {
        guard let release, Self.isVersion(release.version, newerThan: current) else {
            availableRelease = nil
            return
        }
        availableRelease = release
    }

    // MARK: - Cached release

    /// The last release seen on a 200, persisted so 304s across relaunches
    /// still have something to compare against.
    private func loadCachedRelease() -> Release? {
        guard let data = UserDefaults.standard.data(forKey: cachedReleaseKey) else { return nil }
        return try? JSONDecoder().decode(Release.self, from: data)
    }

    private func storeCachedRelease(_ release: Release) {
        if let data = try? JSONEncoder().encode(release) {
            UserDefaults.standard.set(data, forKey: cachedReleaseKey)
        }
    }
}

/// The two fields we need from GitHub's latest-release payload.
private struct LatestRelease: Decodable {
    let tagName: String
    let htmlURL: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}
