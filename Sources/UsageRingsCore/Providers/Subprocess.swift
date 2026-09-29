import Foundation

/// Internal subprocess helpers shared between `ProcessSecurityRunner` (which
/// forks `/usr/bin/security` for the Claude Keychain read) and
/// `ProcessClaudeCLIRunner` (which forks the user's own `claude` CLI to
/// trigger a Claude Code delegated token renewal).
///
/// Both callers need the same guarantees:
///  - Concurrent stdout / stderr drain so a child that writes more than the
///    ~64 KiB pipe buffer cannot deadlock.
///  - A caller-supplied wall-clock deadline; on expiry the child receives
///    SIGTERM immediately, and if it is still alive after a short grace
///    period we escalate to SIGKILL.
///  - The bridge between `Process.terminationHandler` (a callback) and an
///    `await`-able value uses a checked continuation that is resumed at
///    most once, even with two racing tasks (exit vs. deadline).
///  - No blocking `waitUntilExit()` call — that would pin a
///    cooperative-pool thread for the child's whole lifetime.
///
/// Keeping these helpers in one place avoids two copies of the same
/// non-trivial concurrency plumbing drifting apart.
///
/// Nothing here is public — the callers (both public runner types) shape
/// the caller-facing API.

// MARK: - Generic runner entry point

/// Errors bubbled up by the generic runner. Both public runner protocols
/// (`SecuritySubprocessRunner` and `ClaudeCLIProcessRunner`) surface these
/// through their own error types.
enum SubprocessRunError: Error, Equatable {
    /// `Process.run()` threw before the child started.
    case launchFailed
    /// The child did not exit within the caller's deadline.
    case timedOut
}

/// Run `executable` with `arguments` (and optional `environment` /
/// `currentDirectory`), draining stdout+stderr concurrently, bounded by
/// `timeout`. On timeout the child receives SIGTERM immediately and, if
/// still alive after `killGrace` seconds, SIGKILL.
///
/// Returns the exit status plus the raw stdout bytes. Stderr is drained but
/// never returned — some upstream binaries (`/usr/bin/security` in
/// particular) can write Keychain paths, service names, or account hints
/// to stderr, and we never want that anywhere near an error string that
/// might reach the popover.
///
/// Design notes:
///  - `AsyncPipeReader` uses `readabilityHandler` so the draining runs on a
///    Foundation-owned queue rather than on the Swift-concurrency executor.
///    `readDataToEndOfFile()` would block the calling thread for the
///    lifetime of the child; running many refreshes concurrently would
///    starve the cooperative pool.
///  - The termination bridge uses `terminationHandler` (which fires on the
///    process's private queue whether the child exited normally or was
///    terminated) plus a `CheckedContinuation` gated by `OneShot`, so the
///    exit-vs-deadline race cannot resume the continuation twice.
///  - Killing by PID (not by the captured `Process`) is a deliberate
///    choice: `Process` is not `Sendable` and we would otherwise have to
///    capture it in a detached task. The PID-reuse residual race is
///    documented on `ExitBox.finished`.
func runSubprocess(
    executable: URL,
    arguments: [String],
    environment: [String: String]? = nil,
    currentDirectory: URL? = nil,
    timeout: TimeInterval,
    killGrace: TimeInterval
) async throws -> (status: Int32, stdout: Data) {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    if let environment {
        process.environment = environment
    }
    if let currentDirectory {
        process.currentDirectoryURL = currentDirectory
    }
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    // Never share our stdin with the child. If we left `standardInput`
    // unset, the child would inherit the app's stdin — which for a
    // menu-bar SwiftUI process is a live tty when the app was launched
    // from the terminal (`swift run`, `open --stdout`), and a child
    // that reads from it (e.g. `cat` with no args, or an interactive
    // `claude` prompt fallback) would block indefinitely waiting for
    // input while the timeout gradually runs out.
    process.standardInput = FileHandle.nullDevice

    // Set the termination handler before `run()` so we cannot miss a
    // very-fast child.
    let exitBox = ExitBox()
    process.terminationHandler = { p in
        exitBox.finish(status: p.terminationStatus)
    }

    // Drain BEFORE launching so the pipes are draining from the moment the
    // child starts writing.
    let stdoutReader = AsyncPipeReader(fileHandle: stdoutPipe.fileHandleForReading)
    let stderrReader = AsyncPipeReader(fileHandle: stderrPipe.fileHandleForReading)
    stdoutReader.begin()
    stderrReader.begin()

    do {
        try process.run()
    } catch {
        stdoutReader.cancel()
        stderrReader.cancel()
        throw SubprocessRunError.launchFailed
    }

    let deadlineNS = UInt64(max(0.0, timeout) * 1_000_000_000)
    let exitStatus: Int32? = await awaitExitOrDeadline(
        exitBox: exitBox,
        deadlineNS: deadlineNS
    )

    guard let status = exitStatus else {
        // Timeout. SIGTERM immediately; schedule a SIGKILL escalation on a
        // detached task so the caller returns promptly.
        let pid = process.processIdentifier
        process.terminate()
        let killGraceNS = UInt64(max(0.0, killGrace) * 1_000_000_000)
        Task.detached { [exitBox] in
            try? await Task.sleep(nanoseconds: killGraceNS)
            // Skip the escalation once the child is gone — the PID may
            // belong to a recycled process by then.
            guard !exitBox.finished else { return }
            if pid > 0 {
                _ = Darwin.kill(pid, SIGKILL)
            }
        }
        stdoutReader.cancel()
        stderrReader.cancel()
        throw SubprocessRunError.timedOut
    }

    let stdoutData = await stdoutReader.wait()
    _ = await stderrReader.wait()
    return (status, stdoutData)
}

/// Race the process's exit against the caller's deadline. Returns the exit
/// status if it arrives first or `nil` on timeout. Both racing tasks are
/// one-shot: whichever fires first resumes the continuation; the loser is a
/// small leak (the sleep task's continuation returns nothing) that does
/// not delay the caller.
private func awaitExitOrDeadline(
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

// MARK: - Subprocess plumbing

/// Bridges `Process.terminationHandler` (a callback) to an `await`-able
/// value.
///
/// Also exposes a `finished` snapshot the timeout escalator reads to gate
/// its SIGKILL — once `terminationHandler` has fired for a child, sending
/// a signal to that PID is unsafe (the kernel may have recycled it).
final class ExitBox: @unchecked Sendable {
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
final class OneShot: @unchecked Sendable {
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
final class AsyncPipeReader: @unchecked Sendable {
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
