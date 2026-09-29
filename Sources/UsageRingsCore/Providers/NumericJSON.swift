import Foundation

/// Small helper for extracting a numeric value from a JSON leaf.
///
/// `JSONSerialization` returns numbers as `NSNumber`, and it also returns
/// booleans as `NSNumber` wrapping a `CFBooleanRef`. A naive
/// `raw as? Double` therefore accepts `true` / `false` as `1.0` / `0.0`,
/// which would silently turn a broken `"used_percent": true` response into a
/// legitimate "1 %" ring. Every numeric parse in a provider goes through this
/// helper so booleans are consistently rejected.
enum NumericJSON {
    /// Return the numeric value of `raw`, or `nil` if `raw` is missing, null,
    /// a boolean, or not numeric.
    static func number(from raw: Any?) -> Double? {
        guard let raw else { return nil }
        if raw is NSNull { return nil }
        // Reject JSON booleans before the NSNumber branch — they bridge to
        // NSNumber via CFBooleanRef and would otherwise be read as 1 / 0.
        if isBooleanNSNumber(raw) { return nil }
        if let n = raw as? NSNumber {
            let value = n.doubleValue
            return value.isFinite ? value : nil
        }
        if let d = raw as? Double { return d.isFinite ? d : nil }
        if let i = raw as? Int { return Double(i) }
        return nil
    }

    /// `true` when `value` is a JSON boolean bridged from `NSNumber`. The
    /// canonical check is `CFGetTypeID(value) == CFBooleanGetTypeID()`;
    /// `JSONSerialization` wraps JSON booleans in `__NSCFBoolean`, so the
    /// CF type-id comparison distinguishes them from numeric `NSNumber`s.
    private static func isBooleanNSNumber(_ value: Any) -> Bool {
        CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
    }
}
