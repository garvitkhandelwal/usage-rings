import Foundation

// MARK: - Subprocess runner

/// Small subprocess abstraction so `ClaudeProvider`'s credential reader can
/// be exercised without forking `/usr/bin/security` (and without letting a
/// misbehaving child process hang the tests).
///
/// The API is intentionally narrow: one call, arguments already resolved,
/// returns stdout as `Data` plus the exit status. Standard error is drained
/// but never returned — the security binary's stderr can contain keychain
/// paths and item names we do not want anywhere near an error string that
/// eventually reaches the popover row.
public protocol SecuritySubprocessRunner: Sendable {
    /// Run `executable` with `arguments`, drain stdout and stderr
    /// concurrently while the process runs (so a large stdout does not
    /// deadlock on the pipe buffer), and bound the whole call with a
    /// deadline. If the deadline expires the runner terminates the child
    /// and throws `SecuritySubprocessError.timedOut`.
    ///
    /// Implementations must not leak stderr into the returned value or the
    /// thrown error.
    func run(executable: URL, arguments: [String]) async throws -> (status: Int32, stdout: Data)
}

/// Errors from the subprocess layer. Kept separate from `FetchError` because
/// the credential reader translates these into the caller-facing message
/// itself.
public enum SecuritySubprocessError: Error, Equatable, Sendable {
    /// `Process.run()` threw before the child started.
    case launchFailed
    /// The child did not exit within the runner's deadline.
    case timedOut
}

/// Real subprocess runner.
///
/// Design:
///  - `timeout` is the deadline for the child process to exit. On expiry
///    we send SIGTERM immediately and, if the child is still running 0.5 s
///    later, escalate to SIGKILL — so a child that ignores SIGTERM cannot
///    pin the refresh loop past a small grace period. (The pipe drains
///    are torn down when we return; they do not extend past the deadline.)
///  - Bridging the process's exit is done through `terminationHandler`
///    plus a checked continuation; we never call `waitUntilExit()`, which
///    would block a cooperative-pool thread.
///  - Pipes are drained through `readabilityHandler`, whose callbacks
///    run on a Foundation-owned queue rather than the Swift-concurrency
///    executor. `readDataToEndOfFile()` would block the calling thread
///    for the lifetime of the child; running many refreshes concurrently
///    would starve the cooperative pool.
///
/// Wall-clock budget for one Claude refresh:
///  - `isInstalled()` runs the presence subprocess (bounded by `timeout`),
///    then `fetch()` runs the read subprocess sequentially (bounded by
///    `timeout` again), then the HTTP call (bounded by the 15 s
///    transport timeout).
///  - Worst case = 2 × `timeout` + 15 s. With the default 5 s that is
///    10 s of subprocess + 15 s of HTTP = 25 s per refresh — comfortably
///    within a 300 s refresh interval, and short enough that a hung
///    keychain lookup cannot swallow a whole tick.
public struct ProcessSecurityRunner: SecuritySubprocessRunner {

    /// Maximum wall-clock seconds we wait for one child. Default 5 s so a
    /// presence + read pair stays inside 10 s of subprocess time even
    /// against a slow keychain.
    public let timeout: TimeInterval

    /// Wall-clock grace after SIGTERM before escalating to SIGKILL. Kept
    /// small so a child that ignores SIGTERM does not extend the
    /// user-facing "Claude is stuck" period by much.
    public let killGrace: TimeInterval

    public init(timeout: TimeInterval = 5, killGrace: TimeInterval = 0.5) {
        self.timeout = timeout
        self.killGrace = killGrace
    }

    public func run(executable: URL, arguments: [String]) async throws -> (status: Int32, stdout: Data) {
        do {
            return try await runSubprocess(
                executable: executable,
                arguments: arguments,
                environment: nil,
                currentDirectory: nil,
                timeout: timeout,
                killGrace: killGrace
            )
        } catch SubprocessRunError.launchFailed {
            throw SecuritySubprocessError.launchFailed
        } catch SubprocessRunError.timedOut {
            throw SecuritySubprocessError.timedOut
        }
    }
}

// MARK: - Credential reader

/// Read-only accessor for the `Claude Code-credentials` Keychain item.
///
/// The real implementation runs `/usr/bin/security find-generic-password
/// -s "Claude Code-credentials"` (without `-w`) for presence checks and with
/// `-w` for reads. Tests inject a fake so nothing shells out.
///
/// The returned `Data` is the raw JSON body of the Keychain item. Providers
/// must never write it to disk, log it, or include it in any error message —
/// it holds the access token, refresh token, and account metadata.
public protocol ClaudeCredentialReader: Sendable {
    /// `true` when the Keychain item exists (the presence-check command
    /// exits 0 with the real reader). Async because the real check forks a
    /// subprocess.
    func isPresent() async -> Bool

    /// Read the raw JSON payload of the Keychain item.
    ///
    /// - Throws `FetchError.other("Couldn't read Claude Code credentials from Keychain")`
    ///   when the subprocess fails, times out, or the Keychain item vanishes
    ///   between the presence check and the read.
    /// - Never throws a message that echoes the response body, the stderr of
    ///   the subprocess, or the token itself.
    func read() async throws -> Data
}

/// Runs `/usr/bin/security find-generic-password -s "Claude Code-credentials"`
/// via a subprocess runner.
///
/// Notes:
///  - We never invoke Security.framework directly. The Claude Code CLI
///    stores the item without an ACL entry for our app; using
///    `SecItemCopyMatching` would prompt the user on every refresh after any
///    rebuild.
///  - Presence check uses NO `-w` so the token is not read merely to prove
///    the item exists. `security` exits 0 when the item is found and 44
///    when it is not; other statuses are treated as errors.
///  - Read uses `-w` (raw). `security -w` writes the item value to stdout
///    followed by exactly one LF; we strip that LF so downstream parsing
///    does not care.
///  - Standard error is captured by the runner but never surfaced.
public struct SecuritySubprocessCredentialReader: ClaudeCredentialReader {
    /// Exit code from `/usr/bin/security` when the requested item does not
    /// exist. Documented in `security(1)` and stable across macOS releases.
    public static let itemNotFoundExitCode: Int32 = 44

    private static let executable = URL(fileURLWithPath: "/usr/bin/security")
    private static let serviceName = "Claude Code-credentials"

    private let runner: any SecuritySubprocessRunner

    public init(runner: any SecuritySubprocessRunner = ProcessSecurityRunner()) {
        self.runner = runner
    }

    public func isPresent() async -> Bool {
        // Only exit 44 means "the item is not in the Keychain" — that is
        // the one case where the ring should be
        // hidden. Every other outcome (a locked keychain, exit 1, exit 51,
        // timeout, launch failure, …) means we could not tell whether the
        // item exists. In those cases we return `true` so `fetch()` runs
        // and `read()` surfaces the fixed "Couldn't read Claude Code
        // credentials from Keychain" error row, instead of the ring
        // silently disappearing from the popover.
        do {
            let result = try await runner.run(
                executable: Self.executable,
                arguments: ["find-generic-password", "-s", Self.serviceName]
            )
            return result.status != Self.itemNotFoundExitCode
        } catch {
            return true
        }
    }

    public func read() async throws -> Data {
        let result: (status: Int32, stdout: Data)
        do {
            result = try await runner.run(
                executable: Self.executable,
                arguments: ["find-generic-password", "-s", Self.serviceName, "-w"]
            )
        } catch {
            // Timeout or launch failure — the token is unreachable but the
            // Keychain item may exist. Do not surface the underlying error
            // text; the row reads:
            throw FetchError.other("Couldn't read Claude Code credentials from Keychain")
        }
        // Any non-zero exit — including 44 (item not found, which is a race
        // between the presence check and this call) — is surfaced as a
        // generic read failure. `.other` becomes an error row rather than a
        // hidden ring; on the next refresh `isPresent()` will re-check and
        // hide the ring if the item is really gone.
        guard result.status == 0 else {
            throw FetchError.other("Couldn't read Claude Code credentials from Keychain")
        }
        // `security -w` appends exactly one LF; strip it so downstream
        // JSON parsing does not have to.
        var body = result.stdout
        if body.last == 0x0A { body.removeLast() }
        guard !body.isEmpty else {
            throw FetchError.other("Couldn't read Claude Code credentials from Keychain")
        }
        return body
    }
}

// MARK: - Provider

/// Fetches Claude Code plan usage from `api.anthropic.com`.
///
/// Expiry check: before issuing the usage request, the provider inspects the stored
/// `claudeAiOauth.expiresAt` (parsed tolerantly as ms since epoch;
/// missing or non-numeric → treated as unknown). If the stored expiry
/// has passed, the renewer is called first — an expired token can draw
/// a 429 from the endpoint (with a ~1 h `Retry-After`) instead of a
/// 401, and the app must not fall into a "Rate limited" or
/// long-`Retry-After`-locked-out state for a token it already knows is
/// stale. See `handleExpiredCredentialByRenewing` below.
///
/// The 401 renewal path (`handle401ByRenewingAndRetrying`) is still
/// used as a safety net: when a token that *looks* valid client-side
/// is rejected by the server, that is our only signal to renew.
///
/// Parsing rules:
///  - `five_hour` → window kind `.fiveHour`, label `"5h"`.
///  - `seven_day` → window kind `.weekly`, label `"Weekly"`.
///  - Any other top-level key is ignored (many named-window keys can be
///    non-null on this account).
///  - A key present with `null` → skip (window absent, not an error).
///  - If *neither* `five_hour` nor `seven_day` exists as a key, or if a
///    present window object lacks a numeric `utilization`, → `.parse(...)`.
///    Otherwise a silently-renamed API field would give an `.ok` state
///    with no windows and a blank ring.
///  - Plan name: `nil`.
///
/// Error mapping:
///  - Credential body could not be parsed as JSON → `.parse(_)` (fixed
///    message, never echoes input).
///  - Missing `claudeAiOauth.accessToken` (item exists but the field the
///    CLI stores is not there) → `.signedOut("Open Claude Code to refresh")`.
///  - HTTP 401 → attempt delegated CLI renewal (see below). If renewal
///    succeeded and the retry still returns 401, or renewal itself
///    failed, → `.signedOut("Run \`claude\` in Terminal to sign in")`.
///    Otherwise (renewal disabled, no binary, or in cooldown after a
///    success) → `.signedOut("Open Claude Code to refresh")`. Cooldown
///    that follows a *failed* attempt keeps the "Run `claude` in
///    Terminal" text for the whole cooldown window.
///  - HTTP 403 → `.signedOut("Open Claude Code to refresh")`.
///  - HTTP 429 while the stored `expiresAt` is past →
///    `.signedOut(...)` (no `Retry-After` lock-out).
///  - HTTP 429 with a valid-looking token → `.rateLimited(retryAfter:)`.
///  - HTTP 5xx → `.server(status)`.
///  - `URLError` connectivity codes → `.offline`; `.timedOut` → `.timeout`.
///  - Usage-response body not parseable → `.parse(_)`.
///
/// Delegated renewal: when the CLI
/// token has expired, running the `claude` CLI itself renews the
/// Keychain item. The provider consults the injected `renewer` in two
/// places — the pre-flight expiry check described above, and on an
/// HTTP 401 — and if it returns `.succeeded` re-reads the credential
/// and retries the usage call ONCE. When the retry still returns 401,
/// or a 429 arrives while the stored expiry is still past, the
/// provider calls `renewer.markLastRenewalIneffective()` so the
/// remainder of the 30-minute cooldown keeps the "Run `claude` in
/// Terminal to sign in" row instead of flipping to "Open Claude Code
/// to refresh" one refresh later. The renewer owns the cooldown,
/// in-flight and binary-lookup logic; the provider only decides which
/// row message to surface based on the outcome. The provider never
/// touches the Keychain itself — that is what the CLI's own login
/// flow does.
public struct ClaudeProvider: UsageProvider {
    public let id: ProviderID = .claude

    private let transport: HTTPTransport
    private let credentials: ClaudeCredentialReader
    private let renewer: any ClaudeCLIRenewer
    private let now: @Sendable () -> Date

    /// The endpoint URL is a literal — not user-configurable.
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Value of the `User-Agent` header sent on every Claude usage
    /// request. Without a `claude-code/*` User-Agent the endpoint answers
    /// HTTP 429 (retry-after ~1 h) instead of the true status; observed
    /// 2026-09-29. Kept as a single named constant so a version bump is a
    /// one-line change.
    public static let userAgent = "claude-code/2.1.0"

    /// Row text when renewal is unavailable (toggle off, no binary, or
    /// cooldown active): the same "Open Claude Code to refresh" the ring
    /// used to show unconditionally before delegated renewal existed.
    static let signedOutReasonNoRenewal = "Open Claude Code to refresh"

    /// Row text after a renewal attempt that ran but did not restore the
    /// token — either the CLI itself failed, or it succeeded but the
    /// retried usage call still returned 401. The user needs to interact
    /// with the CLI directly.
    static let signedOutReasonRenewalFailed = "Run `claude` in Terminal to sign in"

    public init(
        transport: HTTPTransport,
        credentials: ClaudeCredentialReader,
        renewer: any ClaudeCLIRenewer = DisabledClaudeCLIRenewer(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.transport = transport
        self.credentials = credentials
        self.renewer = renewer
        self.now = now
    }

    public func isInstalled() async -> Bool {
        await credentials.isPresent()
    }

    public func fetch() async throws -> ProviderUsage {
        var credentialBody = try await readCredential()
        var token = try extractAccessToken(from: credentialBody)
        var storedExpiresAt = extractExpiresAt(from: credentialBody)

        // Pre-flight expiry check. If the stored expiry is already past
        // when we go to fetch, the endpoint is likely to answer 429 (rate
        // limited) rather than 401. Trigger the delegated renewal now
        // — before making
        // any HTTP call — so a live user does not get stuck on a
        // "Rate limited" row for the ~1 h Retry-After the endpoint likes
        // to return for expired tokens.
        //
        // On `.succeeded`: re-read the credential (new token, new
        // expiresAt) and drop into the normal HTTP path — one usage call
        // total, no second renewal on 401. If the re-read or token
        // extraction fails despite a successful CLI, tell the renewer
        // the attempt was ineffective (so the cooldown row remains "Run
        // `claude`") and surface the same "Run `claude`" text.
        //
        // On any non-success renewal outcome: throw the appropriate
        // signed-out row without ever calling the endpoint.
        var renewalWasSuccessfulThisFetch = false
        if let expiresAt = storedExpiresAt, expiresAt <= now() {
            let outcome = await renewer.attemptRenewal()
            switch outcome {
            case .succeeded:
                do {
                    credentialBody = try await readCredential()
                    token = try extractAccessToken(from: credentialBody)
                    storedExpiresAt = extractExpiresAt(from: credentialBody)
                    renewalWasSuccessfulThisFetch = true
                } catch {
                    // The CLI reported success but we cannot read or
                    // parse the resulting credential — treat as the
                    // 401-after-successful-renewal case: mark the
                    // renewal ineffective and surface the "Run
                    // `claude`" row. The raw error text (which could
                    // include our sanitised messages, but for
                    // consistency with the 401 retry path we do not
                    // propagate it) is dropped.
                    renewer.markLastRenewalIneffective()
                    throw FetchError.signedOut(Self.signedOutReasonRenewalFailed)
                }
            case .failed, .inCooldownAfterFailure:
                throw FetchError.signedOut(Self.signedOutReasonRenewalFailed)
            case .disabled, .noBinary, .inCooldown:
                throw FetchError.signedOut(Self.signedOutReasonNoRenewal)
            }
        }

        let (data, response) = try await performUsageRequest(token: token)

        // 401 is the classic delegated-renewal trigger: the token *looks*
        // valid client-side but the server rejects it. Only attempt
        // renewal here if we haven't already renewed inside this fetch
        // — a fresh Keychain token that STILL returns 401 will not be
        // fixed by another CLI run, and burning a second attempt would
        // just waste a Claude usage quantum. In that case, tell the
        // renewer the just-completed attempt was ineffective so the
        // cooldown row stays on the "Run `claude`" flavour.
        //
        // 403 (which the endpoint has never been observed emitting but
        // the mapper treats the same) surfaces as the plain
        // "Open Claude Code to refresh" row.
        if response.statusCode == 401 {
            if renewalWasSuccessfulThisFetch {
                renewer.markLastRenewalIneffective()
                throw FetchError.signedOut(Self.signedOutReasonRenewalFailed)
            }
            return try await handle401ByRenewingAndRetrying()
        }

        // 429 while the stored expiry is past → treat as signed out
        // rather than as `.rateLimited(retryAfter:)`. Setting a
        // Retry-After here would ice the Claude ring for the whole
        // hour-scale value the endpoint returns for expired tokens —
        // preventing the very next refresh (which might catch a freshly
        // renewed token) from firing.
        //
        // `now()` is re-sampled here (rather than reusing the pre-flight
        // reading) so a token that was still-future when we read it but
        // has since aged past its expiry — a plausible outcome when the
        // network round trip is slow — is caught by this branch instead
        // of being mis-classified as generic `.rateLimited`.
        if response.statusCode == 429,
           let expiresAt = storedExpiresAt,
           expiresAt <= now() {
            if renewalWasSuccessfulThisFetch {
                renewer.markLastRenewalIneffective()
                throw FetchError.signedOut(Self.signedOutReasonRenewalFailed)
            }
            throw FetchError.signedOut(Self.signedOutReasonNoRenewal)
        }

        if let mapped = HTTPErrorMapper.mapStatus(
            response.statusCode,
            response: response,
            signedOutReason: Self.signedOutReasonNoRenewal
        ) {
            throw mapped
        }

        return try parseUsage(data: data)
    }

    // MARK: - Request

    /// Build and issue a single Claude usage request with the given
    /// bearer token. Returns the raw body plus response for the caller
    /// to inspect (401 vs. other statuses). Non-HTTP transport errors
    /// (connectivity, timeout) are mapped to `FetchError` here so the
    /// caller does not have to.
    private func performUsageRequest(token: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            return try await transport.get(request)
        } catch let fetchError as FetchError {
            throw fetchError
        } catch let urlError as URLError {
            throw HTTPErrorMapper.mapURLError(urlError)
        } catch {
            // Do not stringify — the underlying description can carry URLs
            // or headers.
            throw FetchError.other("Network error")
        }
    }

    // MARK: - Renewal path

    /// The 401 renewal loop. The `UsageStore`'s per-provider in-flight
    /// guard already prevents two concurrent Claude fetches; the
    /// renewer's own internal lock is a further defensive layer.
    ///
    /// - Renewal disabled / no binary / in cooldown after a success →
    ///   surface the plain `signedOutReasonNoRenewal` row. These are
    ///   all "we could not even try" outcomes.
    /// - Renewal succeeded → re-read the credential (a fresh Keychain
    ///   read; the CLI may have written a new token) and retry the
    ///   usage call exactly once. If the retry returns 401, or 429
    ///   while the re-read `expiresAt` is still past, mark the renewal
    ///   ineffective (so the remaining cooldown window keeps the
    ///   "Run `claude`" row) and surface `signedOutReasonRenewalFailed`.
    ///   Other statuses (5xx, 429 with a valid-looking token, unclassified)
    ///   are mapped normally without marking the renewal ineffective.
    ///   On success, return the parsed usage.
    /// - Renewal failed or is in cooldown after a failure → surface
    ///   `signedOutReasonRenewalFailed`. Never retry inside one fetch
    ///   beyond the single renew-and-retry cycle; the **renewer's**
    ///   30-minute cooldown blocks another attempt until the next
    ///   refresh window.
    private func handle401ByRenewingAndRetrying() async throws -> ProviderUsage {
        let outcome = await renewer.attemptRenewal()
        switch outcome {
        case .disabled, .noBinary, .inCooldown:
            throw FetchError.signedOut(Self.signedOutReasonNoRenewal)
        case .failed, .inCooldownAfterFailure:
            throw FetchError.signedOut(Self.signedOutReasonRenewalFailed)
        case .succeeded:
            // Re-read the credential. If it now lacks a token, the CLI
            // wiped the item without re-writing it — treat as the same
            // "run claude in terminal" outcome, and tell the renewer
            // its attempt was ineffective so the cooldown window keeps
            // that text.
            let newBody: Data
            do {
                newBody = try await readCredential()
            } catch {
                renewer.markLastRenewalIneffective()
                throw FetchError.signedOut(Self.signedOutReasonRenewalFailed)
            }
            let newToken: String
            do {
                newToken = try extractAccessToken(from: newBody)
            } catch {
                renewer.markLastRenewalIneffective()
                throw FetchError.signedOut(Self.signedOutReasonRenewalFailed)
            }
            let newExpiresAt = extractExpiresAt(from: newBody)
            let (retryData, retryResponse) = try await performUsageRequest(token: newToken)
            if retryResponse.statusCode == 401 {
                renewer.markLastRenewalIneffective()
                throw FetchError.signedOut(Self.signedOutReasonRenewalFailed)
            }
            // 429 with a re-read expiresAt still in the past → signed
            // out, no `Retry-After` lock-out: a 429 received while the
            // stored expiresAt is past is shown as signed out. This is
            // the same rule the pre-flight branch applies; it must
            // also cover the 401-retry path when the
            // CLI wrote a credential whose new expiresAt is still
            // stale. Marks the renewal ineffective so the cooldown row
            // keeps the "Run `claude`" text.
            if retryResponse.statusCode == 429,
               let expiry = newExpiresAt,
               expiry <= now() {
                renewer.markLastRenewalIneffective()
                throw FetchError.signedOut(Self.signedOutReasonRenewalFailed)
            }
            // Any other non-2xx status (429 with a valid-looking token,
            // 5xx, unclassified) is not evidence that the renewal
            // itself failed — the token might well be good and the
            // server is having a bad day. Do NOT mark the renewal
            // ineffective in these cases; a `.rateLimited(retryAfter:)`
            // / `.server(status)` / `.other(...)` row surfaces the
            // real cause. The provider-level in-flight guard already
            // prevents a second Claude fetch this tick.
            if let mapped = HTTPErrorMapper.mapStatus(
                retryResponse.statusCode,
                response: retryResponse,
                signedOutReason: Self.signedOutReasonRenewalFailed
            ) {
                throw mapped
            }
            return try parseUsage(data: retryData)
        }
    }

    // MARK: - Credential handling

    private func readCredential() async throws -> Data {
        do {
            return try await credentials.read()
        } catch let fetchError as FetchError {
            throw fetchError
        } catch {
            // Any other reader failure: same sanitised message.
            throw FetchError.other("Couldn't read Claude Code credentials from Keychain")
        }
    }

    /// Tolerant read of `claudeAiOauth.expiresAt` (milliseconds since
    /// epoch). Returns `nil` for any body that is not JSON, is not an
    /// object, is missing the field, or holds a non-numeric value.
    ///
    /// The read is deliberately silent on failure: this value is only a
    /// *hint* used to decide whether to trigger delegated renewal
    /// pre-flight. A missing or malformed value must not fail the fetch —
    /// the HTTP call is still the source of truth for whether the token
    /// is currently accepted by the server.
    private func extractExpiresAt(from body: Data) -> Date? {
        guard
            let json = try? JSONSerialization.jsonObject(with: body, options: []),
            let root = json as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any]
        else {
            return nil
        }
        // Accept Int, Int64, Double, NSNumber; reject bools and strings.
        // `NumericJSON.number` already rejects `CFBoolean` bridged values.
        guard let ms = NumericJSON.number(from: oauth["expiresAt"]) else {
            return nil
        }
        return Date(timeIntervalSince1970: ms / 1000.0)
    }

    private func extractAccessToken(from body: Data) throws -> String {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: body, options: [])
        } catch {
            // Parse failure. The body holds the raw Keychain JSON — do NOT
            // include it, or its length, or a hash of it, in the message.
            throw FetchError.parse("Claude credentials could not be parsed")
        }
        guard let root = json as? [String: Any] else {
            throw FetchError.parse("Claude credentials JSON was not an object")
        }
        guard
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String,
            !token.isEmpty
        else {
            // The Keychain item exists and parses as JSON but does not carry
            // a usable accessToken. Ask the user to reopen Claude Code so
            // its own login flow can rewrite the item.
            throw FetchError.signedOut("Open Claude Code to refresh")
        }
        return token
    }

    // MARK: - Usage response parsing

    private func parseUsage(data: Data) throws -> ProviderUsage {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw FetchError.parse("Claude usage response could not be parsed")
        }
        guard let root = json as? [String: Any] else {
            throw FetchError.parse("Claude usage response was not a JSON object")
        }

        // Distinguish "key missing entirely" from "key present but null" —
        // the second is a legitimate signal that this account does not have
        // that window right now, the first is a broken response.
        let hasFiveHour = root.keys.contains("five_hour")
        let hasSevenDay = root.keys.contains("seven_day")
        guard hasFiveHour || hasSevenDay else {
            throw FetchError.parse("Claude usage response missing five_hour and seven_day")
        }

        var windows: [UsageWindow] = []
        if hasFiveHour, let win = try window(from: root["five_hour"], label: "5h", kind: .fiveHour) {
            windows.append(win)
        }
        if hasSevenDay, let win = try window(from: root["seven_day"], label: "Weekly", kind: .weekly) {
            windows.append(win)
        }

        return ProviderUsage(
            id: .claude,
            plan: nil,
            windows: windows,
            fetchedAt: now()
        )
    }

    /// Build a `UsageWindow` from a raw JSON value, or return `nil` for a
    /// null / missing entry.
    ///
    /// Throws `.parse` when the value is an object (not null) but lacks a
    /// numeric `utilization` — that shape is the API silently renaming a
    /// field, which we must not treat as "0 % used".
    private func window(from raw: Any?, label: String, kind: UsageWindowKind) throws -> UsageWindow? {
        // Null / NSNull / genuinely-missing → skip.
        if raw == nil { return nil }
        if raw is NSNull { return nil }
        guard let dict = raw as? [String: Any] else {
            // Some non-null, non-object thing (number, string, array).
            throw FetchError.parse("Claude usage window \(label) had unexpected shape")
        }
        // `NumericJSON.number(from:)` rejects JSON booleans — `true` / `false`
        // bridge to `NSNumber` via `CFBooleanRef` and would otherwise be read
        // as 1 / 0. A silent rename of `utilization` to a boolean field must
        // NOT surface as "1 %".
        guard let percent = NumericJSON.number(from: dict["utilization"]) else {
            throw FetchError.parse("Claude usage window \(label) missing utilization")
        }
        let resetsAt = parseResetTimestamp(dict["resets_at"] as? String)
        return UsageWindow(label: label, usedPercent: percent, resetsAt: resetsAt, kind: kind)
    }

    private func parseResetTimestamp(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        // `ISO8601DateFormatter` is not `Sendable`, so we avoid a shared
        // static instance under Swift 6 strict concurrency and build a
        // fresh formatter each parse. The cost is negligible: at most two
        // reset timestamps per fetch, once every 300 s.
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
