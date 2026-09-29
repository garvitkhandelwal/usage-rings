import SwiftUI
import AppKit
import UsageRingsCore

/// One entry to render on the menu bar icon: the provider that owns the
/// ring and, when available, a percentage in [0, ∞). A nil percentage means
/// the provider is present in the popover but currently has no ring value
/// (loading / signed-out / offline / error) — the icon draws its track and
/// skips the filled arc.
struct MenuBarEntry: Equatable {
    let id: ProviderID
    let percent: Double?
}

/// Builds the menu bar icon: miniature concentric rings, one per visible
/// provider, using the same outer→inner ring order as the popover, plus a
/// small coloured warning dot when any visible ring is over the 80% / 95%
/// threshold.
///
/// The canvas is `canvasWidth × canvasHeight` (22×18) pt: the rings occupy
/// the leftmost 18-pt square, and the dot sits in the extra 4 pt margin at
/// the top-right so it never overlaps the arcs. Ring colours are always
/// the provider brand colours (lavender / teal / amber) in `.colour` and
/// `.withPercent`; `.mono` uses `Color.primary`, and the image ships as
/// a template when there is no warning so AppKit tints it in the menu
/// bar's system colour. When a warning is active on `.mono` the image
/// ships non-template and the rings are drawn in the label colour
/// resolved for the menu bar's colour scheme — passed in explicitly via
/// `makeImage(colorScheme:)` because `ImageRenderer` does not inherit
/// the menu bar's appearance from the SwiftUI environment (without this,
/// `Color.primary` bakes in as opaque black and the rings are invisible
/// against a dark menu bar).
enum MenuBarIcon {

    /// Total icon canvas size in points. Delegated to Core so the sizing
    /// is unit-tested (see `MenuBarIconGeometry`).
    static var canvasSize: CGSize {
        CGSize(width: MenuBarIconGeometry.canvasWidth,
               height: MenuBarIconGeometry.canvasHeight)
    }

    /// Render the mini-rings image for a given set of entries, icon style,
    /// and menu bar colour scheme.
    ///
    /// `colorScheme` is applied to the SwiftUI content driving
    /// `ImageRenderer` — critical for `.mono` + warning, where the rings
    /// are drawn with `Color.primary` and must resolve to the *menu bar's*
    /// label colour rather than the app-default light-mode black.
    @MainActor
    static func makeImage(
        entries: [MenuBarEntry],
        tint: IconTintLevel,
        style: IconStyle,
        colorScheme: ColorScheme
    ) -> NSImage {
        let size = canvasSize
        let content = MiniRingsView(entries: entries, tint: tint, style: style)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, colorScheme)
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let fallback = NSImage(size: size)
        let image = renderer.nsImage ?? fallback
        image.isTemplate = menuBarIconIsTemplate(
            style: style,
            tint: tint,
            entryCount: entries.count
        )
        return image
    }
}

/// The SwiftUI `MenuBarExtra` label — image plus optional percent text.
///
/// Reads `@Environment(\.colorScheme)` and threads it through to
/// `MenuBarIcon.makeImage` so the produced `NSImage` renders `Color.primary`
/// against the *menu bar's* actual appearance. SwiftUI re-renders this
/// view whenever the environment `colorScheme` flips (system light↔dark),
/// so the icon adapts automatically without extra observers.
struct MenuBarLabel: View {

    let entries: [MenuBarEntry]
    let tint: IconTintLevel
    let style: IconStyle

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: MenuBarIcon.makeImage(
                entries: entries,
                tint: tint,
                style: style,
                colorScheme: colorScheme
            ))
            .accessibilityHidden(true)
            if style == .withPercent, let highest = highestPercentText {
                // Spec (2026-09-29): the % text keeps the provider-neutral
                // label colour; the warning dot on the icon carries the
                // 80%/95% threshold signal, so the text is never recoloured.
                Text(highest)
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
        }
        .accessibilityLabel(accessibilityText)
    }

    private var highestPercentText: String? {
        let values = entries.compactMap { $0.percent }
        guard let max = values.max() else { return nil }
        return Formatting.percentText(max)
    }

    /// Accessibility label for VoiceOver. Includes the highest visible
    /// percentage and, when the icon shows a warning dot, an "almost at
    /// limit" / "nearing limit" phrase so users of screen readers get the
    /// same signal the sighted user gets from the dot. Wording is
    /// centralised in `iconAccessibilityWarningSuffix(dot:)` in Core so
    /// it is unit-tested.
    private var accessibilityText: String {
        let base: String
        if let text = highestPercentText {
            base = "Usage Rings, highest \(text)"
        } else {
            base = "Usage Rings"
        }
        return base + iconAccessibilityWarningSuffix(dot: menuBarWarningDot(tint: tint))
    }
}

/// The Canvas-based rendering used both by the menu bar label directly and
/// by `MenuBarIcon.makeImage` via `ImageRenderer`.
struct MiniRingsView: View {

    let entries: [MenuBarEntry]
    let tint: IconTintLevel
    let style: IconStyle

    var body: some View {
        Canvas { ctx, size in
            // Ring stack sizing: rings sit in a square of side
            // `min(width, height)` at the top-left of the canvas. That
            // leaves the right margin (canvas width beyond `side`) free
            // for the warning dot.
            let side = min(size.width, size.height)
            let scale = side / MenuBarIconGeometry.side
            let centre = CGPoint(x: side / 2, y: side / 2)

            // Empty entries → draw one neutral placeholder outline so the
            // menu bar item is never invisible. Without this the whole
            // status item is blank when every provider is hidden and the
            // user cannot reach Settings / Quit. Uses the outer ring's
            // centre radius; the template flag on the produced NSImage
            // (see `makeImage`) will tint the outline in the menu bar's
            // system colour.
            if shouldDrawMenuBarPlaceholder(entryCount: entries.count) {
                let centreRadius = MenuBarIconGeometry.centreLineRadius(index: 0) * scale
                let strokeWidth = MenuBarIconGeometry.strokeWidth * scale
                let trackRect = CGRect(
                    x: centre.x - centreRadius, y: centre.y - centreRadius,
                    width: centreRadius * 2, height: centreRadius * 2
                )
                ctx.stroke(
                    Path(ellipseIn: trackRect),
                    with: .color(Color.primary),
                    style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
                )
                return
            }
            for (index, entry) in entries.enumerated() {
                let centreRadius = MenuBarIconGeometry.centreLineRadius(index: index) * scale
                guard centreRadius > 0 else { continue }
                let strokeWidth = MenuBarIconGeometry.strokeWidth * scale
                let baseCGColor = ringColor(for: entry.id)
                // Track.
                let trackRect = CGRect(
                    x: centre.x - centreRadius, y: centre.y - centreRadius,
                    width: centreRadius * 2, height: centreRadius * 2
                )
                ctx.stroke(
                    Path(ellipseIn: trackRect),
                    with: .color(baseCGColor.opacity(0.25)),
                    style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
                )
                // Filled arc, if any.
                if let percent = entry.percent, percent > 0 {
                    let fraction = min(max(percent / 100, 0), 1)
                    if fraction > 0 {
                        var arcPath = Path()
                        arcPath.addArc(
                            center: centre,
                            radius: centreRadius,
                            startAngle: .degrees(-90),
                            endAngle: .degrees(-90 + 360 * fraction),
                            clockwise: false
                        )
                        ctx.stroke(
                            arcPath,
                            with: .color(baseCGColor),
                            style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
                        )
                    }
                }
            }
            // Warning dot: painted last, in the right-margin area of the
            // canvas (beyond the ring square) so it never overlaps the
            // ring arcs. No clear-ring cutout is needed here because the
            // dot sits on empty canvas.
            if let dot = menuBarWarningDot(tint: tint) {
                drawWarningDot(ctx: &ctx, canvasSize: size, dot: dot)
            }
        }
        .frame(
            width: MenuBarIconGeometry.canvasWidth,
            height: MenuBarIconGeometry.canvasHeight
        )
    }

    /// Colour for a given provider's ring.
    ///
    /// - `.mono` → `Color.primary`. Combined with the template flag from
    ///   `menuBarIconIsTemplate(style:tint:entryCount:)`, this renders as
    ///   the menu bar's system tint when there is no warning (template),
    ///   and as the label colour for the menu bar's colour scheme when a
    ///   warning is active (non-template — the coloured dot must survive
    ///   the menu bar's tinting). The colour scheme is set explicitly on
    ///   the renderer content in `MenuBarIcon.makeImage`, so `.primary`
    ///   resolves against the menu bar's appearance rather than
    ///   `ImageRenderer`'s default.
    /// - `.colour` / `.withPercent` → the provider's brand colour, always.
    ///   The 80% / 95% threshold warning is conveyed by the dot; the rings
    ///   themselves are never recoloured.
    private func ringColor(for id: ProviderID) -> Color {
        switch style {
        case .mono:
            return .primary
        case .colour, .withPercent:
            return Theme.color(for: id)
        }
    }

    /// Paint the coloured warning dot in the canvas's top-right margin.
    ///
    /// The dot's centre is `MenuBarWarningDotGeometry.centre(canvasWidth:)`
    /// — a fixed offset from the right edge of the canvas, scaled to the
    /// actual rendered size. There is no cutout: `canvasWidth` is chosen
    /// (22 pt for an 18 pt ring stack) so the dot's bounding circle sits
    /// entirely outside the ring stack and can't clip an arc.
    private func drawWarningDot(ctx: inout GraphicsContext, canvasSize: CGSize, dot: MenuBarWarningDot) {
        let scale = canvasSize.height / MenuBarIconGeometry.canvasHeight
        let dotRadius = (MenuBarWarningDotGeometry.diameter / 2) * scale
        let centre = MenuBarWarningDotGeometry.centre(canvasWidth: canvasSize.width)
        let dotRect = CGRect(
            x: centre.x - dotRadius, y: centre.y - dotRadius,
            width: dotRadius * 2, height: dotRadius * 2
        )
        let dotColour: Color = {
            switch dot {
            case .amber: return .orange
            case .red:   return .red
            }
        }()
        ctx.fill(Path(ellipseIn: dotRect), with: .color(dotColour))
    }
}
