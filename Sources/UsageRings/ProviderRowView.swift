import SwiftUI
import AppKit
import UsageRingsCore

/// One row in the popover under the rings: coloured dot, provider name, state
/// text (reset countdown or per-state message), optional secondary line, and
/// right-aligned percentage. Clicking the row opens the provider's usage page
/// in the default browser.
struct ProviderRowView: View {

    let id: ProviderID
    let state: ProviderState
    let now: Date
    /// The Settings preference for which window drives this provider's
    /// ring. Passed through so the row's primary/percent/secondary text all
    /// agree with what the ring is drawing.
    let preference: RingWindowPreference

    var body: some View {
        Button(action: openUsagePage) {
            HStack(alignment: .center, spacing: 10) {
                Circle()
                    .fill(Theme.color(for: id))
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(id.displayName)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.primary)
                        // Allow the primary text (which carries the row's
                        // state message — reset countdown, sign-in prompt,
                        // parse-error blurb, etc.) up to 2 lines before
                        // truncating. Longer messages still hover-tooltip
                        // via `.help(primary)` below so the full text is
                        // always reachable.
                        Text(primary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .help(primary)
                    }
                    if let secondary {
                        Text(secondary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(secondary)
                    }
                }

                Spacer(minLength: 4)

                if let percent {
                    Text(percent)
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }
            }
            // Apply padding first so the button's hit region includes it —
            // clicking the small vertical gap between rows should still open
            // the provider's usage page. `.contentShape` after `.padding`
            // makes the shape cover the padded frame.
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Open \(id.displayName) usage page")
    }

    private var primary: String {
        RowText.primaryText(state: state, now: now, preference: preference)
    }

    private var secondary: String? {
        RowText.secondaryLine(state: state, now: now, preference: preference)
    }

    private var percent: String? {
        RowText.percentText(state: state, preference: preference)
    }

    private var accessibilityText: String {
        var pieces: [String] = [id.displayName]
        if !primary.isEmpty { pieces.append(primary) }
        if let percent { pieces.append(percent) }
        if let secondary { pieces.append(secondary) }
        return pieces.joined(separator: ", ")
    }

    private func openUsagePage() {
        NSWorkspace.shared.open(id.usagePageURL)
    }
}
