import SwiftUI
import AppKit
import UsageRingsCore

/// The window-style menu bar popover.
///
/// Layout, top → bottom: title header with plan-names subtitle, ring stack,
/// per-provider rows, divider, footer with Refresh / Settings gear / Quit.
/// A 1-minute `TimelineView` ticker recomputes the relative texts ("N min
/// ago", "Reset in …") without hitting the network.
///
/// The popover-open refresh (refresh on popover open when data is older
/// than 60 s) is wired through a hidden `WindowVisibilityObserver` NSView
/// rather than SwiftUI's `onAppear`. `MenuBarExtra(.window)` keeps the
/// popover's view hierarchy alive across hides on macOS 14 – 26, so
/// `onAppear` only fires once. The observer listens for the containing
/// `NSWindow`'s occlusion / becomeKey notifications, which fire every time
/// the user re-opens the menu bar item. `onAppear` is retained as a
/// belt-and-braces first-show trigger; the store's single-flight and
/// staleness checks make duplicate calls harmless.
struct PopoverView: View {

    /// The main app model — owns the store and scheduler.
    let model: AppModel

    var body: some View {
        // 60 s ticker so "N min ago" / "Reset in …" advance without a
        // network call. The rings and rows all read `context.date` as
        // their "now", keeping the popover internally consistent.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(now: context.date)
        }
        .frame(width: 320)
        .padding(.vertical, 12)
        // First-show path (belt-and-braces — the window observer below
        // also fires on the first show).
        .onAppear {
            model.onPopoverAppear()
        }
        // Per-open path: attach a hidden NSView that watches the popover's
        // containing NSWindow for visibility transitions and calls
        // `onPopoverAppear()` on each one. See `WindowVisibilityObserver`.
        .background(WindowVisibilityObserver { model.onPopoverAppear() })
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        VStack(spacing: 12) {
            header
            RingsView(
                visible: model.visibleProviders,
                lastRefresh: model.store.lastRefresh,
                now: now,
                onCentreTap: { model.refreshNow() },
                ringWindowPreference: { model.ringWindowPreference(for: $0) }
            )
            .padding(.horizontal, 12)

            rows(now: now)

            Divider().padding(.horizontal, 12)

            footer
                .padding(.horizontal, 12)
        }
    }

    private var header: some View {
        VStack(spacing: 2) {
            Text("Usage Rings")
                .font(.headline)
            if let subtitle = model.planNamesSubtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private func rows(now: Date) -> some View {
        let visible = model.visibleProviders
        if visible.isEmpty {
            Text("No providers detected")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
        } else {
            VStack(spacing: 0) {
                ForEach(visible, id: \.id) { item in
                    ProviderRowView(
                        id: item.id,
                        state: item.state,
                        now: now,
                        preference: model.ringWindowPreference(for: item.id)
                    )
                    .padding(.horizontal, 12)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button(action: { model.refreshNow() }) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)

            Spacer()

            Button(action: { model.presentSettings() }) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Settings")

            Button(action: { NSApp.terminate(nil) }) {
                Text("Quit")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("q")
        }
        .font(.callout)
    }
}
