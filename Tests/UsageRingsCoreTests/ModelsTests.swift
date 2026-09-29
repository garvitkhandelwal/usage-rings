import XCTest
@testable import UsageRingsCore

final class ProviderIDTests: XCTestCase {

    func testRingOrderOuterToInner() {
        XCTAssertEqual(ProviderID.ringOrderOuterToInner, [.claude, .codex, .cursor])
    }

    func testDisplayNames() {
        XCTAssertEqual(ProviderID.claude.displayName, "Claude Code")
        XCTAssertEqual(ProviderID.codex.displayName, "Codex")
        XCTAssertEqual(ProviderID.cursor.displayName, "Cursor")
    }

    func testUsagePageURLs() {
        XCTAssertEqual(ProviderID.claude.usagePageURL.absoluteString, "https://claude.ai/settings/usage")
        XCTAssertEqual(ProviderID.codex.usagePageURL.absoluteString, "https://chatgpt.com/codex/settings/usage")
        XCTAssertEqual(ProviderID.cursor.usagePageURL.absoluteString, "https://cursor.com/dashboard?tab=usage")
    }

    func testCaseIterableContainsAllThree() {
        XCTAssertEqual(Set(ProviderID.allCases), Set([.claude, .codex, .cursor]))
    }
}

final class WindowSelectionTests: XCTestCase {

    private func makeWindow(_ kind: UsageWindowKind, percent: Double) -> UsageWindow {
        UsageWindow(label: kind.rawValue, usedPercent: percent, resetsAt: nil, kind: kind)
    }

    private func makeUsage(_ windows: [UsageWindow]) -> ProviderUsage {
        ProviderUsage(id: .claude, plan: nil, windows: windows, fetchedAt: Date(timeIntervalSince1970: 0))
    }

    // MARK: - Auto

    func testAutoPicksHigherPercent() {
        let low = makeWindow(.fiveHour, percent: 20)
        let high = makeWindow(.weekly, percent: 60)
        let selection = selectWindows(for: makeUsage([low, high]), preference: .auto)
        XCTAssertEqual(selection.ring, high)
        XCTAssertEqual(selection.secondary, low)
    }

    func testAutoWithSingleWindowHasNoSecondary() {
        let only = makeWindow(.fiveHour, percent: 30)
        let selection = selectWindows(for: makeUsage([only]), preference: .auto)
        XCTAssertEqual(selection.ring, only)
        XCTAssertNil(selection.secondary)
    }

    // MARK: - onDemand rule

    func testAutoNeverPicksOnDemandForRing() {
        // On-demand has a higher percent, but it must never take the ring slot.
        let plan = makeWindow(.billingCycle, percent: 40)
        let onDemand = makeWindow(.onDemand, percent: 90)
        let selection = selectWindows(for: makeUsage([plan, onDemand]), preference: .auto)
        XCTAssertEqual(selection.ring, plan)
        XCTAssertEqual(selection.secondary, onDemand)
    }

    func testSpecificOnDemandDoesNotOverrideRule() {
        // Even if a caller passes .specific(.onDemand), the ring must stay eligible.
        let plan = makeWindow(.billingCycle, percent: 40)
        let onDemand = makeWindow(.onDemand, percent: 5)
        let selection = selectWindows(for: makeUsage([plan, onDemand]), preference: .specific(.onDemand))
        XCTAssertEqual(selection.ring, plan)
        XCTAssertEqual(selection.secondary, onDemand)
    }

    func testOnDemandOnlyProviderYieldsNoRing() {
        // Not realistic in practice, but the rule must hold.
        let onDemand = makeWindow(.onDemand, percent: 42)
        let selection = selectWindows(for: makeUsage([onDemand]), preference: .auto)
        XCTAssertNil(selection.ring)
        XCTAssertEqual(selection.secondary, onDemand)
    }

    // MARK: - Explicit preference

    func testSpecificPreferenceHonouredWhenPresent() {
        let fiveHour = makeWindow(.fiveHour, percent: 20)
        let weekly = makeWindow(.weekly, percent: 60)
        let selection = selectWindows(for: makeUsage([fiveHour, weekly]),
                                      preference: .specific(.fiveHour))
        XCTAssertEqual(selection.ring, fiveHour)
        XCTAssertEqual(selection.secondary, weekly)
    }

    func testSpecificPreferenceFallsBackToAutoWhenWindowMissing() {
        let fiveHour = makeWindow(.fiveHour, percent: 20)
        let weekly = makeWindow(.weekly, percent: 60)
        // Prefer .primary but the provider does not have it.
        let selection = selectWindows(for: makeUsage([fiveHour, weekly]),
                                      preference: .specific(.primary))
        XCTAssertEqual(selection.ring, weekly)
        XCTAssertEqual(selection.secondary, fiveHour)
    }

    // MARK: - Empty

    func testEmptyWindowsYieldsNothing() {
        let selection = selectWindows(for: makeUsage([]), preference: .auto)
        XCTAssertNil(selection.ring)
        XCTAssertNil(selection.secondary)
    }
}

final class FixturesResourceTests: XCTestCase {

    /// The test target must copy the Fixtures directory so later tasks can
    /// parse them. This guards the Package.swift resources entry.
    func testFixturesAreBundled() throws {
        let bundle = Bundle.module
        for name in ["claude-usage", "codex-usage", "cursor-usage"] {
            guard let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
                XCTFail("Missing fixture: \(name).json")
                continue
            }
            let data = try Data(contentsOf: url)
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data),
                             "\(name).json is not valid JSON")
        }
    }
}
