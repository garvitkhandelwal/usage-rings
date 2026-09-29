import Foundation
import Observation

/// In-memory store of per-provider `ProviderState`, driven by parallel
/// `UsageProvider.fetch()` calls. This is the object the SwiftUI views bind
/// to.
///
/// Design notes:
///  - `@MainActor` because SwiftUI reads it on the main thread; `@Observable`
///    so field changes trigger view updates.
///  - No persistence: on relaunch we start from `.loading` and refetch.
///  - `refreshAll()` runs enabled+installed providers in parallel with a
///    task group. Each provider's result is applied to `states` the moment
///    it arrives — a slow provider never blocks the others' rings from
///    updating.
///  - `refreshAll()` is single-flight: overlapping callers (timer tick +
///    wake, popover open + centre click, wake + manual refresh) join the
///    in-flight call rather than firing a second concurrent fetch. Without
///    this guard, overlapping calls would double-hit the vendor endpoints,
///    bypass `Retry-After`, and could overwrite newer results with older
///    ones.
///  - A `Retry-After` from a 429 response causes the store to skip that
///    provider on later `refreshAll()` calls until the retry time passes —
///    the previous `.stale` value stays visible in the meantime.
///  - `lastRefresh` advances only when at least one provider succeeded on
///    that refresh: it is the "last time the popover really has current
///    data" for at least one ring, not a wall-clock ping.
///  - Clock is injected so tests can pin `lastRefresh` and the retry-after
///    deadline; production passes `Date()`.
@MainActor
@Observable
public final class UsageStore {

    /// Current state per provider. Providers not present here are treated as
    /// `.hidden` by the UI.
    public private(set) var states: [ProviderID: ProviderState] = [:]

    /// Wall-clock time of the last `refreshAll()` in which at least one
    /// provider fetch succeeded. Not advanced when every provider failed,
    /// timed out, went offline or was skipped: in those cases the popover
    /// still shows the previous "Updated N min ago" text.
    public private(set) var lastRefresh: Date? = nil

    /// Providers currently enabled in Settings. Disabled providers are not
    /// fetched and are rendered as `.hidden`.
    public private(set) var enabledProviders: Set<ProviderID>

    private let providers: [ProviderID: any UsageProvider]
    private let clock: @Sendable () -> Date

    /// Wall-clock time until which a given provider should not be re-fetched
    /// because it returned a 429 with a `Retry-After` value. Cleared on the
    /// next successful fetch.
    private var retryAfter: [ProviderID: Date] = [:]

    /// The currently in-flight `refreshAll()` task, if any. See the
    /// single-flight note in the class docstring.
    private var currentTask: Task<Void, Never>?

    /// Per-provider in-flight guard. A provider ID is added the moment
    /// its child task is spawned and removed the moment its result has
    /// been applied to `states`. Both `refreshAll` and
    /// `refreshProviders(_:)` consult this set and skip any provider
    /// that is already in flight, so:
    ///
    ///  - a Refresh / timer / wake tick during a targeted re-enable fetch
    ///    never spawns a second concurrent fetch for the same provider,
    ///  - a targeted re-enable during a running `refreshAll` waits on
    ///    the running fetch's result rather than firing another one,
    ///  - late results from an older fetch cannot race a newer one to
    ///    clobber `retryAfter` or turn fresh `.ok` back into `.stale`.
    private var inFlight: Set<ProviderID> = []

    public init(
        providers: [any UsageProvider],
        enabledProviders: Set<ProviderID> = Set(ProviderID.allCases),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        var byID: [ProviderID: any UsageProvider] = [:]
        for provider in providers { byID[provider.id] = provider }
        self.providers = byID
        self.enabledProviders = enabledProviders
        self.clock = clock
        // Seed initial states: enabled → loading, others → hidden. Actual
        // installation status is only checked when we go to fetch.
        for id in ProviderID.allCases {
            states[id] = enabledProviders.contains(id) ? .loading : .hidden
        }
    }

    /// Update the enabled-provider set. Newly-disabled providers switch to
    /// `.hidden` immediately; newly-enabled providers are marked `.loading`
    /// until the next refresh completes.
    public func setEnabledProviders(_ enabled: Set<ProviderID>) {
        self.enabledProviders = enabled
        for id in ProviderID.allCases {
            if !enabled.contains(id) {
                states[id] = .hidden
            } else if case .hidden = states[id] ?? .hidden {
                // Was hidden (either not installed or previously disabled)
                // — mark loading so the next refresh shows a spinner rather
                // than staying blank.
                states[id] = .loading
            }
        }
    }

    /// Fetch every enabled+installed provider in parallel and map outcomes
    /// into `ProviderState`. Called by the refresh scheduler, by popover
    /// open (if stale), by the wake notification, and by the Refresh
    /// button.
    ///
    /// Single-flight: if a previous call is still running, this call awaits
    /// it and returns without firing a fresh set of requests.
    public func refreshAll() async {
        if let running = currentTask {
            await running.value
            return
        }
        let task: Task<Void, Never> = Task { [weak self] in
            if let self {
                await self.performRefresh()
            }
        }
        currentTask = task
        await task.value
        // Only the leader ever reaches here; waiters returned above.
        currentTask = nil
    }

    private func performRefresh() async {
        let toConsider = collectCandidates(ids: nil)
        await runFetch(for: toConsider, advanceLastRefresh: true)
    }

    /// Fetch a specific subset of providers, bypassing the general
    /// single-flight guard on `refreshAll`.
    ///
    /// Used when Settings enables a provider mid-flight: `refreshAll()`
    /// would collapse into the running call and skip the newly enabled
    /// provider (its snapshot was taken *before* the toggle), leaving it
    /// as a spinner for up to one refresh interval. This method starts a
    /// targeted fetch for the given IDs so the newly enabled ring loads
    /// immediately.
    ///
    /// Per-provider in-flight guard: if any of the requested IDs is
    /// already being fetched by another call (targeted or general) the
    /// duplicate is dropped. The result of the already-running fetch will
    /// land through the normal apply loop; if the provider was re-enabled
    /// in the meantime it will end up `.ok` at that point without a second
    /// network round-trip.
    ///
    /// The result-apply loop still re-checks `enabledProviders`, so if the
    /// user flips the toggle off again before this returns the ring stays
    /// hidden.
    ///
    /// A targeted fetch does NOT advance the global `lastRefresh` — that
    /// timestamp is the "at least one ring has genuinely current data
    /// across the whole set" reading used by the popover-open staleness
    /// check. If a single-provider refresh advanced it, the centre would
    /// read "Updated now" while other rings might be minutes old.
    public func refreshProviders(_ ids: Set<ProviderID>) async {
        guard !ids.isEmpty else { return }
        let toConsider = collectCandidates(ids: ids)
        await runFetch(for: toConsider, advanceLastRefresh: false)
    }

    /// Collect the `(id, provider)` pairs eligible for fetching this pass.
    ///
    /// - If `ids` is nil, iterate all providers (the `refreshAll` path).
    /// - Otherwise iterate only the given IDs (the targeted-refresh path).
    ///
    /// Disabled, unregistered and retry-after-iced providers are filtered
    /// out. `.hidden` is *not* written here for the targeted path — a
    /// caller asking for a specific ID that happens to be disabled just
    /// gets an empty list; the store's state stays as it was.
    private func collectCandidates(ids: Set<ProviderID>?) -> [(ProviderID, any UsageProvider)] {
        let startedAt = clock()
        var out: [(ProviderID, any UsageProvider)] = []
        let iterate: [ProviderID] = ids.map { ids in
            ProviderID.allCases.filter { ids.contains($0) }
        } ?? ProviderID.allCases

        for id in iterate {
            guard enabledProviders.contains(id) else {
                // On the general refresh path we also proactively write
                // `.hidden` for disabled providers so the popover shows a
                // fresh view. On the targeted path we skip in silence.
                if ids == nil { states[id] = .hidden }
                continue
            }
            guard let provider = providers[id] else {
                if ids == nil { states[id] = .hidden }
                continue
            }
            if inFlight.contains(id) {
                // Already being fetched by another call — do not spawn a
                // duplicate. Its result will land through the apply loop
                // when the running fetch completes.
                continue
            }
            if let until = retryAfter[id], until > startedAt {
                // Retry-After is still in effect. Leave the current state
                // (should be `.stale` or `.error`) untouched.
                continue
            }
            out.append((id, provider))
        }
        return out
    }

    /// Run the given fetch batch in parallel and apply results as they
    /// arrive.
    ///
    /// - Parameter advanceLastRefresh: only the `refreshAll` path passes
    ///   `true` — a single-provider targeted fetch must not touch the
    ///   global "at least one ring is genuinely current across the whole
    ///   set" timestamp used by the popover-open staleness check.
    ///
    /// The `inFlight` set is written on the way in and cleared as each
    /// result is applied so no two callers can race the same provider.
    private func runFetch(for candidates: [(ProviderID, any UsageProvider)], advanceLastRefresh: Bool) async {
        // Reserve every candidate under the in-flight guard before we
        // spawn any tasks. From this point on any other caller iterating
        // `collectCandidates` will skip these IDs.
        for (id, _) in candidates {
            inFlight.insert(id)
        }
        var anySucceeded = false
        await withTaskGroup(of: (ProviderID, ProviderOutcome).self) { group in
            for (id, provider) in candidates {
                group.addTask {
                    // `isInstalled()` runs inside the child task, not on
                    // the main actor. Two reasons: (1) the Claude
                    // implementation forks `/usr/bin/security`, which can
                    // pause for tens of ms — blocking the main actor
                    // there would freeze the popover; (2) doing it in
                    // parallel with the other providers means one slow
                    // presence check never delays the others' rings from
                    // updating.
                    guard await provider.isInstalled() else {
                        return (id, .notInstalled)
                    }
                    do {
                        let usage = try await provider.fetch()
                        return (id, .success(usage))
                    } catch {
                        return (id, .failure(error))
                    }
                }
            }
            // Apply each result the moment it arrives — the slowest
            // provider must not delay the others' rings from updating.
            for await (id, outcome) in group {
                // Clear the in-flight guard for this provider before any
                // early-continue below, so a follow-up refreshAll or
                // refreshProviders can pick it up again on the next call.
                inFlight.remove(id)
                // The user may have disabled this provider *during* the
                // in-flight fetch (Settings toggle → mid-refresh). If so,
                // do not apply the result: the ring was hidden the moment
                // they flipped the toggle and must stay hidden. Without
                // this guard a newly-disabled ring would flicker back
                // into view for one popover paint when its request
                // returned.
                guard enabledProviders.contains(id) else {
                    states[id] = .hidden
                    // Clear any lingering retry-after so re-enabling the
                    // provider does not silently skip the next refresh.
                    retryAfter[id] = nil
                    continue
                }
                let arrivedAt = clock()
                switch outcome {
                case .notInstalled:
                    states[id] = .hidden
                case .success(let usage):
                    states[id] = .ok(usage)
                    retryAfter[id] = nil
                    anySucceeded = true
                case .failure(let error):
                    let fetchError = normalise(error)
                    let previous = states[id]
                    states[id] = mapFailure(
                        fetchError,
                        previous: previous,
                        now: arrivedAt,
                        id: id
                    )
                }
            }
        }

        // Only advance lastRefresh when the caller ran the general refresh
        // path AND at least one ring has genuinely current data. If every
        // provider failed / timed out / went offline, or if this was a
        // targeted single-provider fetch, the popover keeps the previous
        // "Updated N min ago".
        if advanceLastRefresh && anySucceeded {
            lastRefresh = clock()
        }
    }

    /// Route an arbitrary `Error` into a `FetchError` case.
    ///
    /// - Already a `FetchError` → return unchanged.
    /// - `URLError` → run through `HTTPErrorMapper.mapURLError` so a bare
    ///   `URLError.notConnectedToInternet` thrown by a provider (or by an
    ///   injected transport in tests) is treated as `.offline` and not as
    ///   a "raw error dump" `.other`.
    /// - Anything else → a short human `.other("Unexpected error")`. We do
    ///   *not* stringify the underlying error: `String(describing:)` can
    ///   leak URLs, header names or other details that make poor row text.
    private func normalise(_ error: Error) -> FetchError {
        if let fetchError = error as? FetchError { return fetchError }
        if let urlError = error as? URLError { return HTTPErrorMapper.mapURLError(urlError) }
        return .other("Unexpected error")
    }

    private func mapFailure(
        _ error: FetchError,
        previous: ProviderState?,
        now: Date,
        id: ProviderID
    ) -> ProviderState {
        switch error {
        case .signedOut(let reason):
            retryAfter[id] = nil
            return .signedOut(reason: reason)

        case .rateLimited(let seconds):
            if let seconds {
                retryAfter[id] = now.addingTimeInterval(seconds)
            } else {
                retryAfter[id] = nil
            }
            if let last = previousUsage(from: previous) {
                return .stale(last, since: staleSince(from: previous, fallback: now))
            }
            return .error("Rate limited")

        case .server(let code):
            retryAfter[id] = nil
            if let last = previousUsage(from: previous) {
                return .stale(last, since: staleSince(from: previous, fallback: now))
            }
            return .error("Server error \(code)")

        case .timeout:
            // A slow but reachable endpoint — keep the last value visible
            // as stale rather than dropping to Offline.
            retryAfter[id] = nil
            if let last = previousUsage(from: previous) {
                return .stale(last, since: staleSince(from: previous, fallback: now))
            }
            return .error("Timed out")

        case .offline:
            retryAfter[id] = nil
            return .offline

        case .parse(let message):
            retryAfter[id] = nil
            return .error(message)

        case .other(let message):
            retryAfter[id] = nil
            return .error(message)
        }
    }

    private func previousUsage(from state: ProviderState?) -> ProviderUsage? {
        switch state {
        case .ok(let usage): return usage
        case .stale(let usage, _): return usage
        default: return nil
        }
    }

    /// Preserve the original stale-since timestamp across consecutive
    /// stale transitions: the "As of 12 min ago" text should measure from
    /// when the data actually went stale, not from the most recent failed
    /// retry. If the previous state was not already stale, use the current
    /// wall-clock time as the fallback.
    private func staleSince(from state: ProviderState?, fallback: Date) -> Date {
        if case .stale(_, let since) = state { return since }
        return fallback
    }

    /// Outcome of one provider's child task in the refresh group.
    ///
    /// `.notInstalled` was previously determined on the main actor before
    /// spawning the task; now we let the child task ask the provider itself
    /// (see `performRefresh`), so we need a third outcome the group loop can
    /// map to `.hidden`.
    private enum ProviderOutcome: Sendable {
        case notInstalled
        case success(ProviderUsage)
        case failure(Error)
    }
}
