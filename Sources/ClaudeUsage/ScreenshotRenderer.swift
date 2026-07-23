#if DEBUG
import AppKit
import SwiftUI

/// Renders the panel with mock data to `docs/screenshot-{light,dark}.png` so
/// the README images can be regenerated without real accounts.
///
/// Fully offscreen via `ImageRenderer` (no window/display needed). Live AppKit
/// controls — buttons, the checkbox — can't rasterize offscreen, so the panel
/// is rendered with `screenshotMode` on, which substitutes static SwiftUI
/// look-alikes for them (see `MenuContentView`).
///
/// Invoked by `AppEntry` on `--render-screenshots` (see `make screenshots`).
@MainActor
enum ScreenshotRenderer {
    static func run() {
        _ = NSApplication.shared
        render(scheme: .light, to: "docs/screenshot-light.png")
        render(scheme: .dark, to: "docs/screenshot-dark.png")
    }

    private static func render(scheme: ColorScheme, to path: String) {
        // Drive AppKit-resolved colors/materials alongside SwiftUI's colorScheme.
        NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)

        let panel = MenuContentView(store: .makeMock())
            .environment(\.screenshotMode, true)
            .background(
                .regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
            .padding(28)
            .environment(\.colorScheme, scheme)

        let renderer = ImageRenderer(content: panel)
        renderer.scale = 2

        guard let cgImage = renderer.cgImage else {
            FileHandle.standardError.write(Data("Failed to render \(path)\n".utf8))
            return
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("Failed to encode \(path)\n".utf8))
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            print("Wrote \(path) (\(cgImage.width)×\(cgImage.height))")
        } catch {
            FileHandle.standardError.write(Data("Failed to write \(path): \(error)\n".utf8))
        }
    }
}
#endif
