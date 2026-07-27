#if DEBUG
import AppKit

/// README-screenshot support (`make screenshots`): seeds fake accounts,
/// auto-opens the panel, captures the app's own panel window — no Screen
/// Recording permission, nothing else on screen can leak into the image —
/// composites it onto a gradient, writes the PNG, and exits.
/// Active only when CLAUDE_USAGE_MOCK is set in the environment.
enum Mock {
    static var isEnabled: Bool { env("CLAUDE_USAGE_MOCK") != nil }

    private static func env(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key]
    }

    // MARK: - Fake data

    static let accounts: [AccountMeta] = [
        AccountMeta(
            id: "mock-work", email: "work@example.com", organizationName: nil,
            provider: .claude, label: "Work"),
        AccountMeta(
            id: "mock-personal", email: "personal@example.com", organizationName: nil,
            provider: .claude, label: "Personal"),
        AccountMeta(
            id: "mock-codex", email: "personal@example.com", organizationName: nil,
            provider: .codex),
    ]

    static var states: [String: AccountDisplayState] {
        let now = Date()
        func limits(_ rows: [(String, Double, TimeInterval)]) -> [LimitStatus] {
            rows.enumerated().map { index, row in
                LimitStatus(
                    id: row.0, name: row.0, percent: row.1,
                    resetsAt: now.addingTimeInterval(row.2),
                    isActive: index == 0, sortOrder: index,
                    // Session rows reset within a day; everything else is a
                    // seven-day window, matching both providers' real shapes.
                    windowSeconds: row.2 < 24 * 3600 ? 5 * 3600 : 7 * 86400)
            }
        }
        func state(
            _ rows: [(String, Double, TimeInterval)], credits: CreditsStatus? = nil
        ) -> AccountDisplayState {
            var state = AccountDisplayState()
            state.limits = limits(rows)
            state.credits = credits
            state.lastUpdated = now.addingTimeInterval(-45)
            return state
        }
        return [
            "mock-work": state(
                [
                    ("Session", 76, 1 * 3600 + 42 * 60),
                    ("Weekly", 48, 3 * 86400 + 4 * 3600),
                    ("Fable", 31, 3 * 86400 + 4 * 3600 + 120),
                ],
                credits: CreditsStatus(
                    usedMinor: 1240, limitMinor: 2500, currency: "GBP", exponent: 2,
                    percent: nil, enabled: true)),
            "mock-personal": state(
                [
                    ("Session", 91, 38 * 60),
                    ("Weekly", 24, 5 * 86400 + 11 * 3600),
                ],
                credits: CreditsStatus(
                    usedMinor: 320, limitMinor: nil, currency: "GBP", exponent: 2,
                    percent: 0, enabled: true)),
            // The Codex weekly window is deliberately mid-flight (reset in
            // 2d 8h ⇒ started 4¾ days ago): its expanded trend chart is the
            // one in the README, and a window that only just began would
            // show a sliver of recorded history against six blank days.
            "mock-codex": state([
                ("Session", 18, 2 * 3600 + 5 * 60),
                ("Weekly", 71, 2 * 86400 + 8 * 3600),
            ]),
        ]
    }

    /// One expanded trend chart for the screenshots — the Codex account, whose
    /// single seven-day window makes for exactly one chart. The Claude
    /// accounts stay collapsed, so the shot also shows the closed affordance.
    static let expandedTrends: Set<String> = ["mock-codex|Weekly"]

    // MARK: - Fake trend

    /// A plausible recorded-and-projected series for the trend chart. Mock
    /// mode never writes history (see `UsageHistoryStore.record`), so the
    /// screenshots would otherwise show an empty chart.
    ///
    /// Shape: recording starts a few hours into the window, climbs in daily
    /// bursts separated by flat overnight stretches, and lands exactly on the
    /// limit's current percent — then projects from the most recent burst's
    /// pace, the same way the real fit does.
    static func trend(for limit: LimitStatus, windowStart: Date, windowEnd: Date)
        -> UsageTrend?
    {
        let now = Date()
        let start = windowStart.addingTimeInterval(5 * 3600)
        guard now > start.addingTimeInterval(3600) else { return nil }

        let span = now.timeIntervalSince(start)
        let steps = 96
        // Fraction of the total climb completed by each step: flat at night
        // (a cosine trough), steeper by day, normalized to end at 1.
        var shape: [Double] = []
        var total = 0.0
        for step in 0..<steps {
            let phase = Double(step) / Double(steps) * span / 86400 * 2 * .pi
            total += max(0.05, 0.5 + 0.5 * cos(phase))
            shape.append(total)
        }
        let recorded = shape.enumerated().map { index, cumulative in
            UsageTrend.Point(
                date: start.addingTimeInterval(span * Double(index) / Double(steps - 1)),
                percent: limit.percent * cumulative / total)
        }

        guard let latest = recorded.last else { return nil }
        // Recent pace: the last eighth of the series, which is where a real
        // 12-hour fit would be looking.
        let earlier = recorded[recorded.count - steps / 8]
        let hours = latest.date.timeIntervalSince(earlier.date) / 3600
        let rate = hours > 0 ? max(0, (latest.percent - earlier.percent) / hours) : 0
        let projection = UsageTrend.project(
            from: latest, ratePerHour: rate, windowEnd: windowEnd)
        return UsageTrend(
            windowStart: windowStart, windowEnd: windowEnd, recorded: recorded,
            projected: projection.points, ratePerHour: rate,
            projectedAtReset: projection.atReset, exhaustsAt: projection.exhaustsAt)
    }

    // MARK: - Screenshot sequence

    @MainActor
    static func activateIfEnabled() {
        guard isEnabled else { return }
        let dark = env("CLAUDE_USAGE_APPEARANCE") == "dark"
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        guard let path = env("CLAUDE_USAGE_SHOT") else { return }
        attemptCapture(path: path, dark: dark, attempt: 1)
    }

    /// The panel auto-closes whenever the app deactivates (a stray click or
    /// keystroke elsewhere is enough), so each stage re-checks it and starts
    /// over instead of failing.
    @MainActor
    private static func attemptCapture(path: String, dark: Bool, attempt: Int) {
        guard attempt <= 5 else {
            return fail("gave up after 5 attempts (panel keeps closing)")
        }
        let retry = { attemptCapture(path: path, dark: dark, attempt: attempt + 1) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if panelWindow() == nil { openPanel() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let panel = panelWindow() else { return retry() }
                placeBackdrop(behind: panel, dark: dark)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    guard let panel = panelWindow() else { return retry() }
                    captureAndExit(panel: panel, path: path, dark: dark)
                }
            }
        }
    }

    @MainActor private static var backdrop: NSWindow?

    @MainActor
    private static func panelWindow() -> NSWindow? {
        NSApp.windows.first {
            $0 !== backdrop && $0.isVisible && $0.frame.width >= 300 && $0.frame.height >= 200
        }
    }

    @MainActor
    private static func openPanel() {
        for window in NSApp.windows {
            if let button = findSubview(of: NSStatusBarButton.self, in: window.contentView) {
                button.performClick(nil)
                return
            }
        }
        fail("status item button not found")
    }

    private static func findSubview<T: NSView>(of type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = findSubview(of: type, in: subview) { return match }
        }
        return nil
    }

    /// Puts a solid window directly behind the panel so its material blurs
    /// against a known color instead of whatever is on the user's screen.
    @MainActor
    private static func placeBackdrop(behind panel: NSWindow, dark: Bool) {
        backdrop?.orderOut(nil)
        let window = NSWindow(
            contentRect: panel.frame.insetBy(dx: -120, dy: -120),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor =
            dark ? NSColor(white: 0.10, alpha: 1) : NSColor(white: 0.95, alpha: 1)
        window.level = panel.level
        window.ignoresMouseEvents = true
        window.order(.below, relativeTo: panel.windowNumber)
        backdrop = window

        // The panel's frosted look is a window-server glass effect that
        // window captures resolve against black (murky gray). Painting a
        // solid window background underneath gives clean, deterministic
        // colors; the window's rounded-corner mask still applies to it.
        panel.backgroundColor = dark
            ? NSColor(calibratedWhite: 0.13, alpha: 1)
            : NSColor(calibratedWhite: 0.94, alpha: 1)
    }

    @MainActor
    private static func captureAndExit(panel: NSWindow, path: String, dark: Bool) {
        guard let (image, scale) = capture(window: panel) else {
            return fail("window capture failed")
        }
        guard let rep = composite(panel: image, scale: scale, dark: dark),
            let data = rep.representation(using: .png, properties: [:])
        else { return fail("compositing failed") }
        do {
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            return fail("write failed: \(error)")
        }
        print("screenshot written: \(path)")
        exit(0)
    }

    /// Captures the panel window's on-screen pixels. Capturing our own window
    /// does not require the Screen Recording permission.
    @MainActor
    private static func capture(window: NSWindow) -> (CGImage, CGFloat)? {
        let windowID = CGWindowID(window.windowNumber)
        if let image = CGWindowListCreateImage(
            .null, .optionIncludingWindow, windowID, [.boundsIgnoreFraming, .bestResolution]) {
            return (image, CGFloat(image.width) / window.frame.width)
        }
        // Fallback: render the view hierarchy directly (no window-server pass).
        guard let view = window.contentView,
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let cgImage = rep.cgImage else { return nil }
        return (cgImage, CGFloat(rep.pixelsWide) / view.bounds.width)
    }

    /// Re-blends the panel's semi-transparent material pixels over a solid
    /// base color so the on-screen backdrop blur doesn't influence the result,
    /// while keeping the rounded-corner silhouette intact.
    private static func flatten(panel: CGImage, over color: NSColor) -> CGImage {
        guard
            let context = CGContext(
                data: nil, width: panel.width, height: panel.height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return panel }
        let rect = CGRect(x: 0, y: 0, width: panel.width, height: panel.height)
        context.draw(panel, in: rect)
        context.setBlendMode(.destinationOver)
        context.setFillColor(color.cgColor)
        context.fill(rect)
        context.setBlendMode(.destinationIn)
        context.draw(panel, in: rect)
        return context.makeImage() ?? panel
    }

    private static func composite(panel raw: CGImage, scale: CGFloat, dark: Bool)
        -> NSBitmapImageRep?
    {
        let base = dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.97, alpha: 1)
        let panel = flatten(panel: raw, over: base)
        let padding = Int(48 * scale)
        let width = panel.width + padding * 2
        let height = panel.height + padding * 2
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let bounds = NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        let colors =
            dark
            ? [
                NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.18, alpha: 1),
                NSColor(calibratedRed: 0.20, green: 0.14, blue: 0.26, alpha: 1),
            ]
            : [
                NSColor(calibratedRed: 0.78, green: 0.84, blue: 0.94, alpha: 1),
                NSColor(calibratedRed: 0.90, green: 0.85, blue: 0.94, alpha: 1),
            ]
        NSGradient(colors: colors)?.draw(in: bounds, angle: -35)

        let cgContext = context.cgContext
        let panelRect = CGRect(x: padding, y: padding, width: panel.width, height: panel.height)
        cgContext.saveGState()
        cgContext.setShadow(
            offset: CGSize(width: 0, height: -10 * scale), blur: 30 * scale,
            color: NSColor.black.withAlphaComponent(dark ? 0.55 : 0.30).cgColor)
        cgContext.draw(panel, in: panelRect)
        cgContext.restoreGState()
        // Second pass brings the material's remaining translucency to ~full
        // opacity without touching the transparent rounded corners.
        cgContext.draw(panel, in: panelRect)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data(("mock screenshot error: \(message)\n").utf8))
        exit(1)
    }
}
#endif
