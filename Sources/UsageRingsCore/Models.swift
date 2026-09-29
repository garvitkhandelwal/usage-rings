import Foundation

/// Identifier for one of the three supported providers.
///
/// Cases are declared in the outer→inner ring order that the popover uses.
public enum ProviderID: String, CaseIterable, Sendable, Hashable, Codable {
    case claude
    case codex
    case cursor

    /// Human-readable name shown in the popover row and settings.
    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        }
    }

    /// The provider's usage page URL, opened when a row is clicked.
    public var usagePageURL: URL {
        switch self {
        case .claude: return URL(string: "https://claude.ai/settings/usage")!
        case .codex: return URL(string: "https://chatgpt.com/codex/settings/usage")!
        case .cursor: return URL(string: "https://cursor.com/dashboard?tab=usage")!
        }
    }

    /// Ring order outer → inner, matching `CaseIterable.allCases` here.
    public static var ringOrderOuterToInner: [ProviderID] { Self.allCases }

    /// The `UsageWindowKind`s this provider can drive as the *ring* window.
    ///
    /// Used by the Settings picker to build "Auto + these kinds" — the user
    /// can never pick a kind the provider does not produce, and `.onDemand`
    /// is deliberately excluded (Cursor's on-demand spend is only ever the
    /// secondary line — see `selectWindows`).
    public var ringWindowKinds: [UsageWindowKind] {
        switch self {
        case .claude: return [.fiveHour, .weekly]
        case .codex: return [.primary, .secondary]
        case .cursor: return [.billingCycle]
        }
    }
}

/// Category of a usage window. Used for user preferences and to pick the
/// window that drives the ring vs. the one that only appears as a secondary
/// text line.
public enum UsageWindowKind: String, Sendable, Hashable, Codable, CaseIterable {
    /// Claude's rolling 5-hour window.
    case fiveHour
    /// Claude's 7-day / weekly window.
    case weekly
    /// Codex's primary rate-limit window.
    case primary
    /// Codex's secondary rate-limit window.
    case secondary
    /// Cursor's billing-cycle window (included plan usage).
    case billingCycle
    /// Cursor's on-demand spend window. Never selected as the ring window;
    /// only ever shown as the secondary line.
    case onDemand
}

/// One usage window returned by a provider (e.g. Claude's 5-hour window).
public struct UsageWindow: Sendable, Hashable, Codable {
    /// Short label shown in the secondary line, e.g. "5h", "Weekly", "Monthly".
    public let label: String
    /// Used percentage (0–100). May exceed 100 for a "second lap" ring.
    public let usedPercent: Double
    /// Absolute time this window resets, or nil if the provider omits it.
    public let resetsAt: Date?
    /// Category — drives ring / secondary selection and preferences.
    public let kind: UsageWindowKind
    /// Optional dollar amount, in US cents, for windows whose display text is
    /// a currency figure rather than (or in addition to) a percentage. Used
    /// by Cursor's on-demand secondary line, which reads "$20.83 on-demand"
    /// from `amountCents: 2083`. Never populated for Claude or Codex windows,
    /// and never displayed for a non-`.onDemand` window even if set.
    public let amountCents: Int?
    /// Optional currency limit paired with `amountCents`, in US cents. When
    /// present and positive the on-demand secondary line reads
    /// "$20.83 of $50.00 on-demand"; when nil or 0 it reads
    /// "$20.83 on-demand". Never populated for Claude or Codex windows.
    public let limitCents: Int?

    public init(
        label: String,
        usedPercent: Double,
        resetsAt: Date?,
        kind: UsageWindowKind,
        amountCents: Int? = nil,
        limitCents: Int? = nil
    ) {
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.kind = kind
        self.amountCents = amountCents
        self.limitCents = limitCents
    }
}

/// A single successful fetch from one provider.
public struct ProviderUsage: Sendable, Hashable, Codable {
    public let id: ProviderID
    /// Human-readable plan name, if the provider returned one.
    public let plan: String?
    public let windows: [UsageWindow]
    public let fetchedAt: Date

    public init(id: ProviderID, plan: String?, windows: [UsageWindow], fetchedAt: Date) {
        self.id = id
        self.plan = plan
        self.windows = windows
        self.fetchedAt = fetchedAt
    }
}

/// UI state per provider ring.
public enum ProviderState: Sendable, Hashable {
    case loading
    case ok(ProviderUsage)
    /// Server error or rate limit — keep the last usage and mark it stale from `since`.
    case stale(ProviderUsage, since: Date)
    /// No connectivity — no values shown.
    case offline
    /// Token expired / not signed in. `reason` is the "Open <Tool> to refresh" hint.
    case signedOut(reason: String)
    case error(String)
    /// Not installed on this Mac, or disabled in Settings.
    case hidden
}

/// User preference for which window drives a provider's ring.
public enum RingWindowPreference: Sendable, Hashable, Codable {
    /// Choose automatically: the window with the highest `usedPercent`,
    /// excluding any `.onDemand` window.
    case auto
    /// Always show this specific window as the ring, falling back to `.auto`
    /// if that window is not present in the fetched usage.
    case specific(UsageWindowKind)
}

/// Result of resolving a `RingWindowPreference` against a `ProviderUsage`.
public struct WindowSelection: Sendable, Hashable {
    /// The window driving the ring, or nil if none is eligible.
    public let ring: UsageWindow?
    /// The other window shown as the secondary line, or nil if there is none.
    public let secondary: UsageWindow?

    public init(ring: UsageWindow?, secondary: UsageWindow?) {
        self.ring = ring
        self.secondary = secondary
    }
}

/// Pick the ring window and the secondary window for a provider's usage,
/// honouring the user's preference.
///
/// Rules:
///  - `.onDemand` windows are never the ring window; they only ever appear as
///    the secondary line.
///  - `auto` picks the non-onDemand window with the highest `usedPercent`.
///  - `.specific(kind)` picks that window if present (and not `.onDemand`);
///    otherwise falls back to `auto`.
///  - The secondary is the remaining non-ring window. If several remain
///    (unusual), the one with the highest `usedPercent` is picked. An
///    `.onDemand` window, if present, is preferred as the secondary since it
///    can never take the ring slot.
public func selectWindows(for usage: ProviderUsage, preference: RingWindowPreference) -> WindowSelection {
    let windows = usage.windows
    guard !windows.isEmpty else { return WindowSelection(ring: nil, secondary: nil) }

    let ringEligible = windows.filter { $0.kind != .onDemand }

    var ring: UsageWindow? = nil
    switch preference {
    case .specific(let kind) where kind != .onDemand:
        ring = ringEligible.first(where: { $0.kind == kind })
        if ring == nil {
            ring = ringEligible.max(by: { $0.usedPercent < $1.usedPercent })
        }
    case .auto, .specific:
        ring = ringEligible.max(by: { $0.usedPercent < $1.usedPercent })
    }

    // Secondary: any remaining window (identity match, not just kind — a
    // provider could hypothetically return two windows of the same kind).
    let remaining = windows.filter { candidate in
        guard let ring else { return true }
        return !(candidate == ring)
    }
    let secondary: UsageWindow?
    if let onDemand = remaining.first(where: { $0.kind == .onDemand }) {
        secondary = onDemand
    } else {
        secondary = remaining.max(by: { $0.usedPercent < $1.usedPercent })
    }

    return WindowSelection(ring: ring, secondary: secondary)
}
