import XCTest
import SwiftUI
import AppKit
@testable import UsageRings
@testable import UsageRingsCore

/// Verifies the production `MenuBarIcon.makeImage` API under both light and
/// dark colour schemes. Without threading the menu bar's colour scheme
/// into `ImageRenderer`, `Color.primary` in the SwiftUI content bakes in
/// as opaque black, and mono rings are near-invisible on a dark menu bar.
@MainActor
final class MenuBarIconRenderTests: XCTestCase {

    /// Round-trip through TIFF/PNG so we always get a real
    /// `NSBitmapImageRep` (ImageRenderer's default representation on
    /// macOS 14 is a `NSCGImageRep`, whose `colorAt(x:y:)` returns nil).
    private func bitmap(from image: NSImage) -> NSBitmapImageRep? {
        if let bitmap = image.representations.first as? NSBitmapImageRep {
            return bitmap
        }
        guard let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }

    /// Grab the ring-edge pixel at 3 o'clock (roughly on the outer ring's
    /// centre line) so tests can assert what colour the mono ring rendered
    /// against a given colour scheme.
    private func pixelAtOuterRingEdge(_ image: NSImage) -> NSColor? {
        guard let bitmap = bitmap(from: image) else { return nil }
        let width = CGFloat(bitmap.pixelsWide)
        let height = CGFloat(bitmap.pixelsHigh)
        let side = min(MenuBarIconGeometry.side, MenuBarIconGeometry.canvasHeight)
        let scaleX = width / MenuBarIconGeometry.canvasWidth
        let scaleY = height / MenuBarIconGeometry.canvasHeight
        let centreRadius = MenuBarIconGeometry.centreLineRadius(index: 0)
        let px = Int(((side / 2) + centreRadius) * scaleX)
        let py = Int((side / 2) * scaleY)
        return bitmap.colorAt(x: min(px, bitmap.pixelsWide - 1),
                              y: min(py, bitmap.pixelsHigh - 1))
    }

    /// Grab the top-right corner (where the warning dot lives) so tests
    /// can check the dot colour.
    private func pixelAtWarningDot(_ image: NSImage) -> NSColor? {
        guard let bitmap = bitmap(from: image) else { return nil }
        let width = CGFloat(bitmap.pixelsWide)
        let height = CGFloat(bitmap.pixelsHigh)
        let scaleX = width / MenuBarIconGeometry.canvasWidth
        let scaleY = height / MenuBarIconGeometry.canvasHeight
        let centre = MenuBarWarningDotGeometry.centre()
        let px = Int(centre.x * scaleX)
        let py = Int(centre.y * scaleY)
        return bitmap.colorAt(x: min(px, bitmap.pixelsWide - 1),
                              y: min(py, bitmap.pixelsHigh - 1))
    }

    private var typicalEntries: [MenuBarEntry] {
        [
            MenuBarEntry(id: .claude, percent: 30),
            MenuBarEntry(id: .codex,  percent: 55),
            MenuBarEntry(id: .cursor, percent: 70),
        ]
    }

    /// Under `.light`, mono rings must render dark (roughly black) so
    /// they read against the light menu bar.
    func testMonoRingIsDarkUnderLightColorScheme() throws {
        let image = MenuBarIcon.makeImage(
            entries: typicalEntries,
            tint: .normal,
            style: .mono,
            colorScheme: .light
        )
        let pixel = try XCTUnwrap(pixelAtOuterRingEdge(image),
                                  "must be able to sample the outer ring pixel")
        // Reject any bright value — light-mode primary is near-black.
        XCTAssertLessThan(pixel.brightnessComponent, 0.35,
                          "mono ring under .light should be dark; got brightness \(pixel.brightnessComponent)")
    }

    /// Under `.dark`, mono rings must render light (roughly white) so
    /// they read against the dark menu bar — a regression guard: if
    /// `.primary` bakes in as light-mode black the rings become
    /// invisible on a dark bar.
    func testMonoRingIsLightUnderDarkColorScheme() throws {
        let image = MenuBarIcon.makeImage(
            entries: typicalEntries,
            tint: .normal,
            style: .mono,
            colorScheme: .dark
        )
        let pixel = try XCTUnwrap(pixelAtOuterRingEdge(image),
                                  "must be able to sample the outer ring pixel")
        XCTAssertGreaterThan(pixel.brightnessComponent, 0.65,
                             "mono ring under .dark should be light; got brightness \(pixel.brightnessComponent) — regression: `.primary` in ImageRenderer is baking in the wrong scheme")
    }

    /// Colour-style ring must be the provider's brand colour regardless of
    /// colour scheme — spec says provider colours always.
    func testColourStyleRingKeepsBrandColourUnderBothSchemes() throws {
        for scheme in [ColorScheme.light, .dark] {
            let image = MenuBarIcon.makeImage(
                entries: typicalEntries,
                tint: .normal,
                style: .colour,
                colorScheme: scheme
            )
            let pixel = try XCTUnwrap(pixelAtOuterRingEdge(image))
            // Claude lavender: (0.72, 0.65, 1.00) — red > 0.5, blue > 0.9.
            let srgb = pixel.usingColorSpace(.sRGB) ?? pixel
            XCTAssertGreaterThan(srgb.blueComponent, 0.7,
                "outer ring under \(scheme) must show lavender-ish blue; got \(srgb)")
        }
    }

    /// The warning dot must be a red-ish pixel under `.red` tint, no
    /// matter which style, and under either colour scheme (the dot is
    /// always a coloured pixel on a non-template image).
    func testRedWarningDotShowsRedPixel() throws {
        for style in [IconStyle.colour, .mono, .withPercent] {
            for scheme in [ColorScheme.light, .dark] {
                let entries = [
                    MenuBarEntry(id: .claude, percent: 30),
                    MenuBarEntry(id: .codex,  percent: 55),
                    MenuBarEntry(id: .cursor, percent: 97),
                ]
                let image = MenuBarIcon.makeImage(
                    entries: entries,
                    tint: .red,
                    style: style,
                    colorScheme: scheme
                )
                let pixel = try XCTUnwrap(pixelAtWarningDot(image))
                let srgb = pixel.usingColorSpace(.sRGB) ?? pixel
                XCTAssertGreaterThan(srgb.redComponent, 0.6,
                    "\(style)/\(scheme): dot must be red-ish; got r=\(srgb.redComponent)")
                XCTAssertLessThan(srgb.blueComponent, 0.6,
                    "\(style)/\(scheme): dot must not be blue-ish; got b=\(srgb.blueComponent)")
            }
        }
    }

    /// Emit a full matrix of PNGs — colour/mono/withPercent × normal/amber/red,
    /// under both `.light` and `.dark`, plus the placeholder — for manual
    /// visual review.
    ///
    /// Enabled by setting `USAGE_RINGS_EMIT_ICON_PNGS=1` in the test
    /// environment; otherwise skipped so noisy filesystem writes don't
    /// happen on every run. Output directory is
    /// `USAGE_RINGS_EMIT_ICON_PNGS_DIR` when set, else a fresh
    /// subdirectory of the system temporary directory — never a
    /// machine-specific path baked into committed code.
    func testEmitVerificationPNGsIfRequested() throws {
        guard ProcessInfo.processInfo.environment["USAGE_RINGS_EMIT_ICON_PNGS"] == "1" else {
            throw XCTSkip("set USAGE_RINGS_EMIT_ICON_PNGS=1 to write PNGs")
        }
        let dir = ProcessInfo.processInfo.environment["USAGE_RINGS_EMIT_ICON_PNGS_DIR"]
            ?? (NSTemporaryDirectory() as NSString)
                .appendingPathComponent("UsageRings-menu-bar-icons")
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        print("emitting menu bar icon PNGs to: \(dir)")
        let scenarios: [(String, [MenuBarEntry], IconTintLevel)] = [
            ("normal", typicalEntries, .normal),
            ("amber",  [
                MenuBarEntry(id: .claude, percent: 30),
                MenuBarEntry(id: .codex,  percent: 55),
                MenuBarEntry(id: .cursor, percent: 85),
            ], .amber),
            ("red", [
                MenuBarEntry(id: .claude, percent: 30),
                MenuBarEntry(id: .codex,  percent: 55),
                MenuBarEntry(id: .cursor, percent: 97),
            ], .red),
        ]
        let styles: [(String, IconStyle)] = [
            ("colour", .colour),
            ("mono",   .mono),
            ("withPercent", .withPercent),
        ]
        for (sName, style) in styles {
            for (tName, entries, tint) in scenarios {
                for scheme in [ColorScheme.light, .dark] {
                    let image = MenuBarIcon.makeImage(
                        entries: entries, tint: tint, style: style, colorScheme: scheme
                    )
                    let path = "\(dir)/\(sName)-\(tName)-\(scheme == .light ? "light" : "dark").png"
                    try writePNG(image, to: path)
                }
            }
        }
        for scheme in [ColorScheme.light, .dark] {
            let image = MenuBarIcon.makeImage(
                entries: [], tint: .normal, style: .colour, colorScheme: scheme
            )
            try writePNG(image, to: "\(dir)/placeholder-\(scheme == .light ? "light" : "dark").png")
        }
    }

    private func writePNG(_ image: NSImage, to path: String) throws {
        guard let bmp = bitmap(from: image),
              let data = bmp.representation(using: .png, properties: [:]) else {
            XCTFail("could not encode PNG for \(path)")
            return
        }
        try data.write(to: URL(fileURLWithPath: path))
    }

    /// Template flag policy round-trip: `.mono` normal is template,
    /// everything with a warning is non-template. Guards against a future
    /// change to `makeImage` that forgets to apply the flag.
    func testTemplateFlagMatchesPolicy() {
        let entries = typicalEntries
        XCTAssertTrue(
            MenuBarIcon.makeImage(entries: entries, tint: .normal, style: .mono, colorScheme: .light).isTemplate,
            "mono + normal must be template"
        )
        XCTAssertFalse(
            MenuBarIcon.makeImage(entries: entries, tint: .amber, style: .mono, colorScheme: .light).isTemplate,
            "mono + amber must be non-template so the dot keeps its colour"
        )
        XCTAssertFalse(
            MenuBarIcon.makeImage(entries: entries, tint: .normal, style: .colour, colorScheme: .light).isTemplate
        )
    }
}
