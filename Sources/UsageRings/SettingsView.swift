import SwiftUI
import AppKit
import ServiceManagement
import UsageRingsCore

/// The Settings window shown by the `Settings` scene.
///
/// Sections: providers on/off, ring window per provider (Auto + that
/// provider's window kinds — `.onDemand` is never offered), refresh
/// interval 1–5 min, icon style, launch at login.
///
/// The launch-at-login toggle is intentionally *not* persisted in
/// Preferences: the source of truth is `SMAppService.mainApp.status`.
/// The toggle reflects that status and calls `register()` /
/// `unregister()` on flip; if either call throws, the error message is
/// shown inline and the toggle snaps back to the current system status.
///
/// Any preference change calls the injected `onPreferencesChanged` closure
/// so the app model can react (rebuild the store's enabled set, reschedule
/// the timer). The store already reads Preferences.enabledProviders via
/// the closure — this callback is the "push" side of the same wire.
struct SettingsView: View {

    let preferences: Preferences
    let onPreferencesChanged: () -> Void

    /// Cached launch-at-login state so a failed `register()` can snap the
    /// toggle back to `SMAppService.mainApp.status`.
    @State private var launchAtLoginEnabled: Bool
    @State private var launchAtLoginError: String?

    init(preferences: Preferences, onPreferencesChanged: @escaping () -> Void) {
        self.preferences = preferences
        self.onPreferencesChanged = onPreferencesChanged
        self._launchAtLoginEnabled = State(
            initialValue: SMAppService.mainApp.status == .enabled
        )
    }

    var body: some View {
        Form {
            providersSection
            ringWindowSection
            refreshSection
            iconSection
            claudeRenewalSection
            launchAtLoginSection
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 560)
        // Re-read the system's launch-at-login status every time the
        // Settings window is presented. The user might have flipped it in
        // System Settings between opens, or approved a `.requiresApproval`
        // prompt that landed after this view was created.
        .onAppear {
            refreshLaunchAtLoginStatus()
        }
    }

    // MARK: - Sections

    private var providersSection: some View {
        Section("Providers") {
            ForEach(ProviderID.allCases, id: \.self) { id in
                Toggle(id.displayName, isOn: Binding(
                    get: { preferences.enabled[id] ?? true },
                    set: { newValue in
                        preferences.setEnabled(id, newValue)
                        onPreferencesChanged()
                    }
                ))
            }
        }
    }

    private var ringWindowSection: some View {
        Section("Ring window") {
            ForEach(ProviderID.allCases, id: \.self) { id in
                Picker(id.displayName, selection: ringWindowBinding(for: id)) {
                    Text("Auto").tag(RingWindowPreference.auto)
                    ForEach(id.ringWindowKinds, id: \.self) { kind in
                        Text(Self.displayLabel(for: kind))
                            .tag(RingWindowPreference.specific(kind))
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    private var refreshSection: some View {
        Section("Refresh") {
            Picker("Interval", selection: Binding(
                get: { Int(preferences.refreshIntervalSeconds / 60) },
                set: { minutes in
                    preferences.setRefreshIntervalSeconds(TimeInterval(minutes) * 60)
                    onPreferencesChanged()
                }
            )) {
                ForEach(1...5, id: \.self) { minutes in
                    Text("\(minutes) min").tag(minutes)
                }
            }
        }
    }

    private var iconSection: some View {
        Section("Menu bar icon") {
            Picker("Style", selection: Binding(
                get: { preferences.iconStyle },
                set: { style in
                    preferences.setIconStyle(style)
                    onPreferencesChanged()
                }
            )) {
                Text("Colour").tag(IconStyle.colour)
                Text("Monochrome").tag(IconStyle.mono)
                Text("Colour with percent").tag(IconStyle.withPercent)
            }
        }
    }

    private var claudeRenewalSection: some View {
        Section("Claude Code") {
            Toggle("Renew Claude login automatically", isOn: Binding(
                get: { preferences.renewClaudeLoginAutomatically },
                set: { newValue in
                    preferences.setRenewClaudeLoginAutomatically(newValue)
                    onPreferencesChanged()
                }
            ))
            Text("Runs a one-word `claude` prompt when the CLI login has expired; uses a tiny amount of usage.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var launchAtLoginSection: some View {
        Section("Startup") {
            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLoginEnabled },
                set: { setLaunchAtLogin($0) }
            ))
            if let error = launchAtLoginError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
    }

    // MARK: - Helpers

    private func ringWindowBinding(for id: ProviderID) -> Binding<RingWindowPreference> {
        Binding(
            get: { preferences.ringWindow[id] ?? .auto },
            set: { newValue in
                preferences.setRingWindow(id, newValue)
                onPreferencesChanged()
            }
        )
    }

    private static func displayLabel(for kind: UsageWindowKind) -> String {
        switch kind {
        case .fiveHour:     return "5-hour"
        case .weekly:       return "Weekly"
        case .primary:      return "Primary"
        case .secondary:    return "Secondary"
        case .billingCycle: return "Billing cycle"
        case .onDemand:     return "On-demand"
        }
    }

    private func setLaunchAtLogin(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshLaunchAtLoginStatus()
        } catch {
            // Show the failure and snap the toggle back to the actual state.
            launchAtLoginError = error.localizedDescription
            refreshLaunchAtLoginStatus(preserveErrorFromCatch: true)
        }
    }

    /// Re-read `SMAppService.mainApp.status` and reconcile the toggle plus
    /// error message.
    ///
    /// The `.requiresApproval` case is important: `register()` can return
    /// success while the OS is still waiting for the user to approve the
    /// login item under System Settings → General → Login Items. If we
    /// silently snap the toggle to `false` in that state the user has no
    /// idea why it "won't stick". Instead we surface an inline hint and
    /// leave the toggle on (approval is pending, not refused).
    private func refreshLaunchAtLoginStatus(preserveErrorFromCatch: Bool = false) {
        let status = SMAppService.mainApp.status
        switch status {
        case .enabled:
            launchAtLoginEnabled = true
            if !preserveErrorFromCatch { launchAtLoginError = nil }
        case .requiresApproval:
            // The user must confirm this item under
            // System Settings → General → Login Items before it actually
            // launches. Leave the toggle on so they see the intent, and
            // tell them exactly where to click.
            launchAtLoginEnabled = true
            launchAtLoginError = "Approve in System Settings → General → Login Items"
        case .notFound, .notRegistered:
            launchAtLoginEnabled = false
            if !preserveErrorFromCatch { launchAtLoginError = nil }
        @unknown default:
            // Future OS may add cases; treat as "off" and clear any stale
            // error text so we do not leave a message that referenced the
            // previous status.
            launchAtLoginEnabled = false
            if !preserveErrorFromCatch { launchAtLoginError = nil }
        }
    }
}
