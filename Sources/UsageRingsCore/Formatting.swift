import Foundation

/// Icon tint level derived from the highest visible ring percentage.
public enum IconTintLevel: String, Sendable, Hashable {
    case normal
    case amber
    case red
}

public enum Formatting {

    // MARK: - Safe Double → Int

    /// Convert a finite `Double` to `Int` without trapping.
    ///
    /// Returns `nil` when the value is non-finite (NaN, ±∞) or when its
    /// magnitude exceeds `Int.max` — both cases would trap `Int(x)` and
    /// `Int(x.rounded())`. The app must not crash on tolerated bad input,
    /// and providers can genuinely hand us huge finite
    /// values (e.g. `used / limit * 100` when `limit` is a tiny non-zero
    /// number).
    static func safeInt(_ value: Double) -> Int? {
        guard value.isFinite else { return nil }
        let rounded = value.rounded()
        // Comparing against Int.max/min as Double is safe because
        // `Double(Int.max)` is representable (albeit rounded up to 2^63);
        // any value ≥ that bound would trap `Int(x)`. Strict inequalities
        // are equivalent to `Int(exactly:)`'s range for practical purposes
        // while keeping the code obviously bounded.
        guard rounded >= Double(Int.min), rounded < Double(Int.max) else { return nil }
        return Int(rounded)
    }

    // MARK: - Duration core

    /// Shared duration formatter used by both `resetText` and the secondary
    /// line's "resets …" suffix.
    ///
    /// Returns nil when `seconds <= 0` (callers substitute the "soon" text
    /// with the right casing) or when `seconds` is so large it cannot fit
    /// into `Int` (rare but possible after wall-clock arithmetic). Otherwise:
    ///  - < 60 min: "Nm" (never "0m")
    ///  - < 24 h: "Nh Nm" (or "Nh" if minutes rounds to 0)
    ///  - ≥ 24 h: "N day" / "N days"
    private static func durationText(seconds: TimeInterval) -> String? {
        guard seconds > 0 else { return nil }
        // Convert via `safeInt` so a huge finite duration (or +∞) does
        // not trap the `Int` conversion. `safeInt` returns nil for values
        // beyond `Int.max`; in that case we substitute `Int.max` so the
        // label falls into the days-bucket with a very-large day count —
        // meaningless but truthfully "very far in the future" and, above
        // all, not a crash.
        let totalSeconds = safeInt(seconds) ?? Int.max
        if totalSeconds < 3600 {
            let minutes = max(1, totalSeconds / 60)
            return "\(minutes)m"
        }
        if totalSeconds < 86_400 {
            let hours = totalSeconds / 3600
            let minutes = (totalSeconds % 3600) / 60
            if minutes == 0 { return "\(hours)h" }
            return "\(hours)h \(minutes)m"
        }
        let days = totalSeconds / 86_400
        return "\(days) \(days == 1 ? "day" : "days")"
    }

    // MARK: - Reset text

    /// Human-readable "Reset in …" text for a window whose reset time is
    /// `resetsAt`, evaluated at `now`.
    ///
    /// Buckets:
    ///  - ≤ 0 s: "Resets soon"
    ///  - < 60 min: "Reset in Nm"
    ///  - < 24 h: "Reset in Nh Nm" (or "Reset in Nh" if minutes rounds to 0)
    ///  - ≥ 24 h: "Reset in N day" / "Reset in N days"
    public static func resetText(resetsAt: Date, now: Date) -> String {
        let seconds = resetsAt.timeIntervalSince(now)
        guard let duration = durationText(seconds: seconds) else {
            return "Resets soon"
        }
        return "Reset in \(duration)"
    }

    // MARK: - Updated text

    /// Human-readable freshness text for the popover centre.
    ///
    /// Buckets:
    ///  - < 60 s: "Now"
    ///  - < 60 min: "N min ago"
    ///  - ≥ 60 min: "N h ago"
    public static func updatedText(fetchedAt: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(fetchedAt))
        if seconds < 60 { return "Now" }
        // `safeInt` guards the Double → Int conversion against non-finite
        // or out-of-range values (a wake after a multi-year sleep, a
        // bogus provider-supplied `fetchedAt`); fall back to `Int.max` so
        // the label reads as "very long ago" rather than trapping.
        let totalSeconds = safeInt(seconds) ?? Int.max
        if totalSeconds < 3600 {
            let minutes = totalSeconds / 60
            return "\(minutes) min ago"
        }
        let hours = totalSeconds / 3600
        return "\(hours) h ago"
    }

    // MARK: - Percent text

    /// Percent shown on the row, rounded to a whole number, e.g. "81%".
    ///
    /// Providers occasionally return NaN or ±infinity (e.g. dividing by a
    /// zero limit). Constructing an `Int` from such a value would trap, and
    /// the Global Constraints forbid crashing on tolerated bad input — so
    /// return the "–%" placeholder instead.
    public static func percentText(_ usedPercent: Double) -> String {
        // NaN/±∞ or a finite value beyond Int range (e.g. 1e20 from a
        // pathological used/limit ratio) would both trap the naive
        // `Int(x.rounded())`. `safeInt` returns nil for both cases.
        guard let rounded = safeInt(usedPercent) else { return "–%" }
        // Clamp negatives to 0: a negative usedPercent (a provider might
        // hand us -1 as a sentinel for "unknown", or a floating-point
        // subtraction could nudge just under zero) would otherwise render
        // as "-1%", which is not a state the popover can meaningfully
        // display. The ring already clamps to [0, ∞); match that here so
        // the row-level text agrees with the arc.
        return "\(max(0, rounded))%"
    }

    // MARK: - Secondary line text

    /// The row's secondary line, e.g. "5h: 22% · resets 3h 10m".
    ///
    /// The "resets …" suffix uses the same duration buckets as `resetText`
    /// but with lowercase wording. If the window has no reset date, only the
    /// label/percent part is shown.
    public static func secondaryLineText(for window: UsageWindow, now: Date) -> String {
        let percent = percentText(window.usedPercent)
        guard let resetsAt = window.resetsAt else {
            return "\(window.label): \(percent)"
        }
        let seconds = resetsAt.timeIntervalSince(now)
        let suffix: String
        if let duration = durationText(seconds: seconds) {
            suffix = "resets \(duration)"
        } else {
            suffix = "resets soon"
        }
        return "\(window.label): \(percent) · \(suffix)"
    }

    // MARK: - Cursor on-demand secondary line

    /// Secondary-line text for a Cursor `.onDemand` window.
    ///
    /// Two shapes:
    ///  - "$20.83 on-demand"           — when `limitCents` is nil or 0.
    ///  - "$20.83 of $50.00 on-demand" — when `limitCents` is a positive value.
    ///
    /// Cents are formatted with two decimal places via `String(format:)`
    /// with a locale-independent `%d.%02d` — no `NumberFormatter`, no
    /// locale-sensitive helper is involved, so the string is stable across
    /// any user locale. The app's UI is English-only and the values are
    /// always US currency.
    ///
    /// Returns `nil` when the window is not `.onDemand`, or when
    /// `amountCents` is missing — the caller should fall through to the
    /// generic secondary-line text or draw nothing.
    public static func onDemandSecondaryLine(for window: UsageWindow) -> String? {
        guard window.kind == .onDemand, let amount = window.amountCents else { return nil }
        let amountText = dollarsText(fromCents: amount)
        if let limit = window.limitCents, limit > 0 {
            let limitText = dollarsText(fromCents: limit)
            return "\(amountText) of \(limitText) on-demand"
        }
        return "\(amountText) on-demand"
    }

    /// Render a signed integer number of US cents as a two-decimal dollar
    /// string. Uses `String(format: "%d.%02d")` (no `NumberFormatter`) so
    /// the decimal separator is always ".", matching every fixture and the
    /// UI's English-only copy — independent of the user's system locale.
    private static func dollarsText(fromCents cents: Int) -> String {
        // Handle negatives defensively; the endpoint never returns negative
        // values today but this keeps the helper honest.
        let sign = cents < 0 ? "-" : ""
        let magnitude = abs(cents)
        let dollars = magnitude / 100
        let remainder = magnitude % 100
        return String(format: "%@$%d.%02d", sign, dollars, remainder)
    }

    // MARK: - Icon tint

    /// Icon tint level from the highest visible ring percentage.
    ///
    /// - amber at ≥ 80%
    /// - red at ≥ 95%
    /// - normal otherwise (and normal for an empty list).
    ///
    /// Compares the *rounded* value that `percentText` displays, so a row
    /// showing "80%" (rounded from 79.6) is always painted amber and the
    /// icon can never disagree with the number. Non-finite percentages and
    /// finite values that overflow `Int` are ignored — they'd render as
    /// "–%" on the row and must not influence the tint either.
    public static func iconTintLevel(visiblePercents: [Double]) -> IconTintLevel {
        let displayed = visiblePercents.compactMap(safeInt)
        guard let maxPercent = displayed.max() else { return .normal }
        if maxPercent >= 95 { return .red }
        if maxPercent >= 80 { return .amber }
        return .normal
    }
}
