import XCTest
@testable import UsageRingsCore

// MARK: - Test doubles

/// A fake `UsageProvider` for exercising `UsageStore` outcome mapping.
///
/// `outcomes` is a queue: each call to `fetch()` pops the next element. If
/// the queue is empty, `fetch()` throws `.other("no more outcomes")` so a
/// test never silently hangs on a stale expectation.
///
/// `@unchecked Sendable` because we protect the mutable queue with a
/// `NSLock`; the actor variant would force the tests to be async everywhere.
final class FakeProvider: UsageProvider, @unchecked Sendable {
    let id: ProviderID
    private let lock = NSLock()
    private var outcomes: [Result<ProviderUsage, Error>]
    private var _installed: Bool
    private var _callCount = 0

    init(id: ProviderID, installed: Bool = true, outcomes: [Result<ProviderUsage, Error>] = []) {
        self.id = id
        self._installed = installed
        self.outcomes = outcomes
    }

    // The lock helpers are non-async so `NSLock.lock()` is legal here; the
    // async `fetch()` below delegates through `popNextOutcome()` which is
    // synchronous.

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var callCount: Int {
        withLock { _callCount }
    }

    func setInstalled(_ value: Bool) {
        withLock { _installed = value }
    }

    func enqueue(_ outcome: Result<ProviderUsage, Error>) {
        withLock { outcomes.append(outcome) }
    }

    func isInstalled() async -> Bool {
        withLock { _installed }
    }

    private func popNextOutcome() -> Result<ProviderUsage, Error> {
        withLock {
            _callCount += 1
            if outcomes.isEmpty {
                return .failure(FetchError.other("no more outcomes"))
            }
            return outcomes.removeFirst()
        }
    }

    func fetch() async throws -> ProviderUsage {
        switch popNextOutcome() {
        case .success(let usage): return usage
        case .failure(let error): throw error
        }
    }
}

/// A `UsageProvider` whose `fetch()` suspends until the test calls
/// `release()`. Used to exercise the single-flight guard and the streaming
/// (apply-as-they-arrive) behaviour of `UsageStore.refreshAll`.
///
/// Handles the "release before fetch()" race with a pending flag so a test
/// that releases before the store has spun up its task group is not
/// deadlocked.
final class SuspendingProvider: UsageProvider, @unchecked Sendable {
    let id: ProviderID
    private let usage: ProviderUsage
    private let lock = NSLock()
    private var _callCount = 0
    private var _installed: Bool
    private var _pendingRelease = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(id: ProviderID, usage: ProviderUsage, installed: Bool = true) {
        self.id = id
        self.usage = usage
        self._installed = installed
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    var callCount: Int { withLock { _callCount } }

    func isInstalled() async -> Bool { withLock { _installed } }

    /// Release whichever `fetch()` is currently suspended (or mark the next
    /// one for immediate return if none is suspended yet).
    func release() {
        let toResume: CheckedContinuation<Void, Never>? = withLock {
            if let c = continuation {
                continuation = nil
                return c
            }
            _pendingRelease = true
            return nil
        }
        toResume?.resume()
    }

    func fetch() async throws -> ProviderUsage {
        let earlyReturn = withLock { () -> Bool in
            _callCount += 1
            if _pendingRelease {
                _pendingRelease = false
                return true
            }
            return false
        }
        if earlyReturn { return usage }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let alreadyReleased = withLock { () -> Bool in
                if _pendingRelease {
                    _pendingRelease = false
                    return true
                }
                continuation = cont
                return false
            }
            if alreadyReleased { cont.resume() }
        }
        return usage
    }
}

// MARK: - Fixtures

/// A `Sendable` clock reference that tests can advance from the main actor
/// while the store's clock closure reads it from the task group. Backed by
/// an `NSLock` so `@Sendable` closure captures are safe.
private final class MockClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ start: Date) { self._now = start }
    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return _now
    }
    func set(_ value: Date) {
        lock.lock(); _now = value; lock.unlock()
    }
    func advance(by seconds: TimeInterval) {
        lock.lock(); _now.addTimeInterval(seconds); lock.unlock()
    }
}

private func makeUsage(_ id: ProviderID, percent: Double = 42, at: TimeInterval = 1_700_000_000) -> ProviderUsage {
    ProviderUsage(
        id: id,
        plan: nil,
        windows: [
            UsageWindow(label: "5h", usedPercent: percent, resetsAt: nil, kind: .fiveHour)
        ],
        fetchedAt: Date(timeIntervalSince1970: at)
    )
}

// MARK: - Tests

@MainActor
final class UsageStoreOutcomeMappingTests: XCTestCase {

    private let clock = MockClock(Date(timeIntervalSince1970: 1_700_000_000))

    private func makeStore(_ providers: [FakeProvider]) -> UsageStore {
        let c = clock
        return UsageStore(
            providers: providers,
            enabledProviders: Set(ProviderID.allCases),
            clock: { c.now }
        )
    }

    func testInitialStatesAreLoading() {
        let store = makeStore([FakeProvider(id: .claude), FakeProvider(id: .codex), FakeProvider(id: .cursor)])
        XCTAssertEqual(store.states[.claude], .loading)
        XCTAssertEqual(store.states[.codex], .loading)
        XCTAssertEqual(store.states[.cursor], .loading)
        XCTAssertNil(store.lastRefresh)
    }

    func testSuccessMapsToOK() async {
        let usage = makeUsage(.claude)
        let claude = FakeProvider(id: .claude, outcomes: [.success(usage)])
        let store = makeStore([claude])
        await store.refreshAll()
        XCTAssertEqual(store.states[.claude], .ok(usage))
        XCTAssertEqual(store.lastRefresh, clock.now)
    }

    func testSignedOutMapsToSignedOut() async {
        let claude = FakeProvider(id: .claude, outcomes: [.failure(FetchError.signedOut("Open Claude Code to refresh"))])
        let store = makeStore([claude])
        await store.refreshAll()
        XCTAssertEqual(store.states[.claude], .signedOut(reason: "Open Claude Code to refresh"))
    }

    func testRateLimitedWithoutPreviousBecomesError() async {
        let claude = FakeProvider(id: .claude, outcomes: [.failure(FetchError.rateLimited(retryAfter: nil))])
        let store = makeStore([claude])
        await store.refreshAll()
        guard case .error = store.states[.claude] else {
            return XCTFail("expected .error, got \(String(describing: store.states[.claude]))")
        }
    }

    func testRateLimitedWithPreviousBecomesStale() async {
        let usage = makeUsage(.claude, percent: 20)
        let claude = FakeProvider(id: .claude, outcomes: [
            .success(usage),
            .failure(FetchError.rateLimited(retryAfter: nil))
        ])
        let store = makeStore([claude])
        await store.refreshAll()
        XCTAssertEqual(store.states[.claude], .ok(usage))
        await store.refreshAll()
        guard case .stale(let kept, let since) = store.states[.claude] else {
            return XCTFail("expected .stale, got \(String(describing: store.states[.claude]))")
        }
        XCTAssertEqual(kept, usage)
        XCTAssertEqual(since, clock.now)
    }

    func testServerErrorWithoutPreviousBecomesError() async {
        let claude = FakeProvider(id: .claude, outcomes: [.failure(FetchError.server(503))])
        let store = makeStore([claude])
        await store.refreshAll()
        guard case .error(let msg) = store.states[.claude] else {
            return XCTFail("expected .error, got \(String(describing: store.states[.claude]))")
        }
        XCTAssertTrue(msg.contains("503"))
    }

    func testServerErrorWithPreviousBecomesStale() async {
        let usage = makeUsage(.claude, percent: 55)
        let claude = FakeProvider(id: .claude, outcomes: [
            .success(usage),
            .failure(FetchError.server(500))
        ])
        let store = makeStore([claude])
        await store.refreshAll()
        await store.refreshAll()
        guard case .stale(let kept, _) = store.states[.claude] else {
            return XCTFail("expected .stale, got \(String(describing: store.states[.claude]))")
        }
        XCTAssertEqual(kept, usage)
    }

    func testOfflineDropsPreviousValue() async {
        let usage = makeUsage(.claude, percent: 20)
        let claude = FakeProvider(id: .claude, outcomes: [
            .success(usage),
            .failure(FetchError.offline)
        ])
        let store = makeStore([claude])
        await store.refreshAll()
        XCTAssertEqual(store.states[.claude], .ok(usage))
        await store.refreshAll()
        XCTAssertEqual(store.states[.claude], .offline)
    }

    func testParseErrorMapsToError() async {
        let claude = FakeProvider(id: .claude, outcomes: [.failure(FetchError.parse("bad json"))])
        let store = makeStore([claude])
        await store.refreshAll()
        XCTAssertEqual(store.states[.claude], .error("bad json"))
    }

    func testOtherErrorMapsToError() async {
        let claude = FakeProvider(id: .claude, outcomes: [.failure(FetchError.other("weird"))])
        let store = makeStore([claude])
        await store.refreshAll()
        XCTAssertEqual(store.states[.claude], .error("weird"))
    }

    func testNonFetchErrorAlsoMapsToError() async {
        struct CustomError: Error {}
        let claude = FakeProvider(id: .claude, outcomes: [.failure(CustomError())])
        let store = makeStore([claude])
        await store.refreshAll()
        // Unknown errors get a short human string, not `String(describing:
        // error)` — the row must never show a raw enum dump or leak URL /
        // header material.
        XCTAssertEqual(store.states[.claude], .error("Unexpected error"))
    }

    func testRawURLErrorIsMappedThroughHTTPErrorMapper() async {
        // A provider that lets a bare URLError.notConnectedToInternet
        // bubble out (rather than translating it to `.offline` itself)
        // must still land in the offline state.
        let claude = FakeProvider(id: .claude, outcomes: [
            .failure(URLError(.notConnectedToInternet))
        ])
        let store = makeStore([claude])
        await store.refreshAll()
        XCTAssertEqual(store.states[.claude], .offline)
    }

    func testRawURLErrorTimeoutIsMappedToStaleWithPrevious() async {
        // URLError.timedOut → FetchError.timeout → stale (keep last value)
        // when there is a prior successful fetch.
        let usage = makeUsage(.claude, percent: 30)
        let claude = FakeProvider(id: .claude, outcomes: [
            .success(usage),
            .failure(URLError(.timedOut))
        ])
        let store = makeStore([claude])
        await store.refreshAll()
        await store.refreshAll()
        guard case .stale(let kept, _) = store.states[.claude] else {
            return XCTFail("expected .stale, got \(String(describing: store.states[.claude]))")
        }
        XCTAssertEqual(kept, usage)
    }

    func testTimeoutWithoutPreviousBecomesError() async {
        let claude = FakeProvider(id: .claude, outcomes: [.failure(FetchError.timeout)])
        let store = makeStore([claude])
        await store.refreshAll()
        XCTAssertEqual(store.states[.claude], .error("Timed out"))
    }

    func testTimeoutWithPreviousBecomesStale() async {
        let usage = makeUsage(.claude, percent: 42)
        let claude = FakeProvider(id: .claude, outcomes: [
            .success(usage),
            .failure(FetchError.timeout)
        ])
        let store = makeStore([claude])
        await store.refreshAll()
        await store.refreshAll()
        guard case .stale(let kept, _) = store.states[.claude] else {
            return XCTFail("expected .stale, got \(String(describing: store.states[.claude]))")
        }
        XCTAssertEqual(kept, usage)
    }

    func testConsecutiveStaleFailuresPreserveOriginalSinceDate() async {
        // The "As of 12 min ago" line should measure from when the data
        // *actually* went stale — not from the most recent failed retry.
        let usage = makeUsage(.claude, percent: 20)
        let claude = FakeProvider(id: .claude, outcomes: [
            .success(usage),
            .failure(FetchError.server(500)),
            .failure(FetchError.server(500))
        ])
        let store = makeStore([claude])
        await store.refreshAll()
        // First failure at clock = T.
        let firstFailAt = clock.now.addingTimeInterval(60)
        clock.set(firstFailAt)
        await store.refreshAll()
        guard case .stale(_, let firstSince) = store.states[.claude] else {
            return XCTFail("expected .stale after first failure")
        }
        XCTAssertEqual(firstSince, firstFailAt)

        // Second failure some time later — since must not be pushed forward.
        clock.set(firstFailAt.addingTimeInterval(120))
        await store.refreshAll()
        guard case .stale(_, let secondSince) = store.states[.claude] else {
            return XCTFail("expected .stale after second failure")
        }
        XCTAssertEqual(secondSince, firstSince, "since must be preserved across consecutive stale transitions")
    }

    func testLastRefreshDoesNotAdvanceWhenAllProvidersFail() async {
        // A refresh where every provider fails / times out / goes offline
        // must not touch lastRefresh: the popover's "Updated N min ago"
        // must not lie about having fresh data.
        let usage = makeUsage(.claude, percent: 20)
        let claude = FakeProvider(id: .claude, outcomes: [
            .success(usage),
            .failure(FetchError.server(500))
        ])
        let codex = FakeProvider(id: .codex, outcomes: [
            .failure(FetchError.offline),
            .failure(FetchError.offline)
        ])
        let cursor = FakeProvider(id: .cursor, outcomes: [
            .failure(FetchError.timeout),
            .failure(FetchError.timeout)
        ])
        let store = makeStore([claude, codex, cursor])

        // First refresh: Claude succeeds → lastRefresh advances.
        await store.refreshAll()
        let firstStamp = store.lastRefresh
        XCTAssertNotNil(firstStamp)

        // Advance the clock, then run a refresh in which nothing succeeds.
        clock.set(clock.now.addingTimeInterval(600))
        await store.refreshAll()
        XCTAssertEqual(store.lastRefresh, firstStamp,
                       "lastRefresh must not advance when no provider succeeded")
    }

    func testLastRefreshStartsNilAndAdvancesOnFirstSuccess() async {
        let usage = makeUsage(.claude)
        let claude = FakeProvider(id: .claude, outcomes: [
            .failure(FetchError.offline),
            .success(usage)
        ])
        let store = makeStore([claude])
        XCTAssertNil(store.lastRefresh)
        // First refresh fails → lastRefresh still nil.
        await store.refreshAll()
        XCTAssertNil(store.lastRefresh, "no successes yet")
        // Second refresh succeeds → advances.
        clock.set(clock.now.addingTimeInterval(60))
        await store.refreshAll()
        XCTAssertEqual(store.lastRefresh, clock.now)
    }

    func testNotInstalledIsHidden() async {
        let claude = FakeProvider(id: .claude, installed: false, outcomes: [])
        let store = makeStore([claude])
        await store.refreshAll()
        XCTAssertEqual(store.states[.claude], .hidden)
        XCTAssertEqual(claude.callCount, 0, "fetch must not be called on uninstalled providers")
    }

    func testDisabledProviderIsHidden() async {
        let usage = makeUsage(.claude)
        let claude = FakeProvider(id: .claude, outcomes: [.success(usage)])
        let c = clock
        let store = UsageStore(
            providers: [claude],
            enabledProviders: [],
            clock: { c.now }
        )
        await store.refreshAll()
        XCTAssertEqual(store.states[.claude], .hidden)
        XCTAssertEqual(claude.callCount, 0)
    }
}

@MainActor
final class UsageStoreParallelIsolationTests: XCTestCase {

    private let clock = MockClock(Date(timeIntervalSince1970: 1_700_000_000))

    /// One provider throwing must not affect the others' outcomes.
    func testOneFailureDoesNotAffectOthers() async {
        let claudeUsage = makeUsage(.claude, percent: 22)
        let cursorUsage = makeUsage(.cursor, percent: 88)
        let claude = FakeProvider(id: .claude, outcomes: [.success(claudeUsage)])
        let codex = FakeProvider(id: .codex, outcomes: [.failure(FetchError.server(500))])
        let cursor = FakeProvider(id: .cursor, outcomes: [.success(cursorUsage)])

        let c = clock
        let store = UsageStore(
            providers: [claude, codex, cursor],
            clock: { c.now }
        )
        await store.refreshAll()
        XCTAssertEqual(store.states[.claude], .ok(claudeUsage))
        XCTAssertEqual(store.states[.cursor], .ok(cursorUsage))
        guard case .error = store.states[.codex] else {
            return XCTFail("expected codex .error, got \(String(describing: store.states[.codex]))")
        }
    }
}

@MainActor
final class UsageStoreRetryAfterTests: XCTestCase {

    private let clock = MockClock(Date(timeIntervalSince1970: 1_700_000_000))

    private func makeStore(_ providers: [FakeProvider]) -> UsageStore {
        let c = clock
        return UsageStore(
            providers: providers,
            enabledProviders: Set(ProviderID.allCases),
            clock: { c.now }
        )
    }

    /// A 429 with `Retry-After: 3600` puts the provider on ice; a follow-up
    /// `refreshAll` before the deadline must not fetch it. After the
    /// deadline, it is fetched normally.
    func testRetryAfterSkipsProviderUntilDeadline() async {
        let baseline = makeUsage(.claude, percent: 20)
        let recovered = makeUsage(.claude, percent: 25)
        let claude = FakeProvider(id: .claude, outcomes: [
            .success(baseline),
            .failure(FetchError.rateLimited(retryAfter: 3600)),
            .success(recovered)
        ])
        let store = makeStore([claude])

        // First fetch succeeds.
        await store.refreshAll()
        XCTAssertEqual(store.states[.claude], .ok(baseline))
        XCTAssertEqual(claude.callCount, 1)

        // Second fetch: 429 with Retry-After 3600 → stale, provider iced.
        clock.advance(by: 60)
        await store.refreshAll()
        guard case .stale(let kept, _) = store.states[.claude] else {
            return XCTFail("expected .stale, got \(String(describing: store.states[.claude]))")
        }
        XCTAssertEqual(kept, baseline)
        XCTAssertEqual(claude.callCount, 2)

        // Third refreshAll fires 30 s later — still well inside the retry-
        // after window. Provider must not be called.
        clock.advance(by: 30)
        await store.refreshAll()
        XCTAssertEqual(claude.callCount, 2, "provider must not be called while Retry-After deadline is in the future")
        guard case .stale = store.states[.claude] else {
            return XCTFail("expected .stale to persist, got \(String(describing: store.states[.claude]))")
        }

        // Advance past the retry-after deadline → provider fetched again.
        clock.advance(by: 3600)
        await store.refreshAll()
        XCTAssertEqual(claude.callCount, 3)
        XCTAssertEqual(store.states[.claude], .ok(recovered))
    }
}

@MainActor
final class UsageStoreSingleFlightTests: XCTestCase {

    private let clock = MockClock(Date(timeIntervalSince1970: 1_700_000_000))

    /// Two overlapping `refreshAll()` calls must result in exactly one
    /// `fetch()` per provider. Otherwise a timer tick + wake, or popover
    /// open + centre click, would double-hit the vendor endpoints and
    /// could overwrite newer results with older ones.
    func testConcurrentRefreshAllCollapsesToSingleFetch() async {
        let usage = makeUsage(.claude, percent: 25)
        let suspending = SuspendingProvider(id: .claude, usage: usage)
        let c = clock
        let store = UsageStore(
            providers: [suspending],
            enabledProviders: [.claude],
            clock: { c.now }
        )

        async let a: Void = store.refreshAll()
        async let b: Void = store.refreshAll()

        // Give the leader time to enter performRefresh, spawn the group
        // task, and reach the suspension inside fetch().
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(suspending.callCount, 1,
                       "overlapping refreshAll calls must share a single fetch")

        suspending.release()
        _ = await (a, b)
        XCTAssertEqual(suspending.callCount, 1)
        XCTAssertEqual(store.states[.claude], .ok(usage))
    }

    /// A subsequent (non-overlapping) `refreshAll()` after the previous
    /// one has completed must fire a fresh fetch — the single-flight guard
    /// is per in-flight call, not a one-shot.
    func testSubsequentRefreshAllAfterCompletionStartsNewFetch() async {
        let usage = makeUsage(.claude)
        let claude = FakeProvider(id: .claude, outcomes: [
            .success(usage),
            .success(usage)
        ])
        let c = clock
        let store = UsageStore(
            providers: [claude],
            enabledProviders: [.claude],
            clock: { c.now }
        )
        await store.refreshAll()
        await store.refreshAll()
        XCTAssertEqual(claude.callCount, 2)
    }
}

@MainActor
final class UsageStoreStreamingResultsTests: XCTestCase {

    private let clock = MockClock(Date(timeIntervalSince1970: 1_700_000_000))

    /// Fast providers must land in `.ok` while a slow provider is still in
    /// flight — the store must not batch state updates to end-of-refresh.
    func testFastProvidersApplyBeforeSlowOneCompletes() async {
        let claudeUsage = makeUsage(.claude, percent: 20)
        let codexUsage = makeUsage(.codex, percent: 40)
        let cursorUsage = makeUsage(.cursor, percent: 60)
        let claude = FakeProvider(id: .claude, outcomes: [.success(claudeUsage)])
        let codex = FakeProvider(id: .codex, outcomes: [.success(codexUsage)])
        let cursor = SuspendingProvider(id: .cursor, usage: cursorUsage)

        let c = clock
        let store = UsageStore(
            providers: [claude, codex, cursor],
            enabledProviders: Set(ProviderID.allCases),
            clock: { c.now }
        )
        let task = Task { await store.refreshAll() }

        // Yield until the fast providers have been drained by the group
        // loop and their state has been applied.
        for _ in 0..<100 {
            if store.states[.claude] == .ok(claudeUsage) &&
                store.states[.codex] == .ok(codexUsage) {
                break
            }
            await Task.yield()
        }
        XCTAssertEqual(store.states[.claude], .ok(claudeUsage),
                       "fast provider must be applied while slow one is pending")
        XCTAssertEqual(store.states[.codex], .ok(codexUsage))
        XCTAssertEqual(store.states[.cursor], .loading,
                       "slow provider still suspended")

        cursor.release()
        await task.value
        XCTAssertEqual(store.states[.cursor], .ok(cursorUsage))
    }
}

@MainActor
final class UsageStoreEnabledFlagTests: XCTestCase {

    private let clock = MockClock(Date(timeIntervalSince1970: 1_700_000_000))

    /// If the user disables a provider *while its fetch is in flight*, the
    /// result must not be applied when it eventually arrives — the ring must
    /// stay hidden. Without this guard the newly-hidden ring would pop back
    /// into view for one popover paint, which the user just went to Settings
    /// to switch off.
    func testDisableMidFlightKeepsResultHidden() async {
        let usage = makeUsage(.claude, percent: 25)
        let suspending = SuspendingProvider(id: .claude, usage: usage)
        let c = clock
        let store = UsageStore(
            providers: [suspending],
            enabledProviders: [.claude],
            clock: { c.now }
        )

        let task = Task { await store.refreshAll() }
        // Give the store time to spawn the group task and reach the
        // suspension inside `fetch()`.
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(suspending.callCount, 1,
                       "provider should be mid-flight before we disable it")

        // Disable while the fetch is still suspended.
        store.setEnabledProviders([])
        XCTAssertEqual(store.states[.claude], .hidden)

        // Let the fetch complete. The result must not be applied.
        suspending.release()
        await task.value
        XCTAssertEqual(store.states[.claude], .hidden,
                       "an in-flight success must not overwrite a mid-flight disable")
    }

    /// Re-enabling a provider *while another refresh is in flight* must
    /// fetch it immediately, not wait for the next timer tick. The general
    /// `refreshAll()` path single-flights and joins the running call, whose
    /// candidate snapshot was taken before the toggle — so it would skip
    /// the newly enabled provider. The fix is `refreshProviders(_:)`, which
    /// bypasses the single-flight guard for a targeted subset.
    func testReenableDuringInFlightRefreshFetchesNewlyEnabled() async {
        let claudeUsage = makeUsage(.claude, percent: 20)
        let codexUsage = makeUsage(.codex, percent: 30)
        let claude = SuspendingProvider(id: .claude, usage: claudeUsage)
        let codex = FakeProvider(id: .codex, outcomes: [.success(codexUsage)])
        let c = clock
        let store = UsageStore(
            providers: [claude, codex],
            enabledProviders: [.claude], // codex initially disabled
            clock: { c.now }
        )

        // Start the general refresh; Claude suspends inside fetch().
        let generalRefresh = Task { await store.refreshAll() }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(claude.callCount, 1)
        XCTAssertEqual(codex.callCount, 0, "codex is disabled — not part of the snapshot")

        // Enable Codex mid-flight, then run a targeted refresh for it.
        store.setEnabledProviders([.claude, .codex])
        await store.refreshProviders([.codex])
        XCTAssertEqual(codex.callCount, 1,
                       "newly enabled provider must be fetched immediately, not wait for next tick")
        XCTAssertEqual(store.states[.codex], .ok(codexUsage))

        // Let the still-running general refresh complete.
        claude.release()
        await generalRefresh.value
        XCTAssertEqual(store.states[.claude], .ok(claudeUsage))
    }

    /// A targeted fetch already in flight must not be fetched a second
    /// time when a general refresh runs concurrently. Otherwise two
    /// requests would race and an older result could clobber a newer one
    /// (or clobber a `retryAfter` set by a concurrent 429).
    func testTargetedFetchInFlightBlocksConcurrentRefreshAll() async {
        let claudeUsage = makeUsage(.claude, percent: 25)
        let codexUsage = makeUsage(.codex, percent: 40)
        let claude = SuspendingProvider(id: .claude, usage: claudeUsage)
        let codex = FakeProvider(id: .codex, outcomes: [.success(codexUsage)])
        let c = clock
        let store = UsageStore(
            providers: [claude, codex],
            enabledProviders: [.claude, .codex],
            clock: { c.now }
        )

        // Targeted fetch of Claude only; Claude suspends inside fetch().
        let targeted = Task { await store.refreshProviders([.claude]) }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(claude.callCount, 1)

        // Concurrent refreshAll must not spawn a second fetch for Claude,
        // but must still fetch Codex.
        await store.refreshAll()
        XCTAssertEqual(claude.callCount, 1,
                       "Claude was already in flight — refreshAll must not spawn a duplicate")
        XCTAssertEqual(codex.callCount, 1)
        XCTAssertEqual(store.states[.codex], .ok(codexUsage))

        // Let the suspended targeted fetch complete.
        claude.release()
        await targeted.value
        XCTAssertEqual(store.states[.claude], .ok(claudeUsage))
        XCTAssertEqual(claude.callCount, 1)
    }

    /// The nastier variant of the race: refreshAll is fetching Claude,
    /// user toggles Claude off, then back on mid-flight. There must be no
    /// second concurrent fetch, and once the original in-flight result
    /// arrives it must be applied (since Claude is enabled again by then).
    func testToggleOffOnDuringInFlightRefreshAppliesOriginalResult() async {
        let usage = makeUsage(.claude, percent: 55)
        let claude = SuspendingProvider(id: .claude, usage: usage)
        let c = clock
        let store = UsageStore(
            providers: [claude],
            enabledProviders: [.claude],
            clock: { c.now }
        )

        // Start refreshAll; Claude suspends inside fetch().
        let refresh = Task { await store.refreshAll() }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(claude.callCount, 1)

        // Toggle Claude off — apply loop will hide it when result arrives.
        store.setEnabledProviders([])
        // Toggle back on — sets state to .loading, then a targeted refresh
        // for the "newly enabled" set: Claude. Because Claude is still in
        // flight, the targeted fetch must not spawn a second fetch.
        store.setEnabledProviders([.claude])
        await store.refreshProviders([.claude])
        XCTAssertEqual(claude.callCount, 1,
                       "Claude was still in flight — targeted re-enable must not spawn a duplicate")

        // Release the original in-flight fetch. Its result must be
        // applied because Claude is enabled again.
        claude.release()
        await refresh.value
        XCTAssertEqual(store.states[.claude], .ok(usage),
                       "the original in-flight result must land as .ok since Claude was re-enabled by the time it arrived")
    }

    /// A targeted `refreshProviders` must not advance the global
    /// `lastRefresh` — otherwise the popover centre would say "Updated
    /// now" while other rings might be minutes old, and the popover-open
    /// staleness check would suppress the next 60 s refresh.
    func testRefreshProvidersDoesNotAdvanceLastRefresh() async {
        let usage = makeUsage(.claude, percent: 20)
        let claude = FakeProvider(id: .claude, outcomes: [.success(usage)])
        let c = clock
        let store = UsageStore(
            providers: [claude],
            enabledProviders: [.claude],
            clock: { c.now }
        )
        XCTAssertNil(store.lastRefresh, "precondition: no successful general refresh yet")
        await store.refreshProviders([.claude])
        XCTAssertEqual(store.states[.claude], .ok(usage),
                       "the targeted fetch must still update the ring state")
        XCTAssertNil(store.lastRefresh,
                     "targeted fetch must not touch the global lastRefresh timestamp")
    }

    /// A targeted `refreshProviders` call with a disabled ID must not
    /// fetch it, and must not overwrite state.
    func testRefreshProvidersSkipsDisabledIDs() async {
        let usage = makeUsage(.codex, percent: 40)
        let codex = FakeProvider(id: .codex, outcomes: [.success(usage)])
        let c = clock
        let store = UsageStore(
            providers: [codex],
            enabledProviders: [], // disabled
            clock: { c.now }
        )
        await store.refreshProviders([.codex])
        XCTAssertEqual(codex.callCount, 0)
        XCTAssertEqual(store.states[.codex], .hidden)
    }

    func testSetEnabledProvidersHidesDisabledAndMarksNewlyEnabledLoading() async {
        let usage = makeUsage(.claude, percent: 40)
        let claude = FakeProvider(id: .claude, outcomes: [.success(usage), .success(usage)])
        let c = clock
        let store = UsageStore(
            providers: [claude],
            enabledProviders: [.claude],
            clock: { c.now }
        )
        await store.refreshAll()
        XCTAssertEqual(store.states[.claude], .ok(usage))

        // Disable Claude → hidden immediately, no fetch on the next refresh.
        store.setEnabledProviders([])
        XCTAssertEqual(store.states[.claude], .hidden)
        await store.refreshAll()
        XCTAssertEqual(claude.callCount, 1, "disabled provider must not be fetched")

        // Re-enable Claude → back to loading, fetched on next refresh.
        store.setEnabledProviders([.claude])
        XCTAssertEqual(store.states[.claude], .loading)
        await store.refreshAll()
        XCTAssertEqual(store.states[.claude], .ok(usage))
        XCTAssertEqual(claude.callCount, 2)
    }
}
