import XCTest
@testable import UsageRingsCore

final class RingGeometryTests: XCTestCase {

    func testCentreLineRadiusDecreasesByStrokePlusGap() {
        let side: CGFloat = 220
        let r0 = RingGeometry.centreLineRadius(index: 0, side: side)
        let r1 = RingGeometry.centreLineRadius(index: 1, side: side)
        let r2 = RingGeometry.centreLineRadius(index: 2, side: side)

        XCTAssertEqual(r0, side / 2 - RingGeometry.strokeWidth / 2, accuracy: 0.0001)
        XCTAssertEqual(r0 - r1, RingGeometry.strokeWidth + RingGeometry.ringGap, accuracy: 0.0001)
        XCTAssertEqual(r1 - r2, RingGeometry.strokeWidth + RingGeometry.ringGap, accuracy: 0.0001)
    }

    func testHoleDiameterForOneRingIsInnerEdge() {
        let hole = RingGeometry.holeDiameter(visibleRingCount: 1)
        // 220 - 22 = 198 (edge-to-edge of the outer ring is 22 pt from
        // the frame; the hole is everything inside the ring).
        XCTAssertEqual(hole, 220 - 2 * RingGeometry.strokeWidth, accuracy: 0.0001)
    }

    func testHoleDiameterShrinksAsRingsAreAdded() {
        let one = RingGeometry.holeDiameter(visibleRingCount: 1)
        let two = RingGeometry.holeDiameter(visibleRingCount: 2)
        let three = RingGeometry.holeDiameter(visibleRingCount: 3)
        XCTAssertGreaterThan(one, two)
        XCTAssertGreaterThan(two, three)
    }

    func testHoleDiameterForThreeRingsFitsCentreLabel() {
        // The whole point of picking `side` as we did: three visible rings
        // must still leave a hole large enough for the "Updated / N min ago"
        // label. If someone shrinks `side` this fires first.
        let hole = RingGeometry.holeDiameter(visibleRingCount: 3)
        XCTAssertGreaterThanOrEqual(hole, RingGeometry.minimumCentreHoleDiameter,
            "Three visible rings must leave at least \(RingGeometry.minimumCentreHoleDiameter) pt for the centre label, got \(hole) pt")
    }

    func testHoleDiameterForZeroRingsIsSide() {
        XCTAssertEqual(RingGeometry.holeDiameter(visibleRingCount: 0), RingGeometry.side)
    }

    func testDefaultSideFitsInPopoverWidth() {
        // Popover is 320 pt wide; we use 12 pt horizontal padding on each
        // side, so the ring stack must fit in 296 pt. `side` = 220 leaves
        // 38 pt of padding either side — comfortable and consistent with
        // the "~320 pt wide" spec.
        XCTAssertLessThanOrEqual(RingGeometry.side, 296)
    }
}

final class MenuBarIconGeometryTests: XCTestCase {

    /// The review flagged the previous (2.4 / 0.6) values because the
    /// innermost ring's inner edge was only 0.6 pt from centre — the ring
    /// rendered as a nearly-solid disc. All three mini rings must have a
    /// visible transparent hole (inner-edge radius > 0.5 pt at 18×18).
    func testAllThreeMiniRingsHaveVisibleHole() {
        for index in 0..<3 {
            let inner = MenuBarIconGeometry.innerEdgeRadius(index: index)
            XCTAssertGreaterThan(inner, 0.5,
                "mini ring at index \(index) must have a visible transparent inner hole; got \(inner) pt")
        }
    }

    /// The outer ring must fit inside the 18 pt frame with half a stroke
    /// clearance on either side.
    func testOuterRingFitsInsideIcon() {
        let outer = MenuBarIconGeometry.centreLineRadius(index: 0)
        let expected = MenuBarIconGeometry.side / 2 - MenuBarIconGeometry.strokeWidth / 2
        XCTAssertEqual(outer, expected, accuracy: 1e-9)
    }

    /// Each subsequent ring sits one stroke plus one gap closer to centre
    /// — same relationship as the popover's `RingGeometry`.
    func testConsecutiveMiniRingsSpacedByStrokePlusGap() {
        let r0 = MenuBarIconGeometry.centreLineRadius(index: 0)
        let r1 = MenuBarIconGeometry.centreLineRadius(index: 1)
        let r2 = MenuBarIconGeometry.centreLineRadius(index: 2)
        XCTAssertEqual(r0 - r1,
                       MenuBarIconGeometry.strokeWidth + MenuBarIconGeometry.ringGap,
                       accuracy: 1e-9)
        XCTAssertEqual(r1 - r2,
                       MenuBarIconGeometry.strokeWidth + MenuBarIconGeometry.ringGap,
                       accuracy: 1e-9)
    }
}

final class ColorMathTests: XCTestCase {

    func testDarkenZeroIsIdentity() {
        let (r, g, b) = ColorMath.darken((0.3, 0.6, 0.9), by: 0)
        XCTAssertEqual(r, 0.3, accuracy: 1e-9)
        XCTAssertEqual(g, 0.6, accuracy: 1e-9)
        XCTAssertEqual(b, 0.9, accuracy: 1e-9)
    }

    func testDarkenOneIsBlack() {
        let (r, g, b) = ColorMath.darken((0.3, 0.6, 0.9), by: 1)
        XCTAssertEqual(r, 0, accuracy: 1e-9)
        XCTAssertEqual(g, 0, accuracy: 1e-9)
        XCTAssertEqual(b, 0, accuracy: 1e-9)
    }

    func testDarkenBelowZeroClampsToIdentity() {
        let (r, g, b) = ColorMath.darken((0.5, 0.5, 0.5), by: -0.4)
        XCTAssertEqual(r, 0.5, accuracy: 1e-9)
        XCTAssertEqual(g, 0.5, accuracy: 1e-9)
        XCTAssertEqual(b, 0.5, accuracy: 1e-9)
    }

    func testDarkenAboveOneClampsToBlack() {
        let (r, g, b) = ColorMath.darken((0.5, 0.5, 0.5), by: 1.7)
        XCTAssertEqual(r, 0, accuracy: 1e-9)
        XCTAssertEqual(g, 0, accuracy: 1e-9)
        XCTAssertEqual(b, 0, accuracy: 1e-9)
    }

    func testSecondLapFactorProducesMateriallyDarkerChannels() {
        // Guardrail: the darken factor must be strong enough that the
        // resulting channels are visibly different from the base for the
        // three brand colours. "Visibly different" here = at least 10%
        // of each channel value.
        let brand: [(r: Double, g: Double, b: Double)] = [
            (0.72, 0.65, 1.00),  // Claude lavender
            (0.14, 0.67, 0.66),  // Codex teal
            (0.98, 0.64, 0.22),  // Cursor amber
        ]
        for base in brand {
            let dark = ColorMath.darken(base, by: ColorMath.secondLapDarkenFactor)
            XCTAssertLessThanOrEqual(dark.r, base.r * 0.9 + 1e-9)
            XCTAssertLessThanOrEqual(dark.g, base.g * 0.9 + 1e-9)
            XCTAssertLessThanOrEqual(dark.b, base.b * 0.9 + 1e-9)
        }
    }
}

final class RingDashStyleTests: XCTestCase {

    func testSignedOutDashHasVisibleGap() {
        // The whole reason this pattern exists: the gap must be larger
        // than the dash so a butt-capped stroke shows
        // real "off" pixels between dashes at the 22 pt stroke width. If
        // someone tweaks the pattern to a short gap this test fires.
        let dash = RingDashStyle.signedOutDash
        XCTAssertEqual(dash.count, 2)
        XCTAssertGreaterThan(dash[1], dash[0], "gap must exceed dash length")
        XCTAssertGreaterThanOrEqual(dash[1], 8, "gap must be visible against 22pt stroke")
    }

    // MARK: - Per-ring dash pattern

    /// The whole point of the per-ring pattern: `dash + gap` divides evenly
    /// into the ring's circumference so there is no partial dash at 3
    /// o'clock (where `Circle` closes its stroke path). Test the innermost
    /// and outermost rings — both must produce integer segment counts.
    func testSignedOutDashPatternDividesCircumferenceEvenly() {
        for index in 0..<3 {
            let radius = RingGeometry.centreLineRadius(index: index)
            let pattern = RingDashStyle.signedOutDashPattern(radius: radius)
            XCTAssertEqual(pattern.count, 2, "pattern must be [dash, gap]")
            let segment = pattern[0] + pattern[1]
            let circumference = 2 * .pi * radius
            let ratio = circumference / segment
            // Allow a very small floating-point wobble.
            XCTAssertEqual(ratio, ratio.rounded(), accuracy: 1e-9,
                           "ring \(index): circumference must be an integer multiple of dash+gap")
        }
    }

    /// The pattern must stay close to the visual target (4 pt on, 10 pt off)
    /// — otherwise the dash count would be right but the dashes could shrink
    /// to invisible slivers on a large ring or bloat on a small one.
    func testSignedOutDashPatternPreservesTargetRatio() {
        let pattern = RingDashStyle.signedOutDashPattern(radius: 100)
        let dash = pattern[0], gap = pattern[1]
        XCTAssertEqual(dash / (dash + gap), 4.0 / 14.0, accuracy: 1e-9,
                       "dash / (dash + gap) must match target 4 / 14")
    }

    /// Smaller rings have shorter circumferences — the pattern must still
    /// produce at least one dash, never a degenerate zero-count.
    func testSignedOutDashPatternHandlesTinyRadius() {
        let pattern = RingDashStyle.signedOutDashPattern(radius: 1)
        XCTAssertEqual(pattern.count, 2)
        XCTAssertGreaterThan(pattern[0], 0, "dash must be > 0 even for tiny rings")
        XCTAssertGreaterThan(pattern[1], 0, "gap must be > 0")
    }

    /// A larger ring should still produce more segments than a smaller one
    /// with the same target — otherwise the segments would be visibly
    /// stretched at the outer radius.
    func testSignedOutDashPatternScalesWithRadius() {
        let small = RingDashStyle.signedOutDashPattern(radius: 30)
        let large = RingDashStyle.signedOutDashPattern(radius: 90)
        let smallSegment = small[0] + small[1]
        let largeSegment = large[0] + large[1]
        // Segment length should be within 15% of the target 14 pt for both.
        XCTAssertLessThan(abs(smallSegment - 14), 14 * 0.15)
        XCTAssertLessThan(abs(largeSegment - 14), 14 * 0.15)
    }
}
