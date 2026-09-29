import SwiftUI
import AppKit
import OSLog
import UsageRingsCore

/// The SwiftUI menu bar app entry point.
///
/// Owns exactly one `AppModel` (created in `@State` so its lifetime matches
/// the app's) that wires the real providers, the `Preferences`, the shared
/// `UsageStore` and the `RefreshScheduler` together. App-wide side effects
/// — the scheduler timer, the wake observer, the initial refresh — kick
/// off from `AppModel.init()`.
///
/// The menu bar item uses `MenuBarExtra(content:label:)` with
/// `.menuBarExtraStyle(.window)`. The `Settings` scene is a plain SwiftUI
/// `Settings { … }` scene; the popover's gear opens it through a captured
/// `@Environment(\.openSettings)` action — see `SettingsActionCapture`
/// below and `AppModel.presentSettings()`. The AppKit selector path
/// (`NSApp.sendAction(#selector(showSettingsWindow:))`) is intercepted by
/// SwiftUI on macOS 14+ with a runtime warning and does not open the
/// window, so we deliberately do not use it.
@main
struct UsageRingsApp: App {

    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
        } label: {
            // The label is mounted for the whole app lifetime, so putting
            // the capture here gives `AppModel.settingsAction` a working
            // value as soon as the menu bar item appears — no need to
            // wait for the user to open the popover first.
            MenuBarLabel(
                entries: model.menuBarEntries,
                tint: model.menuBarTint,
                style: model.preferences.iconStyle
            )
            .background(SettingsActionCapture { action in
                // Only assign once so the label recomposing does not
                // churn observation. The action is stable for the app's
                // lifetime.
                if model.settingsAction == nil {
                    model.settingsAction = action
                }
            })
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(
                preferences: model.preferences,
                onPreferencesChanged: { model.applyPreferences() }
            )
        }
    }
}

/// Zero-size view whose only job is to grab the SwiftUI
/// `openSettings` environment action and hand it to `AppModel`.
///
/// Why: `@Environment(\.openSettings)` is only readable from inside a
/// `View`, but the app needs the action from a code path that does not
/// itself have a SwiftUI environment (the popover gear button reads it
/// through `AppModel.presentSettings()`, and the placeholder icon /
/// alternative future entry points may not sit inside a live SwiftUI
/// hierarchy). Mounting this bridge inside the `MenuBarExtra` label makes
/// the action available as soon as the menu bar item appears — no need
/// to wait for the popover to be shown.
struct SettingsActionCapture: View {
    let onCapture: (@MainActor @escaping () -> Void) -> Void
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                onCapture { openSettings() }
            }
    }
}

/// Bridges SwiftUI to the core store, scheduler and preferences.
///
/// `@MainActor` because the store and scheduler both live on the main
/// actor, and `@Observable` so the popover recomposes when `store.states`
/// or `store.lastRefresh` changes. This is the only place the executable
/// target constructs the real providers — every other view takes injected
/// data.
@MainActor
@Observable
final class AppModel {

    /// User preferences (icon style, per-provider enable, ring window,
    /// refresh interval). Persisted in `UserDefaults`.
    let preferences: Preferences

    /// The in-memory usage store the popover binds to.
    let store: UsageStore

    /// The refresh scheduler that owns the repeating timer plus the wake
    /// observer.
    let scheduler: RefreshScheduler

    /// The SwiftUI `openSettings` action, captured by
    /// `SettingsActionCapture` from the `MenuBarExtra`'s **label**. The
    /// label is mounted for the whole app lifetime, so this is populated
    /// as soon as the menu bar item appears — before the user first opens
    /// the popover. Used by `presentSettings()` so any code path can open
    /// the Settings scene without relying on the popover being visible.
    var settingsAction: (@MainActor () -> Void)? = nil

    /// The "wake up if the data is older than N seconds" threshold used by
    /// `refreshIfStale`: 60 s.
    private static let staleThreshold: TimeInterval = 60

    init() {
        let preferences = Preferences()
        self.preferences = preferences

        let transport = URLSessionTransport()
        let credentialReader = SecuritySubprocessCredentialReader()
        // The renewer reads the "Renew Claude login automatically" toggle
        // fresh on each attempt via the closure below — flipping the
        // Settings toggle takes effect on the very next 401 without a
        // provider rebuild. The read goes through the nonisolated
        // `Preferences.renewClaudeLoginAutomaticallyValue(in:)` static
        // because `attemptRenewal()` runs inside the Claude fetch's
        // child task (non-main-actor), and `UserDefaults` is
        // thread-safe. The renewer holds no reference to `Preferences`.
        let renewer = DefaultClaudeCLIRenewer(
            isEnabled: { Preferences.renewClaudeLoginAutomaticallyValue() }
        )
        let claude = ClaudeProvider(
            transport: transport,
            credentials: credentialReader,
            renewer: renewer
        )
        let codex = CodexProvider(transport: transport, auth: FileSystemCodexAuthReader())
        let cursor = CursorProvider(transport: transport, auth: FileSystemCursorAuthReader())

        // Ring order (outer→inner): Claude, Codex, Cursor. The store hides
        // any `ProviderID` whose provider says it is not installed, and any
        // that is currently disabled in Settings.
        let store = UsageStore(
            providers: [claude, codex, cursor],
            enabledProviders: preferences.enabledProviders
        )
        self.store = store

        // Break the reference cycle: the scheduler captures the store
        // weakly via a closure that only fires when the app is alive.
        //
        // `hasAnyOffline` is consulted by the scheduler right after each
        // refresh to decide whether to schedule the one-shot offline
        // follow-up (see `RefreshScheduling.shouldScheduleOfflineFollowUp`).
        self.scheduler = RefreshScheduler(
            interval: preferences.refreshIntervalSeconds,
            refresh: { [weak store] in
                await store?.refreshAll()
            },
            hasAnyOffline: { [weak store] in
                guard let store else { return false }
                return store.states.values.contains { state in
                    if case .offline = state { return true }
                    return false
                }
            },
            lastRefresh: { [weak store] in store?.lastRefresh }
        )

        // Kick off the initial refresh and start the timer + wake observer.
        // The initial refresh is routed through the scheduler so an offline
        // launch (Wi-Fi still associating, captive portal not yet cleared)
        // triggers the same one-shot follow-up hook as any other tick.
        scheduler.start()
        scheduler.refreshNow()
    }

    /// Programmatically open the SwiftUI `Settings` scene.
    ///
    /// Uses the environment action captured by `SettingsActionCapture` (the
    /// only reliable path on macOS 14+; the AppKit selector route
    /// `NSApp.sendAction(#selector(showSettingsWindow:))` is intercepted
    /// with a runtime warning and does not open the window).
    ///
    /// Fallback: if the capture has not yet fired (label not yet mounted,
    /// which would only happen if this is called before the first SwiftUI
    /// scene evaluation), we emit one `Logger.warning` line and give up
    /// silently — the message is a fixed English sentence carrying no
    /// tokens, URLs, or user identifiers, so it is safe to log. The
    /// intended caller is the popover gear button, which only runs after
    /// the popover has appeared (and thus after the label has mounted),
    /// so the fallback is purely defensive.
    func presentSettings() {
        activateForSettingsPresentation()
        if let action = settingsAction {
            action()
        } else {
            Self.log.warning("presentSettings called before openSettings action was captured; menu bar label has not appeared yet")
        }
    }

    private static let log = Logger(subsystem: "dev.usagerings.UsageRings", category: "settings")

    /// Visible providers in ring order (outer→inner), excluding any that
    /// are currently `.hidden` (disabled in Settings or not installed).
    var visibleProviders: [(id: ProviderID, state: ProviderState)] {
        RowText.visibleProviders(states: store.states)
    }

    /// Header subtitle text — provider short name + title-cased plan for
    /// every visible provider that returned a plan, joined with " · ".
    /// `nil` when no provider has reported a plan name (Claude never does).
    ///
    /// The actual formatting lives in `RowText.headerSubtitle` so it can
    /// be unit-tested without a view host.
    var planNamesSubtitle: String? {
        RowText.headerSubtitle(visible: visibleProviders)
    }

    /// The Settings preference for a provider's ring window. Defaults to
    /// `.auto` for any provider the preferences dictionary is missing.
    func ringWindowPreference(for id: ProviderID) -> RingWindowPreference {
        preferences.ringWindow[id] ?? .auto
    }

    /// Menu bar icon entries in outer→inner ring order.
    ///
    /// For each visible provider we surface a `MenuBarEntry` with the
    /// current ring window's `usedPercent`, or `nil` when the state has no
    /// ring value (loading / signed-out / offline / error). The label view
    /// draws a track for the nil case and the filled arc otherwise.
    var menuBarEntries: [MenuBarEntry] {
        visibleProviders.map { item in
            let percent: Double? = {
                let usage: ProviderUsage?
                switch item.state {
                case .ok(let u): usage = u
                case .stale(let u, _): usage = u
                default: usage = nil
                }
                guard let usage else { return nil }
                let selection = selectWindows(
                    for: usage,
                    preference: ringWindowPreference(for: item.id)
                )
                return selection.ring?.usedPercent
            }()
            return MenuBarEntry(id: item.id, percent: percent)
        }
    }

    /// Icon tint level from the highest visible ring percentage — amber at
    /// ≥ 80%, red at ≥ 95%.
    var menuBarTint: IconTintLevel {
        let percents = menuBarEntries.compactMap { $0.percent }
        return Formatting.iconTintLevel(visiblePercents: percents)
    }

    /// Fire an unconditional refresh (Refresh button, centre-tap on the
    /// ring stack). Runs on the store's single-flight guard so overlapping
    /// calls coalesce, and routes through the scheduler so an offline
    /// result triggers the one-shot follow-up hook.
    func refreshNow() {
        scheduler.refreshNow()
    }

    /// Called from the popover's visibility hooks. Only refreshes if the
    /// store's `lastRefresh` is more than 60 s old (or has never been set).
    func onPopoverAppear() {
        scheduler.refreshIfStale(olderThan: Self.staleThreshold)
    }

    /// Bring the app to the front so a Settings window opened by SwiftUI's
    /// `openSettings` environment action appears on top of whatever the
    /// user is looking at. `LSUIElement = true` means the app is not
    /// activated by default when its Settings window is created.
    ///
    /// The SwiftUI `openSettings` action itself is captured from the
    /// `MenuBarExtra` label by `SettingsActionCapture` and stored on
    /// `settingsAction`; `presentSettings()` fires it. Going through the
    /// environment is the only reliable path on macOS 14+;
    /// `NSApp.sendAction(#selector(showSettingsWindow:))` is intercepted
    /// with a runtime warning ("Please use SettingsLink") and does not
    /// open the window.
    func activateForSettingsPresentation() {
        NSApp.activate(ignoringOtherApps: true)
        // Sometimes the newly-created Settings window opens behind another
        // app's window. Ordering our windows to the front once after a
        // brief pause covers that edge case.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            for window in NSApp.windows where window.title == "Usage Rings Settings" || window.identifier?.rawValue.contains("Settings") == true {
                window.orderFrontRegardless()
                window.makeKey()
            }
        }
    }

    /// Called by Settings whenever a preference changes.
    ///
    /// Rebuilds the store's enabled set (disabled providers hide, newly
    /// enabled ones flip to `.loading` until the next fetch) and updates
    /// the scheduler's interval **only when it actually changed** —
    /// otherwise flipping an icon style would silently push the next
    /// refresh out to 5 minutes from now, resetting whatever partial
    /// interval was already elapsed.
    ///
    /// When the enabled set actually changes we run a *targeted* fetch for
    /// only the newly-enabled providers via `store.refreshProviders(_:)`.
    /// This is the important fix over `refreshAll()`: if a general refresh
    /// is currently in flight, `refreshAll` would single-flight into it
    /// (returning immediately after the running one completes) and the
    /// newly-enabled providers would keep spinning until the next timer
    /// tick.
    func applyPreferences() {
        let newEnabled = preferences.enabledProviders
        let previouslyEnabled = store.enabledProviders
        let newlyEnabled = newEnabled.subtracting(previouslyEnabled)

        store.setEnabledProviders(newEnabled)

        let newInterval = preferences.refreshIntervalSeconds
        if newInterval != scheduler.currentInterval {
            scheduler.reschedule(interval: newInterval)
        }

        if !newlyEnabled.isEmpty {
            Task { await store.refreshProviders(newlyEnabled) }
        }
    }
}
