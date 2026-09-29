import XCTest
@testable import UsageRingsCore

/// Tests for `ClaudeProvider`, `SecuritySubprocessCredentialReader`, and
/// `ProcessSecurityRunner`.
///
/// A real Keychain call is never made: every credential-reader test injects
/// a `FakeSecuritySubprocessRunner`. The provider tests inject a
/// `FakeCredentialReader` and `RecordingTransport`. The one runner test that
/// launches a real subprocess uses `/bin/sh`, `/bin/echo`, `/bin/sleep`, or
/// `/bin/dd` — never `/usr/bin/security` and never the network. The fixture
/// used is `Tests/UsageRingsCoreTests/Fixtures/claude-usage.json`.
final class ClaudeProviderTests: XCTestCase {

    // MARK: - Test doubles

    /// Injectable credential reader. The store never sees real Keychain
    /// data in tests; the fake either yields a hand-crafted JSON body or
    /// throws.
    final class FakeCredentialReader: ClaudeCredentialReader, @unchecked Sendable {
        private let lock = NSLock()
        private var _present: Bool
        private var _readResult: Result<Data, Error>
        private var _readCallCount = 0
        private var _isPresentCallCount = 0

        init(present: Bool = true, readResult: Result<Data, Error>) {
            self._present = present
            self._readResult = readResult
        }

        var readCallCount: Int { withLock { _readCallCount } }
        var isPresentCallCount: Int { withLock { _isPresentCallCount } }

        private func withLock<T>(_ body: () -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            return body()
        }

        func isPresent() async -> Bool {
            withLock {
                _isPresentCallCount += 1
                return _present
            }
        }

        func read() async throws -> Data {
            let result: Result<Data, Error> = withLock {
                _readCallCount += 1
                return _readResult
            }
            switch result {
            case .success(let data): return data
            case .failure(let error): throw error
            }
        }
    }

    /// Clock stub that yields a scripted sequence of `Date`s in order
    /// so a test can observe the provider's behaviour when
    /// `now()` returns different values at the pre-flight expiry check
    /// vs. the 429 branch check. Falls back to the last provided value
    /// after the script is exhausted, so a test does not need to
    /// pre-compute every single call site.
    final class ClockStub: @unchecked Sendable {
        private let lock = NSLock()
        private var times: [Date]
        private var last: Date

        init(times: [Date]) {
            precondition(!times.isEmpty)
            self.times = times
            self.last = times.first!
        }

        func next() -> Date {
            lock.lock(); defer { lock.unlock() }
            if times.isEmpty { return last }
            last = times.removeFirst()
            return last
        }
    }

    /// Credential reader that yields a scripted sequence of bodies. Used
    /// to test the "read → 401 → renew → re-read (new body) → retry"
    /// path where the second read must observe a different token from
    /// the first.
    final class SequentialCredentialReader: ClaudeCredentialReader, @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [Data]
        private var _readCount = 0

        init(bodies: [Data]) {
            self.bodies = bodies
        }

        var readCount: Int {
            lock.lock(); defer { lock.unlock() }
            return _readCount
        }

        func isPresent() async -> Bool { true }

        func read() async throws -> Data {
            let next: Data? = {
                lock.lock(); defer { lock.unlock() }
                _readCount += 1
                guard !bodies.isEmpty else { return nil }
                return bodies.removeFirst()
            }()
            guard let data = next else {
                throw FetchError.other("Couldn't read Claude Code credentials from Keychain")
            }
            return data
        }
    }

    /// The shared `RecordingTransport` (see `TestSupport/RecordingTransport.swift`)
    /// is used verbatim; each test builds one bound to `ClaudeProvider.endpoint`
    /// so the returned `HTTPURLResponse.url` matches what production would emit.
    private func makeTransport() -> RecordingTransport {
        RecordingTransport(responseURL: ClaudeProvider.endpoint)
    }

    // MARK: - Helpers

    /// Sentinel token: if this string ever leaks into an error message we
    /// spot it immediately.
    static let sentinelToken = "sk-ant-oat01-TEST-SENTINEL-DO-NOT-LEAK"

    static func credentialJSON(
        token: String = sentinelToken,
        expiresAtMs: Int64 = 4_102_444_800_000
    ) -> Data {
        let dict: [String: Any] = [
            "mcpOAuth": [:],
            "claudeAiOauth": [
                "accessToken": token,
                "refreshToken": "sk-ant-ort01-refresh-placeholder",
                "expiresAt": expiresAtMs,
                "refreshTokenExpiresAt": expiresAtMs + 86_400_000,
                "scopes": ["a", "b"],
                "subscriptionType": "pro",
                "rateLimitTier": "default"
            ] as [String: Any]
        ]
        return try! JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    }

    private func fixture() throws -> Data {
        // Fail (not skip): the fixture is checked in and must be readable.
        // A missing fixture is a build-system regression, not an environmental
        // absence.
        let url = Bundle.module.url(forResource: "claude-usage", withExtension: "json", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "claude-usage", withExtension: "json")
        guard let url else {
            XCTFail("claude-usage.json fixture not found in test bundle")
            throw FetchError.other("fixture missing")
        }
        return try Data(contentsOf: url)
    }

    private func makeProvider(
        credentials: ClaudeCredentialReader,
        transport: HTTPTransport,
        renewer: any ClaudeCLIRenewer = DisabledClaudeCLIRenewer(),
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_780_000_000) }
    ) -> ClaudeProvider {
        ClaudeProvider(transport: transport, credentials: credentials, renewer: renewer, now: now)
    }

    // MARK: - Request construction

    func testFetchIssuesGETWithBearerAndAnthropicBetaAndAccept() async throws {
        let creds = FakeCredentialReader(readResult: .success(Self.credentialJSON()))
        let transport = makeTransport()
        transport.enqueue(status: 200, body: try fixture())
        let provider = makeProvider(credentials: creds, transport: transport)

        _ = try await provider.fetch()

        XCTAssertEqual(transport.requests.count, 1)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer \(Self.sentinelToken)"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "anthropic-beta"),
            "oauth-2025-04-20"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Accept"),
            "application/json"
        )
        XCTAssertEqual(creds.readCallCount, 1, "one read() per fetch()")
    }

    // MARK: - User-Agent (Claude request identity)

    func testFetchSendsClaudeCodeUserAgentHeader() async throws {
        // Without a `claude-code/*` User-Agent the endpoint answers 429
        // instead of the true status (observed 2026-09-29). Load-bearing
        // header — assert its exact value against the named constant so a
        // rename or typo lights up here.
        let creds = FakeCredentialReader(readResult: .success(Self.credentialJSON()))
        let transport = makeTransport()
        transport.enqueue(status: 200, body: try fixture())
        let provider = makeProvider(credentials: creds, transport: transport)

        _ = try await provider.fetch()

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "User-Agent"),
            ClaudeProvider.userAgent
        )
        XCTAssertEqual(ClaudeProvider.userAgent, "claude-code/2.1.0",
                       "constant is load-bearing and must be verbatim")
    }

    // MARK: - Parsing

    func testParsesFiveHourAndSevenDayFromFixture() async throws {
        let creds = FakeCredentialReader(readResult: .success(Self.credentialJSON()))
        let transport = makeTransport()
        transport.enqueue(status: 200, body: try fixture())
        let fixedNow = Date(timeIntervalSince1970: 1_780_000_000)
        let provider = makeProvider(credentials: creds, transport: transport, now: { fixedNow })

        let usage = try await provider.fetch()

        XCTAssertEqual(usage.id, .claude)
        XCTAssertNil(usage.plan, "plan name is nil unless explicitly present")
        XCTAssertEqual(usage.fetchedAt, fixedNow)
        XCTAssertEqual(usage.windows.count, 2)
        XCTAssertEqual(creds.readCallCount, 1)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let fiveHour = try XCTUnwrap(usage.windows.first(where: { $0.kind == .fiveHour }))
        XCTAssertEqual(fiveHour.label, "5h")
        XCTAssertEqual(fiveHour.usedPercent, 5.0, accuracy: 0.0001)
        XCTAssertEqual(fiveHour.resetsAt, formatter.date(from: "2026-09-28T22:49:59.633107+00:00"))

        let weekly = try XCTUnwrap(usage.windows.first(where: { $0.kind == .weekly }))
        XCTAssertEqual(weekly.label, "Weekly")
        XCTAssertEqual(weekly.usedPercent, 1.0, accuracy: 0.0001)
        XCTAssertEqual(weekly.resetsAt, formatter.date(from: "2026-10-02T19:59:59.633130+00:00"))
    }

    func testNullFiveHourAndSevenDayAreSkipped() async throws {
        // Both keys present but null → OK, zero windows.
        let body: [String: Any] = [
            "five_hour": NSNull(),
            "seven_day": NSNull(),
            "seven_day_opus": NSNull(),
            "extra_usage": ["is_enabled": false]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let creds = FakeCredentialReader(readResult: .success(Self.credentialJSON()))
        let transport = makeTransport()
        transport.enqueue(status: 200, body: data)
        let provider = makeProvider(credentials: creds, transport: transport)

        let usage = try await provider.fetch()
        XCTAssertEqual(usage.windows.count, 0)
    }

    func testUnknownWindowsAreIgnored() async throws {
        let body: [String: Any] = [
            "five_hour": [
                "utilization": 12.5,
                "resets_at": "2026-09-28T22:49:59.633107+00:00"
            ] as [String: Any],
            "seven_day": NSNull(),
            "iguana_necktie": [
                "utilization": 3.0,
                "resets_at": "2026-11-05T07:59:00+00:00"
            ] as [String: Any]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let creds = FakeCredentialReader(readResult: .success(Self.credentialJSON()))
        let transport = makeTransport()
        transport.enqueue(status: 200, body: data)
        let provider = makeProvider(credentials: creds, transport: transport)

        let usage = try await provider.fetch()
        XCTAssertEqual(usage.windows.count, 1)
        XCTAssertEqual(usage.windows.first?.kind, .fiveHour)
    }

    func testIntegerUtilizationIsAccepted() async throws {
        let body: [String: Any] = [
            "five_hour": [
                "utilization": 7,
                "resets_at": "2026-09-28T22:49:59.633107+00:00"
            ] as [String: Any]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let creds = FakeCredentialReader(readResult: .success(Self.credentialJSON()))
        let transport = makeTransport()
        transport.enqueue(status: 200, body: data)
        let provider = makeProvider(credentials: creds, transport: transport)

        let usage = try await provider.fetch()
        XCTAssertEqual(usage.windows.first?.usedPercent, 7.0)
    }

    // MARK: - Strict-parsing failures

    func testEmptyJSONObjectYieldsParseError() async throws {
        // `{}` — neither five_hour nor seven_day present. The API silently
        // renaming both fields must NOT surface as an OK ring with no data.
        let data = try JSONSerialization.data(withJSONObject: [String: Any]())
        let creds = FakeCredentialReader(readResult: .success(Self.credentialJSON()))
        let transport = makeTransport()
        transport.enqueue(status: 200, body: data)
        let provider = makeProvider(credentials: creds, transport: transport)

        do {
            _ = try await provider.fetch()
            XCTFail("expected parse error")
        } catch let error as FetchError {
            guard case .parse = error else {
                return XCTFail("expected .parse, got \(error)")
            }
        }
    }

    func testWindowPresentWithoutUtilizationYieldsParseError() async throws {
        // `{"five_hour":{"util":5}}` — key present, object present, but
        // `utilization` renamed to `util`. Must be an error, not "0 %".
        let body: [String: Any] = [
            "five_hour": ["util": 5, "resets_at": "2026-09-28T22:49:59.633107+00:00"] as [String: Any]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let creds = FakeCredentialReader(readResult: .success(Self.credentialJSON()))
        let transport = makeTransport()
        transport.enqueue(status: 200, body: data)
        let provider = makeProvider(credentials: creds, transport: transport)

        do {
            _ = try await provider.fetch()
            XCTFail("expected parse error")
        } catch let error as FetchError {
            guard case .parse = error else {
                return XCTFail("expected .parse, got \(error)")
            }
        }
    }

    func testUtilizationBooleanYieldsParseError() async throws {
        // JSON `true` bridges to NSNumber wrapping a CFBoolean; a naive
        // `raw as? Double` reads it as 1.0 and the ring silently sits at
        // 1%. Must be rejected as a parse error.
        let body: [String: Any] = [
            "five_hour": [
                "utilization": true,
                "resets_at": "2026-09-28T22:49:59.633107+00:00"
            ] as [String: Any]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let creds = FakeCredentialReader(readResult: .success(Self.credentialJSON()))
        let transport = makeTransport()
        transport.enqueue(status: 200, body: data)
        let provider = makeProvider(credentials: creds, transport: transport)

        do {
            _ = try await provider.fetch()
            XCTFail("expected parse error")
        } catch let error as FetchError {
            guard case .parse = error else {
                return XCTFail("expected .parse, got \(error)")
            }
        }
    }

    func testResponseNotAnObjectYieldsParseError() async throws {
        // `[]` — root is an array, not an object. Must be an error.
        let data = try JSONSerialization.data(withJSONObject: [Any]())
        let creds = FakeCredentialReader(readResult: .success(Self.credentialJSON()))
        let transport = makeTransport()
        transport.enqueue(status: 200, body: data)
        let provider = makeProvider(credentials: creds, transport: transport)

        do {
            _ = try await provider.fetch()
            XCTFail("expected parse error")
        } catch let error as FetchError {
            guard case .parse = error else {
                return XCTFail("expected .parse, got \(error)")
            }
        }
    }

    func testOnlyOneOfFiveHourAndSevenDayPresentIsOK() async throws {
        // If `five_hour` is a key (even null) but `seven_day` is missing
        // entirely, we still consider the shape "known" — the endpoint has
        // deliberately hidden the weekly window (as it does for some plan
        // states), rather than silently renaming it. One-window ring.
        let body: [String: Any] = [
            "five_hour": [
                "utilization": 4.0,
                "resets_at": "2026-09-28T22:49:59.633107+00:00"
            ] as [String: Any]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let creds = FakeCredentialReader(readResult: .success(Self.credentialJSON()))
        let transport = makeTransport()
        transport.enqueue(status: 200, body: data)
        let provider = makeProvider(credentials: creds, transport: transport)

        let usage = try await provider.fetch()
        XCTAssertEqual(usage.windows.count, 1)
        XCTAssertEqual(usage.windows.first?.kind, .fiveHour)
    }

    // MARK: - Pre-flight expiry check

    func testPastExpiresAtWithDefaultRenewerSkipsHTTPCall() async throws {
        // If the stored `expiresAt` is already past, the provider tries
        // to renew BEFORE hitting the
        // usage endpoint. With the default `DisabledClaudeCLIRenewer`
        // that returns `.disabled` and the row is
        // "Open Claude Code to refresh" — with NO HTTP call fired.
        let pastMs: Int64 = 1_000_000_000_000 // 2001
        let creds = FakeCredentialReader(readResult: .success(Self.credentialJSON(expiresAtMs: pastMs)))
        let transport = makeTransport()
        transport.enqueue(status: 200, body: try fixture())
        let provider = makeProvider(credentials: creds, transport: transport)

        do {
            _ = try await provider.fetch()
            XCTFail("expected signedOut")
        } catch let error as FetchError {
            XCTAssertEqual(error, .signedOut("Open Claude Code to refresh"))
        }
        XCTAssertEqual(transport.requests.count, 0,
                       "expired credential + disabled renewer must not call the endpoint")
    }

    func testFutureExpiresAtStillIssuesTheRequest() async throws {
        // A valid-looking token proceeds to the HTTP call as before.
        let futureMs: Int64 = 4_102_444_800_000 // 2100
        let creds = FakeCredentialReader(readResult: .success(Self.credentialJSON(expiresAtMs: futureMs)))
        let transport = makeTransport()
        transport.enqueue(status: 200, body: try fixture())
        let provider = makeProvider(credentials: creds, transport: transport)

        _ = try await provider.fetch()
        XCTAssertEqual(transport.requests.count, 1, "future expiresAt must not trigger renewal")
    }

    // MARK: - Error paths

    func testMissingTokenInCredentialJSONYieldsSignedOut() async throws {
        let credentialWithoutToken = try JSONSerialization.data(
            withJSONObject: ["claudeAiOauth": ["expiresAt": 0] as [String: Any]]
        )
        let creds = FakeCredentialReader(readResult: .success(credentialWithoutToken))
        let transport = makeTransport()
        let provider = makeProvider(credentials: creds, transport: transport)

        do {
            _ = try await provider.fetch()
            XCTFail("expected signedOut")
        } catch let error as FetchError {
            XCTAssertEqual(error, .signedOut("Open Claude Code to refresh"))
        }
        XCTAssertEqual(transport.requests.count, 0, "no request must fire when token is missing")
    }

    func testCredentialReaderThatThrowsOtherIsPassedThrough() async {
        // Runner-level "Couldn't read..." must reach the store unchanged.
        let creds = FakeCredentialReader(readResult: .failure(FetchError.other("Couldn't read Claude Code credentials from Keychain")))
        let transport = makeTransport()
        let provider = makeProvider(credentials: creds, transport: transport)

        do {
            _ = try await provider.fetch()
            XCTFail("expected other")
        } catch let error as FetchError {
            XCTAssertEqual(error, .other("Couldn't read Claude Code credentials from Keychain"))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testMalformedCredentialJSONYieldsParseErrorWithoutLeakingBytes() async {
        let junk = Data("not-json-\(Self.sentinelToken)".utf8)
        let creds = FakeCredentialReader(readResult: .success(junk))
        let transport = makeTransport()
        let provider = makeProvider(credentials: creds, transport: transport)

        do {
            _ = try await provider.fetch()
            XCTFail("expected parse error")
        } catch let error as FetchError {
            switch error {
            case .parse(let message):
                XCTAssertFalse(message.contains(Self.sentinelToken),
                               "credential bytes must never appear in the error message")
                XCTAssertFalse(message.contains("not-json"),
                               "credential bytes must never appear in the error message")
            default:
                XCTFail("expected .parse, got \(error)")
            }
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testMalformedUsageJSONYieldsParseError() async throws {
        let creds = FakeCredentialReader(readResult: .success(Self.credentialJSON()))
        let transport = makeTransport()
        transport.enqueue(status: 200, body: Data("<html>oops</html>".utf8))
        let provider = makeProvider(credentials: creds, transport: transport)

        do {
            _ = try await provider.fetch()
            XCTFail("expected parse error")
        } catch let error as FetchError {
            guard case .parse = error else {
                return XCTFail("expected .parse, got \(error)")
            }
        }
    }

    func testHTTP401WithDefaultRenewerMapsToOpenClaudeCode() async throws {
        // Default renewer is `DisabledClaudeCLIRenewer`, which returns
        // `.disabled` — the provider surfaces "Open Claude Code to
        // refresh" without ever forking the CLI.
        let creds = FakeCredentialReader(readResult: .success(Self.credentialJSON()))
        let transport = makeTransport()
        transport.enqueue(status: 401, body: Data("{\"error\":\"unauthorized\"}".utf8))
        let provider = makeProvider(credentials: creds, transport: transport)

        do {
            _ = try await provider.fetch()
            XCTFail("expected signedOut")
        } catch let error as FetchError {
            XCTAssertEqual(error, .signedOut("Open Claude Code to refresh"))
        }
    }

    func testHTTP403MapsToSignedOut() async throws {
        let creds = FakeCredentialReader(readResult: .success(Self.credentialJSON()))
        let transport = makeTransport()
        transport.enqueue(status: 403, body: Data())
        let provider = makeProvider(credentials: creds, transport: transport)

        do {
            _ = try await provider.fetch()
            XCTFail("expected signedOut")
        } catch let error as FetchError {
            XCTAssertEqual(error, .signedOut("Open Claude Code to refresh"))
        }
    }

    func testHTTP429MapsToRateLimitedWithRetryAfter() async throws {
        let creds = FakeCredentialReader(readResult: .success(Self.credentialJSON()))
        let transport = makeTransport()
        transport.enqueue(status: 429, body: Data(), headers: ["Retry-After": "45"])
        let provider = makeProvider(credentials: creds, transport: transport)

        do {
            _ = try await provider.fetch()
            XCTFail("expected rateLimited")
        } catch let error as FetchError {
            XCTAssertEqual(error, .rateLimited(retryAfter: 45))
        }
    }

    func testHTTP500MapsToServer() async throws {
        let creds = FakeCredentialReader(readResult: .success(Self.credentialJSON()))
        let transport = makeTransport()
        transport.enqueue(status: 503, body: Data())
        let provider = makeProvider(credentials: creds, transport: transport)

        do {
            _ = try await provider.fetch()
            XCTFail("expected server")
        } catch let error as FetchError {
            XCTAssertEqual(error, .server(503))
        }
    }

    func testConnectivityURLErrorMapsToOffline() async throws {
        let creds = FakeCredentialReader(readResult: .success(Self.credentialJSON()))
        let transport = makeTransport()
        transport.enqueue(error: URLError(.notConnectedToInternet))
        let provider = makeProvider(credentials: creds, transport: transport)

        do {
            _ = try await provider.fetch()
            XCTFail("expected offline")
        } catch let error as FetchError {
            XCTAssertEqual(error, .offline)
        }
    }

    func testTimeoutURLErrorMapsToTimeout() async throws {
        let creds = FakeCredentialReader(readResult: .success(Self.credentialJSON()))
        let transport = makeTransport()
        transport.enqueue(error: URLError(.timedOut))
        let provider = makeProvider(credentials: creds, transport: transport)

        do {
            _ = try await provider.fetch()
            XCTFail("expected timeout")
        } catch let error as FetchError {
            XCTAssertEqual(error, .timeout)
        }
    }

    // MARK: - Delegated CLI renewal

    /// A ClaudeCLIRenewer test double whose outcome is programmable.
    ///
    /// `attemptRenewal()` also records how many times it was called so a
    /// test can assert the provider never called it (toggle-off /
    /// disabled path) or called it exactly once (retry path).
    final class FakeClaudeCLIRenewer: ClaudeCLIRenewer, @unchecked Sendable {
        private let lock = NSLock()
        private var _outcomes: [ClaudeRenewalOutcome]
        private var _callCount = 0
        private var _markIneffectiveCallCount = 0

        init(outcomes: [ClaudeRenewalOutcome]) {
            self._outcomes = outcomes
        }

        var callCount: Int {
            lock.lock(); defer { lock.unlock() }
            return _callCount
        }

        var markIneffectiveCallCount: Int {
            lock.lock(); defer { lock.unlock() }
            return _markIneffectiveCallCount
        }

        func attemptRenewal() async -> ClaudeRenewalOutcome {
            popNextOutcome()
        }

        func markLastRenewalIneffective() {
            lock.lock(); defer { lock.unlock() }
            _markIneffectiveCallCount += 1
        }

        /// Non-async helper so `NSLock.lock()` (which the Swift 6
        /// compiler disallows from async contexts) does not leak into
        /// `attemptRenewal()`.
        private func popNextOutcome() -> ClaudeRenewalOutcome {
            lock.lock(); defer { lock.unlock() }
            _callCount += 1
            guard !_outcomes.isEmpty else { return .failed }
            return _outcomes.removeFirst()
        }
    }

    func testHTTP401WithSucceededRenewalReReadsCredentialAndRetriesOK() async throws {
        // Two credential reads: first returns the original (expired-seeming)
        // token; second returns a "renewed" one. Two HTTP responses: 401
        // then 200 with the fixture.
        let originalToken = "sk-ant-oat01-EXPIRED"
        let renewedToken = "sk-ant-oat01-RENEWED"
        let firstBody = Self.credentialJSON(token: originalToken)
        let secondBody = Self.credentialJSON(token: renewedToken)
        let reader = SequentialCredentialReader(bodies: [firstBody, secondBody])
        let transport = makeTransport()
        transport.enqueue(status: 401, body: Data("{}".utf8))
        transport.enqueue(status: 200, body: try fixture())
        let renewer = FakeClaudeCLIRenewer(outcomes: [.succeeded])
        let provider = makeProvider(credentials: reader, transport: transport, renewer: renewer)

        let usage = try await provider.fetch()

        XCTAssertEqual(renewer.callCount, 1, "renewer must be invoked exactly once on 401")
        XCTAssertEqual(reader.readCount, 2, "credential must be re-read after successful renewal")
        XCTAssertEqual(transport.requests.count, 2, "usage call must be retried exactly once")
        // The retry must carry the NEW token, not the original.
        XCTAssertEqual(
            transport.requests[0].value(forHTTPHeaderField: "Authorization"),
            "Bearer \(originalToken)"
        )
        XCTAssertEqual(
            transport.requests[1].value(forHTTPHeaderField: "Authorization"),
            "Bearer \(renewedToken)"
        )
        XCTAssertEqual(usage.windows.count, 2, "retry parsed the fixture successfully")
    }

    func testHTTP401ThenRenewalSucceededButRetryStill401YieldsRunClaudeInTerminal() async throws {
        // The CLI ran but the endpoint still rejects the new token — the
        // user must resolve it themselves.
        let reader = SequentialCredentialReader(bodies: [
            Self.credentialJSON(token: "t1"),
            Self.credentialJSON(token: "t2")
        ])
        let transport = makeTransport()
        transport.enqueue(status: 401, body: Data())
        transport.enqueue(status: 401, body: Data())
        let renewer = FakeClaudeCLIRenewer(outcomes: [.succeeded])
        let provider = makeProvider(credentials: reader, transport: transport, renewer: renewer)

        do {
            _ = try await provider.fetch()
            XCTFail("expected signedOut")
        } catch let error as FetchError {
            XCTAssertEqual(error, .signedOut("Run `claude` in Terminal to sign in"))
        }
    }

    func testHTTP401WithRenewerFailedYieldsRunClaudeInTerminal() async throws {
        let creds = FakeCredentialReader(readResult: .success(Self.credentialJSON()))
        let transport = makeTransport()
        transport.enqueue(status: 401, body: Data())
        let renewer = FakeClaudeCLIRenewer(outcomes: [.failed])
        let provider = makeProvider(credentials: creds, transport: transport, renewer: renewer)

        do {
            _ = try await provider.fetch()
            XCTFail("expected signedOut")
        } catch let error as FetchError {
            XCTAssertEqual(error, .signedOut("Run `claude` in Terminal to sign in"))
        }
        XCTAssertEqual(transport.requests.count, 1, "no retry when renewer failed")
    }

    func testHTTP401WithNoBinaryYieldsOpenClaudeCode() async throws {
        let creds = FakeCredentialReader(readResult: .success(Self.credentialJSON()))
        let transport = makeTransport()
        transport.enqueue(status: 401, body: Data())
        let renewer = FakeClaudeCLIRenewer(outcomes: [.noBinary])
        let provider = makeProvider(credentials: creds, transport: transport, renewer: renewer)

        do {
            _ = try await provider.fetch()
            XCTFail("expected signedOut")
        } catch let error as FetchError {
            XCTAssertEqual(error, .signedOut("Open Claude Code to refresh"))
        }
    }

    func testHTTP401InCooldownYieldsOpenClaudeCode() async throws {
        let creds = FakeCredentialReader(readResult: .success(Self.credentialJSON()))
        let transport = makeTransport()
        transport.enqueue(status: 401, body: Data())
        let renewer = FakeClaudeCLIRenewer(outcomes: [.inCooldown])
        let provider = makeProvider(credentials: creds, transport: transport, renewer: renewer)

        do {
            _ = try await provider.fetch()
            XCTFail("expected signedOut")
        } catch let error as FetchError {
            XCTAssertEqual(error, .signedOut("Open Claude Code to refresh"))
        }
    }

    func testHTTP401WithDisabledRenewerYieldsOpenClaudeCode() async throws {
        let creds = FakeCredentialReader(readResult: .success(Self.credentialJSON()))
        let transport = makeTransport()
        transport.enqueue(status: 401, body: Data())
        let renewer = FakeClaudeCLIRenewer(outcomes: [.disabled])
        let provider = makeProvider(credentials: creds, transport: transport, renewer: renewer)

        do {
            _ = try await provider.fetch()
            XCTFail("expected signedOut")
        } catch let error as FetchError {
            XCTAssertEqual(error, .signedOut("Open Claude Code to refresh"))
        }
    }

    func testDisabledRenewerIsNotCalledOnNon401Responses() async throws {
        // 200 response — renewer must never be consulted on a successful
        // fetch. If the provider always called it defensively we would
        // waste a Claude prompt on every refresh.
        let creds = FakeCredentialReader(readResult: .success(Self.credentialJSON()))
        let transport = makeTransport()
        transport.enqueue(status: 200, body: try fixture())
        let renewer = FakeClaudeCLIRenewer(outcomes: [.succeeded])
        let provider = makeProvider(credentials: creds, transport: transport, renewer: renewer)

        _ = try await provider.fetch()
        XCTAssertEqual(renewer.callCount, 0, "renewer must only be consulted on 401")
    }

    func testHTTP403DoesNotTriggerRenewal() async throws {
        // 403 is not the "token expired" signal — renewal cannot fix a
        // permission failure and we do not want to burn Claude usage
        // pretending it can.
        let creds = FakeCredentialReader(readResult: .success(Self.credentialJSON()))
        let transport = makeTransport()
        transport.enqueue(status: 403, body: Data())
        let renewer = FakeClaudeCLIRenewer(outcomes: [.succeeded])
        let provider = makeProvider(credentials: creds, transport: transport, renewer: renewer)

        do {
            _ = try await provider.fetch()
            XCTFail("expected signedOut")
        } catch let error as FetchError {
            XCTAssertEqual(error, .signedOut("Open Claude Code to refresh"))
        }
        XCTAssertEqual(renewer.callCount, 0)
    }

    // MARK: - Pre-flight renewal on expired credential

    func testExpiredCredentialPreflightRenewalReReadsAndFetchesExactlyOnce() async throws {
        // expiresAt past → renew → re-read → one usage call, after renewal.
        let pastMs: Int64 = 1_000_000_000_000
        let futureMs: Int64 = 4_102_444_800_000
        let reader = SequentialCredentialReader(bodies: [
            Self.credentialJSON(token: "expired-token", expiresAtMs: pastMs),
            Self.credentialJSON(token: "renewed-token", expiresAtMs: futureMs)
        ])
        let transport = makeTransport()
        transport.enqueue(status: 200, body: try fixture())
        let renewer = FakeClaudeCLIRenewer(outcomes: [.succeeded])
        let provider = makeProvider(credentials: reader, transport: transport, renewer: renewer)

        let usage = try await provider.fetch()

        XCTAssertEqual(renewer.callCount, 1, "one pre-flight renewal attempt")
        XCTAssertEqual(reader.readCount, 2, "credential re-read after renewal")
        XCTAssertEqual(transport.requests.count, 1,
                       "usage endpoint is called exactly once, after renewal")
        XCTAssertEqual(
            transport.requests[0].value(forHTTPHeaderField: "Authorization"),
            "Bearer renewed-token",
            "the sole HTTP request must carry the post-renewal token"
        )
        XCTAssertEqual(usage.windows.count, 2)
    }

    func testExpiredCredentialInCooldownSkipsHTTPCall() async throws {
        // Expired + cooldown → no HTTP call.
        let pastMs: Int64 = 1_000_000_000_000
        let creds = FakeCredentialReader(readResult: .success(Self.credentialJSON(expiresAtMs: pastMs)))
        let transport = makeTransport()
        transport.enqueue(status: 200, body: try fixture())
        let renewer = FakeClaudeCLIRenewer(outcomes: [.inCooldown])
        let provider = makeProvider(credentials: creds, transport: transport, renewer: renewer)

        do {
            _ = try await provider.fetch()
            XCTFail("expected signedOut")
        } catch let error as FetchError {
            XCTAssertEqual(error, .signedOut("Open Claude Code to refresh"))
        }
        XCTAssertEqual(transport.requests.count, 0,
                       "cooldown on an expired credential must not call the endpoint")
    }

    func testExpiredCredentialInCooldownAfterFailureKeepsRunClaudeText() async throws {
        // After a failed renewal, keep "Run `claude` in Terminal to
        // sign in" while the cooldown runs.
        let pastMs: Int64 = 1_000_000_000_000
        let creds = FakeCredentialReader(readResult: .success(Self.credentialJSON(expiresAtMs: pastMs)))
        let transport = makeTransport()
        let renewer = FakeClaudeCLIRenewer(outcomes: [.inCooldownAfterFailure])
        let provider = makeProvider(credentials: creds, transport: transport, renewer: renewer)

        do {
            _ = try await provider.fetch()
            XCTFail("expected signedOut")
        } catch let error as FetchError {
            XCTAssertEqual(error, .signedOut("Run `claude` in Terminal to sign in"))
        }
        XCTAssertEqual(transport.requests.count, 0)
    }

    func testExpiredCredentialWithRenewerFailedYieldsRunClaudeAndNoHTTP() async throws {
        let pastMs: Int64 = 1_000_000_000_000
        let creds = FakeCredentialReader(readResult: .success(Self.credentialJSON(expiresAtMs: pastMs)))
        let transport = makeTransport()
        let renewer = FakeClaudeCLIRenewer(outcomes: [.failed])
        let provider = makeProvider(credentials: creds, transport: transport, renewer: renewer)

        do {
            _ = try await provider.fetch()
            XCTFail("expected signedOut")
        } catch let error as FetchError {
            XCTAssertEqual(error, .signedOut("Run `claude` in Terminal to sign in"))
        }
        XCTAssertEqual(transport.requests.count, 0)
    }

    func testExpiredCredentialPreflightSucceededThen401MapsToRunClaudeAndNoSecondRenewal() async throws {
        // Pre-flight succeeded, retry (which is the sole HTTP call this
        // fetch) returns 401 → "Run `claude` in Terminal to sign
        // in", NO second renewal attempt inside this fetch, and the
        // renewer is told the attempt was ineffective so the cooldown
        // row keeps the same text.
        let pastMs: Int64 = 1_000_000_000_000
        let futureMs: Int64 = 4_102_444_800_000
        let reader = SequentialCredentialReader(bodies: [
            Self.credentialJSON(token: "expired", expiresAtMs: pastMs),
            Self.credentialJSON(token: "renewed-but-broken", expiresAtMs: futureMs)
        ])
        let transport = makeTransport()
        transport.enqueue(status: 401, body: Data())
        let renewer = FakeClaudeCLIRenewer(outcomes: [.succeeded])
        let provider = makeProvider(credentials: reader, transport: transport, renewer: renewer)

        do {
            _ = try await provider.fetch()
            XCTFail("expected signedOut")
        } catch let error as FetchError {
            XCTAssertEqual(error, .signedOut("Run `claude` in Terminal to sign in"))
        }
        XCTAssertEqual(renewer.callCount, 1,
                       "renewer must be called exactly once — the pre-flight — and NOT again on 401")
        XCTAssertEqual(transport.requests.count, 1,
                       "usage endpoint is called exactly once, after pre-flight renewal")
        XCTAssertEqual(renewer.markIneffectiveCallCount, 1,
                       "provider must tell the renewer the pre-flight was ineffective")
    }

    func testExpiredCredentialPreflightNoBinaryYieldsOpenClaudeCodeAndNoHTTP() async throws {
        // Explicit variant of the "no HTTP call" test — a Mac with no
        // `claude` on disk must never hit the usage endpoint for a
        // pre-expired token.
        let pastMs: Int64 = 1_000_000_000_000
        let creds = FakeCredentialReader(readResult: .success(Self.credentialJSON(expiresAtMs: pastMs)))
        let transport = makeTransport()
        let renewer = FakeClaudeCLIRenewer(outcomes: [.noBinary])
        let provider = makeProvider(credentials: creds, transport: transport, renewer: renewer)

        do {
            _ = try await provider.fetch()
            XCTFail("expected signedOut")
        } catch let error as FetchError {
            XCTAssertEqual(error, .signedOut("Open Claude Code to refresh"))
        }
        XCTAssertEqual(transport.requests.count, 0)
        XCTAssertEqual(renewer.markIneffectiveCallCount, 0)
    }

    func testExpiredCredentialPreflightSucceededThenReReadFailsMapsToRunClaude() async throws {
        // If the re-read after a successful pre-flight renewal fails
        // (or the extracted token is missing), surface
        // "Run `claude` in Terminal to sign in" — same as the 401
        // retry path — not the raw reader error, and mark the renewal
        // ineffective so the cooldown keeps that text.
        let pastMs: Int64 = 1_000_000_000_000
        // First read succeeds (returns expired body); second read throws.
        final class FirstThenThrowingReader: ClaudeCredentialReader, @unchecked Sendable {
            let firstBody: Data
            let lock = NSLock()
            var callCount = 0
            init(firstBody: Data) { self.firstBody = firstBody }
            func isPresent() async -> Bool { true }
            func read() async throws -> Data {
                let n: Int = { lock.lock(); defer { lock.unlock() }; callCount += 1; return callCount }()
                if n == 1 { return firstBody }
                throw FetchError.other("Couldn't read Claude Code credentials from Keychain")
            }
        }
        let reader = FirstThenThrowingReader(firstBody: Self.credentialJSON(expiresAtMs: pastMs))
        let transport = makeTransport()
        let renewer = FakeClaudeCLIRenewer(outcomes: [.succeeded])
        let provider = makeProvider(credentials: reader, transport: transport, renewer: renewer)

        do {
            _ = try await provider.fetch()
            XCTFail("expected signedOut")
        } catch let error as FetchError {
            XCTAssertEqual(error, .signedOut("Run `claude` in Terminal to sign in"))
        }
        XCTAssertEqual(transport.requests.count, 0,
                       "re-read failure must NOT be followed by a usage call")
        XCTAssertEqual(renewer.markIneffectiveCallCount, 1)
    }

    func testExpiredCredentialPreflightSucceededThenReReadMissingTokenMapsToRunClaude() async throws {
        // Same guarantee for the "extractAccessToken" branch: a
        // re-read that succeeds but yields a body without a usable
        // accessToken must become "Run `claude`", not "Open Claude
        // Code to refresh" (the raw extractor throws signedOut with
        // that text) — and must mark the renewal ineffective.
        let pastMs: Int64 = 1_000_000_000_000
        let futureMs: Int64 = 4_102_444_800_000
        let bodyWithoutToken = try JSONSerialization.data(
            withJSONObject: [
                "claudeAiOauth": [
                    "expiresAt": futureMs
                ] as [String: Any]
            ]
        )
        let reader = SequentialCredentialReader(bodies: [
            Self.credentialJSON(expiresAtMs: pastMs),
            bodyWithoutToken
        ])
        let transport = makeTransport()
        let renewer = FakeClaudeCLIRenewer(outcomes: [.succeeded])
        let provider = makeProvider(credentials: reader, transport: transport, renewer: renewer)

        do {
            _ = try await provider.fetch()
            XCTFail("expected signedOut")
        } catch let error as FetchError {
            XCTAssertEqual(error, .signedOut("Run `claude` in Terminal to sign in"))
        }
        XCTAssertEqual(transport.requests.count, 0)
        XCTAssertEqual(renewer.markIneffectiveCallCount, 1)
    }

    // MARK: - Ineffective renewal marks cooldown correctly

    func testHTTP401RetryReturns429WithReReadStillExpiredMapsToSignedOutNoRetryAfter() async throws {
        // A 429 received while the stored expiresAt is past is shown
        // as signed out. This applies not just to the pre-flight
        // path but also to the 401-retry path — a CLI that "succeeds"
        // but writes a still-expired credential, followed by a 429 from
        // the endpoint, must not lock the ring out for a Retry-After
        // window.
        let pastMs: Int64 = 1_000_000_000_000
        let reader = SequentialCredentialReader(bodies: [
            Self.credentialJSON(token: "t1"),
            Self.credentialJSON(token: "t2", expiresAtMs: pastMs) // still expired after renewal
        ])
        let transport = makeTransport()
        transport.enqueue(status: 401, body: Data())                              // initial call
        transport.enqueue(status: 429, body: Data(), headers: ["Retry-After": "3600"]) // retry
        let renewer = FakeClaudeCLIRenewer(outcomes: [.succeeded])
        let provider = makeProvider(credentials: reader, transport: transport, renewer: renewer)

        do {
            _ = try await provider.fetch()
            XCTFail("expected signedOut, not rateLimited")
        } catch let error as FetchError {
            XCTAssertEqual(error, .signedOut("Run `claude` in Terminal to sign in"))
        }
        XCTAssertEqual(renewer.markIneffectiveCallCount, 1,
                       "429-while-expired on the retry path must mark the renewal ineffective")
    }

    func testHTTP401RetryReturns429WithFutureExpiresAtStillMapsToRateLimited() async throws {
        // Guard against over-eager signed-out mapping: a retry that
        // gets 429 with a valid-looking new token stays as
        // `.rateLimited(retryAfter:)` and does NOT mark the renewal
        // ineffective (the renewal itself worked; the server is just
        // busy).
        let futureMs: Int64 = 4_102_444_800_000
        let reader = SequentialCredentialReader(bodies: [
            Self.credentialJSON(token: "t1"),
            Self.credentialJSON(token: "t2", expiresAtMs: futureMs)
        ])
        let transport = makeTransport()
        transport.enqueue(status: 401, body: Data())
        transport.enqueue(status: 429, body: Data(), headers: ["Retry-After": "45"])
        let renewer = FakeClaudeCLIRenewer(outcomes: [.succeeded])
        let provider = makeProvider(credentials: reader, transport: transport, renewer: renewer)

        do {
            _ = try await provider.fetch()
            XCTFail("expected rateLimited")
        } catch let error as FetchError {
            XCTAssertEqual(error, .rateLimited(retryAfter: 45))
        }
        XCTAssertEqual(renewer.markIneffectiveCallCount, 0,
                       "renewer must NOT be marked ineffective for a plain 429 after a good renewal")
    }

    func testHTTP401RetryReturns5xxDoesNotMarkRenewalIneffective() async throws {
        // Server-side 5xx is not evidence that the renewal itself
        // failed. Provider must surface `.server(status)` and leave the
        // renewer's failure flag alone so the cooldown row does not get
        // spuriously flipped to "Run `claude` in Terminal to sign in".
        let futureMs: Int64 = 4_102_444_800_000
        let reader = SequentialCredentialReader(bodies: [
            Self.credentialJSON(token: "t1"),
            Self.credentialJSON(token: "t2", expiresAtMs: futureMs)
        ])
        let transport = makeTransport()
        transport.enqueue(status: 401, body: Data())
        transport.enqueue(status: 503, body: Data())
        let renewer = FakeClaudeCLIRenewer(outcomes: [.succeeded])
        let provider = makeProvider(credentials: reader, transport: transport, renewer: renewer)

        do {
            _ = try await provider.fetch()
            XCTFail("expected server")
        } catch let error as FetchError {
            XCTAssertEqual(error, .server(503))
        }
        XCTAssertEqual(renewer.markIneffectiveCallCount, 0,
                       "renewer must NOT be marked ineffective for a 5xx after a good renewal")
    }

    func testHTTP401AfterSuccessfulRenewalMarksRenewalIneffective() async throws {
        // Guardrail for the 401 retry path: the provider must call
        // `markLastRenewalIneffective()` when a `.succeeded` renewer
        // outcome is followed by a 401 on the retry. The next
        // in-cooldown attempt should then return `.inCooldownAfterFailure`.
        let reader = SequentialCredentialReader(bodies: [
            Self.credentialJSON(token: "t1"),
            Self.credentialJSON(token: "t2")
        ])
        let transport = makeTransport()
        transport.enqueue(status: 401, body: Data())
        transport.enqueue(status: 401, body: Data())
        let renewer = FakeClaudeCLIRenewer(outcomes: [.succeeded])
        let provider = makeProvider(credentials: reader, transport: transport, renewer: renewer)

        do {
            _ = try await provider.fetch()
            XCTFail("expected signedOut")
        } catch let error as FetchError {
            XCTAssertEqual(error, .signedOut("Run `claude` in Terminal to sign in"))
        }
        XCTAssertEqual(renewer.markIneffectiveCallCount, 1,
                       "post-successful-renewal 401 must mark the renewal ineffective")
    }

    func testMissingExpiresAtSkipsPreflightAndProceedsNormally() async throws {
        // A credential body with no `expiresAt` field must NOT trigger
        // pre-flight renewal — the pre-check is a hint, not a hard
        // requirement.
        let jsonWithoutExpiresAt = try JSONSerialization.data(
            withJSONObject: [
                "claudeAiOauth": [
                    "accessToken": "no-expiry-token",
                    "scopes": ["a", "b"]
                ] as [String: Any]
            ]
        )
        let creds = FakeCredentialReader(readResult: .success(jsonWithoutExpiresAt))
        let transport = makeTransport()
        transport.enqueue(status: 200, body: try fixture())
        let renewer = FakeClaudeCLIRenewer(outcomes: [.succeeded])
        let provider = makeProvider(credentials: creds, transport: transport, renewer: renewer)

        _ = try await provider.fetch()
        XCTAssertEqual(renewer.callCount, 0, "missing expiresAt must not trigger pre-flight")
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testNonNumericExpiresAtSkipsPreflight() async throws {
        // If expiresAt is a string (or anything non-numeric) treat it as
        // "unknown" and proceed as if it were missing.
        let jsonWithStringExpiresAt = try JSONSerialization.data(
            withJSONObject: [
                "claudeAiOauth": [
                    "accessToken": "tok",
                    "expiresAt": "not-a-number"
                ] as [String: Any]
            ]
        )
        let creds = FakeCredentialReader(readResult: .success(jsonWithStringExpiresAt))
        let transport = makeTransport()
        transport.enqueue(status: 200, body: try fixture())
        let renewer = FakeClaudeCLIRenewer(outcomes: [.succeeded])
        let provider = makeProvider(credentials: creds, transport: transport, renewer: renewer)

        _ = try await provider.fetch()
        XCTAssertEqual(renewer.callCount, 0)
        XCTAssertEqual(transport.requests.count, 1)
    }

    // MARK: - 429 mapping (expired vs valid tokens)

    func testHTTP429AfterSuccessfulRenewalButRenewedCredentialStillExpiredMapsToSignedOut() async throws {
        // Pre-flight renewer.succeeded, but the credential re-read
        // yields an expiresAt that is still past (CLI reported OK but
        // wrote a bad token). The HTTP call then returns 429; the
        // provider treats this as signedOut, NOT `.rateLimited`, and
        // uses the "Run `claude`" flavour because a renewal DID run
        // this fetch but did not restore access.
        let pastMs: Int64 = 1_000_000_000_000
        let reader = SequentialCredentialReader(bodies: [
            Self.credentialJSON(expiresAtMs: pastMs),
            Self.credentialJSON(expiresAtMs: pastMs) // still "expired" after renewal
        ])
        let transport = makeTransport()
        transport.enqueue(status: 429, body: Data(), headers: ["Retry-After": "3600"])
        let renewer = FakeClaudeCLIRenewer(outcomes: [.succeeded])
        let provider = makeProvider(credentials: reader, transport: transport, renewer: renewer)

        do {
            _ = try await provider.fetch()
            XCTFail("expected signedOut, not rateLimited")
        } catch let error as FetchError {
            XCTAssertEqual(error, .signedOut("Run `claude` in Terminal to sign in"))
        }
        XCTAssertEqual(renewer.markIneffectiveCallCount, 1,
                       "provider must tell the renewer the attempt was ineffective")
    }

    func testHTTP429MapsToSignedOutNoRenewalReasonWhenClockAdvancesPastValidExpiry() async throws {
        // Exercise the `signedOutReasonNoRenewal` branch of the 429
        // handling. Credential's expiresAt is in the future at read
        // time (pre-flight is skipped), the HTTP call then takes long
        // enough that the wall clock advances past that expiry. The
        // provider re-samples the clock at the 429 branch and treats
        // the 429 as signedOut. Because no renewal happened this fetch,
        // the text is "Open Claude Code to refresh", not "Run `claude`".
        let tokenExpiryMs: Int64 = 1_780_000_000_000 // (Date(timeIntervalSince1970: 1_780_000_000))
        let clock = ClockStub(times: [
            Date(timeIntervalSince1970: 1_779_999_990), // pre-flight sample → future
            Date(timeIntervalSince1970: 1_780_000_010)  // 429 branch sample → past
        ])
        let creds = FakeCredentialReader(readResult: .success(Self.credentialJSON(expiresAtMs: tokenExpiryMs)))
        let transport = makeTransport()
        transport.enqueue(status: 429, body: Data(), headers: ["Retry-After": "3600"])
        let renewer = FakeClaudeCLIRenewer(outcomes: [])
        let provider = makeProvider(
            credentials: creds,
            transport: transport,
            renewer: renewer,
            now: { clock.next() }
        )

        do {
            _ = try await provider.fetch()
            XCTFail("expected signedOut")
        } catch let error as FetchError {
            XCTAssertEqual(error, .signedOut("Open Claude Code to refresh"))
        }
        XCTAssertEqual(renewer.callCount, 0, "no pre-flight renewal (expiry was future at check time)")
        XCTAssertEqual(renewer.markIneffectiveCallCount, 0)
    }

    func testHTTP429WithFutureExpiresAtMapsToRateLimitedAsBefore() async throws {
        // A valid-looking token that gets rate-limited keeps its old
        // behaviour: `.rateLimited(retryAfter:)`.
        let futureMs: Int64 = 4_102_444_800_000
        let creds = FakeCredentialReader(readResult: .success(Self.credentialJSON(expiresAtMs: futureMs)))
        let transport = makeTransport()
        transport.enqueue(status: 429, body: Data(), headers: ["Retry-After": "45"])
        let provider = makeProvider(credentials: creds, transport: transport)

        do {
            _ = try await provider.fetch()
            XCTFail("expected rateLimited")
        } catch let error as FetchError {
            XCTAssertEqual(error, .rateLimited(retryAfter: 45))
        }
    }

    func testHTTP429WithMissingExpiresAtMapsToRateLimited() async throws {
        // No expiresAt → we cannot know if the token is stale → keep the
        // old 429 behaviour.
        let json = try JSONSerialization.data(
            withJSONObject: [
                "claudeAiOauth": ["accessToken": "t"] as [String: Any]
            ]
        )
        let creds = FakeCredentialReader(readResult: .success(json))
        let transport = makeTransport()
        transport.enqueue(status: 429, body: Data(), headers: ["Retry-After": "60"])
        let provider = makeProvider(credentials: creds, transport: transport)

        do {
            _ = try await provider.fetch()
            XCTFail("expected rateLimited")
        } catch let error as FetchError {
            XCTAssertEqual(error, .rateLimited(retryAfter: 60))
        }
    }

    // MARK: - isInstalled

    func testIsInstalledMirrorsCredentialReader() async {
        let present = FakeCredentialReader(present: true, readResult: .success(Data()))
        let absent = FakeCredentialReader(present: false, readResult: .success(Data()))
        let transport = makeTransport()
        let one = await makeProvider(credentials: present, transport: transport).isInstalled()
        let two = await makeProvider(credentials: absent, transport: transport).isInstalled()
        XCTAssertTrue(one)
        XCTAssertFalse(two)
    }
}

// MARK: - Credential reader (with fake runner)

/// Fake runner recording every subprocess invocation and returning canned
/// (status, stdout) pairs. Used to exercise
/// `SecuritySubprocessCredentialReader` without touching the real
/// `/usr/bin/security` binary.
final class FakeSecuritySubprocessRunner: SecuritySubprocessRunner, @unchecked Sendable {
    struct Call: Equatable, Sendable {
        let executable: URL
        let arguments: [String]
    }
    private let lock = NSLock()
    private var responses: [Result<(status: Int32, stdout: Data), Error>]
    private var _calls: [Call] = []

    init(responses: [Result<(status: Int32, stdout: Data), Error>]) {
        self.responses = responses
    }

    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    private func recordAndPop(executable: URL, arguments: [String]) -> Result<(status: Int32, stdout: Data), Error>? {
        lock.lock(); defer { lock.unlock() }
        _calls.append(Call(executable: executable, arguments: arguments))
        guard !responses.isEmpty else { return nil }
        return responses.removeFirst()
    }

    func run(executable: URL, arguments: [String]) async throws -> (status: Int32, stdout: Data) {
        guard let result = recordAndPop(executable: executable, arguments: arguments) else {
            throw FetchError.other("no runner response")
        }
        switch result {
        case .success(let pair): return pair
        case .failure(let error): throw error
        }
    }
}

final class SecuritySubprocessCredentialReaderTests: XCTestCase {

    private let expectedExecutable = URL(fileURLWithPath: "/usr/bin/security")

    // MARK: - Presence check

    func testIsPresentUsesFindGenericPasswordWithoutDashW() async {
        // The presence check must NOT pull the token — that is what -w
        // does. We just ask "does the item exist?"
        let runner = FakeSecuritySubprocessRunner(responses: [
            .success((status: 0, stdout: Data()))
        ])
        let reader = SecuritySubprocessCredentialReader(runner: runner)

        let present = await reader.isPresent()
        XCTAssertTrue(present)
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(runner.calls[0].executable, expectedExecutable)
        XCTAssertEqual(
            runner.calls[0].arguments,
            ["find-generic-password", "-s", "Claude Code-credentials"]
        )
        XCTAssertFalse(runner.calls[0].arguments.contains("-w"),
                       "presence check must not include -w")
    }

    func testIsPresentReturnsFalseOnlyOnExit44() async {
        // Exit 44 (`errSecItemNotFound`) is the one and only outcome that
        // means "the item is not in the Keychain".
        let runner = FakeSecuritySubprocessRunner(responses: [
            .success((status: 44, stdout: Data()))
        ])
        let reader = SecuritySubprocessCredentialReader(runner: runner)
        let present = await reader.isPresent()
        XCTAssertFalse(present)
    }

    func testIsPresentReturnsTrueOnOtherNonZeroExit() async {
        // Exit 1 (or anything else the security binary might emit for a
        // locked keychain, an ACL prompt refusal, or an unknown error)
        // must NOT hide the ring. Return `true` so `read()` runs and the
        // fixed "Couldn't read..." error row is displayed to the user.
        let runner = FakeSecuritySubprocessRunner(responses: [
            .success((status: 1, stdout: Data()))
        ])
        let reader = SecuritySubprocessCredentialReader(runner: runner)
        let present = await reader.isPresent()
        XCTAssertTrue(present, "unknown nonzero must not be treated as 'not installed'")
    }

    func testIsPresentReturnsTrueOnRunnerTimeout() async {
        // A timeout is inconclusive — we do not know whether the item is
        // there. Keep the ring visible so `read()` produces the error row
        // rather than silently hiding the provider.
        let runner = FakeSecuritySubprocessRunner(responses: [
            .failure(SecuritySubprocessError.timedOut)
        ])
        let reader = SecuritySubprocessCredentialReader(runner: runner)
        let present = await reader.isPresent()
        XCTAssertTrue(present, "timeout must not hide the ring — read() surfaces the fixed error")
    }

    func testIsPresentReturnsTrueOnLaunchFailure() async {
        let runner = FakeSecuritySubprocessRunner(responses: [
            .failure(SecuritySubprocessError.launchFailed)
        ])
        let reader = SecuritySubprocessCredentialReader(runner: runner)
        let present = await reader.isPresent()
        XCTAssertTrue(present)
    }

    // MARK: - Read

    func testReadUsesFindGenericPasswordWithDashW() async throws {
        let payload = Data(#"{"claudeAiOauth":{"accessToken":"tok"}}"#.utf8)
        let runner = FakeSecuritySubprocessRunner(responses: [
            .success((status: 0, stdout: payload))
        ])
        let reader = SecuritySubprocessCredentialReader(runner: runner)

        _ = try await reader.read()
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(runner.calls[0].executable, expectedExecutable)
        XCTAssertEqual(
            runner.calls[0].arguments,
            ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        )
    }

    func testReadStripsSingleTrailingLineFeed() async throws {
        var payload = Data(#"{"claudeAiOauth":{"accessToken":"tok"}}"#.utf8)
        payload.append(0x0A) // security -w always appends one LF
        let runner = FakeSecuritySubprocessRunner(responses: [
            .success((status: 0, stdout: payload))
        ])
        let reader = SecuritySubprocessCredentialReader(runner: runner)
        let body = try await reader.read()
        XCTAssertEqual(body.last, UInt8(ascii: "}"),
                       "trailing LF must be stripped")
        XCTAssertEqual(body, Data(#"{"claudeAiOauth":{"accessToken":"tok"}}"#.utf8))
    }

    func testReadOnExit44ThrowsGenericReadFailure() async {
        // Race case: item vanished between isPresent and read. Surface
        // a sanitised "Couldn't read..." message; the next isInstalled()
        // will hide the ring.
        let runner = FakeSecuritySubprocessRunner(responses: [
            .success((status: 44, stdout: Data()))
        ])
        let reader = SecuritySubprocessCredentialReader(runner: runner)
        do {
            _ = try await reader.read()
            XCTFail("expected error")
        } catch let error as FetchError {
            XCTAssertEqual(error, .other("Couldn't read Claude Code credentials from Keychain"))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testReadOnOtherNonZeroThrowsGenericReadFailure() async {
        for status in [Int32(1), Int32(2), Int32(51)] {
            let runner = FakeSecuritySubprocessRunner(responses: [
                .success((status: status, stdout: Data()))
            ])
            let reader = SecuritySubprocessCredentialReader(runner: runner)
            do {
                _ = try await reader.read()
                XCTFail("expected error for status \(status)")
            } catch let error as FetchError {
                XCTAssertEqual(error, .other("Couldn't read Claude Code credentials from Keychain"))
            } catch {
                XCTFail("wrong error for status \(status): \(error)")
            }
        }
    }

    func testReadOnTimeoutThrowsGenericReadFailure() async {
        let runner = FakeSecuritySubprocessRunner(responses: [
            .failure(SecuritySubprocessError.timedOut)
        ])
        let reader = SecuritySubprocessCredentialReader(runner: runner)
        do {
            _ = try await reader.read()
            XCTFail("expected error")
        } catch let error as FetchError {
            XCTAssertEqual(error, .other("Couldn't read Claude Code credentials from Keychain"))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testReadOnEmptyBodyThrowsGenericReadFailure() async {
        let runner = FakeSecuritySubprocessRunner(responses: [
            .success((status: 0, stdout: Data()))
        ])
        let reader = SecuritySubprocessCredentialReader(runner: runner)
        do {
            _ = try await reader.read()
            XCTFail("expected error")
        } catch let error as FetchError {
            XCTAssertEqual(error, .other("Couldn't read Claude Code credentials from Keychain"))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testReadErrorMessageIsFixedAndDoesNotEchoStderrOrToken() async {
        // Confirms the reader does not stringify anything the runner
        // returned — even if a fake runner passed sensitive-looking bytes
        // through `.other`, the reader replaces the message with the
        // fixed one.
        let stderrLookingError = FetchError.other("stderr: unknown thing \(ClaudeProviderTests.sentinelToken)")
        let runner = FakeSecuritySubprocessRunner(responses: [
            .failure(stderrLookingError)
        ])
        let reader = SecuritySubprocessCredentialReader(runner: runner)
        do {
            _ = try await reader.read()
            XCTFail("expected error")
        } catch let error as FetchError {
            guard case .other(let message) = error else {
                return XCTFail("expected .other, got \(error)")
            }
            XCTAssertEqual(message, "Couldn't read Claude Code credentials from Keychain")
            XCTAssertFalse(message.contains(ClaudeProviderTests.sentinelToken))
            XCTAssertFalse(message.contains("stderr"))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}

// MARK: - Real ProcessSecurityRunner

/// Exercises the real `ProcessSecurityRunner` against harmless system
/// binaries (never `/usr/bin/security`, never the network). Confirms the
/// concurrent-drain and deadline paths behave correctly.
final class ProcessSecurityRunnerTests: XCTestCase {

    func testRunsExecutableAndReturnsStdoutAndZeroExit() async throws {
        let runner = ProcessSecurityRunner(timeout: 5)
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["-n", "hello"]
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, Data("hello".utf8))
    }

    func testDrainsLargeStdoutWithoutDeadlockingOnPipeBuffer() async throws {
        // 256 KiB — comfortably above the ~64 KiB pipe buffer. If the
        // runner waits for exit before draining, this deadlocks.
        let runner = ProcessSecurityRunner(timeout: 10)
        let byteCount = 256 * 1024
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/dd"),
            arguments: ["if=/dev/zero", "bs=1024", "count=256", "status=none"]
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout.count, byteCount,
                       "runner must drain the full pipe, not truncate at the buffer")
    }

    func testNonZeroExitIsReturnedNotThrown() async throws {
        let runner = ProcessSecurityRunner(timeout: 5)
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/false"),
            arguments: []
        )
        XCTAssertNotEqual(result.status, 0)
    }

    func testTimeoutTerminatesTheChildAndThrowsPromptly() async {
        // /bin/sleep 5 with a 0.3 s deadline. The runner must NOT wait for
        // the child's file descriptors to close before returning; it
        // sends SIGTERM immediately, detaches the SIGKILL escalation, and
        // returns to the caller. The hard bound this test checks is that
        // the call returns close to the deadline, not close to the
        // child's original wall-clock lifetime.
        let runner = ProcessSecurityRunner(timeout: 0.3, killGrace: 0.2)
        let start = Date()
        do {
            _ = try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"]
            )
            XCTFail("expected timeout")
        } catch let error as SecuritySubprocessError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let elapsed = Date().timeIntervalSince(start)
        // A generous ceiling that still catches "waiting on the child's
        // pipe to close" regressions. The observed wall time on the test
        // machine is ~0.3 s.
        XCTAssertLessThan(elapsed, 1.0,
                          "runner must not block on the child's pipes/exit after the deadline")
    }

    func testTimeoutStillEscalatesToSIGKILLForUnresponsiveChild() async throws {
        // /bin/sh -c 'trap "" TERM; exec sleep 30' — a child that IGNORES
        // SIGTERM. `exec` replaces the shell with `sleep` so the escalated
        // SIGKILL targets the same PID we identified (no leftover shell
        // grandchild lingering after the test). The runner's SIGKILL
        // escalation is what stops it. We assert both that the runner
        // returns promptly AND that the child actually dies within the
        // grace window.
        let runner = ProcessSecurityRunner(timeout: 0.3, killGrace: 0.2)
        // Launch a matching child ourselves so we can observe its PID and
        // confirm SIGKILL landed. Wrap the sleep in a script that echoes
        // its PID to stdout so we can read it back after the timeout.
        let pidFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("usagerings-sigkill-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let start = Date()
        do {
            _ = try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                // `exec` so the sleep replaces the shell — the PID the
                // runner captured IS the sleep. Write the PID to a file
                // BEFORE the exec so the test can read it after the fact.
                arguments: ["-c", "echo $$ > \(pidFile.path); trap '' TERM; exec sleep 30"]
            )
            XCTFail("expected timeout")
        } catch let error as SecuritySubprocessError {
            XCTAssertEqual(error, .timedOut)
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 1.0,
                          "SIGKILL escalation must not extend the caller-facing wait")

        // Wait a beat for the escalation task's grace window to elapse and
        // the actual SIGKILL to reap the process.
        try? await Task.sleep(nanoseconds: 500_000_000)

        // Read the recorded PID and confirm the process is gone. `kill -0`
        // returns 0 while the process exists and errors once it has been
        // reaped. If the pid file is missing the shell must have died
        // before writing it — that would be a test-harness bug rather
        // than the runner's, so fail loudly rather than swallow it.
        guard let contents = try? String(contentsOf: pidFile),
              let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            XCTFail("pid file not written; cannot verify SIGKILL delivery")
            return
        }
        let alive = Darwin.kill(pid, 0)
        XCTAssertNotEqual(alive, 0,
                          "child process (pid \(pid)) must be dead after SIGKILL escalation")
        // Belt and braces: if the process somehow survived, kill it so the
        // test host is not left with a lingering sleep.
        if alive == 0 { _ = Darwin.kill(pid, SIGKILL) }
    }

    func testChildInheritsNullStdinNotTheParentsTty() async throws {
        // If we did NOT redirect stdin to /dev/null, a child reading
        // from it (`cat` with no args) would inherit the app's stdin
        // and block indefinitely on read while our 60 s deadline slowly
        // burned. With stdin = /dev/null, `cat` sees EOF immediately
        // and exits within milliseconds with empty output.
        let runner = ProcessSecurityRunner(timeout: 5)
        let start = Date()
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/cat"),
            arguments: []
        )
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(result.status, 0, "cat with stdin = /dev/null must exit cleanly")
        XCTAssertEqual(result.stdout, Data(), "cat of empty stdin must yield empty stdout")
        XCTAssertLessThan(elapsed, 1.0,
                          "cat with stdin = /dev/null must return promptly, not hang on tty read")
    }

    func testStderrIsDrainedButNotSurfaced() async throws {
        // /bin/sh -c 'echo stderr-only >&2; exit 0'
        let runner = ProcessSecurityRunner(timeout: 5)
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo stderr-only >&2; exit 0"]
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, Data(),
                       "stderr must never end up in the stdout Data")
    }
}
