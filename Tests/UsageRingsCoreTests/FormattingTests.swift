import XCTest
@testable import UsageRingsCore

final class FormattingResetTextTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func at(_ seconds: TimeInterval) -> Date {
        now.addingTimeInterval(seconds)
    }

    func testResetsSoonForPastReset() {
        XCTAssertEqual(Formatting.resetText(resetsAt: at(-1), now: now), "Resets soon")
    }

    func testResetsSoonForZeroDelta() {
        XCTAssertEqual(Formatting.resetText(resetsAt: now, now: now), "Resets soon")
    }

    func testMinutesUnderOneHour() {
        // 45 minutes → "Reset in 45m"
        XCTAssertEqual(Formatting.resetText(resetsAt: at(45 * 60), now: now), "Reset in 45m")
    }

    func testMinutesFloorNeverBelowOne() {
        // 30 seconds still shows "Reset in 1m", not "0m".
        XCTAssertEqual(Formatting.resetText(resetsAt: at(30), now: now), "Reset in 1m")
    }

    func testHoursAndMinutes() {
        let seconds: TimeInterval = 3 * 3600 + 10 * 60
        XCTAssertEqual(Formatting.resetText(resetsAt: at(seconds), now: now), "Reset in 3h 10m")
    }

    func testExactHours() {
        XCTAssertEqual(Formatting.resetText(resetsAt: at(5 * 3600), now: now), "Reset in 5h")
    }

    func testDaysPlural() {
        XCTAssertEqual(Formatting.resetText(resetsAt: at(2 * 86_400), now: now), "Reset in 2 days")
    }

    func testDaysSingular() {
        // 25 hours → 1 day (floored)
        XCTAssertEqual(Formatting.resetText(resetsAt: at(25 * 3600), now: now), "Reset in 1 day")
    }

    func testExactHourBoundary() {
        // 3600 s crosses into the hours bucket.
        XCTAssertEqual(Formatting.resetText(resetsAt: at(3600), now: now), "Reset in 1h")
    }

    func testExactDayBoundary() {
        // 86 400 s crosses into the days bucket.
        XCTAssertEqual(Formatting.resetText(resetsAt: at(86_400), now: now), "Reset in 1 day")
    }
}

final class FormattingUpdatedTextTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testNowForZeroSeconds() {
        XCTAssertEqual(Formatting.updatedText(fetchedAt: now, now: now), "Now")
    }

    func testNowForUnderOneMinute() {
        let fetched = now.addingTimeInterval(-59)
        XCTAssertEqual(Formatting.updatedText(fetchedAt: fetched, now: now), "Now")
    }

    func testMinutesAgo() {
        let fetched = now.addingTimeInterval(-4 * 60)
        XCTAssertEqual(Formatting.updatedText(fetchedAt: fetched, now: now), "4 min ago")
    }

    func testHoursAgo() {
        let fetched = now.addingTimeInterval(-2 * 3600)
        XCTAssertEqual(Formatting.updatedText(fetchedAt: fetched, now: now), "2 h ago")
    }

    func testFutureFetchDateReturnsNow() {
        let fetched = now.addingTimeInterval(30)
        XCTAssertEqual(Formatting.updatedText(fetchedAt: fetched, now: now), "Now")
    }

    func testExactSixtySecondsBoundary() {
        // 60 s crosses out of the "Now" bucket into "1 min ago".
        let fetched = now.addingTimeInterval(-60)
        XCTAssertEqual(Formatting.updatedText(fetchedAt: fetched, now: now), "1 min ago")
    }

    func testExactOneHourBoundary() {
        // 3600 s crosses into the hours bucket.
        let fetched = now.addingTimeInterval(-3600)
        XCTAssertEqual(Formatting.updatedText(fetchedAt: fetched, now: now), "1 h ago")
    }
}

final class FormattingPercentTests: XCTestCase {

    func testWholePercent() {
        XCTAssertEqual(Formatting.percentText(81), "81%")
    }

    func testRoundsToNearest() {
        XCTAssertEqual(Formatting.percentText(80.4), "80%")
        XCTAssertEqual(Formatting.percentText(80.6), "81%")
    }

    func testZero() {
        XCTAssertEqual(Formatting.percentText(0), "0%")
    }

    func testOverOneHundred() {
        XCTAssertEqual(Formatting.percentText(122), "122%")
    }

    func testNaNIsPlaceholder() {
        // A provider that divides by a zero limit could hand us NaN; we
        // must not trap.
        XCTAssertEqual(Formatting.percentText(.nan), "–%")
    }

    func testPositiveInfinityIsPlaceholder() {
        XCTAssertEqual(Formatting.percentText(.infinity), "–%")
    }

    func testNegativeInfinityIsPlaceholder() {
        XCTAssertEqual(Formatting.percentText(-.infinity), "–%")
    }
}

final class FormattingSecondaryLineTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testWithReset() {
        let window = UsageWindow(
            label: "5h",
            usedPercent: 22,
            resetsAt: now.addingTimeInterval(3 * 3600 + 10 * 60),
            kind: .fiveHour
        )
        XCTAssertEqual(
            Formatting.secondaryLineText(for: window, now: now),
            "5h: 22% · resets 3h 10m"
        )
    }

    func testWithoutReset() {
        let window = UsageWindow(label: "Weekly", usedPercent: 4, resetsAt: nil, kind: .weekly)
        XCTAssertEqual(Formatting.secondaryLineText(for: window, now: now), "Weekly: 4%")
    }

    func testWithMinutesReset() {
        let window = UsageWindow(
            label: "5h",
            usedPercent: 90,
            resetsAt: now.addingTimeInterval(45 * 60),
            kind: .fiveHour
        )
        XCTAssertEqual(
            Formatting.secondaryLineText(for: window, now: now),
            "5h: 90% · resets 45m"
        )
    }

    func testWithDaysReset() {
        let window = UsageWindow(
            label: "Weekly",
            usedPercent: 77,
            resetsAt: now.addingTimeInterval(3 * 86_400),
            kind: .weekly
        )
        XCTAssertEqual(
            Formatting.secondaryLineText(for: window, now: now),
            "Weekly: 77% · resets 3 days"
        )
    }

    func testResetsSoonSuffixForPastReset() {
        // Previously an untested branch of the duplicated helper.
        let window = UsageWindow(
            label: "5h",
            usedPercent: 50,
            resetsAt: now.addingTimeInterval(-1),
            kind: .fiveHour
        )
        XCTAssertEqual(
            Formatting.secondaryLineText(for: window, now: now),
            "5h: 50% · resets soon"
        )
    }

    func testExactHoursSuffix() {
        // Previously untested "resets Nh" branch.
        let window = UsageWindow(
            label: "5h",
            usedPercent: 10,
            resetsAt: now.addingTimeInterval(5 * 3600),
            kind: .fiveHour
        )
        XCTAssertEqual(
            Formatting.secondaryLineText(for: window, now: now),
            "5h: 10% · resets 5h"
        )
    }

    func testSingularDaySuffix() {
        // Previously untested "resets 1 day" branch.
        let window = UsageWindow(
            label: "Weekly",
            usedPercent: 33,
            resetsAt: now.addingTimeInterval(25 * 3600),
            kind: .weekly
        )
        XCTAssertEqual(
            Formatting.secondaryLineText(for: window, now: now),
            "Weekly: 33% · resets 1 day"
        )
    }
}

final class FormattingOnDemandLineTests: XCTestCase {

    private func window(
        amountCents: Int? = nil,
        limitCents: Int? = nil,
        kind: UsageWindowKind = .onDemand
    ) -> UsageWindow {
        UsageWindow(
            label: "On-demand",
            usedPercent: 0,
            resetsAt: nil,
            kind: kind,
            amountCents: amountCents,
            limitCents: limitCents
        )
    }

    func testNilForNonOnDemandWindow() {
        // Even with amount/limit set, a non-onDemand window must not render
        // the currency line — it belongs to Cursor's on-demand row only.
        let w = window(amountCents: 2083, limitCents: 5000, kind: .fiveHour)
        XCTAssertNil(Formatting.onDemandSecondaryLine(for: w))
    }

    func testNilForOnDemandWithoutAmount() {
        let w = window(amountCents: nil, limitCents: 5000)
        XCTAssertNil(Formatting.onDemandSecondaryLine(for: w))
    }

    func testAmountOnlyWithNilLimit() {
        // Fixture case: enabled=true, limit=null → "$20.83 on-demand".
        let w = window(amountCents: 2083, limitCents: nil)
        XCTAssertEqual(Formatting.onDemandSecondaryLine(for: w), "$20.83 on-demand")
    }

    func testAmountOnlyWithZeroLimit() {
        // Zero limit is treated like a nil limit.
        let w = window(amountCents: 2083, limitCents: 0)
        XCTAssertEqual(Formatting.onDemandSecondaryLine(for: w), "$20.83 on-demand")
    }

    func testAmountAndPositiveLimit() {
        let w = window(amountCents: 2083, limitCents: 5000)
        XCTAssertEqual(
            Formatting.onDemandSecondaryLine(for: w),
            "$20.83 of $50.00 on-demand"
        )
    }

    func testCentsBoundary() {
        // 100 cents → "$1.00"; 5 cents → "$0.05" (two-decimal padding).
        let w = window(amountCents: 100, limitCents: 5)
        XCTAssertEqual(
            Formatting.onDemandSecondaryLine(for: w),
            "$1.00 of $0.05 on-demand"
        )
    }

    func testZeroAmount() {
        let w = window(amountCents: 0, limitCents: nil)
        XCTAssertEqual(Formatting.onDemandSecondaryLine(for: w), "$0.00 on-demand")
    }

    func testNegativeAmountRendersLeadingMinus() {
        // Defensive — the endpoint has never been observed to return
        // negative on-demand spend, but the helper must not trap.
        let w = window(amountCents: -50, limitCents: nil)
        XCTAssertEqual(Formatting.onDemandSecondaryLine(for: w), "-$0.50 on-demand")
    }
}

final class FormattingIconTintTests: XCTestCase {

    func testEmptyIsNormal() {
        XCTAssertEqual(Formatting.iconTintLevel(visiblePercents: []), .normal)
    }

    func testBelowAmberThreshold() {
        // 79.0 rounds to "79%" — stays normal.
        XCTAssertEqual(Formatting.iconTintLevel(visiblePercents: [79.0]), .normal)
    }

    func testAtAmberThreshold() {
        XCTAssertEqual(Formatting.iconTintLevel(visiblePercents: [80.0]), .amber)
    }

    func testJustUnderRawAmberBecomesAmberAfterRounding() {
        // 79.9 displays as "80%", so the icon must also read amber.
        XCTAssertEqual(Formatting.iconTintLevel(visiblePercents: [79.9]), .amber)
    }

    func testBelowRedThreshold() {
        // 94.0 rounds to "94%" — stays amber.
        XCTAssertEqual(Formatting.iconTintLevel(visiblePercents: [94.0]), .amber)
    }

    func testAtRedThreshold() {
        XCTAssertEqual(Formatting.iconTintLevel(visiblePercents: [95.0]), .red)
    }

    func testJustUnderRawRedBecomesRedAfterRounding() {
        // 94.9 displays as "95%", so the icon must also read red.
        XCTAssertEqual(Formatting.iconTintLevel(visiblePercents: [94.9]), .red)
    }

    func testMaxWins() {
        // The highest visible ring drives the tint.
        XCTAssertEqual(Formatting.iconTintLevel(visiblePercents: [10, 80, 30]), .amber)
        XCTAssertEqual(Formatting.iconTintLevel(visiblePercents: [10, 80, 96]), .red)
    }

    func testAlignsWithRoundedPercent_belowRoundingBoundary() {
        // 79.4 rounds to "79%" so the icon must stay normal.
        XCTAssertEqual(Formatting.iconTintLevel(visiblePercents: [79.4]), .normal)
        XCTAssertEqual(Formatting.percentText(79.4), "79%")
    }

    func testAlignsWithRoundedPercent_atRoundingBoundary() {
        // 79.5 rounds to "80%" so the icon must go amber to match the row.
        XCTAssertEqual(Formatting.iconTintLevel(visiblePercents: [79.5]), .amber)
        XCTAssertEqual(Formatting.percentText(79.5), "80%")
    }

    func testAlignsWithRoundedPercent_underDisplayedAmber() {
        // 79.6 would previously show "80%" while the icon stayed normal.
        XCTAssertEqual(Formatting.iconTintLevel(visiblePercents: [79.6]), .amber)
        XCTAssertEqual(Formatting.percentText(79.6), "80%")
    }

    func testAlignsWithRoundedPercent_underDisplayedRed() {
        // 94.5 rounds to "95%" so the icon must go red.
        XCTAssertEqual(Formatting.iconTintLevel(visiblePercents: [94.5]), .red)
        XCTAssertEqual(Formatting.percentText(94.5), "95%")
    }

    func testIgnoresNonFinitePercents() {
        // Non-finite values must not trap and must not be treated as high.
        XCTAssertEqual(Formatting.iconTintLevel(visiblePercents: [.nan]), .normal)
        XCTAssertEqual(Formatting.iconTintLevel(visiblePercents: [.infinity]), .normal)
        // With a real value alongside, only the real value drives the tint.
        XCTAssertEqual(Formatting.iconTintLevel(visiblePercents: [.nan, 50]), .normal)
        XCTAssertEqual(Formatting.iconTintLevel(visiblePercents: [.infinity, 96]), .red)
    }
}
