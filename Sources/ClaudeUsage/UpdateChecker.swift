import Combine
import Foundation

/// Polls GitHub's latest-release endpoint and publishes any release newer
/// than the running build, so the panel can offer a link to the release page.
/// No auto-download/install — the app ships as a zip, so a pointer is enough.
@MainActor
final class UpdateChecker: ObservableObject {
    /// A published release newer than the running build.
    struct Release: Codable, Equatable {
        /// Semantic version with any leading "v" stripped, e.g. "1.2.0".
        let version: String
        /// The release's `html_url` — the human-facing GitHub release page.
        let url: URL
    }

    @Published private(set) var availableRelease: Release?

    /// UserDefaults keys, internal so tests can seed and inspect persisted
    /// state through an isolated suite.
    enum DefaultsKey {
        static let etag = "updateETag"
        static let cachedRelease = "updateCachedRelease"
    }

    private static let endpoint = AppInfo.latestReleaseAPI
    /// Once a day is plenty; combined with ETag caching, 304 responses don't
    /// count against GitHub's unauthenticated rate limit.
    private let checkInterval: TimeInterval = 24 * 60 * 60
    private let currentVersion: String?
    private let defaults: UserDefaults
    private var checkLoop: Task<Void, Never>?

    /// Production configuration: the real bundle version, standard defaults,
    /// and the daily check loop running.
    convenience init() {
        self.init(currentVersion: Self.bundleVersion, defaults: .standard)
        // Dev builds (`swift run`) have no Info.plist and no .app wrapper, so
        // there is no version to compare against — never check, never nag.
        if currentVersion != nil { startCheckLoop() }
    }

    /// Designated initializer with no loop and no network so tests can drive
    /// the pieces directly. Re-evaluating the cached release here (not in the
    /// loop) matters in production too: without it, a relaunch whose first
    /// check answers 304 would hide an update we already know about — the
    /// ETag matches precisely because nothing new was published.
    init(currentVersion: String?, defaults: UserDefaults) {
        self.currentVersion = currentVersion
        self.defaults = defaults
        guard currentVersion != nil else { return }
        publishIfNewer(loadCachedRelease())
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
        guard let currentVersion else { return }

        var request = URLRequest(url: Self.endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(
            "claude-usage-menu-bar/\(currentVersion) (update check)",
            forHTTPHeaderField: "User-Agent")
        if let etag = defaults.string(forKey: DefaultsKey.etag) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        request.timeoutInterval = 15

        guard let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse,
            // 304: nothing published since the stored ETag — the cached
            // release (already evaluated at init) is still the latest.
            http.statusCode == 200
        else { return }

        ingest(latestReleaseBody: data, etag: http.value(forHTTPHeaderField: "ETag"))
    }

    /// Processes a 200 body from the latest-release endpoint: parse, persist,
    /// publish. Split from the network call so the pipeline is testable
    /// without stubbing URLSession.
    func ingest(latestReleaseBody data: Data, etag: String?) {
        guard let latest = try? JSONDecoder().decode(LatestRelease.self, from: data),
            let url = URL(string: latest.htmlURL)
        else { return }

        // Only remember the ETag once the body parsed, so a truncated or
        // malformed 200 can't poison future conditional requests.
        if let etag {
            defaults.set(etag, forKey: DefaultsKey.etag)
        }

        let release = Release(version: Self.version(fromTag: latest.tagName), url: url)
        storeCachedRelease(release)
        publishIfNewer(release)
    }

    // MARK: - Version comparison

    /// The running build's marketing version, or nil for dev builds. A bare
    /// executable launched via `swift run` has no Info.plist and no .app
    /// wrapper; both checks guard against nagging during development.
    nonisolated static var bundleVersion: String? {
        guard Bundle.main.bundleURL.pathExtension == "app",
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String,
            !version.isEmpty, version != "0.0.0"
        else { return nil }
        return version
    }

    /// Tags are conventionally "v1.2.0"; the bundle version has no prefix.
    static func version(fromTag tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
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

    private func publishIfNewer(_ release: Release?) {
        guard let currentVersion, let release,
            Self.isVersion(release.version, newerThan: currentVersion)
        else {
            availableRelease = nil
            return
        }
        availableRelease = release
    }

    // MARK: - Cached release

    /// The last release seen on a 200, persisted so 304s across relaunches
    /// still have something to compare against.
    private func loadCachedRelease() -> Release? {
        guard let data = defaults.data(forKey: DefaultsKey.cachedRelease) else { return nil }
        return try? JSONDecoder().decode(Release.self, from: data)
    }

    private func storeCachedRelease(_ release: Release) {
        if let data = try? JSONEncoder().encode(release) {
            defaults.set(data, forKey: DefaultsKey.cachedRelease)
        }
    }
}

/// The two fields we need from GitHub's latest-release payload.
struct LatestRelease: Decodable {
    let tagName: String
    let htmlURL: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}
