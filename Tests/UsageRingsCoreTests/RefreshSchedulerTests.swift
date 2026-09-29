import XCTest
@testable import UsageRingsCore

final class RefreshSchedulingTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Clamping

    func testClampFloorsAtSixty() {
        XCTAssertEqual(RefreshScheduling.clampedInterval(0), 60)
        XCTAssertEqual(RefreshScheduling.clampedInterval(30), 60)
        XCTAssertEqual(RefreshScheduling.clampedInterval(-100), 60)
    }

    func testClampCeilsAtThreeHundred() {
        XCTAssertEqual(RefreshScheduling.clampedInterval(500), 300)
        XCTAssertEqual(RefreshScheduling.clampedInterval(.infinity), 300)
    }

    func testClampPreservesInRange() {
        XCTAssertEqual(RefreshScheduling.clampedInterval(60), 60)
        XCTAssertEqual(RefreshScheduling.clampedInterval(120), 120)
        XCTAssertEqual(RefreshScheduling.clampedInterval(300), 300)
    }

    // MARK: - Due-logic

    func testNoPreviousRefreshIsAlwaysDue() {
        XCTAssertTrue(RefreshScheduling.isDue(now: now, lastRefresh: nil, interval: 300))
    }

    func testWithinIntervalIsNotDue() {
        let last = now.addingTimeInterval(-60)
        XCTAssertFalse(RefreshScheduling.isDue(now: now, lastRefresh: last, interval: 300))
    }

    func testAtIntervalBoundaryIsDue() {
        // Exactly `interval` seconds since the last refresh must count as
        // due — otherwise a 300 s timer could push the actual refresh out
        // to 301 s and miss the "≤ 5 min freshness" promise.
        let last = now.addingTimeInterval(-300)
        XCTAssertTrue(RefreshScheduling.isDue(now: now, lastRefresh: last, interval: 300))
    }

    func testOverdueAfterSimulatedTwoHourSleepIsDueImmediately() {
        // The machine went to sleep 5 s after the last successful refresh
        // and woke 2 h later. The very next tick must be due, not "wait
        // another interval".
        let last = now.addingTimeInterval(-2 * 3600 - 5)
        XCTAssertTrue(RefreshScheduling.isDue(now: now, lastRefresh: last, interval: 300))
    }

    func testFuturLastRefreshIsNotDue() {
        // Clock went backwards (or a bad injected clock). We do not fetch
        // in a tight loop; wait until real time catches up.
        let last = now.addingTimeInterval(60)
        XCTAssertFalse(RefreshScheduling.isDue(now: now, lastRefresh: last, interval: 300))
    }

    // MARK: - Wake delay / offline follow-up decisions

    func testWakeRefreshDelayIsTenSeconds() {
        // Waking straight into a URLSession call almost always fails with
        // `.notConnectedToInternet` — the Wi-Fi radio is up but has not
        // re-associated yet. 10 s covers the typical gap without feeling
        // laggy to the user.
        XCTAssertEqual(RefreshScheduling.wakeRefreshDelay, 10)
    }

    func testOfflineFollowUpDelayIsThirtySeconds() {
        XCTAssertEqual(RefreshScheduling.offlineFollowUpDelay, 30)
    }

    func testFollowUpScheduledWhenNormalRefreshWentOffline() {
        // Normal (non-follow-up) refresh that saw at least one .offline →
        // schedule ONE follow-up.
        XCTAssertTrue(RefreshScheduling.shouldScheduleOfflineFollowUp(
            anyOffline: true, isFollowUp: false
        ))
    }

    func testFollowUpNotScheduledWhenNothingWentOffline() {
        // A clean refresh (no .offline anywhere) needs no follow-up.
        XCTAssertFalse(RefreshScheduling.shouldScheduleOfflineFollowUp(
            anyOffline: false, isFollowUp: false
        ))
    }

    func testFollowUpNotScheduledFromAnotherFollowUp() {
        // A follow-up that is itself offline must NOT schedule yet another
        // one — otherwise the app would poll the network every 30 s
        // indefinitely while offline, defeating the point of the offline
        // state.
        XCTAssertFalse(RefreshScheduling.shouldScheduleOfflineFollowUp(
            anyOffline: true, isFollowUp: true
        ))
        XCTAssertFalse(RefreshScheduling.shouldScheduleOfflineFollowUp(
            anyOffline: false, isFollowUp: true
        ))
    }
}

/// Sendable holders for the scheduler's injected closures. The scheduler
/// takes `@Sendable` closures for `refresh`, `lastRefresh` and `clock`; the
/// tests need to observe / mutate state from the main actor, so we wrap the
/// state in reference types with `NSLock` protection.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func increment() {
        lock.lock(); _value += 1; lock.unlock()
    }
}

private final class OptionalDateHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Date?
    var value: Date? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
    }
    func set(_ v: Date?) {
        lock.lock(); _value = v; lock.unlock()
    }
}

private final class DateHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Date
    init(_ v: Date) { self._value = v }
    var value: Date {
        get { lock.lock(); defer { lock.unlock() }; return _value }
    }
    func set(_ v: Date) {
        lock.lock(); _value = v; lock.unlock()
    }
}

/// Integration tests for `RefreshScheduler.refreshIfStale(olderThan:)`.
///
/// The wake observer and the repeating timer are wired against AppKit /
/// the main run loop; a robust unit test of those would need a run-loop
/// spin. The pure due-logic they call is covered above.
@MainActor
final class RefreshSchedulerRefreshIfStaleTests: XCTestCase {

    private func makeScheduler(
        interval: TimeInterval = 300,
        now: DateHolder,
        lastRefresh: OptionalDateHolder,
        callCount: CallCounter
    ) -> RefreshScheduler {
        RefreshScheduler(
            interval: interval,
            refresh: { callCount.increment() },
            lastRefresh: { lastRefresh.value },
            clock: { now.value }
        )
    }

    /// `refreshIfStale` spawns the actual refresh through a `Task`; wait
    /// for it to reach the increment before observing the counter.
    private func waitForCall(_ counter: CallCounter, expected: Int) async {
        for _ in 0..<200 {
            if counter.value >= expected { return }
            await Task.yield()
        }
    }

    func testRefreshIfStaleFiresWhenNoPreviousRefresh() async {
        let now = DateHolder(Date(timeIntervalSince1970: 1_700_000_000))
        let last = OptionalDateHolder()
        let calls = CallCounter()
        let s = makeScheduler(now: now, lastRefresh: last, callCount: calls)
        s.refreshIfStale(olderThan: 60)
        await waitForCall(calls, expected: 1)
        XCTAssertEqual(calls.value, 1)
    }

    func testRefreshIfStaleFiresWhenOlderThanThreshold() async {
        let now = DateHolder(Date(timeIntervalSince1970: 1_700_000_000))
        let last = OptionalDateHolder()
        last.set(now.value.addingTimeInterval(-90))
        let calls = CallCounter()
        let s = makeScheduler(now: now, lastRefresh: last, callCount: calls)
        s.refreshIfStale(olderThan: 60)
        await waitForCall(calls, expected: 1)
        XCTAssertEqual(calls.value, 1)
    }

    func testRefreshIfStaleSkipsWhenFresh() async {
        let now = DateHolder(Date(timeIntervalSince1970: 1_700_000_000))
        let last = OptionalDateHolder()
        last.set(now.value.addingTimeInterval(-30))
        let calls = CallCounter()
        let s = makeScheduler(now: now, lastRefresh: last, callCount: calls)
        s.refreshIfStale(olderThan: 60)
        // Yield a few times to catch any errant spawn.
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(calls.value, 0)
    }

    func testRescheduleAcceptsAndClampsIntervalWithoutStartingTimer() async {
        let now = DateHolder(Date(timeIntervalSince1970: 1_700_000_000))
        let last = OptionalDateHolder()
        let calls = CallCounter()
        let s = makeScheduler(interval: 120, now: now, lastRefresh: last, callCount: calls)
        // A reschedule before start() must not throw or start the timer.
        s.reschedule(interval: 1000)   // clamped to 300
        s.reschedule(interval: 10)     // clamped to 60
        // No timer running, no refresh should have fired.
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(calls.value, 0)
    }

    func testRefreshIfStalePassesHasAnyOfflineIntoDecision() async {
        // When hasAnyOffline returns true after the refresh, the scheduler
        // should follow the shouldScheduleOfflineFollowUp policy internally.
        // We verify by asking hasAnyOffline whether it was queried after the
        // refresh completed — the pure decision has already been unit tested
        // above; here we just confirm the wiring runs it.
        let now = DateHolder(Date(timeIntervalSince1970: 1_700_000_000))
        let last = OptionalDateHolder()
        let calls = CallCounter()
        let offlineChecks = CallCounter()
        let s = RefreshScheduler(
            interval: 300,
            refresh: { calls.increment() },
            hasAnyOffline: { offlineChecks.increment(); return false },
            lastRefresh: { last.value },
            clock: { now.value }
        )
        s.refreshIfStale(olderThan: 60)
        await waitForCall(calls, expected: 1)
        await waitForCall(offlineChecks, expected: 1)
        XCTAssertEqual(calls.value, 1)
        XCTAssertGreaterThanOrEqual(offlineChecks.value, 1,
                                    "the scheduler must consult hasAnyOffline after a refresh")
    }
}
