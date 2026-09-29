import Foundation
import Observation

/// Menu bar icon rendering style, chosen in Settings.
///
/// - `colour`   (default) — mini concentric rings in each provider's brand
///   colour; tinted amber/red when a ring crosses the 80% / 95% thresholds.
/// - `mono`     — same rings drawn as a monochrome template image; macOS
///   tints the whole icon in the system's menu bar colour.
/// - `withPercent` — same as `colour` plus the highest visible ring's
///   percentage rendered next to the icon.
public enum IconStyle: String, Sendable, Hashable, Codable, CaseIterable {
    case colour
    case mono
    case withPercent
}

/// Pure policy: should the menu bar icon be rendered as a template image?
///
/// Template images are recoloured by AppKit's menu bar system tint — the
/// right behaviour for the neutral `.mono` icon, and the wrong behaviour
/// when any ring has crossed the 80 / 95 % thresholds: the tint turns
/// amber at 80% and red at 95% on any ring. If the icon is template while
/// amber/red, the warning colour vanishes under whatever tint the menu
/// bar is using.
///
/// The rule:
///  - When no providers are visible we draw the placeholder outline
///    (`shouldDrawMenuBarPlaceholder(entryCount:)`). That outline is
///    always template — it is a neutral shape with no warning value.
///  - Otherwise template only when style is `.mono` **and** the icon
///    carries no warning tint. Every other combination — `.colour`,
///    `.withPercent`, or `.mono` with amber/red — draws its own colours
///    and must NOT be a template.
public func menuBarIconIsTemplate(style: IconStyle, tint: IconTintLevel, entryCount: Int) -> Bool {
    if shouldDrawMenuBarPlaceholder(entryCount: entryCount) { return true }
    return style == .mono && tint == .normal
}

/// Backwards-compatible overload for call-sites that pre-date the empty-
/// entries placeholder rule. Behaves as if there is at least one entry.
public func menuBarIconIsTemplate(style: IconStyle, tint: IconTintLevel) -> Bool {
    menuBarIconIsTemplate(style: style, tint: tint, entryCount: 1)
}

/// Should the menu bar icon draw its neutral placeholder ring outline?
///
/// A blank menu bar item would be invisible against the system menu bar,
/// leaving Settings / Quit unreachable when every provider is hidden
/// (all disabled in Settings, or none installed on this Mac). When
/// entries is empty we draw one outline ring so the item is always
/// clickable.
public func shouldDrawMenuBarPlaceholder(entryCount: Int) -> Bool {
    entryCount <= 0
}

/// A coloured warning dot painted at the menu bar icon's top-right when
/// any visible ring has crossed the 80% / 95% thresholds. The whole icon
/// is never recoloured — provider rings stay lavender/teal/amber — and
/// only this small dot signals the warning.
public enum MenuBarWarningDot: Sendable, Hashable {
    case amber
    case red
}

/// Pure policy: which warning dot (if any) should the menu bar icon show?
///
/// Derived from `IconTintLevel`, which itself compares the *rounded*
/// displayed percentage against the 80 / 95 thresholds — so a row showing
/// "80%" (rounded from 79.6) always gets the amber dot and the icon can
/// never disagree with the number. Below 80% there is no dot.
public func menuBarWarningDot(tint: IconTintLevel) -> MenuBarWarningDot? {
    switch tint {
    case .normal: return nil
    case .amber:  return .amber
    case .red:    return .red
    }
}

/// Accessibility suffix appended to the menu bar icon's VoiceOver label
/// when a warning dot is present. Empty string when there is no dot.
///
/// Wording matches the warning thresholds: amber = "nearing limit"
/// (≥ 80%), red = "almost at limit" (≥ 95%). Neither says "over limit" —
/// a plan that has crossed 100% would still show the red dot, and the
/// per-row text carries the actual percentage; the dot itself only tells
/// the user "you are at or near the ceiling".
public func iconAccessibilityWarningSuffix(dot: MenuBarWarningDot?) -> String {
    switch dot {
    case nil:    return ""
    case .amber: return ", nearing limit"
    case .red:   return ", almost at limit"
    }
}

/// User preferences that persist across launches.
///
/// Backed by a `UserDefaults` suite so tests can inject an isolated suite
/// (`UserDefaults(suiteName: "test-\(UUID())")`) and never touch the real
/// domain. `@Observable` + `@MainActor` so SwiftUI views can bind to the
/// stored properties and see updates without a Combine bridge.
///
/// What lives here:
///  - per-provider enable flag (default `true`)
///  - per-provider ring-window preference (default `.auto`)
///  - refresh interval in seconds (default `300`, clamped 60–300)
///  - menu bar icon style (default `.colour`)
///
/// What does NOT live here: launch-at-login. Read it from
/// `SMAppService.mainApp.status` on demand — one source of truth.
@MainActor
@Observable
public final class Preferences {

    /// Per-provider enable flag. Defaults to `true` for any provider that
    /// has never been written.
    public private(set) var enabled: [ProviderID: Bool]

    /// Per-provider ring-window preference. Defaults to `.auto`.
    public private(set) var ringWindow: [ProviderID: RingWindowPreference]

    /// Polling interval in seconds. Always clamped to
    /// `RefreshScheduling.minimumInterval ... maximumInterval` (60…300)
    /// both on read and on write.
    public private(set) var refreshIntervalSeconds: TimeInterval

    /// Menu bar icon style.
    public private(set) var iconStyle: IconStyle

    /// "Renew Claude login automatically". When on (default), the Claude
    /// provider runs the user's own `claude` CLI once in the background on
    /// a 401 so the CLI renews its own Keychain token. When off, the ring
    /// falls back to "Open Claude Code to refresh" without ever forking
    /// the CLI. See `ClaudeCLIRenewer` for the exact behaviour.
    public private(set) var renewClaudeLoginAutomatically: Bool

    private let defaults: UserDefaults

    // MARK: - Keys
    //
    // Namespaced strings so a shared suite (e.g. the app's real domain
    // under a bundle identifier) never collides with unrelated defaults.
    private enum Key {
        static func enabled(_ id: ProviderID) -> String {
            "usageRings.provider.\(id.rawValue).enabled"
        }
        static func window(_ id: ProviderID) -> String {
            "usageRings.provider.\(id.rawValue).window"
        }
        static let refreshInterval = "usageRings.refreshIntervalSeconds"
        static let iconStyle = "usageRings.iconStyle"
        static let renewClaudeLoginAutomatically = "usageRings.renewClaudeLoginAutomatically"
    }

    /// Encode for the ring window UserDefaults key. `"auto"` is a reserved
    /// value that never collides with a `UsageWindowKind.rawValue` (all kinds
    /// are camelCase identifiers, none of them "auto").
    private static let autoWindowRaw = "auto"

    public init(suite: UserDefaults = .standard) {
        self.defaults = suite

        var enabled: [ProviderID: Bool] = [:]
        var windows: [ProviderID: RingWindowPreference] = [:]
        for id in ProviderID.allCases {
            enabled[id] = Self.readEnabled(id, from: suite)
            windows[id] = Self.readRingWindow(id, from: suite)
        }
        self.enabled = enabled
        self.ringWindow = windows
        self.refreshIntervalSeconds = Self.readRefreshInterval(from: suite)
        self.iconStyle = Self.readIconStyle(from: suite)
        self.renewClaudeLoginAutomatically = Self.readRenewClaudeLoginAutomatically(from: suite)
    }

    // MARK: - Enabled

    /// Set of enabled provider IDs — convenience for `UsageStore.setEnabledProviders`.
    public var enabledProviders: Set<ProviderID> {
        Set(ProviderID.allCases.filter { enabled[$0] ?? true })
    }

    public func setEnabled(_ id: ProviderID, _ value: Bool) {
        enabled[id] = value
        defaults.set(value, forKey: Key.enabled(id))
    }

    private static func readEnabled(_ id: ProviderID, from defaults: UserDefaults) -> Bool {
        // `object(forKey:)` distinguishes "never written" from `false`.
        if defaults.object(forKey: Key.enabled(id)) == nil { return true }
        return defaults.bool(forKey: Key.enabled(id))
    }

    // MARK: - Ring window

    public func setRingWindow(_ id: ProviderID, _ preference: RingWindowPreference) {
        // Guard against `.specific(.onDemand)` — on-demand is never a valid
        // ring choice and Settings never offers it. Silently downgrade to
        // `.auto` so a bad UserDefaults value (or a bug elsewhere) can never
        // wedge the ring into an unrenderable state.
        let sanitised: RingWindowPreference
        switch preference {
        case .specific(.onDemand): sanitised = .auto
        default: sanitised = preference
        }
        ringWindow[id] = sanitised
        switch sanitised {
        case .auto:
            defaults.set(Self.autoWindowRaw, forKey: Key.window(id))
        case .specific(let kind):
            defaults.set(kind.rawValue, forKey: Key.window(id))
        }
    }

    private static func readRingWindow(_ id: ProviderID, from defaults: UserDefaults) -> RingWindowPreference {
        guard let raw = defaults.string(forKey: Key.window(id)), !raw.isEmpty else {
            return .auto
        }
        if raw == autoWindowRaw { return .auto }
        guard let kind = UsageWindowKind(rawValue: raw), kind != .onDemand else {
            // Corrupt / unknown / `.onDemand` — fall back to auto.
            return .auto
        }
        return .specific(kind)
    }

    // MARK: - Refresh interval

    public func setRefreshIntervalSeconds(_ seconds: TimeInterval) {
        let clamped = RefreshScheduling.clampedInterval(seconds)
        refreshIntervalSeconds = clamped
        defaults.set(clamped, forKey: Key.refreshInterval)
    }

    private static func readRefreshInterval(from defaults: UserDefaults) -> TimeInterval {
        if defaults.object(forKey: Key.refreshInterval) == nil {
            return RefreshScheduling.clampedInterval(300)
        }
        return RefreshScheduling.clampedInterval(defaults.double(forKey: Key.refreshInterval))
    }

    // MARK: - Icon style

    public func setIconStyle(_ style: IconStyle) {
        iconStyle = style
        defaults.set(style.rawValue, forKey: Key.iconStyle)
    }

    private static func readIconStyle(from defaults: UserDefaults) -> IconStyle {
        guard let raw = defaults.string(forKey: Key.iconStyle),
              let style = IconStyle(rawValue: raw) else {
            return .colour
        }
        return style
    }

    // MARK: - Renew Claude login automatically

    public func setRenewClaudeLoginAutomatically(_ value: Bool) {
        renewClaudeLoginAutomatically = value
        defaults.set(value, forKey: Key.renewClaudeLoginAutomatically)
    }

    private static func readRenewClaudeLoginAutomatically(from defaults: UserDefaults) -> Bool {
        renewClaudeLoginAutomaticallyValue(in: defaults)
    }

    /// Read-only accessor for the toggle from any actor.
    ///
    /// `Preferences` is `@MainActor` because SwiftUI reads / writes it on
    /// the main thread. The Claude CLI renewer runs inside the Claude
    /// fetch's child task (non-isolated) and needs to check the toggle on
    /// every attempt without hopping to the main actor for a boolean
    /// read. `UserDefaults` is documented as thread-safe, so a
    /// `nonisolated` static reader against the same key is safe from any
    /// concurrency context. Defaults to `true` when the toggle has never
    /// been touched, matching the instance property's semantics.
    public nonisolated static func renewClaudeLoginAutomaticallyValue(
        in defaults: UserDefaults = .standard
    ) -> Bool {
        if defaults.object(forKey: Key.renewClaudeLoginAutomatically) == nil { return true }
        return defaults.bool(forKey: Key.renewClaudeLoginAutomatically)
    }
}
