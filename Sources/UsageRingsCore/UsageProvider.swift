import Foundation

/// One usage provider — Claude, Codex, or Cursor — abstracted so the store
/// can drive them uniformly and tests can substitute fakes.
///
/// Implementations are `Sendable` because the store fans them out across a
/// task group. `isInstalled()` is `async` because at least one implementation
/// (Claude) has to fork `/usr/bin/security` to answer, and running that
/// synchronously would either block the main actor or spawn a background
/// thread every 300 s just for a "does the item exist" check. Providers that
/// can answer instantly (Codex file-exists check, Cursor DB open) still
/// implement the requirement with an `async` function that just returns —
/// there is no runtime cost to marking a body `async` when it does not
/// suspend.
///
/// The store calls `isInstalled()` from inside each provider's child task in
/// its refresh task group — never on the main actor — so a slow answer for
/// one provider never blocks the others' rings from updating.
///
/// A provider that is not installed is hidden — its ring is not drawn and
/// `fetch()` is not called.
public protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    func isInstalled() async -> Bool
    func fetch() async throws -> ProviderUsage
}

/// Classified failure surfaced by a `UsageProvider.fetch()` call.
///
/// Providers translate transport-level errors (HTTP status, `URLError`) to
/// one of these cases; the store then maps them to a `ProviderState`.
///
/// `Equatable` conformance is convenient for tests — it does not compare
/// associated `String` payloads case-insensitively or anything clever, it is
/// the derived synthesised comparison.
public enum FetchError: Error, Equatable, Sendable {
    /// 401 / 403 or an equivalent local signal. `String` is the "Open <Tool>
    /// to refresh" hint the row displays.
    case signedOut(String)
    /// 429. `retryAfter` is parsed from the `Retry-After` header, in seconds.
    case rateLimited(retryAfter: TimeInterval?)
    /// 5xx.
    case server(Int)
    /// The request timed out. Distinct from `.offline` — a slow but
    /// reachable endpoint should keep the last usage value visible (stale)
    /// rather than dropping to the "No internet" state.
    case timeout
    /// No connectivity — `URLError.notConnectedToInternet` and friends.
    case offline
    /// Body was received but could not be parsed.
    case parse(String)
    /// Anything else the provider decides is not a crash but not classifiable.
    case other(String)
}
