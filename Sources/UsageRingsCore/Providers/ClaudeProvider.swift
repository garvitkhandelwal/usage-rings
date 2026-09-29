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
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // `terminationHandler` fires on the process's private queue whether
        // the child exited normally or was terminated. Set it before
        // `run()` so we cannot miss a very-fast child.
        let exitBox = ExitBox()
        process.terminationHandler = { p in
            exitBox.finish(status: p.terminationStatus)
        }

        // Set up drains before launching so the pipes are draining from the
        // instant the child starts writing. `AsyncPipeReader` uses
        // `readabilityHandler`, which fires on a Foundation-owned queue —
        // no Swift-concurrency thread is blocked for the child's lifetime.
        let stdoutReader = AsyncPipeReader(fileHandle: stdoutPipe.fileHandleForReading)
        let stderrReader = AsyncPipeReader(fileHandle: stderrPipe.fileHandleForReading)
        stdoutReader.begin()
        stderrReader.begin()

        do {
            try process.run()
        } catch {
            stdoutReader.cancel()
            stderrReader.cancel()
            throw SecuritySubprocessError.launchFailed
        }

        let deadlineNS = UInt64(max(0.0, timeout) * 1_000_000_000)
        let exitStatus: Int32? = await Self.awaitExitOrDeadline(
            exitBox: exitBox,
            deadlineNS: deadlineNS
        )

        guard let status = exitStatus else {
            // Timeout. SIGTERM immediately; schedule a SIGKILL escalation
            // on a detached task so the caller returns promptly rather
            // than waiting on `readabilityHandler` EOF. Killing by PID
            // (not by the `Process` reference) means we do not need to
            // capture a non-Sendable `Process` in the detached task.
            //
            // PID reuse is unlikely in this short window but not
            // impossible — the kernel does not police that. Gate the
            // SIGKILL on the child not having exited yet (as observed by
            // our own `terminationHandler`, which fires whenever the
            // child exits): if `exitBox.finished` is already `true` the
            // child is gone and its PID may have been recycled, so we
            // must not signal anything.
            //
            // This narrows the race but does not close it: the kernel
            // may reap the child before Foundation dispatches
            // `terminationHandler`, so a `finished == false` snapshot
            // is a necessary but not sufficient condition. See
            // `ExitBox.finished` for the residual-window analysis.
            let pid = process.processIdentifier
            process.terminate()
            let killGraceNS = UInt64(max(0.0, killGrace) * 1_000_000_000)
            Task.detached { [exitBox] in
                try? await Task.sleep(nanoseconds: killGraceNS)
                // Only escalate if we have NOT observed the child exit.
                // Once `terminationHandler` has fired the PID belongs to
                // whichever process the kernel next recycled it to; we
                // must not signal that. See `ExitBox.finished` for why
                // this narrows but does not eliminate the race.
                guard !exitBox.finished else { return }
                if pid > 0 {
                    _ = Darwin.kill(pid, SIGKILL)
                }
            }
            stdoutReader.cancel()
            stderrReader.cancel()
            throw SecuritySubprocessError.timedOut
        }

        let stdoutData = await stdoutReader.wait()
        _ = await stderrReader.wait()
        return (status, stdoutData)
    }

    /// Race the process's exit against the caller's deadline, returning
    /// the exit status if it arrives first or `nil` on timeout. Both racing
    /// tasks are one-shot: whichever fires first resumes the continuation;
    /// the loser is a small leak (the sleep task's continuation returns
    /// nothing) that does not delay the caller.
    private static func awaitExitOrDeadline(
        exitBox: ExitBox,
        deadlineNS: UInt64
    ) async -> Int32? {
        let winner = OneShot()
        return await withCheckedContinuation { (cont: CheckedContinuation<Int32?, Never>) in
            Task {
                let status = await exitBox.wait()
                if winner.fire() {
                    cont.resume(returning: status)
                }
            }
            Task {
                _ = try? await Task.sleep(nanoseconds: deadlineNS)
                if winner.fire() {
                    cont.resume(returning: nil)
                }
            }
        }
    }
}

// MARK: - Subprocess plumbing (module-private)

/// Bridges `Process.terminationHandler` (a callback) to an `await`-able
/// value.
///
/// Also exposes a `finished` snapshot the timeout escalator reads to gate
/// its SIGKILL — once `terminationHandler` has fired for a child, sending
/// a signal to that PID is unsafe (the kernel may have recycled it).
private final class ExitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    /// `true` once we have OBSERVED the child exit — meaning
    /// `terminationHandler` has fired and `finish(status:)` recorded it.
    ///
    /// The SIGKILL-escalation task reads this snapshot before signalling
    /// so it can skip a signal to a PID that has already been reused by
    /// the kernel. Note this is a *narrowing*, not an *elimination*: the
    /// kernel may reap the child before Foundation calls our
    /// `terminationHandler`, so `finished == false` does not prove the
    /// PID is still ours. Holding the lock across `Darwin.kill` would
    /// not help — the race is kernel-side, not Swift-side. This narrow
    /// window (roughly the time between the child's `exit(2)` and
    /// Foundation's callback dispatch, i.e. a Foundation-owned queue
    /// hop) is the residual risk we accept.
    var finished: Bool {
        lock.lock(); defer { lock.unlock() }
        return status != nil
    }

    func finish(status: Int32) {
        lock.lock()
        self.status = status
        let toResume = waiters
        waiters = []
        lock.unlock()
        for continuation in toResume {
            continuation.resume(returning: status)
        }
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            lock.lock()
            if let status {
                lock.unlock()
                continuation.resume(returning: status)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

/// A one-shot flag used to guarantee that a checked continuation is
/// resumed at most once when two racing tasks might both try.
private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    /// Returns `true` for the first caller (which owns the resume) and
    /// `false` for every subsequent caller.
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

/// Non-blocking pipe drain. Uses `readabilityHandler` so the reading
/// happens on Foundation's file-descriptor queue rather than on a
/// cooperative-pool thread. `wait()` bridges the accumulated data into
/// `async` via a checked continuation.
///
/// The reader is one-shot: once EOF (empty `availableData`) is observed,
/// or `cancel()` is called, the internal buffer is delivered to any
/// waiter and no further data is accepted.
private final class AsyncPipeReader: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let lock = NSLock()
    private var buffer = Data()
    private var completed = false
    private var waiters: [CheckedContinuation<Data, Never>] = []

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
    }

    func begin() {
        // Capture `self` weakly — if the reader has been dropped by the
        // time the handler fires, there is nothing to accumulate to.
        fileHandle.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            if chunk.isEmpty {
                // EOF. Tear down the handler and deliver the buffer.
                handle.readabilityHandler = nil
                self.finish()
            } else {
                self.append(chunk)
            }
        }
    }

    /// Force completion (deliver whatever we have so far). Used on the
    /// timeout path: the pipe may not have hit EOF yet — the child is
    /// still being killed — and we do not want to keep the caller
    /// waiting on it.
    func cancel() {
        fileHandle.readabilityHandler = nil
        finish()
    }

    private func append(_ chunk: Data) {
        lock.lock()
        if !completed { buffer.append(chunk) }
        lock.unlock()
    }

    private func finish() {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let result = buffer
        let toResume = waiters
        waiters = []
        lock.unlock()
        for w in toResume { w.resume(returning: result) }
    }

    func wait() async -> Data {
        await withCheckedContinuation { (cont: CheckedContinuation<Data, Never>) in
            lock.lock()
            if completed {
                let result = buffer
                lock.unlock()
                cont.resume(returning: result)
            } else {
                waiters.append(cont)
                lock.unlock()
            }
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
/// Behaviour: this provider does NOT consult the credential's
/// client-side `expiresAt` at all. Whether the token is still valid is
/// the server's call — an HTTP 401 tells us to surface the signed-out
/// row, and that is the one source of truth this provider consults.
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
///  - HTTP 401 / 403 → `.signedOut("Open Claude Code to refresh")`.
///  - HTTP 429 → `.rateLimited(retryAfter:)`.
///  - HTTP 5xx → `.server(status)`.
///  - `URLError` connectivity codes → `.offline`; `.timedOut` → `.timeout`.
///  - Usage-response body not parseable → `.parse(_)`.
public struct ClaudeProvider: UsageProvider {
    public let id: ProviderID = .claude

    private let transport: HTTPTransport
    private let credentials: ClaudeCredentialReader
    private let now: @Sendable () -> Date

    /// The endpoint URL is a literal — not user-configurable.
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Value of the `User-Agent` header sent on every Claude usage
    /// request. Without a `claude-code/*` User-Agent the endpoint answers
    /// HTTP 429 (retry-after ~1 h) instead of the true status; observed
    /// 2026-09-29. Kept as a single named constant so a version bump is a
    /// one-line change.
    public static let userAgent = "claude-code/2.1.0"

    public init(
        transport: HTTPTransport,
        credentials: ClaudeCredentialReader,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.transport = transport
        self.credentials = credentials
        self.now = now
    }

    public func isInstalled() async -> Bool {
        await credentials.isPresent()
    }

    public func fetch() async throws -> ProviderUsage {
        let credentialBody = try await readCredential()
        let token = try extractAccessToken(from: credentialBody)

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await transport.get(request)
        } catch let fetchError as FetchError {
            throw fetchError
        } catch let urlError as URLError {
            throw HTTPErrorMapper.mapURLError(urlError)
        } catch {
            // Do not stringify — the underlying description can carry URLs
            // or headers.
            throw FetchError.other("Network error")
        }

        if let mapped = HTTPErrorMapper.mapStatus(
            response.statusCode,
            response: response,
            signedOutReason: "Open Claude Code to refresh"
        ) {
            throw mapped
        }

        return try parseUsage(data: data)
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
