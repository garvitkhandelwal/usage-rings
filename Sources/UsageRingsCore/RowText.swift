import Foundation

/// Pure text-derivation helpers used by the popover's provider rows and the
/// rings centre label. Kept in Core so the SwiftUI views stay declarative and
/// the logic is testable without a view host.
///
/// The states table drives what a row and the centre display in each case.
/// This is the one place that lookup lives; both `ProviderRowView` and
/// `RingsView` route through it.
public enum RowText {

    /// Left-hand text shown next to the provider name in a row.
    ///
    /// Mapping (from the states table):
    ///  - `.loading`               → "Checking…"
    ///  - `.ok(usage)`             → "Reset in …" from the selected ring window,
    ///                               or "" when the window has no reset date.
    ///  - `.stale(usage, _)`       → "As of Now" / "As of N min ago" / "As of N h ago"
    ///                               measured from `usage.fetchedAt` — the age of
    ///                               the data being displayed, NOT the moment
    ///                               the fetch first failed. If the row read the
    ///                               failure time instead, the user would be
    ///                               told "As of 12 min ago" while the values
    ///                               on screen might actually be hours old
    ///                               (last successful poll happened before a
    ///                               long failure streak).
    ///  - `.offline`               → "No internet connection"
    ///  - `.signedOut(reason)`     → the reason ("Open Claude Code to refresh")
    ///  - `.error(message)`        → the message (already user-facing, short)
    ///  - `.hidden`                → ""
    public static func primaryText(
        state: ProviderState,
        now: Date,
        preference: RingWindowPreference = .auto
    ) -> String {
        switch state {
        case .loading:
            return "Checking…"
        case .ok(let usage):
            let selection = selectWindows(for: usage, preference: preference)
            guard let ring = selection.ring, let resetsAt = ring.resetsAt else { return "" }
            return Formatting.resetText(resetsAt: resetsAt, now: now)
        case .stale(let usage, _):
            return "As of \(Formatting.updatedText(fetchedAt: usage.fetchedAt, now: now))"
        case .offline:
            return "No internet connection"
        case .signedOut(let reason):
            return reason
        case .error(let message):
            return message
        case .hidden:
            return ""
        }
    }

    /// Right-hand percent text on a row, or `nil` when the row has no
    /// percentage (offline, signed out, error, loading, hidden).
    ///
    /// Uses the last known window even in the `.stale` case — that is the
    /// point of `.stale`: keep the value visible with a "12 min ago"
    /// disclaimer rather than blanking it.
    public static func percentText(
        state: ProviderState,
        preference: RingWindowPreference = .auto
    ) -> String? {
        switch state {
        case .ok(let usage), .stale(let usage, _):
            let selection = selectWindows(for: usage, preference: preference)
            guard let ring = selection.ring else { return nil }
            return Formatting.percentText(ring.usedPercent)
        case .loading, .offline, .signedOut, .error, .hidden:
            return nil
        }
    }

    /// Secondary line under the row, or `nil` when there is none.
    ///
    /// Only produced when we have a resolved secondary window (a two-window
    /// provider showing the non-ring one). Cursor's on-demand window has a
    /// specialised currency line — "$20.83 on-demand" or "$20.83 of $50.00
    /// on-demand" — routed through `Formatting.onDemandSecondaryLine`; every
    /// other kind falls back to the generic "5h: 22% · resets 3h 10m"
    /// helper.
    public static func secondaryLine(
        state: ProviderState,
        now: Date,
        preference: RingWindowPreference = .auto
    ) -> String? {
        switch state {
        case .ok(let usage), .stale(let usage, _):
            let selection = selectWindows(for: usage, preference: preference)
            guard let secondary = selection.secondary else { return nil }
            if secondary.kind == .onDemand,
               let text = Formatting.onDemandSecondaryLine(for: secondary) {
                return text
            }
            return Formatting.secondaryLineText(for: secondary, now: now)
        case .loading, .offline, .signedOut, .error, .hidden:
            return nil
        }
    }

    /// The lower half of the rings centre label ("Updated" appears above it).
    ///
    /// - Before the first successful refresh (`lastRefresh == nil`) → "…"
    /// - Otherwise → `Formatting.updatedText` ("Now", "N min ago", "N h ago").
    public static func centreText(lastRefresh: Date?, now: Date) -> String {
        guard let last = lastRefresh else { return "…" }
        return Formatting.updatedText(fetchedAt: last, now: now)
    }

    /// Providers to draw in the popover, outer→inner ring order, excluding
    /// any that are `.hidden` (either disabled in Settings or not installed).
    ///
    /// The returned tuples pair each provider's ID with its current state so
    /// the view can render them in a single loop without a second lookup.
    public static func visibleProviders(
        states: [ProviderID: ProviderState]
    ) -> [(id: ProviderID, state: ProviderState)] {
        var result: [(id: ProviderID, state: ProviderState)] = []
        for id in ProviderID.ringOrderOuterToInner {
            let state = states[id] ?? .hidden
            if case .hidden = state { continue }
            result.append((id, state))
        }
        return result
    }

    /// Header subtitle text under "Usage Rings" in the popover.
    ///
    /// For each visible provider that returned a plan name we emit
    /// "`<Short> <Plan>`" — e.g. "Codex Free", "Cursor Enterprise" — with
    /// each plan title-cased so a raw lowercase API string like
    /// "enterprise" never surfaces to the user. Multiple providers are
    /// joined with " · ".
    ///
    /// Returns `nil` when no visible provider has a plan name; the caller
    /// hides the subtitle line rather than showing an empty label. Claude
    /// never returns a plan name, so a Claude-only popover is expected to
    /// have no subtitle.
    ///
    /// Kept in Core so the formatting has direct unit tests and is not
    /// entangled with SwiftUI view code.
    public static func headerSubtitle(
        visible: [(id: ProviderID, state: ProviderState)]
    ) -> String? {
        let pieces = visible.compactMap { item -> String? in
            let plan: String?
            switch item.state {
            case .ok(let usage): plan = usage.plan
            case .stale(let usage, _): plan = usage.plan
            default: plan = nil
            }
            guard let plan, !plan.isEmpty else { return nil }
            return "\(item.id.headerShortName) \(titleCasedPlan(plan))"
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: " \u{00B7} ")
    }

    /// Title-case an API plan string for the header subtitle.
    ///
    /// The endpoints return values like "free", "plus", "pro", "enterprise",
    /// occasionally "team_v2". We split on whitespace and underscores so
    /// each segment renders as "Team V2" (rather than "Team_v2"), then join
    /// with a single space. Fully alphabetic segments are lower-cased and
    /// have their first character upper-cased; anything already in mixed
    /// or upper case (e.g. "IO", a hypothetical acronym) is left untouched.
    private static func titleCasedPlan(_ raw: String) -> String {
        let separators = CharacterSet(charactersIn: " \t\u{00A0}_")
        let segments = raw.unicodeScalars
            .split(whereSeparator: { separators.contains($0) })
            .map { String($0) }
            .filter { !$0.isEmpty }
        guard !segments.isEmpty else { return raw }
        return segments.map { segment -> String in
            // Only rewrite an all-lowercase or all-uppercase segment — we
            // do not want to touch a segment the API deliberately mixed.
            let isAllLower = segment.allSatisfy { !$0.isUppercase }
            guard isAllLower else { return segment }
            let first = segment.prefix(1).uppercased()
            let rest = segment.dropFirst()
            return first + rest
        }.joined(separator: " ")
    }
}

extension ProviderID {
    /// Short provider name used in the header subtitle (e.g. "Codex Free"),
    /// where the full display name would repeat the word "Code" from
    /// "Claude Code" alongside a plan and read awkwardly.
    var headerShortName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        }
    }
}
