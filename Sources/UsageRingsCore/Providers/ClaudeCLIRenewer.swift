import Foundation

// MARK: - Binary lookup

/// Locates the user's `claude` CLI on this Mac by checking a fixed list of
/// candidate paths in order. The first candidate whose path exists on
/// disk wins. If none exists there is no CLI on this Mac and no renewal
/// is possible.
///
/// The candidate list is fixed and searched in this order:
///     ~/.local/bin/claude, ~/.claude/local/claude,
///     /opt/homebrew/bin/claude, /usr/local/bin/claude
///
/// The home-directory lookup and the file-existence check are both
/// injectable so tests can drive the lookup order without a real
/// filesystem probe.
public struct ClaudeCLIBinaryFinder: Sendable {

    /// Candidate paths, in the order they are tried. Tilde paths are
    /// expanded against the injected home directory; absolute paths are
    /// used unchanged.
    public static let candidatePaths: [String] = [
        "~/.local/bin/claude",
        "~/.claude/local/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude"
    ]

    private let fileExists: @Sendable (String) -> Bool
    private let homeDirectory: @Sendable () -> String

    /// - Parameters:
    ///   - fileExists: Called with each expanded candidate path; returns
    ///     `true` when the file is on disk. Defaults to
    ///     `FileManager.default.isExecutableFile(atPath:)` because a
    ///     non-executable file at one of these paths is not a claude CLI
    ///     we can invoke.
    ///   - homeDirectory: Called once per lookup to expand `~/…` prefixes.
    ///     Defaults to `NSHomeDirectory()`.
    public init(
        fileExists: @escaping @Sendable (String) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0)
        },
        homeDirectory: @escaping @Sendable () -> String = {
            NSHomeDirectory()
        }
    ) {
        self.fileExists = fileExists
        self.homeDirectory = homeDirectory
    }

    /// Expand a candidate path — replace a leading `~/` with the injected
    /// home directory. Absolute paths are returned unchanged.
    public func expand(_ candidate: String) -> String {
        if candidate.hasPrefix("~/") {
            return homeDirectory() + String(candidate.dropFirst(1))
        }
        return candidate
    }

    /// First existing candidate path (expanded), or `nil` if none exists.
    public func find() -> String? {
        for candidate in Self.candidatePaths {
            let path = expand(candidate)
            if fileExists(path) { return path }
        }
        return nil
    }
}

// MARK: - Process runner for the claude CLI

/// Small subprocess abstraction for the `claude` CLI. Mirrors
/// `SecuritySubprocessRunner`'s design but accepts an explicit environment
/// and working directory — the renewer needs full control over those so
/// the child cannot inherit CLAUDE_*/ANTHROPIC_* variables from the app's
/// environment.
///
/// Only the exit status is returned; stdout and stderr are drained and
/// discarded. The CLI's output can include prompt text, model responses,
/// and diagnostic detail; none of that should ever reach the popover or a
/// log file.
public protocol ClaudeCLIProcessRunner: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL,
        timeout: TimeInterval
    ) async throws -> Int32
}

/// Errors surfaced by `ClaudeCLIProcessRunner` implementations. Kept
/// separate from `FetchError` because the renewer collapses every failure
/// mode (launch, timeout, non-zero exit) into a single `.failed` outcome
/// before the provider ever sees it.
public enum ClaudeCLIProcessError: Error, Equatable, Sendable {
    /// `Process.run()` threw before the child started.
    case launchFailed
    /// The child did not exit within the caller's deadline.
    case timedOut
}

/// Real implementation. Delegates to the shared `runSubprocess` helper so
/// the concurrent-drain, deadline, and terminate-then-kill guarantees are
/// identical to the security-command runner.
public struct ProcessClaudeCLIRunner: ClaudeCLIProcessRunner {

    /// Grace period between SIGTERM and SIGKILL for an unresponsive child.
    /// Kept small so a `claude` CLI that ignores SIGTERM does not extend
    /// the user-facing wait by much.
    public let killGrace: TimeInterval

    public init(killGrace: TimeInterval = 0.5) {
        self.killGrace = killGrace
    }

    public func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL,
        timeout: TimeInterval
    ) async throws -> Int32 {
        do {
            let result = try await runSubprocess(
                executable: executable,
                arguments: arguments,
                environment: environment,
                currentDirectory: currentDirectory,
                timeout: timeout,
                killGrace: killGrace
            )
            return result.status
        } catch SubprocessRunError.launchFailed {
            throw ClaudeCLIProcessError.launchFailed
        } catch SubprocessRunError.timedOut {
            throw ClaudeCLIProcessError.timedOut
        }
    }
}

// MARK: - Renewer

/// Outcome of one renewal attempt.
public enum ClaudeRenewalOutcome: Sendable, Equatable {
    /// The CLI ran and exited 0 — the Keychain item may have been rewritten
    /// by the CLI. The provider re-reads the credential and retries the
    /// usage call once.
    case succeeded

    /// The CLI ran but exited non-zero, or the subprocess timed out /
    /// failed to launch. The token was not renewed. The provider surfaces
    /// "Run `claude` in Terminal to sign in".
    case failed

    /// No candidate binary exists on this Mac. No renewal is possible.
    /// The provider surfaces "Open Claude Code to refresh".
    case noBinary

    /// The 30-minute cooldown since the last attempt (which succeeded, or
    /// never happened) has not elapsed. The provider surfaces
    /// "Open Claude Code to refresh".
    case inCooldown

    /// The 30-minute cooldown after a **failed** attempt has not elapsed.
    /// Distinct from `.inCooldown` so the provider can keep the
    /// "Run `claude` in Terminal to sign in" row visible for the whole
    /// cooldown window, instead of flipping the ring back to
    /// "Open Claude Code to refresh" after the first refresh.
    case inCooldownAfterFailure

    /// The "Renew Claude login automatically" setting is off. The provider
    /// surfaces "Open Claude Code to refresh".
    case disabled
}

/// Injectable protocol for the delegated-renewal behaviour.
///
/// The provider consults this in two places:
///  - **Pre-flight** — when the stored `claudeAiOauth.expiresAt` is
///    already past (an expired token can draw a 429 instead of a 401,
///    so the app renews before making any HTTP call).
///  - **On 401** — when a token that looks valid client-side is
///    rejected by the server.
///
/// The renewer decides whether renewal should run at all (toggle, binary
/// presence, cooldown, in-flight) and, when it should, forks the CLI once
/// and reports the outcome. It never returns any bytes to the caller.
///
/// `markLastRenewalIneffective()` lets the provider tell the renewer that
/// a renewal it recorded as successful did not actually restore access
/// (the retry still returned 401, or the response was 429 while the
/// stored expiry was still past). The renewer then treats the pending
/// cooldown window as if the attempt had failed, so the row keeps
/// "Run `claude` in Terminal to sign in" for the whole cooldown rather
/// than flipping to "Open Claude Code to refresh" one refresh later.
public protocol ClaudeCLIRenewer: Sendable {
    func attemptRenewal() async -> ClaudeRenewalOutcome
    /// Called by the caller when a renewal that was reported as
    /// `.succeeded` did not actually restore access. Implementations
    /// must arrange for the next cooldown-blocked attempt to return
    /// `.inCooldownAfterFailure` rather than `.inCooldown`.
    func markLastRenewalIneffective()
}

/// Renewer that always returns `.disabled`. Used as the default in
/// `ClaudeProvider.init` for callers that do not wire the delegated
/// renewal (existing tests, other providers, or a build that has the
/// setting off statically).
public struct DisabledClaudeCLIRenewer: ClaudeCLIRenewer {
    public init() {}
    public func attemptRenewal() async -> ClaudeRenewalOutcome { .disabled }
    public func markLastRenewalIneffective() { /* no-op: nothing to track */ }
}

/// Default renewer.
///
/// Behaviour on `attemptRenewal()`:
///  1. If the injected `isEnabled` closure returns `false`, immediately
///     return `.disabled` without touching the filesystem or the CLI.
///  2. Locate the CLI binary via `ClaudeCLIBinaryFinder`. If nothing is
///     found return `.noBinary`. Binary lookup happens BEFORE cooldown /
///     in-flight bookkeeping so a Mac without the CLI never marks its
///     internal "last attempt" clock — the cooldown only starts once we
///     have actually tried to run something.
///  3. Under an internal lock, check the cooldown (30 minutes since the
///     last completed attempt, success or failure) and the in-flight
///     guard. Either failing → return `.inCooldown` (in-flight is folded
///     into cooldown-style skip — the provider does not need to
///     distinguish).
///  4. Reserve the slot (set in-flight), release the lock, run the CLI in
///     a fresh temporary working directory with a curated environment,
///     then release the slot and record the attempt time.
///  5. Return `.succeeded` if the CLI exited 0, `.failed` otherwise
///     (non-zero exit, timeout, or launch failure — all rolled into the
///     one outcome the provider maps to "Run `claude` in Terminal to sign
///     in").
///
/// Concurrency: the provider is single-in-flight via `UsageStore`'s
/// per-provider in-flight guard, so the renewer's own lock protects
/// against a defensive-programming-only case (a caller invoking
/// `attemptRenewal` from two tasks). The lock guards `lastAttemptAt`
/// and `inFlight`; no CPU-intensive work runs under it.
public final class DefaultClaudeCLIRenewer: ClaudeCLIRenewer, @unchecked Sendable {

    /// Exact prompt argument passed to `claude -p`. Kept as a named
    /// constant so a change to the prompt shows up in one place — this is
    /// the one-word prompt the CLI executes to trigger its own token
    /// refresh. Keep in sync with the README's Privacy section.
    public static let prompt = "Reply with OK"

    /// Argument list, in order, after `<claude>`. Exact argument list;
    /// keep in sync with the README's Privacy section. Kept public so
    /// tests can assert the exact list without duplicating the strings.
    public static let arguments: [String] = [
        "-p", prompt,
        "--model", "haiku",
        "--no-session-persistence",
        "--tools", "",
        "--strict-mcp-config"
    ]

    /// PATH prefix put in front of the binary's own directory. The CLI
    /// must find only system tools plus itself.
    public static let systemPathPrefix = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// The one set of environment variables the CLI is allowed to
    /// inherit. Everything else — in particular CLAUDE_* / ANTHROPIC_* —
    /// is stripped.
    public static let allowedEnvironmentKeys: Set<String> = [
        "HOME", "USER", "LOGNAME", "LANG"
    ]

    private let isEnabled: @Sendable () -> Bool
    private let finder: ClaudeCLIBinaryFinder
    private let runner: any ClaudeCLIProcessRunner
    private let now: @Sendable () -> Date
    private let temporaryDirectoryFactory: @Sendable () throws -> URL
    private let processEnvironment: @Sendable () -> [String: String]
    private let cooldown: TimeInterval
    private let timeout: TimeInterval

    private let lock = NSLock()
    private var lastAttemptAt: Date?
    /// Whether the last attempt that landed inside the cooldown window
    /// ended in `.failed`. Used to keep the "Run `claude` in Terminal to
    /// sign in" row visible for the whole cooldown after a bad attempt,
    /// rather than flipping to "Open Claude Code to refresh" one refresh
    /// later. Reset to `false` on a successful attempt.
    private var lastAttemptFailed = false
    private var inFlight = false

    /// - Parameters:
    ///   - isEnabled: Read on every attempt. When the caller flips the
    ///     Preferences toggle off, the renewer immediately returns
    ///     `.disabled` on the next attempt without touching state.
    ///   - finder: Binary locator; defaults to the real filesystem.
    ///   - runner: Subprocess runner; defaults to the real one.
    ///   - now: Clock, defaults to `Date()`. Injectable so the cooldown
    ///     path can be tested deterministically.
    ///   - temporaryDirectoryFactory: Called to create the fresh working
    ///     directory the CLI is invoked in. The directory is deleted
    ///     after each attempt.
    ///   - processEnvironment: Provides the parent process's environment
    ///     so the curated env can be built. Defaults to
    ///     `ProcessInfo.processInfo.environment`.
    ///   - cooldown: Seconds between attempts. Defaults to 30 minutes.
    ///   - timeout: Wall-clock budget for one CLI invocation. Defaults
    ///     to 60 seconds.
    public init(
        isEnabled: @escaping @Sendable () -> Bool,
        finder: ClaudeCLIBinaryFinder = ClaudeCLIBinaryFinder(),
        runner: any ClaudeCLIProcessRunner = ProcessClaudeCLIRunner(),
        now: @escaping @Sendable () -> Date = Date.init,
        temporaryDirectoryFactory: @escaping @Sendable () throws -> URL = {
            try DefaultClaudeCLIRenewer.makeFreshTemporaryDirectory()
        },
        processEnvironment: @escaping @Sendable () -> [String: String] = {
            ProcessInfo.processInfo.environment
        },
        cooldown: TimeInterval = 30 * 60,
        timeout: TimeInterval = 60
    ) {
        self.isEnabled = isEnabled
        self.finder = finder
        self.runner = runner
        self.now = now
        self.temporaryDirectoryFactory = temporaryDirectoryFactory
        self.processEnvironment = processEnvironment
        self.cooldown = cooldown
        self.timeout = timeout
    }

    public func attemptRenewal() async -> ClaudeRenewalOutcome {
        guard isEnabled() else { return .disabled }

        // Locate the binary BEFORE touching cooldown state. On a Mac with
        // no CLI at all, we do not want a `.noBinary` result to also mark
        // the cooldown clock — otherwise the next Mac that DOES sync a
        // fresh binary in would still be in cooldown from a "we didn't
        // even try" attempt.
        guard let binaryPath = finder.find() else { return .noBinary }

        // Reserve a slot under the lock. Cooldown and in-flight fold into
        // either `.inCooldown` or `.inCooldownAfterFailure` depending on
        // what the last recorded attempt was — the caller uses the
        // distinction to keep "Run `claude` in Terminal to sign in"
        // visible for the whole cooldown after a failed attempt, instead
        // of flipping back to "Open Claude Code to refresh" one refresh
        // later.
        let currentTime = now()
        enum Reservation { case ok, blocked(afterFailure: Bool) }
        let reservation: Reservation = withLock {
            if inFlight {
                return .blocked(afterFailure: lastAttemptFailed)
            }
            if let last = lastAttemptAt, currentTime.timeIntervalSince(last) < cooldown {
                return .blocked(afterFailure: lastAttemptFailed)
            }
            inFlight = true
            return .ok
        }
        switch reservation {
        case .ok: break
        case .blocked(let afterFailure):
            return afterFailure ? .inCooldownAfterFailure : .inCooldown
        }

        // At this point we own the in-flight slot. `finalOutcome` starts
        // as `.failed` so a mid-function throw (temp-dir factory) still
        // marks the attempt as failed and armes the "keep the failed
        // text visible during cooldown" behaviour. The defer below is
        // what actually records the state.
        var finalOutcome: ClaudeRenewalOutcome = .failed
        defer {
            let completedAt = now()
            withLock {
                inFlight = false
                lastAttemptAt = completedAt
                lastAttemptFailed = (finalOutcome == .failed)
            }
        }

        // Fresh temp directory as the CLI's cwd. If the factory throws,
        // do not run — `finalOutcome` stays `.failed` so the provider
        // surfaces the "Run `claude` in Terminal" hint rather than
        // silently doing nothing.
        let cwd: URL
        do {
            cwd = try temporaryDirectoryFactory()
        } catch {
            return .failed
        }
        defer {
            // Best-effort cleanup. If the CLI wrote junk into the cwd, we
            // sweep it here. Failure to remove is not surfaced — the
            // directory lives under NSTemporaryDirectory() and the OS
            // will clean it up on the next boot.
            try? FileManager.default.removeItem(at: cwd)
        }

        // Build the curated environment. The binary's own directory is
        // appended to PATH so any wrapper script the CLI relies on can
        // still be resolved.
        let binaryURL = URL(fileURLWithPath: binaryPath)
        let binaryDirectory = binaryURL.deletingLastPathComponent().path
        let env = Self.curatedEnvironment(
            processEnvironment: processEnvironment(),
            binaryDirectory: binaryDirectory
        )

        do {
            let status = try await runner.run(
                executable: binaryURL,
                arguments: Self.arguments,
                environment: env,
                currentDirectory: cwd,
                timeout: timeout
            )
            finalOutcome = status == 0 ? .succeeded : .failed
        } catch {
            // Timeout, launch failure, anything unexpected: single
            // `.failed` outcome. The provider maps that to
            // "Run `claude` in Terminal to sign in".
            finalOutcome = .failed
        }
        return finalOutcome
    }

    /// Build the curated environment: only HOME, USER, LOGNAME, LANG
    /// inherited from the parent process (only when actually set), plus a
    /// hardcoded PATH.
    ///
    /// The exclusion of CLAUDE_* and ANTHROPIC_* is deliberate: a user
    /// with `CLAUDE_API_KEY` in their shell profile would otherwise have
    /// the CLI attempt to authenticate against that key rather than
    /// renewing the Keychain OAuth session. Similarly `CLAUDE_CONFIG_DIR`
    /// could point the CLI at a foreign config.
    static func curatedEnvironment(
        processEnvironment: [String: String],
        binaryDirectory: String
    ) -> [String: String] {
        var env: [String: String] = [:]
        for key in allowedEnvironmentKeys {
            if let value = processEnvironment[key], !value.isEmpty {
                env[key] = value
            }
        }
        // PATH is always set: system directories first (so `/usr/bin/env`
        // and friends resolve to system copies) followed by the CLI's
        // own directory.
        env["PATH"] = "\(systemPathPrefix):\(binaryDirectory)"
        return env
    }

    public func markLastRenewalIneffective() {
        // Flip the failure flag under the lock. If the cooldown window
        // is still open from a recently-recorded `.succeeded` attempt,
        // the next in-cooldown `attemptRenewal()` will now return
        // `.inCooldownAfterFailure` and the provider will keep showing
        // "Run `claude` in Terminal to sign in" for the whole window.
        //
        // Safe to call even if no attempt was ever recorded: the flag
        // simply sticks around until a subsequent successful attempt
        // clears it. Since the pre-check for cooldown compares
        // `lastAttemptAt` first, a Mac that never ran renewal will
        // still be free to try on the next 401 / expiry check.
        withLock {
            lastAttemptFailed = true
        }
    }

    /// Create a fresh temporary directory under `NSTemporaryDirectory()`,
    /// unique to this invocation. The directory is deleted after the
    /// attempt completes.
    public static func makeFreshTemporaryDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("usage-rings-claude-renewal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}
