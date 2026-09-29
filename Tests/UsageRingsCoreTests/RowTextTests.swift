import XCTest
@testable import UsageRingsCore

final class RowTextTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func usage(
        _ id: ProviderID = .claude,
        windows: [UsageWindow]
    ) -> ProviderUsage {
        ProviderUsage(id: id, plan: nil, windows: windows, fetchedAt: now)
    }

    // MARK: - primaryText

    func testLoadingShowsCheckingEllipsis() {
        XCTAssertEqual(RowText.primaryText(state: .loading, now: now), "Checking\u{2026}")
    }

    func testOkShowsResetText() {
        let win = UsageWindow(label: "5h", usedPercent: 10, resetsAt: now.addingTimeInterval(2 * 3600 + 30 * 60), kind: .fiveHour)
        let state = ProviderState.ok(usage(windows: [win]))
        XCTAssertEqual(RowText.primaryText(state: state, now: now), "Reset in 2h 30m")
    }

    func testOkWithoutResetDateShowsEmptyString() {
        let win = UsageWindow(label: "Monthly", usedPercent: 10, resetsAt: nil, kind: .billingCycle)
        let state = ProviderState.ok(usage(windows: [win]))
        XCTAssertEqual(RowText.primaryText(state: state, now: now), "")
    }

    func testStaleShowsAsOfMeasuredFromFetchedAt() {
        // "As of N min ago" measures the age of the data being displayed
        // — usage.fetchedAt — NOT the failure moment. If the row read the
        // failure time instead, the user would be told "As of 12 min ago"
        // while the on-screen numbers might actually be hours old.
        let win = UsageWindow(label: "5h", usedPercent: 20, resetsAt: nil, kind: .fiveHour)
        let stalePayload = ProviderUsage(
            id: .claude,
            plan: nil,
            windows: [win],
            fetchedAt: now.addingTimeInterval(-30 * 60) // data is 30 min old
        )
        // Failure was recorded only 5 min ago — a red herring for this text.
        let state = ProviderState.stale(stalePayload, since: now.addingTimeInterval(-5 * 60))
        XCTAssertEqual(RowText.primaryText(state: state, now: now), "As of 30 min ago")
    }

    func testOfflineText() {
        XCTAssertEqual(RowText.primaryText(state: .offline, now: now), "No internet connection")
    }

    func testSignedOutText() {
        XCTAssertEqual(
            RowText.primaryText(state: .signedOut(reason: "Open Claude Code to refresh"), now: now),
            "Open Claude Code to refresh"
        )
    }

    func testErrorText() {
        XCTAssertEqual(RowText.primaryText(state: .error("Server error 503"), now: now), "Server error 503")
    }

    func testHiddenTextIsEmpty() {
        XCTAssertEqual(RowText.primaryText(state: .hidden, now: now), "")
    }

    // MARK: - percentText

    func testPercentPresentForOk() {
        let win = UsageWindow(label: "5h", usedPercent: 81.0, resetsAt: nil, kind: .fiveHour)
        XCTAssertEqual(RowText.percentText(state: .ok(usage(windows: [win]))), "81%")
    }

    func testPercentPresentForStale() {
        let win = UsageWindow(label: "5h", usedPercent: 42.5, resetsAt: nil, kind: .fiveHour)
        let state = ProviderState.stale(usage(windows: [win]), since: now)
        XCTAssertEqual(RowText.percentText(state: state), "43%")
    }

    func testPercentNilForNonUsageStates() {
        XCTAssertNil(RowText.percentText(state: .loading))
        XCTAssertNil(RowText.percentText(state: .offline))
        XCTAssertNil(RowText.percentText(state: .signedOut(reason: "x")))
        XCTAssertNil(RowText.percentText(state: .error("x")))
        XCTAssertNil(RowText.percentText(state: .hidden))
    }

    // MARK: - secondaryLine

    func testSecondaryLinePresentWhenTwoWindows() {
        let five = UsageWindow(label: "5h", usedPercent: 22, resetsAt: now.addingTimeInterval(3 * 3600 + 10 * 60), kind: .fiveHour)
        let weekly = UsageWindow(label: "Weekly", usedPercent: 60, resetsAt: now.addingTimeInterval(4 * 86400), kind: .weekly)
        // Weekly is higher so it drives the ring; the secondary line shows 5h.
        let state = ProviderState.ok(usage(windows: [five, weekly]))
        XCTAssertEqual(RowText.secondaryLine(state: state, now: now), "5h: 22% \u{00B7} resets 3h 10m")
    }

    func testSecondaryLineNilForOneWindow() {
        let win = UsageWindow(label: "5h", usedPercent: 22, resetsAt: nil, kind: .fiveHour)
        XCTAssertNil(RowText.secondaryLine(state: .ok(usage(windows: [win])), now: now))
    }

    func testSecondaryLineNilForNonUsageStates() {
        XCTAssertNil(RowText.secondaryLine(state: .loading, now: now))
        XCTAssertNil(RowText.secondaryLine(state: .offline, now: now))
        XCTAssertNil(RowText.secondaryLine(state: .signedOut(reason: "x"), now: now))
    }

    func testSecondaryLineForOnDemandRoutesThroughCurrencyHelper() {
        // Cursor: the plan window drives the ring; the on-demand window
        // appears as the secondary line using the "$X.YZ on-demand" text
        // rather than the generic "label: percent" text.
        let plan = UsageWindow(
            label: "Monthly",
            usedPercent: 50,
            resetsAt: now.addingTimeInterval(10 * 86400),
            kind: .billingCycle
        )
        let onDemand = UsageWindow(
            label: "On-demand",
            usedPercent: 0,
            resetsAt: nil,
            kind: .onDemand,
            amountCents: 2083,
            limitCents: nil
        )
        let state = ProviderState.ok(usage(.cursor, windows: [plan, onDemand]))
        XCTAssertEqual(
            RowText.secondaryLine(state: state, now: now),
            "$20.83 on-demand"
        )
    }

    func testSecondaryLineForOnDemandWithLimit() {
        let plan = UsageWindow(
            label: "Monthly",
            usedPercent: 50,
            resetsAt: now.addingTimeInterval(10 * 86400),
            kind: .billingCycle
        )
        let onDemand = UsageWindow(
            label: "On-demand",
            usedPercent: 0,
            resetsAt: nil,
            kind: .onDemand,
            amountCents: 2083,
            limitCents: 5000
        )
        let state = ProviderState.ok(usage(.cursor, windows: [plan, onDemand]))
        XCTAssertEqual(
            RowText.secondaryLine(state: state, now: now),
            "$20.83 of $50.00 on-demand"
        )
    }

    // MARK: - centreText

    func testCentreTextWithoutLastRefreshIsEllipsis() {
        XCTAssertEqual(RowText.centreText(lastRefresh: nil, now: now), "\u{2026}")
    }

    func testCentreTextRecent() {
        XCTAssertEqual(RowText.centreText(lastRefresh: now.addingTimeInterval(-10), now: now), "Now")
    }

    func testCentreTextMinutesAgo() {
        XCTAssertEqual(RowText.centreText(lastRefresh: now.addingTimeInterval(-4 * 60), now: now), "4 min ago")
    }

    // MARK: - visibleProviders

    func testVisibleProvidersInRingOrderExcludingHidden() {
        let claudeUsage = usage(.claude, windows: [
            UsageWindow(label: "5h", usedPercent: 10, resetsAt: nil, kind: .fiveHour),
        ])
        let states: [ProviderID: ProviderState] = [
            .claude: .ok(claudeUsage),
            .codex: .hidden,
            .cursor: .loading,
        ]
        let visible = RowText.visibleProviders(states: states)
        XCTAssertEqual(visible.map(\.id), [.claude, .cursor])
    }

    func testVisibleProvidersMissingKeyIsHidden() {
        let visible = RowText.visibleProviders(states: [:])
        XCTAssertTrue(visible.isEmpty)
    }

    // MARK: - headerSubtitle

    private func usageWithPlan(_ id: ProviderID, plan: String?) -> ProviderUsage {
        ProviderUsage(
            id: id,
            plan: plan,
            windows: [UsageWindow(label: "5h", usedPercent: 0, resetsAt: nil, kind: .fiveHour)],
            fetchedAt: now
        )
    }

    func testHeaderSubtitleNilWhenNoPlansPresent() {
        // Claude never returns a plan name — the popover should hide the
        // subtitle rather than show an empty label.
        let visible: [(id: ProviderID, state: ProviderState)] = [
            (.claude, .ok(usageWithPlan(.claude, plan: nil)))
        ]
        XCTAssertNil(RowText.headerSubtitle(visible: visible))
    }

    func testHeaderSubtitleTitleCasesAndPrefixesProvider() {
        // Raw lowercase API strings ("free", "enterprise") must never
        // surface. Prefix each with the provider short name so the user
        // knows what plan belongs to which ring.
        let visible: [(id: ProviderID, state: ProviderState)] = [
            (.codex, .ok(usageWithPlan(.codex, plan: "free"))),
            (.cursor, .ok(usageWithPlan(.cursor, plan: "enterprise"))),
        ]
        XCTAssertEqual(
            RowText.headerSubtitle(visible: visible),
            "Codex Free \u{00B7} Cursor Enterprise"
        )
    }

    func testHeaderSubtitleHandlesUnderscoreAndMixedSegments() {
        // Underscored plan names ("team_v2") should read "Team V2".
        // A mixed-case segment ("Pro") is left alone.
        let visible: [(id: ProviderID, state: ProviderState)] = [
            (.codex, .ok(usageWithPlan(.codex, plan: "team_v2"))),
            (.cursor, .ok(usageWithPlan(.cursor, plan: "Pro"))),
        ]
        XCTAssertEqual(
            RowText.headerSubtitle(visible: visible),
            "Codex Team V2 \u{00B7} Cursor Pro"
        )
    }

    func testHeaderSubtitleReadsPlanFromStaleUsage() {
        // A .stale state must still contribute its plan name — the popover
        // should not lose the subtitle just because a refresh failed.
        let visible: [(id: ProviderID, state: ProviderState)] = [
            (.codex, .stale(usageWithPlan(.codex, plan: "plus"), since: now)),
        ]
        XCTAssertEqual(
            RowText.headerSubtitle(visible: visible),
            "Codex Plus"
        )
    }

    func testHeaderSubtitleIgnoresProvidersWithoutPlan() {
        // Claude has no plan; Codex does. Only Codex contributes.
        let visible: [(id: ProviderID, state: ProviderState)] = [
            (.claude, .ok(usageWithPlan(.claude, plan: nil))),
            (.codex, .ok(usageWithPlan(.codex, plan: "pro"))),
        ]
        XCTAssertEqual(
            RowText.headerSubtitle(visible: visible),
            "Codex Pro"
        )
    }
}
