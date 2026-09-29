import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Pure timing decisions shared between the live scheduler and its tests.
///
/// Keeping these separate means tests can exercise the "am I due?" logic and
/// interval clamping without spinning a real `Timer` or waiting for one to
/// fire.
public enum RefreshScheduling {

    /// Minimum polling interval (60–300 s).
    public static let minimumInterval: TimeInterval = 60

    /// Maximum polling interval.
    public static let maximumInterval: TimeInterval = 300

    /// Timer tolerance in seconds.
    public static let tolerance: TimeInterval = 30

    /// Seconds to wait after a wake notification before running the wake
    /// refresh.
    ///
    /// Waking straight into a network call almost always fails with
    /// `URLError.notConnectedToInternet` on macOS — the Wi-Fi radio has
    /// resumed but has not yet acquired an IP address / reachability. That
    /// failure would map to `.offline` and blank every ring until the next
    /// timer tick 5 minutes later. 10 s is long enough for a typical
    /// network association to complete and short enough that the user does
    /// not perceive it as latency after opening the popover.
    public static let wakeRefreshDelay: TimeInterval = 10

    /// Seconds to wait after a refresh that saw at least one provider in
    /// `.offline` before running a single follow-up refresh.
    ///
    /// A refresh that lands during a network drop (wake, dropped Wi-Fi,
    /// captive portal that has not yet completed) frequently comes back
    /// with every ring blank. Rather than force the user to wait a full
    /// polling interval, we schedule one follow-up 30 s later — long
    /// enough for the network to typically come back, short enough that
    /// the popover feels responsive. Only ONE follow-up per offline
    /// refresh: a follow-up that is itself offline does NOT schedule
    /// another (see `shouldScheduleOfflineFollowUp`).
    public static let offlineFollowUpDelay: TimeInterval = 30

    /// Clamp a caller-supplied interval into the allowed 60–300 s range.
    public static func clampedInterval(_ seconds: TimeInterval) -> TimeInterval {
        return min(max(seconds, minimumInterval), maximumInterval)
    }

    /// Given the current time, the last refresh timestamp and the polling
    /// interval, decide whether a refresh should run now.
    ///
    ///  - Never refreshed → due.
    ///  - `now - lastRefresh >= interval` → due (also handles wall-clock
    ///    jumps forward, e.g. after a 2 h sleep).
    ///  - `now < lastRefresh` (clock went backwards) → not due; we wait for
    ///    the interval to elapse from the last recorded refresh.
    public static func isDue(now: Date, lastRefresh: Date?, interval: TimeInterval) -> Bool {
        guard let last = lastRefresh else { return true }
        return now.timeIntervalSince(last) >= interval
    }

    /// Should the scheduler schedule a one-shot offline follow-up refresh?
    ///
    /// Rules:
    ///  - `anyOffline` must be `true` — the refresh that just completed
    ///    saw at least one ring go to `.offline`.
    ///  - `isFollowUp` must be `false` — a follow-up that is itself
    ///    offline does NOT schedule another. Without this the app could
    ///    poll the vendor endpoints every 30 s indefinitely while the
    ///    network stays down, defeating the point of the offline state.
    public static func shouldScheduleOfflineFollowUp(anyOffline: Bool, isFollowUp: Bool) -> Bool {
        return anyOffline && !isFollowUp
    }
}

/// Owns a repeating `Timer` that periodically triggers a caller-supplied
/// refresh closure, plus a wake-from-sleep observer and a helper for the
/// popover-open path.
///
/// The scheduler is deliberately dumb: it does not itself hold the store or
/// know how fetches are performed. The app wires it to
/// `Task { await store.refreshAll() }`. Timing decisions live on
/// `RefreshScheduling` so they can be unit-tested without a run loop.
///
/// The interval is passed in at construction and can be updated with
/// `reschedule(interval:)`.
@MainActor
public final class RefreshScheduler {

    private var timer: Timer?
    private var interval: TimeInterval
    private let refresh: @MainActor () async -> Void
    private let hasAnyOffline: @MainActor () -> Bool
    private let lastRefreshProvider: @MainActor () -> Date?
    private let clock: @Sendable () -> Date
    private var wakeObserver: NSObjectProtocol?

    /// A pending offline follow-up timer, if any. `nil` when no follow-up
    /// is currently scheduled.
    ///
    /// Held on the class rather than fired-and-forgotten so `stop()` can
    /// invalidate it and a second-in-a-row offline refresh does not queue
    /// two follow-ups.
    private var offlineFollowUpTimer: Timer?

    /// A pending wake refresh (10 s post-wake), if any.
    ///
    /// Held so `stop()` can cancel it. If two wake notifications arrive
    /// within 10 s of each other, the second is folded into the first —
    /// we do not want to spin up a second refresh path.
    private var wakeDelayTimer: Timer?

    /// Current polling interval in seconds, always clamped to
    /// `RefreshScheduling.minimumInterval ... maximumInterval`. Read by
    /// the app model so it can skip a redundant `reschedule` when the
    /// user toggles an unrelated preference.
    public var currentInterval: TimeInterval { interval }

    /// - Parameters:
    ///   - interval: Caller-supplied polling interval, clamped to 60–300 s.
    ///   - refresh: Async closure invoked whenever the timer fires, when
    ///     the popover asks for a stale refresh, or when the machine
    ///     wakes. Awaited so the follow-up decision can consult
    ///     `hasAnyOffline` after the refresh has landed its results.
    ///   - hasAnyOffline: Accessor returning `true` when at least one
    ///     provider is currently in the `.offline` state. Used to decide
    ///     whether to schedule a one-shot offline follow-up (see
    ///     `RefreshScheduling.shouldScheduleOfflineFollowUp`). Defaults
    ///     to `{ false }` so callers uninterested in the follow-up
    ///     behaviour (existing tests) opt in explicitly.
    ///   - lastRefresh: Read-only accessor for the store's `lastRefresh`
    ///     used by `refreshIfStale(olderThan:)`.
    ///   - clock: Injectable clock for tests; defaults to `Date()`.
    public init(
        interval: TimeInterval,
        refresh: @escaping @MainActor () async -> Void,
        hasAnyOffline: @escaping @MainActor () -> Bool = { false },
        lastRefresh: @escaping @MainActor () -> Date?,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.interval = RefreshScheduling.clampedInterval(interval)
        self.refresh = refresh
        self.hasAnyOffline = hasAnyOffline
        self.lastRefreshProvider = lastRefresh
        self.clock = clock
    }

    /// Begin scheduling. Also subscribes to `NSWorkspace.didWakeNotification`
    /// so the app refreshes as soon as the machine comes back from sleep.
    public func start() {
        installTimer()
        installWakeObserver()
    }

    /// Cancel the timer and wake observer. Safe to call more than once.
    public func stop() {
        timer?.invalidate()
        timer = nil
        offlineFollowUpTimer?.invalidate()
        offlineFollowUpTimer = nil
        wakeDelayTimer?.invalidate()
        wakeDelayTimer = nil
        removeWakeObserver()
    }

    /// Update the polling interval. If the timer is already running, it is
    /// reinstalled with the new interval; otherwise the new interval will
    /// take effect on the next `start()`.
    public func reschedule(interval: TimeInterval) {
        self.interval = RefreshScheduling.clampedInterval(interval)
        if timer != nil {
            installTimer()
        }
    }

    /// Popover-open path: run the refresh only if the store's `lastRefresh`
    /// (the time of the most recent refresh in which at least one provider
    /// succeeded) is more than `seconds` seconds old, or if there has
    /// never been a successful refresh yet.
    public func refreshIfStale(olderThan seconds: TimeInterval) {
        let now = clock()
        let last = lastRefreshProvider()
        if RefreshScheduling.isDue(now: now, lastRefresh: last, interval: seconds) {
            runRefresh(isFollowUp: false)
        }
    }

    /// Unconditional refresh path (Refresh button, centre-tap on the ring
    /// stack, initial refresh at launch). Runs through the same
    /// `runRefresh` plumbing as the timer so an offline result triggers
    /// the one-shot follow-up.
    public func refreshNow() {
        runRefresh(isFollowUp: false)
    }

    // MARK: - Private

    /// Run one refresh through the injected closure, then optionally
    /// schedule the one-shot offline follow-up.
    ///
    /// - Parameter isFollowUp: `true` when this call is itself the
    ///   already-scheduled follow-up. A follow-up that lands offline again
    ///   does NOT schedule yet another follow-up.
    private func runRefresh(isFollowUp: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refresh()
            let anyOffline = self.hasAnyOffline()
            if RefreshScheduling.shouldScheduleOfflineFollowUp(
                anyOffline: anyOffline,
                isFollowUp: isFollowUp
            ) {
                self.scheduleOfflineFollowUp()
            }
        }
    }

    /// Schedule a single one-shot refresh
    /// `RefreshScheduling.offlineFollowUpDelay` seconds from now, replacing
    /// any prior pending follow-up. Marked as a follow-up so it will not
    /// itself schedule another one.
    private func scheduleOfflineFollowUp() {
        offlineFollowUpTimer?.invalidate()
        let t = Timer(
            timeInterval: RefreshScheduling.offlineFollowUpDelay,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.offlineFollowUpTimer = nil
                self?.runRefresh(isFollowUp: true)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        offlineFollowUpTimer = t
    }

    private func installTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.runRefresh(isFollowUp: false)
            }
        }
        t.tolerance = RefreshScheduling.tolerance
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func installWakeObserver() {
        #if canImport(AppKit)
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleWakeRefresh()
            }
        }
        #endif
    }

    /// Delay the wake refresh by `RefreshScheduling.wakeRefreshDelay`
    /// seconds so URLSession has a chance to see the network come back
    /// before the fetch fires. A second wake notification arriving inside
    /// the delay window is folded into the pending refresh.
    private func scheduleWakeRefresh() {
        if wakeDelayTimer != nil { return }
        let t = Timer(
            timeInterval: RefreshScheduling.wakeRefreshDelay,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.wakeDelayTimer = nil
                self?.runRefresh(isFollowUp: false)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        wakeDelayTimer = t
    }

    private func removeWakeObserver() {
        #if canImport(AppKit)
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
        }
        #endif
    }
}
