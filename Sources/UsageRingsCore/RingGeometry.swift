import Foundation
import CoreGraphics

/// Pure geometric constants and math for the popover's concentric ring stack.
///
/// Kept in Core so the numbers can be unit-tested and there is exactly one
/// place that decides the ring stroke, gap and side length. The SwiftUI
/// `RingsView` reads everything through this namespace.
///
/// Layout: N rings drawn as concentric circles inside a square of side
/// `side`. Ring 0 is the outer ring; each subsequent ring sits one stroke
/// plus one gap closer to the centre. The stroke is drawn centred on the
/// ring's radius — half the stroke lies outside the radius, half inside.
public enum RingGeometry {

    /// Stroke width of each ring, in points (spec: 22 pt).
    public static let strokeWidth: CGFloat = 22

    /// Radial gap between adjacent rings, in points (spec: 4 pt).
    public static let ringGap: CGFloat = 4

    /// Fixed side length of the ring square in the popover.
    ///
    /// Sized so the innermost of three visible rings still leaves a hole
    /// large enough to hold the two-line "Updated / N min ago" centre label.
    /// See `holeDiameter(visibleRingCount:)` for the math; 220 gives a
    /// 72 pt centre hole with three rings — comfortable for "12 min ago"
    /// at the callout font size.
    public static let side: CGFloat = 220

    /// Minimum centre-hole diameter required to display the two-line
    /// "Updated / N min ago" label without collision with the innermost
    /// ring. Used by tests to guarantee `side` stays large enough as the
    /// number of visible rings changes.
    ///
    /// Measured empirically at the popover's font sizes: "Updated"
    /// (`caption2`) is ~40 pt wide; "12 min ago" (`callout`) is ~60 pt
    /// wide with a `.semibold` monospacedDigit style. 60 pt is the
    /// lower bound.
    public static let minimumCentreHoleDiameter: CGFloat = 60

    /// Centre-line radius of the ring at the given index (0 = outer).
    ///
    /// The stroke is centred on this radius — half the stroke lies outside
    /// it and half inside. A negative return means the ring would not fit
    /// inside the given side (only possible when the caller passes an
    /// obviously-too-small side); callers should clamp before drawing.
    public static func centreLineRadius(index: Int, side: CGFloat = Self.side) -> CGFloat {
        side / 2 - strokeWidth / 2 - CGFloat(index) * (strokeWidth + ringGap)
    }

    /// Diameter of the transparent "hole" in the middle of the stack when
    /// `visibleRingCount` rings are drawn.
    ///
    /// This is the diameter available to the centre label. For
    /// `visibleRingCount == 0` we treat the whole square as available.
    public static func holeDiameter(visibleRingCount: Int, side: CGFloat = Self.side) -> CGFloat {
        guard visibleRingCount > 0 else { return side }
        let innermostCentreRadius = centreLineRadius(index: visibleRingCount - 1, side: side)
        // The inner edge of the innermost ring sits stroke/2 inside its
        // centre line. Anything smaller than that is inside the hole.
        let innerEdgeRadius = innermostCentreRadius - strokeWidth / 2
        return max(0, innerEdgeRadius * 2)
    }
}

/// Geometry for the menu bar icon's mini concentric rings.
///
/// Kept in Core (a) so the sizing is unit-tested — a review flagged the
/// innermost ring rendering as an almost-solid disc at the old
/// `(strokeWidth: 2.4, ringGap: 0.6)` values, and (b) so both the app's
/// SwiftUI Canvas renderer and any future NSImage producer read from one
/// place. Values chosen so `centreLineRadius(index: 2) - strokeWidth/2`
/// leaves a visible transparent hole inside the innermost ring at 18×18.
///
/// The canvas the icon renders into is `canvasWidth × canvasHeight` points.
/// The rings sit in a square of side `side` at the top-left of that canvas
/// (the extra width on the right is a margin reserved for the warning dot
/// — see `MenuBarWarningDotGeometry`). Widening the canvas beyond `side`
/// is required: painting the dot inside the 18-pt ring square would erase
/// ring arcs directly under the dot's clear-ring cutout (the outer ring's
/// arc tip near 1:30 was seen to disappear at 14%).
public enum MenuBarIconGeometry {

    /// Ring-square side length in points (18×18 pt ring stack).
    public static let side: CGFloat = 18

    /// Total icon canvas width in points. The rings occupy the leftmost
    /// `side` points; the extra `canvasWidth - side` points to the right
    /// are the dot's margin.
    public static let canvasWidth: CGFloat = 22

    /// Total icon canvas height in points — same as the ring stack side.
    public static let canvasHeight: CGFloat = side

    /// Stroke width of each mini ring, in points.
    public static let strokeWidth: CGFloat = 1.6

    /// Radial gap between adjacent mini rings, in points.
    public static let ringGap: CGFloat = 0.8

    /// Centre of the ring stack inside the canvas — the rings are painted
    /// in the leftmost `side × side` square at the top of the canvas.
    public static let ringCentre: CGPoint = CGPoint(x: side / 2, y: side / 2)

    /// Centre-line radius of the mini ring at `index` (0 = outer). Mirrors
    /// `RingGeometry.centreLineRadius(index:side:)` for the icon-sized
    /// stack.
    public static func centreLineRadius(index: Int) -> CGFloat {
        side / 2 - strokeWidth / 2 - CGFloat(index) * (strokeWidth + ringGap)
    }

    /// The inner-edge radius of the ring at `index` — half a stroke inside
    /// the centre line. For the ring to *look* like a ring rather than a
    /// disc this must be positive (there has to be transparent room in
    /// the middle). Tests enforce this for indices 0…2.
    public static func innerEdgeRadius(index: Int) -> CGFloat {
        centreLineRadius(index: index) - strokeWidth / 2
    }

    /// The outer-edge radius of the ring at `index` — half a stroke outside
    /// the centre line. The dot must sit outside this radius from the ring
    /// centre or it clips the arcs.
    public static func outerEdgeRadius(index: Int) -> CGFloat {
        centreLineRadius(index: index) + strokeWidth / 2
    }
}

/// Geometry of the small warning dot painted at the menu bar icon's
/// top-right corner.
///
/// The dot is a filled disc placed in the extra margin to the right of the
/// ring stack — never over the arcs themselves. That margin is baked into
/// `MenuBarIconGeometry.canvasWidth` (22 pt for an 18 pt ring stack), so
/// the dot cannot erase a nearby ring arc. (On an 18-pt canvas the dot's
/// 1 pt clear cutout wiped an arc tip near 1:30 on the outer ring.) Kept
/// in Core so the sizing and placement are unit-tested and cannot silently
/// drift.
public enum MenuBarWarningDotGeometry {

    /// Diameter of the coloured warning dot, in points (≈ 5 pt).
    public static let diameter: CGFloat = 5

    /// Centre of the warning dot for a canvas of width `canvasWidth` (in
    /// points), relative to the canvas's top-left origin (SwiftUI Canvas
    /// coordinates: +x right, +y down).
    ///
    /// Positioned flush with the top-right corner of the canvas: the dot's
    /// outer edge touches both the top edge and the right edge.
    public static func centre(canvasWidth: CGFloat = MenuBarIconGeometry.canvasWidth) -> CGPoint {
        let inset = diameter / 2
        return CGPoint(x: canvasWidth - inset, y: inset)
    }
}

/// Small colour-math helpers used to derive a visibly-darker "second lap"
/// colour without pulling SwiftUI into Core.
///
/// Kept as tuples of 0…1 RGB so the math is pure and unit-testable; the
/// SwiftUI `Theme` builds `Color` values from these tuples.
public enum ColorMath {

    /// Factor used to darken the base ring colour into the second-lap
    /// colour ("second lap wraps with a darker overlap"). 0.35 gives a
    /// clearly-different tone against every one of the three brand
    /// colours in both light and dark popovers.
    public static let secondLapDarkenFactor: Double = 0.35

    /// Blend an sRGB triple toward black by `factor` in [0, 1].
    ///
    /// - `factor == 0` → unchanged.
    /// - `factor == 1` → black.
    /// - Values outside [0, 1] are clamped.
    public static func darken(
        _ rgb: (r: Double, g: Double, b: Double),
        by factor: Double
    ) -> (r: Double, g: Double, b: Double) {
        let f = max(0, min(1, factor))
        return (
            r: rgb.r * (1 - f),
            g: rgb.g * (1 - f),
            b: rgb.b * (1 - f)
        )
    }
}

/// Ring track styling for the `.signedOut` state.
///
/// Isolated so the exact dash pattern is testable — the review flagged a
/// round-cap + short-dash combination that visually merged into a solid
/// stroke. The values below produce visibly-separated dashes for the
/// 22 pt stroke width used by the popover.
public enum RingDashStyle {

    /// Target dash pattern (points on, points off) for the signed-out
    /// track. The live renderer uses `signedOutDashPattern(radius:)` — this
    /// constant is the visual target the per-ring computation rounds toward
    /// so the pattern still reads as "short dash, longer gap" at every ring
    /// size.
    ///
    /// Butt-capped in `RingsView` so a "4 pt on" dash renders as a 4 pt
    /// segment (not extended by half-stroke-width caps into a merged
    /// solid line).
    public static let signedOutDash: [CGFloat] = [4, 10]

    /// Per-ring dash pattern that divides the ring's circumference into a
    /// whole number of `(dash + gap)` segments.
    ///
    /// Why per-ring: a `Circle.stroke(dash: [4, 10])` closes at 3 o'clock,
    /// where the last dash almost never lines up with the pattern boundary.
    /// The result is a visibly-partial dash at that one spot. Computing
    /// the pattern from the ring's actual circumference removes the
    /// partial dash without changing the visual language of the target.
    ///
    /// The returned array is `[dash, gap]` in points, with:
    ///  - `dash + gap` chosen so `circumference / (dash + gap)` is an
    ///    integer (rounded to the nearest whole segment count),
    ///  - the `dash : (dash + gap)` ratio preserved from `signedOutDash`
    ///    (4 : 14 today) so the visual weight is stable across rings.
    ///
    /// For a radius so small there is no room for even one full segment
    /// this returns a pattern with a very small dash and gap; the "at least
    /// one segment" clamp on `n` guarantees positive values.
    public static func signedOutDashPattern(radius: CGFloat) -> [CGFloat] {
        let targetDash = signedOutDash[0]
        let targetGap = signedOutDash[1]
        let targetSegment = targetDash + targetGap
        let circumference = 2 * CGFloat.pi * max(radius, 0.0001)
        let rawSegments = circumference / targetSegment
        let segments = max(1, Int(rawSegments.rounded()))
        let actualSegment = circumference / CGFloat(segments)
        let dashRatio = targetDash / targetSegment
        let dash = actualSegment * dashRatio
        let gap = actualSegment - dash
        return [dash, gap]
    }
}
