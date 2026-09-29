import XCTest
@testable import UsageRingsCore

/// Preferences tests use an isolated `UserDefaults` suite per test so nothing
/// touches the real domain and tests can run in any order without cross-talk.
@MainActor
final class PreferencesTests: XCTestCase {

    private var suiteName: String = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "test.usageRings.preferences.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        // Ensure a truly fresh domain even if the OS somehow returns a
        // suite with residual data.
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Defaults

    func testDefaultsWhenNothingHasBeenWritten() {
        let prefs = Preferences(suite: defaults)
        XCTAssertEqual(prefs.enabledProviders, Set(ProviderID.allCases))
        for id in ProviderID.allCases {
            XCTAssertEqual(prefs.ringWindow[id], .auto)
        }
        XCTAssertEqual(prefs.refreshIntervalSeconds, 300)
        XCTAssertEqual(prefs.iconStyle, .colour)
    }

    // MARK: - Enabled flag

    func testDisablingAProviderPersistsAndReflectsInEnabledSet() {
        let prefs = Preferences(suite: defaults)
        prefs.setEnabled(.codex, false)
        XCTAssertFalse(prefs.enabled[.codex] ?? true)
        XCTAssertFalse(prefs.enabledProviders.contains(.codex))

        // Round-trip: a fresh Preferences on the same suite must see the
        // change we just made.
        let reloaded = Preferences(suite: defaults)
        XCTAssertFalse(reloaded.enabled[.codex] ?? true)
        XCTAssertEqual(reloaded.enabledProviders, Set([.claude, .cursor]))
    }

    func testReenableAfterDisable() {
        let prefs = Preferences(suite: defaults)
        prefs.setEnabled(.claude, false)
        prefs.setEnabled(.claude, true)
        let reloaded = Preferences(suite: defaults)
        XCTAssertTrue(reloaded.enabled[.claude] ?? false)
    }

    // MARK: - Ring window

    func testRingWindowPersistsForSpecificKind() {
        let prefs = Preferences(suite: defaults)
        prefs.setRingWindow(.claude, .specific(.weekly))
        let reloaded = Preferences(suite: defaults)
        XCTAssertEqual(reloaded.ringWindow[.claude], .specific(.weekly))
    }

    func testRingWindowPersistsForAuto() {
        let prefs = Preferences(suite: defaults)
        prefs.setRingWindow(.claude, .specific(.fiveHour))
        prefs.setRingWindow(.claude, .auto)
        let reloaded = Preferences(suite: defaults)
        XCTAssertEqual(reloaded.ringWindow[.claude], .auto)
    }

    func testRingWindowOnDemandIsSanitisedToAuto() {
        let prefs = Preferences(suite: defaults)
        prefs.setRingWindow(.cursor, .specific(.onDemand))
        XCTAssertEqual(prefs.ringWindow[.cursor], .auto,
                       "onDemand must never survive as a ring choice")
        let reloaded = Preferences(suite: defaults)
        XCTAssertEqual(reloaded.ringWindow[.cursor], .auto)
    }

    func testRingWindowUnknownRawFallsBackToAuto() {
        // Simulate a corrupt / future value written to defaults.
        defaults.set("garbage", forKey: "usageRings.provider.claude.window")
        let prefs = Preferences(suite: defaults)
        XCTAssertEqual(prefs.ringWindow[.claude], .auto)
    }

    // MARK: - Refresh interval

    func testRefreshIntervalDefaultsTo300() {
        let prefs = Preferences(suite: defaults)
        XCTAssertEqual(prefs.refreshIntervalSeconds, 300)
    }

    func testRefreshIntervalPersistsInsideAllowedRange() {
        let prefs = Preferences(suite: defaults)
        prefs.setRefreshIntervalSeconds(120)
        XCTAssertEqual(prefs.refreshIntervalSeconds, 120)
        let reloaded = Preferences(suite: defaults)
        XCTAssertEqual(reloaded.refreshIntervalSeconds, 120)
    }

    func testRefreshIntervalIsClampedOnWrite() {
        let prefs = Preferences(suite: defaults)
        prefs.setRefreshIntervalSeconds(5)     // below minimum → 60
        XCTAssertEqual(prefs.refreshIntervalSeconds, 60)
        prefs.setRefreshIntervalSeconds(9_999) // above maximum → 300
        XCTAssertEqual(prefs.refreshIntervalSeconds, 300)
    }

    func testRefreshIntervalIsClampedOnRead() {
        // Someone (or an older build) wrote an out-of-range value directly.
        defaults.set(5.0, forKey: "usageRings.refreshIntervalSeconds")
        let prefs = Preferences(suite: defaults)
        XCTAssertEqual(prefs.refreshIntervalSeconds, 60)
        defaults.set(999.0, forKey: "usageRings.refreshIntervalSeconds")
        let prefs2 = Preferences(suite: defaults)
        XCTAssertEqual(prefs2.refreshIntervalSeconds, 300)
    }

    // MARK: - Icon style

    func testIconStyleDefaultsToColour() {
        let prefs = Preferences(suite: defaults)
        XCTAssertEqual(prefs.iconStyle, .colour)
    }

    func testIconStylePersists() {
        let prefs = Preferences(suite: defaults)
        prefs.setIconStyle(.withPercent)
        let reloaded = Preferences(suite: defaults)
        XCTAssertEqual(reloaded.iconStyle, .withPercent)
    }

    func testIconStyleUnknownFallsBackToColour() {
        defaults.set("neon", forKey: "usageRings.iconStyle")
        let prefs = Preferences(suite: defaults)
        XCTAssertEqual(prefs.iconStyle, .colour)
    }

    // MARK: - Renew Claude login automatically

    func testRenewClaudeLoginDefaultsToOn() {
        let prefs = Preferences(suite: defaults)
        XCTAssertTrue(prefs.renewClaudeLoginAutomatically,
                      "Renew Claude login automatically defaults to on")
    }

    func testRenewClaudeLoginPersistsAfterToggleOff() {
        let prefs = Preferences(suite: defaults)
        prefs.setRenewClaudeLoginAutomatically(false)
        XCTAssertFalse(prefs.renewClaudeLoginAutomatically)
        let reloaded = Preferences(suite: defaults)
        XCTAssertFalse(reloaded.renewClaudeLoginAutomatically)
    }

    func testRenewClaudeLoginPersistsAfterToggleOn() {
        let prefs = Preferences(suite: defaults)
        prefs.setRenewClaudeLoginAutomatically(false)
        prefs.setRenewClaudeLoginAutomatically(true)
        let reloaded = Preferences(suite: defaults)
        XCTAssertTrue(reloaded.renewClaudeLoginAutomatically)
    }

    func testRenewClaudeLoginNonisolatedReaderMirrorsInstanceProperty() {
        // The `attemptRenewal()` closure runs off the main actor and
        // reads through this static, so it must return the same value
        // the SwiftUI toggle sees.
        let prefs = Preferences(suite: defaults)
        prefs.setRenewClaudeLoginAutomatically(false)
        XCTAssertEqual(
            Preferences.renewClaudeLoginAutomaticallyValue(in: defaults),
            false
        )
        prefs.setRenewClaudeLoginAutomatically(true)
        XCTAssertEqual(
            Preferences.renewClaudeLoginAutomaticallyValue(in: defaults),
            true
        )
    }

    func testRenewClaudeLoginNonisolatedReaderDefaultsToOnWhenUnwritten() {
        XCTAssertEqual(
            Preferences.renewClaudeLoginAutomaticallyValue(in: defaults),
            true
        )
    }

    // MARK: - ProviderID.ringWindowKinds

    func testRingWindowKindsDoesNotIncludeOnDemand() {
        for id in ProviderID.allCases {
            XCTAssertFalse(id.ringWindowKinds.contains(.onDemand),
                           "\(id) offered .onDemand as a ring choice")
        }
    }

    func testRingWindowKindsMatchesEachProvidersActualWindows() {
        XCTAssertEqual(ProviderID.claude.ringWindowKinds, [.fiveHour, .weekly])
        XCTAssertEqual(ProviderID.codex.ringWindowKinds, [.primary, .secondary])
        XCTAssertEqual(ProviderID.cursor.ringWindowKinds, [.billingCycle])
    }
}

/// Template-image policy for the menu bar icon.
///
/// The critical case the review flagged: `.mono` + amber/red must NOT be
/// template — otherwise AppKit's menu bar tint recolours the warning arcs
/// back to neutral and the "you crossed 80/95%" signal disappears.
final class MenuBarIconTemplatePolicyTests: XCTestCase {

    func testMonoNormalIsTemplate() {
        XCTAssertTrue(menuBarIconIsTemplate(style: .mono, tint: .normal))
    }

    func testMonoAmberIsNotTemplate() {
        XCTAssertFalse(menuBarIconIsTemplate(style: .mono, tint: .amber),
                       "amber warning must not be re-tinted away by AppKit")
    }

    func testMonoRedIsNotTemplate() {
        XCTAssertFalse(menuBarIconIsTemplate(style: .mono, tint: .red),
                       "red warning must not be re-tinted away by AppKit")
    }

    func testColourStyleIsNeverTemplate() {
        for tint in [IconTintLevel.normal, .amber, .red] {
            XCTAssertFalse(menuBarIconIsTemplate(style: .colour, tint: tint))
            XCTAssertFalse(menuBarIconIsTemplate(style: .withPercent, tint: tint))
        }
    }

    // MARK: - Placeholder / empty entries

    func testShouldDrawPlaceholderWhenEmpty() {
        // A blank status item would be invisible against the menu bar and
        // Settings / Quit would become unreachable — draw a placeholder.
        XCTAssertTrue(shouldDrawMenuBarPlaceholder(entryCount: 0))
    }

    func testShouldNotDrawPlaceholderWhenAtLeastOneEntry() {
        XCTAssertFalse(shouldDrawMenuBarPlaceholder(entryCount: 1))
        XCTAssertFalse(shouldDrawMenuBarPlaceholder(entryCount: 3))
    }

    func testPlaceholderIsAlwaysTemplateRegardlessOfStyleOrTint() {
        // Even with `.colour` + red the placeholder outline must render as
        // template so it inherits the menu bar's system colour and does not
        // masquerade as a warning.
        XCTAssertTrue(menuBarIconIsTemplate(style: .colour, tint: .red, entryCount: 0))
        XCTAssertTrue(menuBarIconIsTemplate(style: .mono, tint: .amber, entryCount: 0))
        XCTAssertTrue(menuBarIconIsTemplate(style: .withPercent, tint: .normal, entryCount: 0))
    }

    func testNonEmptyEntriesFollowsExistingTintPolicy() {
        // Ensure the entry-count-aware overload preserves the old behaviour.
        XCTAssertTrue(menuBarIconIsTemplate(style: .mono, tint: .normal, entryCount: 3))
        XCTAssertFalse(menuBarIconIsTemplate(style: .mono, tint: .amber, entryCount: 3))
        XCTAssertFalse(menuBarIconIsTemplate(style: .colour, tint: .normal, entryCount: 3))
    }
}

/// Warning dot policy for the menu bar icon.
///
/// The threshold warning is not applied to the whole-icon tint; instead
/// it appears as a small dot at the icon's top-right: amber at ≥ 80%,
/// red at ≥ 95%, absent below 80%. Kept in Core so the dot's colour is a
/// pure function of the (already-rounded) tint level and has one test-covered
/// source of truth.
final class MenuBarWarningDotPolicyTests: XCTestCase {

    func testNormalTintHasNoDot() {
        XCTAssertNil(menuBarWarningDot(tint: .normal))
    }

    func testAmberTintYieldsAmberDot() {
        XCTAssertEqual(menuBarWarningDot(tint: .amber), .amber)
    }

    func testRedTintYieldsRedDot() {
        XCTAssertEqual(menuBarWarningDot(tint: .red), .red)
    }

    // MARK: - Accessibility suffix

    /// No dot → empty suffix, so the base label reads naturally.
    func testAccessibilitySuffixIsEmptyWithoutDot() {
        XCTAssertEqual(iconAccessibilityWarningSuffix(dot: nil), "")
    }

    /// Amber (≥ 80%): "nearing limit".
    func testAccessibilitySuffixForAmberSaysNearingLimit() {
        XCTAssertEqual(iconAccessibilityWarningSuffix(dot: .amber), ", nearing limit")
    }

    /// Red (≥ 95%) is *near* the limit, not necessarily past it — the row
    /// text carries the actual number. Say "almost at limit", not "over
    /// limit warning".
    func testAccessibilitySuffixForRedSaysAlmostAtLimit() {
        XCTAssertEqual(iconAccessibilityWarningSuffix(dot: .red), ", almost at limit")
    }

    /// The red-tint suffix must not claim the user is over the limit —
    /// guardrail against a regression to the earlier wording.
    func testAccessibilitySuffixNeverClaimsOverLimit() {
        for dot in [MenuBarWarningDot?.none, .amber, .red] {
            let text = iconAccessibilityWarningSuffix(dot: dot)
            XCTAssertFalse(text.lowercased().contains("over"),
                "suffix must not use 'over' phrasing; got \(text)")
        }
    }
}

/// Geometry of the coloured warning dot on the menu bar icon.
///
/// The dot lives in the extra right-margin the icon canvas carries —
/// otherwise the 1 pt clear ring around the dot would clip ring arcs
/// near 1:30 (a Claude arc tip near 14% could be erased). These tests
/// pin the dot to the canvas margin and forbid overlap with the outer
/// ring's bounding circle.
final class MenuBarWarningDotGeometryTests: XCTestCase {

    func testDotFitsInsideCanvasAtTopRight() {
        let width = MenuBarIconGeometry.canvasWidth
        let centre = MenuBarWarningDotGeometry.centre(canvasWidth: width)
        let radius = MenuBarWarningDotGeometry.diameter / 2
        // Right / top must not clip the canvas edges.
        XCTAssertLessThanOrEqual(centre.x + radius, width, "dot must not clip the right edge")
        XCTAssertGreaterThanOrEqual(centre.y - radius, 0, "dot must not clip the top edge")
    }

    func testDotDimensionsAreFivePoints() {
        // ≈ 5 pt diameter dot. (No clear-ring cutout — the dot sits in a
        // widened canvas margin instead.)
        XCTAssertEqual(MenuBarWarningDotGeometry.diameter, 5)
    }

    func testDotDoesNotOverlapOuterRingBoundingCircle() {
        // The dot must sit clear of the outer ring's outer edge or it
        // will clip arcs. Distance from the ring centre to the dot centre
        // must exceed
        //   (outer ring outer-edge radius) + (dot radius).
        let width = MenuBarIconGeometry.canvasWidth
        let ringCentre = MenuBarIconGeometry.ringCentre
        let dotCentre = MenuBarWarningDotGeometry.centre(canvasWidth: width)
        let dx = dotCentre.x - ringCentre.x
        let dy = dotCentre.y - ringCentre.y
        let distance = (dx * dx + dy * dy).squareRoot()
        let outerRingEdge = MenuBarIconGeometry.outerEdgeRadius(index: 0)
        let dotRadius = MenuBarWarningDotGeometry.diameter / 2
        XCTAssertGreaterThan(distance, outerRingEdge + dotRadius,
            "dot must not overlap the outer ring; distance \(distance) vs required > \(outerRingEdge + dotRadius)")
    }

    func testCanvasHasExtraRightMarginForDot() {
        // Sanity: the canvas must actually be wider than the ring square,
        // or the dot has nowhere to live.
        XCTAssertGreaterThan(MenuBarIconGeometry.canvasWidth, MenuBarIconGeometry.side,
            "canvas width must exceed the ring stack side so the dot lives outside the arcs")
    }
}
