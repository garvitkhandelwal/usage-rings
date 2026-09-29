import XCTest
@testable import UsageRingsCore

/// Tests for `ClaudeCLIBinaryFinder`, `DefaultClaudeCLIRenewer`, and the
/// curated-environment / cooldown / lookup-order rules the delegated
/// renewal path relies on.
///
/// The real `claude` CLI is never invoked from these tests: every case
/// injects a `FakeClaudeCLIProcessRunner` that records the invocation and
/// returns a canned exit status (or throws), and every filesystem probe
/// goes through an injectable `fileExists` closure. Nothing here touches
/// the network or the real Keychain.
final class ClaudeCLIBinaryFinderTests: XCTestCase {

    /// Reference-typed accumulator so the `@Sendable` `fileExists`
    /// closure can record probes without tripping the Swift 6
    /// var-capture diagnostic.
    final class ProbeLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _paths: [String] = []
        func append(_ path: String) {
            lock.lock(); defer { lock.unlock() }
            _paths.append(path)
        }
        var paths: [String] {
            lock.lock(); defer { lock.unlock() }
            return _paths
        }
    }

    func testFirstCandidateWinsWhenAllExist() {
        let probes = ProbeLog()
        let finder = ClaudeCLIBinaryFinder(
            fileExists: { path in probes.append(path); return true },
            homeDirectory: { "/Users/tester" }
        )
        XCTAssertEqual(finder.find(), "/Users/tester/.local/bin/claude")
        // We must probe in the documented order and stop at the first hit.
        XCTAssertEqual(probes.paths, ["/Users/tester/.local/bin/claude"])
    }

    func testFallsThroughToClaudeLocalWhenLocalBinMissing() {
        let existing: Set<String> = ["/Users/tester/.claude/local/claude"]
        let probes = ProbeLog()
        let finder = ClaudeCLIBinaryFinder(
            fileExists: { path in probes.append(path); return existing.contains(path) },
            homeDirectory: { "/Users/tester" }
        )
        XCTAssertEqual(finder.find(), "/Users/tester/.claude/local/claude")
        XCTAssertEqual(probes.paths, [
            "/Users/tester/.local/bin/claude",
            "/Users/tester/.claude/local/claude"
        ])
    }

    func testFallsThroughToHomebrew() {
        let existing: Set<String> = ["/opt/homebrew/bin/claude"]
        let finder = ClaudeCLIBinaryFinder(
            fileExists: { existing.contains($0) },
            homeDirectory: { "/Users/tester" }
        )
        XCTAssertEqual(finder.find(), "/opt/homebrew/bin/claude")
    }

    func testFallsThroughToUsrLocal() {
        let existing: Set<String> = ["/usr/local/bin/claude"]
        let finder = ClaudeCLIBinaryFinder(
            fileExists: { existing.contains($0) },
            homeDirectory: { "/Users/tester" }
        )
        XCTAssertEqual(finder.find(), "/usr/local/bin/claude")
    }

    func testReturnsNilWhenNoCandidateExists() {
        let finder = ClaudeCLIBinaryFinder(
            fileExists: { _ in false },
            homeDirectory: { "/Users/tester" }
        )
        XCTAssertNil(finder.find())
    }

    func testCandidateOrderIsFixed() {
        // The lookup order is fixed; if a refactor reshuffles the array
        // we want a failing test here rather than a subtle change in
        // which binary is picked.
        XCTAssertEqual(ClaudeCLIBinaryFinder.candidatePaths, [
            "~/.local/bin/claude",
            "~/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ])
    }

    func testExpandDoesNotChangeAbsolutePaths() {
        let finder = ClaudeCLIBinaryFinder(
            fileExists: { _ in false },
            homeDirectory: { "/Users/tester" }
        )
        XCTAssertEqual(finder.expand("/opt/homebrew/bin/claude"), "/opt/homebrew/bin/claude")
        XCTAssertEqual(finder.expand("~/.local/bin/claude"), "/Users/tester/.local/bin/claude")
    }
}

// MARK: - Fake process runner

/// Records every invocation and returns a canned exit status (or throws).
final class FakeClaudeCLIProcessRunner: ClaudeCLIProcessRunner, @unchecked Sendable {
    struct Call: Sendable {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
        let currentDirectory: URL
        let timeout: TimeInterval
    }
    private let lock = NSLock()
    private var responses: [Result<Int32, Error>]
    private var _calls: [Call] = []

    init(responses: [Result<Int32, Error>]) {
        self.responses = responses
    }

    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL,
        timeout: TimeInterval
    ) async throws -> Int32 {
        let result: Result<Int32, Error>? = {
            lock.lock(); defer { lock.unlock() }
            _calls.append(Call(
                executable: executable,
                arguments: arguments,
                environment: environment,
                currentDirectory: currentDirectory,
                timeout: timeout
            ))
            guard !responses.isEmpty else { return nil }
            return responses.removeFirst()
        }()
        switch result {
        case .some(.success(let status)): return status
        case .some(.failure(let error)): throw error
        case .none:
            XCTFail("FakeClaudeCLIProcessRunner ran out of responses")
            throw ClaudeCLIProcessError.launchFailed
        }
    }
}

// MARK: - DefaultClaudeCLIRenewer

final class DefaultClaudeCLIRenewerTests: XCTestCase {

    /// Build a renewer wired to a fake runner with a stubbed binary path.
    private func makeRenewer(
        enabled: Bool = true,
        binaryPath: String? = "/Users/tester/.local/bin/claude",
        runner: FakeClaudeCLIProcessRunner,
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_800_000_000) },
        environment: [String: String] = [:],
        cooldown: TimeInterval = 30 * 60,
        timeout: TimeInterval = 60
    ) -> DefaultClaudeCLIRenewer {
        // The finder either always returns the injected binary (path
        // "exists") or never (path is nil).
        let finder = ClaudeCLIBinaryFinder(
            fileExists: { candidate in candidate == binaryPath },
            homeDirectory: { "/Users/tester" }
        )
        // A directory URL that mimics NSTemporaryDirectory. We do NOT
        // actually create anything in the tests — the fake runner never
        // reads the cwd.
        let tempDir = URL(fileURLWithPath: "/tmp/usage-rings-test-\(UUID().uuidString)", isDirectory: true)
        return DefaultClaudeCLIRenewer(
            isEnabled: { enabled },
            finder: finder,
            runner: runner,
            now: now,
            temporaryDirectoryFactory: { tempDir },
            processEnvironment: { environment },
            cooldown: cooldown,
            timeout: timeout
        )
    }

    // MARK: - Disabled / no-binary / cooldown

    func testDisabledToggleReturnsDisabledWithoutRunningTheCLI() async {
        let runner = FakeClaudeCLIProcessRunner(responses: [.success(0)])
        let renewer = makeRenewer(enabled: false, runner: runner)
        let outcome = await renewer.attemptRenewal()
        XCTAssertEqual(outcome, .disabled)
        XCTAssertEqual(runner.calls.count, 0, "toggle off must not fork the CLI")
    }

    func testMissingBinaryReturnsNoBinary() async {
        let runner = FakeClaudeCLIProcessRunner(responses: [])
        let renewer = makeRenewer(binaryPath: nil, runner: runner)
        let outcome = await renewer.attemptRenewal()
        XCTAssertEqual(outcome, .noBinary)
        XCTAssertEqual(runner.calls.count, 0)
    }

    /// Mutable clock wrapped in a reference type so a `@Sendable` closure
    /// can capture and advance it without tripping the Swift 6 var-capture
    /// diagnostic.
    final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date
        init(start: Date) { self.current = start }
        func advance(by seconds: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            current = current.addingTimeInterval(seconds)
        }
        func read() -> Date {
            lock.lock(); defer { lock.unlock() }
            return current
        }
    }

    func testCooldownBlocksSecondAttemptWithinThirtyMinutes() async {
        let clock = TestClock(start: Date(timeIntervalSince1970: 1_800_000_000))
        let runner = FakeClaudeCLIProcessRunner(responses: [
            .success(0),   // first attempt succeeds
            .success(0)    // second attempt would succeed if allowed
        ])
        let renewer = makeRenewer(runner: runner, now: { clock.read() }, cooldown: 30 * 60)

        let first = await renewer.attemptRenewal()
        XCTAssertEqual(first, .succeeded)
        XCTAssertEqual(runner.calls.count, 1)

        // 10 minutes later — still inside the 30 min cooldown.
        clock.advance(by: 10 * 60)

        let second = await renewer.attemptRenewal()
        XCTAssertEqual(second, .inCooldown)
        XCTAssertEqual(runner.calls.count, 1, "cooldown must skip the second CLI fork")
    }

    func testCooldownExpiresAfterThirtyMinutes() async {
        let clock = TestClock(start: Date(timeIntervalSince1970: 1_800_000_000))
        let runner = FakeClaudeCLIProcessRunner(responses: [
            .success(0),
            .success(0)
        ])
        let renewer = makeRenewer(runner: runner, now: { clock.read() }, cooldown: 30 * 60)

        _ = await renewer.attemptRenewal()

        // 30 minutes + a tick later — outside the window.
        clock.advance(by: 30 * 60 + 1)

        let second = await renewer.attemptRenewal()
        XCTAssertEqual(second, .succeeded)
        XCTAssertEqual(runner.calls.count, 2)
    }

    func testCooldownAppliesAfterAFailure() async {
        // A failed attempt still resets the clock — otherwise a stuck
        // vendor endpoint would let the app hammer the CLI on every
        // refresh.
        let clock = TestClock(start: Date(timeIntervalSince1970: 1_800_000_000))
        let runner = FakeClaudeCLIProcessRunner(responses: [
            .success(1),    // non-zero exit → .failed
            .success(0)
        ])
        let renewer = makeRenewer(runner: runner, now: { clock.read() })

        let first = await renewer.attemptRenewal()
        XCTAssertEqual(first, .failed)

        clock.advance(by: 5 * 60)

        let second = await renewer.attemptRenewal()
        XCTAssertEqual(second, .inCooldownAfterFailure,
                       "failures count toward the cooldown AND remember the failure so the row keeps saying 'Run claude'")
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testCooldownAfterSuccessDoesNotFlagFailure() async {
        // A successful attempt within the cooldown must return
        // `.inCooldown` (not `.inCooldownAfterFailure`) so the provider
        // surfaces the plain "Open Claude Code to refresh" row.
        let clock = TestClock(start: Date(timeIntervalSince1970: 1_800_000_000))
        let runner = FakeClaudeCLIProcessRunner(responses: [.success(0)])
        let renewer = makeRenewer(runner: runner, now: { clock.read() })
        _ = await renewer.attemptRenewal()
        clock.advance(by: 60)
        let second = await renewer.attemptRenewal()
        XCTAssertEqual(second, .inCooldown)
    }

    func testMarkLastRenewalIneffectiveFlipsCooldownToAfterFailure() async {
        // Two attempts in a row, both scheduled to succeed. The first
        // succeeds; the provider then calls
        // `markLastRenewalIneffective()` (simulating "CLI said OK but
        // retry still 401"). Within the cooldown, the second attempt
        // must return `.inCooldownAfterFailure` — the renewer treats
        // the recorded success as if it had failed.
        let clock = TestClock(start: Date(timeIntervalSince1970: 1_800_000_000))
        let runner = FakeClaudeCLIProcessRunner(responses: [.success(0), .success(0)])
        let renewer = makeRenewer(runner: runner, now: { clock.read() })

        let first = await renewer.attemptRenewal()
        XCTAssertEqual(first, .succeeded)

        renewer.markLastRenewalIneffective()

        clock.advance(by: 60)
        let second = await renewer.attemptRenewal()
        XCTAssertEqual(second, .inCooldownAfterFailure)
        XCTAssertEqual(runner.calls.count, 1,
                       "cooldown must still skip the actual fork")
    }

    func testMarkLastRenewalIneffectiveIsSafeBeforeAnyAttempt() async {
        // The provider can call `markLastRenewalIneffective()` from
        // paths that do not always follow an actual `attemptRenewal()`
        // (a defensive future change might). The flag simply arms the
        // next cooldown check; a fresh attempt that lands outside the
        // cooldown window must still be free to run.
        let clock = TestClock(start: Date(timeIntervalSince1970: 1_800_000_000))
        let runner = FakeClaudeCLIProcessRunner(responses: [.success(0)])
        let renewer = makeRenewer(runner: runner, now: { clock.read() })

        renewer.markLastRenewalIneffective()

        // No prior attempt → cooldown check falls through, we run.
        let outcome = await renewer.attemptRenewal()
        XCTAssertEqual(outcome, .succeeded)
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testFailureFlagResetsAfterSuccessfulAttempt() async {
        // First attempt fails → next cooldown-blocked attempt returns
        // `.inCooldownAfterFailure`. After the cooldown elapses and a
        // fresh attempt succeeds, the following cooldown-blocked
        // attempt must NOT still carry the failure flag.
        let clock = TestClock(start: Date(timeIntervalSince1970: 1_800_000_000))
        let runner = FakeClaudeCLIProcessRunner(responses: [
            .success(1),   // fails
            .success(0),   // succeeds
            .success(0)
        ])
        let renewer = makeRenewer(runner: runner, now: { clock.read() }, cooldown: 30 * 60)

        // Attempt 1: fails.
        _ = await renewer.attemptRenewal()

        // Cooldown elapses, attempt 2 succeeds.
        clock.advance(by: 30 * 60 + 1)
        _ = await renewer.attemptRenewal()

        // Attempt 3 within the new cooldown: must be `.inCooldown`,
        // not `.inCooldownAfterFailure` — the last attempt was a
        // success.
        clock.advance(by: 60)
        let third = await renewer.attemptRenewal()
        XCTAssertEqual(third, .inCooldown)
    }

    // MARK: - Argv / cwd / env

    func testInvocationUsesExactArgv() async {
        let runner = FakeClaudeCLIProcessRunner(responses: [.success(0)])
        let renewer = makeRenewer(runner: runner)
        _ = await renewer.attemptRenewal()
        XCTAssertEqual(runner.calls.count, 1)
        let call = runner.calls[0]
        XCTAssertEqual(call.executable.path, "/Users/tester/.local/bin/claude")
        XCTAssertEqual(call.arguments, [
            "-p", "Reply with OK",
            "--model", "haiku",
            "--no-session-persistence",
            "--tools", "",
            "--strict-mcp-config"
        ], "argv is load-bearing; keep in sync with the README's Privacy section")
    }

    func testCurrentDirectoryIsAFreshTempDirectory() async {
        let runner = FakeClaudeCLIProcessRunner(responses: [.success(0)])
        let renewer = makeRenewer(runner: runner)
        _ = await renewer.attemptRenewal()
        let cwd = runner.calls[0].currentDirectory.path
        XCTAssertTrue(cwd.hasPrefix("/tmp/") || cwd.hasPrefix("/private/tmp/"),
                      "cwd must be a temp path; got \(cwd)")
    }

    /// Exercise the REAL temp-dir factory (not the injected stub) so a
    /// regression that produces an unwritable / non-existent directory
    /// path shows up here rather than only in production. The factory
    /// creates a UUID-suffixed subdirectory under `NSTemporaryDirectory()`;
    /// we check it exists during the CLI call and is cleaned up after.
    func testRealTemporaryDirectoryFactoryCreatesAndCleansUpDirectory() async {
        // A fake runner that captures the cwd before returning. When the
        // capture fires, the directory MUST still be on disk. The
        // cleanup happens in a defer after the runner returns, so by the
        // time we look after attemptRenewal, it must be gone.
        final class CapturingRunner: ClaudeCLIProcessRunner, @unchecked Sendable {
            let lock = NSLock()
            private var _cwd: URL?
            private var _existedDuringCall = false
            var cwd: URL? { lock.lock(); defer { lock.unlock() }; return _cwd }
            var existedDuringCall: Bool { lock.lock(); defer { lock.unlock() }; return _existedDuringCall }
            private func record(cwd: URL, existed: Bool) {
                lock.lock(); defer { lock.unlock() }
                _cwd = cwd
                _existedDuringCall = existed
            }
            func run(
                executable: URL,
                arguments: [String],
                environment: [String: String],
                currentDirectory: URL,
                timeout: TimeInterval
            ) async throws -> Int32 {
                let exists = FileManager.default.fileExists(atPath: currentDirectory.path)
                record(cwd: currentDirectory, existed: exists)
                return 0
            }
        }

        let runner = CapturingRunner()
        // Use the REAL binary finder default (won't find anything here
        // since we haven't installed a fake filesystem probe), so
        // instead swap in a finder that always returns a path. That way
        // the renewer proceeds past the noBinary check.
        let finder = ClaudeCLIBinaryFinder(
            fileExists: { _ in true },
            homeDirectory: { "/Users/tester" }
        )
        // Use the real temporaryDirectoryFactory (default), the one
        // that actually makes a directory on disk.
        let renewer = DefaultClaudeCLIRenewer(
            isEnabled: { true },
            finder: finder,
            runner: runner,
            processEnvironment: { [:] }
        )

        let outcome = await renewer.attemptRenewal()
        XCTAssertEqual(outcome, .succeeded)

        guard let cwd = runner.cwd else {
            XCTFail("runner never captured a cwd")
            return
        }
        XCTAssertTrue(runner.existedDuringCall,
                      "temp directory must exist while the CLI is running")
        XCTAssertTrue(cwd.lastPathComponent.hasPrefix("usage-rings-claude-renewal-"),
                      "unexpected temp dir name: \(cwd.lastPathComponent)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cwd.path),
                       "temp directory must be cleaned up after the attempt")
    }

    // MARK: - Concurrent attempts collapse to one CLI fork

    /// Two `attemptRenewal()` calls fired in parallel must reach the
    /// runner at most once — the second call sees `inFlight = true` and
    /// returns `.inCooldown` (or `.inCooldownAfterFailure`) instead of
    /// spawning a duplicate CLI.
    ///
    /// Uses a signal from the parked runner (a continuation the runner
    /// resumes as it enters its body) so the test fires the second
    /// attempt only after we KNOW the first has already claimed the
    /// in-flight slot. A prior version of this test used a fixed 200 ms
    /// sleep and could hang the whole suite on a slow machine instead
    /// of failing deterministically.
    func testTwoConcurrentAttemptsFireRunnerOnce() async {
        actor SlowRunner: ClaudeCLIProcessRunner {
            var callCount = 0
            var release: CheckedContinuation<Void, Never>?
            /// Continuation stashed by `waitUntilEntered()` before
            /// `run()` fires. Consumed at most once.
            var entered: CheckedContinuation<Void, Never>?
            /// Sticky flag: `true` once `run()` has been entered. If
            /// `waitUntilEntered()` is called *after* `run()` fires,
            /// the flag lets it return immediately instead of parking
            /// on a signal that has already been lost. Reset by
            /// `waitUntilEntered()` so a repeat call would wait for the
            /// next entry (not needed by this test, but safer).
            var hasEntered = false

            func run(
                executable: URL,
                arguments: [String],
                environment: [String: String],
                currentDirectory: URL,
                timeout: TimeInterval
            ) async throws -> Int32 {
                callCount += 1
                // Signal to the test that we are inside the runner and
                // the renewer has by now released its own reservation
                // lock (the runner is called AFTER the reservation is
                // committed). The actor's mutual exclusion means the
                // pair below is atomic against `waitUntilEntered()`.
                if let e = entered {
                    entered = nil
                    e.resume()
                } else {
                    hasEntered = true
                }
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    // Only the first call parks here; a second concurrent
                    // call would also park, and we would deadlock with
                    // no releaser — but the whole point of the test is
                    // that the renewer guarantees at most one call.
                    release = cont
                }
                return 0
            }
            func waitUntilEntered() async {
                // If `run()` has already fired, its `hasEntered` write
                // is visible here (actor mutual exclusion). Take the
                // signal synchronously — never park on a continuation
                // that no one will resume.
                if hasEntered {
                    hasEntered = false
                    return
                }
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    entered = cont
                }
            }
            func releaseNow() {
                release?.resume()
                release = nil
            }
        }

        let runner = SlowRunner()
        let finder = ClaudeCLIBinaryFinder(
            fileExists: { $0 == "/Users/tester/.local/bin/claude" },
            homeDirectory: { "/Users/tester" }
        )
        let tempDir = URL(fileURLWithPath: "/tmp/usage-rings-test-\(UUID().uuidString)", isDirectory: true)
        let renewer = DefaultClaudeCLIRenewer(
            isEnabled: { true },
            finder: finder,
            runner: RunnerAdapter(inner: runner),
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            temporaryDirectoryFactory: { tempDir },
            processEnvironment: { [:] }
        )

        // Fire the first attempt asynchronously and wait for its runner
        // body to be entered (signalled by the actor's `entered`
        // continuation). Only then do we fire the second attempt — its
        // reservation check must observe `inFlight = true`.
        async let first: ClaudeRenewalOutcome = renewer.attemptRenewal()
        await runner.waitUntilEntered()

        let second = await renewer.attemptRenewal()
        let cooldownSkips: [ClaudeRenewalOutcome] = [.inCooldown, .inCooldownAfterFailure]
        XCTAssertTrue(
            cooldownSkips.contains(second),
            "second concurrent attempt must be a cooldown skip; got \(second)"
        )

        // Release the first attempt so it completes and returns.
        await runner.releaseNow()
        let firstResult: ClaudeRenewalOutcome = await first
        XCTAssertEqual(firstResult, .succeeded)
        let calls = await runner.callCount
        XCTAssertEqual(calls, 1, "runner must have been called exactly once")
    }

    /// Actor-to-protocol adapter — the `ClaudeCLIProcessRunner`
    /// protocol is not itself an actor, but we want the runner's state
    /// isolated across the two tasks, so we wrap an actor with a
    /// Sendable struct.
    struct RunnerAdapter: ClaudeCLIProcessRunner, @unchecked Sendable {
        let inner: any ClaudeCLIProcessRunner
        init<A: ClaudeCLIProcessRunner>(inner: A) { self.inner = inner }
        func run(
            executable: URL,
            arguments: [String],
            environment: [String: String],
            currentDirectory: URL,
            timeout: TimeInterval
        ) async throws -> Int32 {
            try await inner.run(
                executable: executable,
                arguments: arguments,
                environment: environment,
                currentDirectory: currentDirectory,
                timeout: timeout
            )
        }
    }

    func testEnvironmentContainsOnlyAllowedKeys() async {
        // The environment we hand to the CLI must not include CLAUDE_* /
        // ANTHROPIC_* variables from the user's shell profile — those
        // would either misdirect the CLI to an API key or point it at a
        // different config, defeating the purpose of the renewal.
        let processEnv: [String: String] = [
            "HOME": "/Users/tester",
            "USER": "tester",
            "LOGNAME": "tester",
            "LANG": "en_US.UTF-8",
            "PATH": "/should/be/replaced",
            "CLAUDE_API_KEY": "sk-ant-LEAK",
            "CLAUDE_CONFIG_DIR": "/somewhere",
            "ANTHROPIC_API_KEY": "sk-ant-LEAK-2",
            "SHELL": "/bin/zsh",
            "TERM": "xterm-256color"
        ]
        let runner = FakeClaudeCLIProcessRunner(responses: [.success(0)])
        let renewer = makeRenewer(runner: runner, environment: processEnv)
        _ = await renewer.attemptRenewal()
        let env = runner.calls[0].environment
        let allowed: Set<String> = ["HOME", "USER", "LOGNAME", "LANG", "PATH"]
        XCTAssertEqual(Set(env.keys), allowed,
                       "environment keys must be exactly the allowed set; got \(env.keys)")
        for banned in ["CLAUDE_API_KEY", "CLAUDE_CONFIG_DIR", "ANTHROPIC_API_KEY", "SHELL", "TERM"] {
            XCTAssertNil(env[banned], "\(banned) must be stripped from the child env")
        }
    }

    func testEnvironmentPATHStartsWithSystemDirsAndEndsWithBinaryDirectory() async {
        let processEnv: [String: String] = [
            "HOME": "/Users/tester",
            "LANG": "en_US.UTF-8"
        ]
        let runner = FakeClaudeCLIProcessRunner(responses: [.success(0)])
        let renewer = makeRenewer(runner: runner, environment: processEnv)
        _ = await renewer.attemptRenewal()
        let path = runner.calls[0].environment["PATH"]
        XCTAssertEqual(path, "/usr/bin:/bin:/usr/sbin:/sbin:/Users/tester/.local/bin",
                       "PATH must be system dirs then the CLI's own directory, verbatim")
    }

    func testEnvironmentSkipsAllowedKeysAbsentFromParent() async {
        // If the parent process has no LANG set, we should NOT emit
        // an empty `LANG=` — an unset variable is different from an
        // empty one for some tools.
        let processEnv: [String: String] = ["HOME": "/Users/tester"]
        let runner = FakeClaudeCLIProcessRunner(responses: [.success(0)])
        let renewer = makeRenewer(runner: runner, environment: processEnv)
        _ = await renewer.attemptRenewal()
        let env = runner.calls[0].environment
        XCTAssertNil(env["LANG"], "LANG must be omitted when the parent has none")
        XCTAssertNil(env["USER"])
        XCTAssertNil(env["LOGNAME"])
        XCTAssertEqual(env["HOME"], "/Users/tester")
    }

    // MARK: - Success / failure / timeout outcomes

    func testExitZeroReturnsSucceeded() async {
        let runner = FakeClaudeCLIProcessRunner(responses: [.success(0)])
        let renewer = makeRenewer(runner: runner)
        let outcome = await renewer.attemptRenewal()
        XCTAssertEqual(outcome, .succeeded)
    }

    func testNonZeroExitReturnsFailed() async {
        let runner = FakeClaudeCLIProcessRunner(responses: [.success(2)])
        let renewer = makeRenewer(runner: runner)
        let outcome = await renewer.attemptRenewal()
        XCTAssertEqual(outcome, .failed)
    }

    func testTimeoutReturnsFailed() async {
        let runner = FakeClaudeCLIProcessRunner(responses: [.failure(ClaudeCLIProcessError.timedOut)])
        let renewer = makeRenewer(runner: runner)
        let outcome = await renewer.attemptRenewal()
        XCTAssertEqual(outcome, .failed)
    }

    func testLaunchFailureReturnsFailed() async {
        let runner = FakeClaudeCLIProcessRunner(responses: [.failure(ClaudeCLIProcessError.launchFailed)])
        let renewer = makeRenewer(runner: runner)
        let outcome = await renewer.attemptRenewal()
        XCTAssertEqual(outcome, .failed)
    }

    func testTimeoutIsPassedThroughToTheRunner() async {
        let runner = FakeClaudeCLIProcessRunner(responses: [.success(0)])
        let renewer = makeRenewer(runner: runner, timeout: 60)
        _ = await renewer.attemptRenewal()
        XCTAssertEqual(runner.calls[0].timeout, 60,
                       "CLI invocation timeout is 60 s")
    }

    // MARK: - Static curated env unit

    func testCuratedEnvironmentIsPureFunction() {
        let env = DefaultClaudeCLIRenewer.curatedEnvironment(
            processEnvironment: [
                "HOME": "/Users/tester",
                "USER": "tester",
                "LOGNAME": "tester",
                "LANG": "en_US.UTF-8",
                "CLAUDE_API_KEY": "sk-ant-oops",
                "PATH": "/some/junk"
            ],
            binaryDirectory: "/opt/homebrew/bin"
        )
        XCTAssertEqual(env["HOME"], "/Users/tester")
        XCTAssertEqual(env["USER"], "tester")
        XCTAssertEqual(env["LOGNAME"], "tester")
        XCTAssertEqual(env["LANG"], "en_US.UTF-8")
        XCTAssertEqual(env["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin")
        XCTAssertNil(env["CLAUDE_API_KEY"])
    }
}
