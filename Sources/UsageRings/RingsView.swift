import SwiftUI
import UsageRingsCore

/// The stack of concentric rings shown at the top of the popover.
///
/// Draws one ring per visible provider, outer→inner in `ProviderID` ring
/// order, with the stroke/gap/side numbers coming from
/// `RingGeometry`. Each ring's appearance follows the states table:
/// filled for `.ok`, half opacity for `.stale`, spinning arc for
/// `.loading`, empty grey for `.offline`, dashed track for
/// `.signedOut`. Above 100% a second lap overlays the first ring in a
/// visibly-darker tone (see `Theme.secondLapColor`) plus a small shadow
/// confined to the leading edge — see `filledRing` — so the user can tell
/// they have blown past the plan limit without a grey halo bleeding into
/// the 4 pt gaps between rings.
///
/// The centre carries the "Updated" / "Now" / "N min ago" label. Tapping
/// the centre triggers a refresh. Tap targets only cover the small
/// centre disc, not the ring itself.
struct RingsView: View {

    let visible: [(id: ProviderID, state: ProviderState)]
    let lastRefresh: Date?
    let now: Date
    let onCentreTap: () -> Void
    /// Per-provider ring-window preference (Settings). `.auto` when a
    /// provider has no entry in the dictionary.
    let ringWindowPreference: (ProviderID) -> RingWindowPreference

    var body: some View {
        ZStack {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                RingLayer(
                    index: index,
                    state: item.state,
                    baseColor: Theme.color(for: item.id),
                    darkerColor: Theme.secondLapColor(for: item.id),
                    side: RingGeometry.side,
                    preference: ringWindowPreference(item.id)
                )
            }
            centreLabel
                .frame(maxWidth: centreHoleDiameter, maxHeight: centreHoleDiameter)
        }
        .frame(width: RingGeometry.side, height: RingGeometry.side)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Usage rings")
    }

    /// Available diameter for the centre label — the transparent hole
    /// inside the innermost visible ring. Sized so the label never
    /// collides with the ring even at N=3.
    private var centreHoleDiameter: CGFloat {
        RingGeometry.holeDiameter(visibleRingCount: max(1, visible.count))
    }

    private var centreLabel: some View {
        VStack(spacing: 1) {
            Text("Updated")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(RowText.centreText(lastRefresh: lastRefresh, now: now))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(4)
        .contentShape(Circle())
        .onTapGesture(perform: onCentreTap)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Refresh now")
    }
}

/// One ring in the concentric stack. All geometry is derived from the ring
/// index and the parent square's side so the layers align without a
/// GeometryReader per ring.
private struct RingLayer: View {

    let index: Int
    let state: ProviderState
    /// The base brand colour drawn for the first lap.
    let baseColor: Color
    /// A visibly-darker colour used to render the second-lap overlap when
    /// the used percentage exceeds 100%.
    let darkerColor: Color
    let side: CGFloat
    /// The Settings preference for which of this provider's windows drives
    /// the ring (auto / a specific kind).
    let preference: RingWindowPreference

    private var centreRadius: CGFloat {
        RingGeometry.centreLineRadius(index: index, side: side)
    }

    private var diameter: CGFloat { max(0, centreRadius * 2) }

    var body: some View {
        content
            .frame(width: diameter, height: diameter)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .hidden:
            EmptyView()

        case .loading:
            ZStack {
                solidTrack(color: baseColor)
                SpinnerArc(color: baseColor)
            }

        case .ok(let usage):
            filledRing(usage: usage, opacity: 1.0)

        case .stale(let usage, _):
            filledRing(usage: usage, opacity: 0.5)

        case .offline:
            // Empty grey track, no value.
            solidTrack(color: .gray)

        case .signedOut:
            // Dashed track — the row text says "Open <Tool> to refresh".
            dashedTrack(color: baseColor)

        case .error:
            // Same visual as offline (empty grey track); the row carries the
            // per-provider message.
            solidTrack(color: .gray)
        }
    }

    private func filledRing(usage: ProviderUsage, opacity: Double) -> some View {
        let selection = selectWindows(for: usage, preference: preference)
        let raw = (selection.ring?.usedPercent ?? 0) / 100
        let firstLap = min(max(raw, 0), 1)
        // Second-lap overlay: above 100% we wrap once and cap the visible
        // second lap at another full turn. Beyond 200% the whole ring is
        // already darker, which is a fine visual signal.
        let secondLap = min(max(raw - 1, 0), 1)
        // Small tail near the leading edge of the second lap that carries
        // the drop shadow. Confining the shadow to this tail (instead of
        // painting it under the entire second-lap arc) prevents the grey
        // halo from bleeding through the 4 pt gaps into the neighbouring
        // rings.
        let tailFraction: Double = 0.06
        let tailStart = max(0, secondLap - tailFraction)
        return ZStack {
            solidTrack(color: baseColor)
            filledArc(fraction: firstLap, color: baseColor)
            if secondLap > 0 {
                // Whole darker second-lap arc, no shadow.
                filledArc(fraction: secondLap, color: darkerColor)
                // Shadowed tail: only the leading ~6 % of the lap. When the
                // second lap is very short we skip the tail entirely — the
                // arc itself is already the "leading edge".
                if secondLap > tailFraction {
                    filledArcSegment(from: tailStart, to: secondLap, color: darkerColor)
                        .shadow(color: .black.opacity(0.35), radius: 1.5, x: 0, y: 0)
                }
            }
        }
        .opacity(opacity)
    }

    private func solidTrack(color: Color) -> some View {
        Circle().stroke(
            color.opacity(Theme.trackOpacity),
            style: StrokeStyle(lineWidth: RingGeometry.strokeWidth, lineCap: .round)
        )
    }

    /// Dashed track for the signed-out state. Uses `.butt` caps so a "4 pt
    /// on / 10 pt off" pattern renders as an actual dashed circle at the
    /// 22 pt stroke width; `.round` caps would extend each dash by
    /// stroke/2 = 11 pt on each end and visually merge the pattern into a
    /// solid ring.
    ///
    /// The pattern is computed per ring from the ring's circumference so
    /// there is no partial dash at 3 o'clock (`Circle` closes there). See
    /// `RingDashStyle.signedOutDashPattern(radius:)` and its tests.
    private func dashedTrack(color: Color) -> some View {
        let pattern = RingDashStyle.signedOutDashPattern(radius: centreRadius)
        return Circle().stroke(
            color.opacity(Theme.trackOpacity + 0.15),
            style: StrokeStyle(
                lineWidth: RingGeometry.strokeWidth,
                lineCap: .butt,
                dash: pattern
            )
        )
    }

    private func filledArc(fraction: Double, color: Color) -> some View {
        Circle()
            .trim(from: 0, to: fraction)
            .stroke(color, style: StrokeStyle(lineWidth: RingGeometry.strokeWidth, lineCap: .round))
            // Start the arc at 12 o'clock, matching Apple Health's rings.
            .rotationEffect(.degrees(-90))
            .animation(.easeInOut(duration: 0.4), value: fraction)
    }

    /// Draw a short arc segment from `from` to `to` (both in [0, 1]) —
    /// used to place a shadowed tail at the leading edge of the second lap
    /// without shadowing the entire arc underneath.
    private func filledArcSegment(from: Double, to: Double, color: Color) -> some View {
        Circle()
            .trim(from: from, to: to)
            .stroke(color, style: StrokeStyle(lineWidth: RingGeometry.strokeWidth, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .animation(.easeInOut(duration: 0.4), value: to)
    }
}

/// A small rotating arc used as the "checking" spinner. Uses
/// `TimelineView(.animation)` so the rotation continues without an
/// `@State`-driven `withAnimation` — safer when SwiftUI recomposes the ring
/// stack (e.g. when the state briefly re-enters `.loading` during a
/// refresh).
private struct SpinnerArc: View {
    let color: Color

    var body: some View {
        TimelineView(.animation) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
            Circle()
                .trim(from: 0, to: 0.18)
                .stroke(color, style: StrokeStyle(lineWidth: RingGeometry.strokeWidth, lineCap: .round))
                .rotationEffect(.degrees(phase.truncatingRemainder(dividingBy: 1.2) / 1.2 * 360))
        }
    }
}
