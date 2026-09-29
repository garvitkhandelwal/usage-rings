import SwiftUI
import UsageRingsCore

/// Visual constants shared by the ring and row views.
///
/// Kept in one place so the ring stroke, the row dot and the future menu bar
/// icon all draw with the same numbers and colours. Nothing here is
/// user-configurable — the settings live in `Preferences`.
///
/// The stroke width, gap and side length come from `RingGeometry` in Core so
/// they can be unit-tested; this file only supplies the SwiftUI-flavoured
/// wrappers (Color values from the RGB tuples, track opacity, etc.).
enum Theme {

    /// Track opacity applied to the ring background circle: 25%.
    static let trackOpacity: Double = 0.25

    /// Provider brand colours in linear-ish sRGB: lavender / teal / amber.
    /// Kept as raw tuples so `secondLapColor(for:)` can darken them
    /// through `ColorMath` without a round-trip through opaque `Color`s.
    private static func brandRGB(for id: ProviderID) -> (r: Double, g: Double, b: Double) {
        switch id {
        case .claude: return (0.72, 0.65, 1.00)   // lavender
        case .codex:  return (0.14, 0.67, 0.66)   // teal
        case .cursor: return (0.98, 0.64, 0.22)   // amber
        }
    }

    /// The base ring colour for a provider.
    static func color(for id: ProviderID) -> Color {
        let (r, g, b) = brandRGB(for: id)
        return Color(red: r, green: g, blue: b)
    }

    /// A visibly-darker version of the base colour used to render the
    /// second lap when a ring exceeds 100%. The darkening factor lives in
    /// `ColorMath.secondLapDarkenFactor` and is covered by unit tests to
    /// make sure it stays materially different from the base.
    static func secondLapColor(for id: ProviderID) -> Color {
        let (r, g, b) = ColorMath.darken(brandRGB(for: id), by: ColorMath.secondLapDarkenFactor)
        return Color(red: r, green: g, blue: b)
    }
}
