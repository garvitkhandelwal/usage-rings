import XCTest
@testable import UsageRingsCore

/// Tests for `CodexProvider` and `FileSystemCodexAuthReader`.
///
/// A real `~/.codex/auth.json` file is never read: the provider tests inject
/// a `FakeCodexAuthReader`, and the file-system reader tests use a
/// tmp-directory path. No network traffic is generated: the transport is a
/// shared `RecordingTransport` helper. The fixture used is
/// `Tests/UsageRingsCoreTests/Fixtures/codex-usage.json`.
final class CodexProviderTests: XCTestCase {

    // MARK: - Test doubles

    /// Auth reader that returns whatever `Result<CodexCredentials?, Error>`
    /// the test wired up. `nil` on success means "auth.json exists but has no
    /// tokens object" (API-key-only mode) — that is not an error, but it does
    /// hide the ring / cause a signed-out row on fetch.
    final class FakeCodexAuthReader: CodexAuthReader, @unchecked Sendable {
        private let lock = NSLock()
        private var _result: Result<CodexCredentials?, Error>
        private var _callCount = 0

        init(_ result: Result<CodexCredentials?, Error>) {
            self._result = result
        }

        var callCount: Int { withLock { _callCount } }

        private func withLock<T>(_ body: () -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            return body()
        }

        func loadCredentials() async throws -> CodexCredentials? {
            let result: Result<CodexCredentials?, Error> = withLock {
                _callCount += 1
                return _result
            }
            switch result {
            case .success(let creds): return creds
            case .failure(let error): throw error
            }
        }
    }

    /// The shared `RecordingTransport` (see `TestSupport/RecordingTransport.swift`)
    /// is used verbatim; each test builds one bound to `CodexProvider.endpoint`.
    private func makeTransport() -> RecordingTransport {
        RecordingTransport(responseURL: CodexProvider.endpoint)
    }

    // MARK: - Helpers

    /// Sentinel token/account id — if either leaks into an error message we
    /// spot it immediately.
    static let sentinelToken = "codex-oat01-TEST-SENTINEL-DO-NOT-LEAK"
    static let sentinelAccountId = "acct_TEST_SENTINEL_DO_NOT_LEAK"

    static var sentinelCredentials: CodexCredentials {
        CodexCredentials(accessToken: sentinelToken, accountId: sentinelAccountId)
    }

    private func fixture() throws -> Data {
        let url = Bundle.module.url(forResource: "codex-usage", withExtension: "json", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "codex-usage", withExtension: "json")
        guard let url else {
            XCTFail("codex-usage.json fixture not found in test bundle")
            throw FetchError.other("fixture missing")
        }
        return try Data(contentsOf: url)
    }

    private func makeProvider(
        auth: CodexAuthReader,
        transport: HTTPTransport,
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_780_000_000) }
    ) -> CodexProvider {
        CodexProvider(transport: transport, auth: auth, now: now)
    }

    // MARK: - Request construction

    func testFetchIssuesGETWithBearerAccountIdAndAccept() async throws {
        let auth = FakeCodexAuthReader(.success(Self.sentinelCredentials))
        let transport = makeTransport()
        transport.enqueue(status: 200, body: try fixture())
        let provider = makeProvider(auth: auth, transport: transport)

        _ = try await provider.fetch()

        XCTAssertEqual(transport.requests.count, 1)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://chatgpt.com/backend-api/wham/usage")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer \(Self.sentinelToken)"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "ChatGPT-Account-Id"),
            Self.sentinelAccountId
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Accept"),
            "application/json"
        )
        XCTAssertEqual(auth.callCount, 1, "one credentials load per fetch()")
    }

    // MARK: - Parsing

    func testParsesFreePlanFixture() async throws {
        let auth = FakeCodexAuthReader(.success(Self.sentinelCredentials))
        let transport = makeTransport()
        transport.enqueue(status: 200, body: try fixture())
        let fixedNow = Date(timeIntervalSince1970: 1_780_000_000)
        let provider = makeProvider(auth: auth, transport: transport, now: { fixedNow })

        let usage = try await provider.fetch()

        XCTAssertEqual(usage.id, .codex)
        XCTAssertEqual(usage.plan, "free")
        XCTAssertEqual(usage.fetchedAt, fixedNow)
        XCTAssertEqual(usage.windows.count, 1, "secondary_window null → skipped")

        let primary = try XCTUnwrap(usage.windows.first)
        XCTAssertEqual(primary.kind, .primary)
        XCTAssertEqual(primary.label, "Monthly", "limit_window_seconds 2592000 → Monthly")
        XCTAssertEqual(primary.usedPercent, 26.0, accuracy: 0.0001)
        XCTAssertEqual(primary.resetsAt, Date(timeIntervalSince1970: 1_792_964_711))
    }

    func testNullSecondaryWindowIsSkipped() async throws {
        let body: [String: Any] = [
            "plan_type": "free",
            "rate_limit": [
                "primary_window": [
                    "used_percent": 10,
                    "limit_window_seconds": 18000,
                    "reset_at": 1_800_000_000
                ] as [String: Any],
                "secondary_window": NSNull()
            ] as [String: Any]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let auth = FakeCodexAuthReader(.success(Self.sentinelCredentials))
        let transport = makeTransport()
        transport.enqueue(status: 200, body: data)
        let provider = makeProvider(auth: auth, transport: transport)

        let usage = try await provider.fetch()
        XCTAssertEqual(usage.windows.count, 1)
        XCTAssertEqual(usage.windows.first?.kind, .primary)
        XCTAssertEqual(usage.windows.first?.label, "5h", "18000 → 5h")
    }

    func testBothWindowsPresent() async throws {
        let body: [String: Any] = [
            "plan_type": "pro",
            "rate_limit": [
                "primary_window": [
                    "used_percent": 40,
                    "limit_window_seconds": 18000,
                    "reset_at": 1_800_000_000
                ] as [String: Any],
                "secondary_window": [
                    "used_percent": 70,
                    "limit_window_seconds": 604800,
                    "reset_at": 1_801_000_000
                ] as [String: Any]
            ] as [String: Any]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let auth = FakeCodexAuthReader(.success(Self.sentinelCredentials))
        let transport = makeTransport()
        transport.enqueue(status: 200, body: data)
        let provider = makeProvider(auth: auth, transport: transport)

        let usage = try await provider.fetch()
        XCTAssertEqual(usage.plan, "pro")
        XCTAssertEqual(usage.windows.count, 2)
        let primary = try XCTUnwrap(usage.windows.first(where: { $0.kind == .primary }))
        let secondary = try XCTUnwrap(usage.windows.first(where: { $0.kind == .secondary }))
        XCTAssertEqual(primary.label, "5h")
        XCTAssertEqual(secondary.label, "Weekly")
        XCTAssertEqual(secondary.usedPercent, 70.0, accuracy: 0.0001)
        XCTAssertEqual(secondary.resetsAt, Date(timeIntervalSince1970: 1_801_000_000))
    }

    func testLabelForArbitraryDaysAndHours() async throws {
        // Not one of the known 3 constants → fall through to "Nd" / "Nh".
        let body: [String: Any] = [
            "plan_type": "pro",
            "rate_limit": [
                "primary_window": [
                    "used_percent": 5,
                    "limit_window_seconds": 259200, // 3 days
                    "reset_at": 1_800_000_000
                ] as [String: Any],
                "secondary_window": [
                    "used_percent": 5,
                    "limit_window_seconds": 7200, // 2 hours
                    "reset_at": 1_801_000_000
                ] as [String: Any]
            ] as [String: Any]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let auth = FakeCodexAuthReader(.success(Self.sentinelCredentials))
        let transport = makeTransport()
        transport.enqueue(status: 200, body: data)
        let provider = makeProvider(auth: auth, transport: transport)

        let usage = try await provider.fetch()
        XCTAssertEqual(usage.windows.first(where: { $0.kind == .primary })?.label, "3d")
        XCTAssertEqual(usage.windows.first(where: { $0.kind == .secondary })?.label, "2h")
    }

    func testLabelForSubHourUsesMinutes() async throws {
        // 1800 s = 30 min → "30m", not "1h". Sub-hour windows must use
        // a minutes fallback rather than rounding up to a full hour.
        let body: [String: Any] = [
            "plan_type": "pro",
            "rate_limit": [
                "primary_window": [
                    "used_percent": 5,
                    "limit_window_seconds": 1800,
                    "reset_at": 1_800_000_000
                ] as [String: Any],
                "secondary_window": NSNull()
            ] as [String: Any]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let auth = FakeCodexAuthReader(.success(Self.sentinelCredentials))
        let transport = makeTransport()
        transport.enqueue(status: 200, body: data)
        let provider = makeProvider(auth: auth, transport: transport)

        let usage = try await provider.fetch()
        XCTAssertEqual(usage.windows.first?.label, "30m")
    }

    func testUsedPercentBooleanYieldsParseError() async throws {
        // JSON `true` bridges to NSNumber wrapping a CFBoolean; a naive
        // `raw as? Double` reads it as 1.0 and the ring silently sits at
        // 1%. Must be rejected as a parse error.
        let body: [String: Any] = [
            "plan_type": "pro",
            "rate_limit": [
                "primary_window": [
                    "used_percent": true,
                    "limit_window_seconds": 2592000,
                    "reset_at": 1_800_000_000
                ] as [String: Any]
            ] as [String: Any]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let auth = FakeCodexAuthReader(.success(Self.sentinelCredentials))
        let transport = makeTransport()
        transport.enqueue(status: 200, body: data)
        let provider = makeProvider(auth: auth, transport: transport)

        do {
            _ = try await provider.fetch()
            XCTFail("expected parse error")
        } catch let error as FetchError {
            guard case .parse = error else {
                return XCTFail("expected .parse, got \(error)")
            }
        }
    }

    func testPlanTypeMissingLeavesPlanNil() async throws {
        let body: [String: Any] = [
            "rate_limit": [
                "primary_window": [
                    "used_percent": 5,
                    "limit_window_seconds": 2592000,
                    "reset_at": 1_800_000_000
                ] as [String: Any],
                "secondary_window": NSNull()
            ] as [String: Any]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let auth = FakeCodexAuthReader(.success(Self.sentinelCredentials))
        let transport = makeTransport()
        transport.enqueue(status: 200, body: data)
        let provider = makeProvider(auth: auth, transport: transport)

        let usage = try await provider.fetch()
        XCTAssertNil(usage.plan)
        XCTAssertEqual(usage.windows.count, 1)
    }

    // MARK: - Strict-parsing failures

    func testMissingRateLimitYieldsParseError() async throws {
        let body: [String: Any] = ["plan_type": "free"]
        let data = try JSONSerialization.data(withJSONObject: body)
        let auth = FakeCodexAuthReader(.success(Self.sentinelCredentials))
        let transport = makeTransport()
        transport.enqueue(status: 200, body: data)
        let provider = makeProvider(auth: auth, transport: transport)

        do {
            _ = try await provider.fetch()
            XCTFail("expected parse error")
        } catch let error as FetchError {
            guard case .parse = error else {
                return XCTFail("expected .parse, got \(error)")
            }
        }
    }

    func testRateLimitPresentButPrimaryWindowKeyRenamedYieldsParseError() async throws {
        // rate_limit has neither primary_window as a key — the API silently
        // renamed it to `primaryWindow` — but does have a null
        // secondary_window (free-plan shape). Must NOT be a blank OK ring.
        let body: [String: Any] = [
            "plan_type": "free",
            "rate_limit": [
                "primaryWindow": [
                    "used_percent": 10,
                    "limit_window_seconds": 2592000,
                    "reset_at": 1_800_000_000
                ] as [String: Any],
                "secondary_window": NSNull()
            ] as [String: Any]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let auth = FakeCodexAuthReader(.success(Self.sentinelCredentials))
        let transport = makeTransport()
        transport.enqueue(status: 200, body: data)
        let provider = makeProvider(auth: auth, transport: transport)

        do {
            _ = try await provider.fetch()
            XCTFail("expected parse error")
        } catch let error as FetchError {
            guard case .parse = error else {
                return XCTFail("expected .parse, got \(error)")
            }
        }
    }

    func testRateLimitWithBothWindowsNullYieldsParseError() async throws {
        // primary_window and secondary_window both present but null. The
        // primary window is required and non-null; both-null must NOT
        // surface as a blank OK ring.
        let body: [String: Any] = [
            "plan_type": "free",
            "rate_limit": [
                "primary_window": NSNull(),
                "secondary_window": NSNull()
            ] as [String: Any]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let auth = FakeCodexAuthReader(.success(Self.sentinelCredentials))
        let transport = makeTransport()
        transport.enqueue(status: 200, body: data)
        let provider = makeProvider(auth: auth, transport: transport)

        do {
            _ = try await provider.fetch()
            XCTFail("expected parse error")
        } catch let error as FetchError {
            guard case .parse = error else {
                return XCTFail("expected .parse, got \(error)")
            }
        }
    }

    func testRateLimitWithNoRelevantKeysYieldsParseError() async throws {
        // rate_limit has neither primary_window nor secondary_window as a
        // key — the whole shape has been renamed.
        let body: [String: Any] = [
            "plan_type": "free",
            "rate_limit": [
                "allowed": true,
                "limit_reached": false
            ] as [String: Any]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let auth = FakeCodexAuthReader(.success(Self.sentinelCredentials))
        let transport = makeTransport()
        transport.enqueue(status: 200, body: data)
        let provider = makeProvider(auth: auth, transport: transport)

        do {
            _ = try await provider.fetch()
            XCTFail("expected parse error")
        } catch let error as FetchError {
            guard case .parse = error else {
                return XCTFail("expected .parse, got \(error)")
            }
        }
    }

    func testWindowMissingUsedPercentYieldsParseError() async throws {
        // primary_window present as an object but `used_percent` is renamed to
        // `usedPercent`. Must be an error, not "0%".
        let body: [String: Any] = [
            "plan_type": "free",
            "rate_limit": [
                "primary_window": [
                    "usedPercent": 12,
                    "limit_window_seconds": 2592000,
                    "reset_at": 1_800_000_000
                ] as [String: Any]
            ] as [String: Any]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let auth = FakeCodexAuthReader(.success(Self.sentinelCredentials))
        let transport = makeTransport()
        transport.enqueue(status: 200, body: data)
        let provider = makeProvider(auth: auth, transport: transport)

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
        let data = try JSONSerialization.data(withJSONObject: [Any]())
        let auth = FakeCodexAuthReader(.success(Self.sentinelCredentials))
        let transport = makeTransport()
        transport.enqueue(status: 200, body: data)
        let provider = makeProvider(auth: auth, transport: transport)

        do {
            _ = try await provider.fetch()
            XCTFail("expected parse error")
        } catch let error as FetchError {
            guard case .parse = error else {
                return XCTFail("expected .parse, got \(error)")
            }
        }
    }

    func testMalformedUsageJSONYieldsParseError() async throws {
        let auth = FakeCodexAuthReader(.success(Self.sentinelCredentials))
        let transport = makeTransport()
        transport.enqueue(status: 200, body: Data("<html>oops</html>".utf8))
        let provider = makeProvider(auth: auth, transport: transport)

        do {
            _ = try await provider.fetch()
            XCTFail("expected parse error")
        } catch let error as FetchError {
            guard case .parse = error else {
                return XCTFail("expected .parse, got \(error)")
            }
        }
    }

    // MARK: - Auth / isInstalled

    func testIsInstalledFalseWhenAuthReaderReturnsNil() async {
        // Reader returns nil for both "file missing" and `"tokens": null` /
        // "tokens key absent" (API-key-only mode). All three states hide the
        // ring; the reader-level distinctions are covered by
        // `FileSystemCodexAuthReaderTests`.
        let auth = FakeCodexAuthReader(.success(nil))
        let transport = makeTransport()
        let installed = await makeProvider(auth: auth, transport: transport).isInstalled()
        XCTAssertFalse(installed)
    }

    func testIsInstalledTrueWhenCredentialsPresent() async {
        let auth = FakeCodexAuthReader(.success(Self.sentinelCredentials))
        let transport = makeTransport()
        let installed = await makeProvider(auth: auth, transport: transport).isInstalled()
        XCTAssertTrue(installed)
    }

    func testIsInstalledTrueOnReaderParseError() async {
        // File exists but is malformed. We do NOT silently hide the ring —
        // the fetch will surface a parse error row so the user can see
        // something's wrong.
        let auth = FakeCodexAuthReader(.failure(FetchError.parse("Codex auth.json could not be parsed")))
        let transport = makeTransport()
        let installed = await makeProvider(auth: auth, transport: transport).isInstalled()
        XCTAssertTrue(installed, "unreadable auth.json must not hide the ring")
    }

    func testFetchWithoutCredentialsThrowsSignedOut() async {
        // isInstalled would say false, but if fetch is called anyway it
        // must not attempt the request.
        let auth = FakeCodexAuthReader(.success(nil))
        let transport = makeTransport()
        let provider = makeProvider(auth: auth, transport: transport)

        do {
            _ = try await provider.fetch()
            XCTFail("expected signedOut")
        } catch let error as FetchError {
            XCTAssertEqual(error, .signedOut("Open Codex to refresh"))
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertEqual(transport.requests.count, 0)
    }

    func testFetchWithReaderParseErrorPassesThrough() async {
        let auth = FakeCodexAuthReader(.failure(FetchError.parse("Codex auth.json could not be parsed")))
        let transport = makeTransport()
        let provider = makeProvider(auth: auth, transport: transport)

        do {
            _ = try await provider.fetch()
            XCTFail("expected parse error")
        } catch let error as FetchError {
            guard case .parse = error else {
                return XCTFail("expected .parse, got \(error)")
            }
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertEqual(transport.requests.count, 0)
    }

    // MARK: - HTTP error paths

    func testHTTP401MapsToSignedOut() async throws {
        let auth = FakeCodexAuthReader(.success(Self.sentinelCredentials))
        let transport = makeTransport()
        transport.enqueue(status: 401, body: Data("{\"error\":\"unauthorized\"}".utf8))
        let provider = makeProvider(auth: auth, transport: transport)

        do {
            _ = try await provider.fetch()
            XCTFail("expected signedOut")
        } catch let error as FetchError {
            XCTAssertEqual(error, .signedOut("Open Codex to refresh"))
        }
    }

    func testHTTP403MapsToSignedOut() async throws {
        let auth = FakeCodexAuthReader(.success(Self.sentinelCredentials))
        let transport = makeTransport()
        transport.enqueue(status: 403, body: Data())
        let provider = makeProvider(auth: auth, transport: transport)

        do {
            _ = try await provider.fetch()
            XCTFail("expected signedOut")
        } catch let error as FetchError {
            XCTAssertEqual(error, .signedOut("Open Codex to refresh"))
        }
    }

    func testHTTP429MapsToRateLimited() async throws {
        let auth = FakeCodexAuthReader(.success(Self.sentinelCredentials))
        let transport = makeTransport()
        transport.enqueue(status: 429, body: Data(), headers: ["Retry-After": "30"])
        let provider = makeProvider(auth: auth, transport: transport)

        do {
            _ = try await provider.fetch()
            XCTFail("expected rateLimited")
        } catch let error as FetchError {
            XCTAssertEqual(error, .rateLimited(retryAfter: 30))
        }
    }

    func testHTTP500MapsToServer() async throws {
        let auth = FakeCodexAuthReader(.success(Self.sentinelCredentials))
        let transport = makeTransport()
        transport.enqueue(status: 502, body: Data())
        let provider = makeProvider(auth: auth, transport: transport)

        do {
            _ = try await provider.fetch()
            XCTFail("expected server")
        } catch let error as FetchError {
            XCTAssertEqual(error, .server(502))
        }
    }

    func testConnectivityURLErrorMapsToOffline() async throws {
        let auth = FakeCodexAuthReader(.success(Self.sentinelCredentials))
        let transport = makeTransport()
        transport.enqueue(error: URLError(.notConnectedToInternet))
        let provider = makeProvider(auth: auth, transport: transport)

        do {
            _ = try await provider.fetch()
            XCTFail("expected offline")
        } catch let error as FetchError {
            XCTAssertEqual(error, .offline)
        }
    }

    func testTimeoutURLErrorMapsToTimeout() async throws {
        let auth = FakeCodexAuthReader(.success(Self.sentinelCredentials))
        let transport = makeTransport()
        transport.enqueue(error: URLError(.timedOut))
        let provider = makeProvider(auth: auth, transport: transport)

        do {
            _ = try await provider.fetch()
            XCTFail("expected timeout")
        } catch let error as FetchError {
            XCTAssertEqual(error, .timeout)
        }
    }
}

// MARK: - FileSystemCodexAuthReader

final class FileSystemCodexAuthReaderTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-auth-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
    }

    private func writeAuth(_ dict: [String: Any]) throws -> URL {
        let path = tempDir.appendingPathComponent("auth.json")
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted])
        try data.write(to: path, options: .atomic)
        return path
    }

    func testMissingFileReturnsNil() async throws {
        let path = tempDir.appendingPathComponent("auth.json") // never created
        let reader = FileSystemCodexAuthReader(path: path)
        let creds = try await reader.loadCredentials()
        XCTAssertNil(creds, "missing file → not installed, not an error")
    }

    func testApiKeyOnlyAuthReturnsNil() async throws {
        // API-key-only auth.json has no `tokens` object.
        let path = try writeAuth([
            "OPENAI_API_KEY": "sk-REDACTED"
        ])
        let reader = FileSystemCodexAuthReader(path: path)
        let creds = try await reader.loadCredentials()
        XCTAssertNil(creds, "API-key-only auth.json → not installed (hidden)")
    }

    func testExplicitNullTokensReturnsNil() async throws {
        // `"tokens": null` is the CLI's way of saying "signed out /
        // API-key-only". Hidden, not an error.
        let path = try writeAuth([
            "tokens": NSNull(),
            "OPENAI_API_KEY": "sk-REDACTED"
        ])
        let reader = FileSystemCodexAuthReader(path: path)
        let creds = try await reader.loadCredentials()
        XCTAssertNil(creds, "\"tokens\": null → hidden")
    }

    func testTokensObjectMissingAccessTokenThrowsParseError() async throws {
        // Present-but-broken `tokens` object: field renamed / missing.
        // Must be a parse error so the user sees a broken-install row,
        // not a silently vanished ring.
        let path = try writeAuth([
            "tokens": ["account_id": "acct_TEST"] as [String: Any]
        ])
        let reader = FileSystemCodexAuthReader(path: path)
        do {
            _ = try await reader.loadCredentials()
            XCTFail("expected parse error")
        } catch let error as FetchError {
            XCTAssertEqual(error, .parse("Codex auth.json tokens missing required fields"))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testTokensObjectMissingAccountIdThrowsParseError() async throws {
        let path = try writeAuth([
            "tokens": ["access_token": "sentinel"] as [String: Any]
        ])
        let reader = FileSystemCodexAuthReader(path: path)
        do {
            _ = try await reader.loadCredentials()
            XCTFail("expected parse error")
        } catch let error as FetchError {
            XCTAssertEqual(error, .parse("Codex auth.json tokens missing required fields"))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testTokensObjectEmptyThrowsParseError() async throws {
        let path = try writeAuth([
            "tokens": [String: Any]()
        ])
        let reader = FileSystemCodexAuthReader(path: path)
        do {
            _ = try await reader.loadCredentials()
            XCTFail("expected parse error")
        } catch let error as FetchError {
            XCTAssertEqual(error, .parse("Codex auth.json tokens missing required fields"))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testTokensObjectWithEmptyStringFieldsThrowsParseError() async throws {
        let path = try writeAuth([
            "tokens": [
                "access_token": "",
                "account_id": ""
            ] as [String: Any]
        ])
        let reader = FileSystemCodexAuthReader(path: path)
        do {
            _ = try await reader.loadCredentials()
            XCTFail("expected parse error")
        } catch let error as FetchError {
            XCTAssertEqual(error, .parse("Codex auth.json tokens missing required fields"))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testTokensNotAnObjectThrowsParseError() async throws {
        // `"tokens": "some-string"` — malformed shape, not null / absent.
        let path = try writeAuth([
            "tokens": "not-an-object"
        ])
        let reader = FileSystemCodexAuthReader(path: path)
        do {
            _ = try await reader.loadCredentials()
            XCTFail("expected parse error")
        } catch let error as FetchError {
            XCTAssertEqual(error, .parse("Codex auth.json tokens missing required fields"))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testValidTokensReturnsCredentials() async throws {
        let path = try writeAuth([
            "tokens": [
                "access_token": "sentinel-access-token",
                "account_id": "acct_SENTINEL",
                "refresh_token": "refresh-should-not-be-read"
            ] as [String: Any]
        ])
        let reader = FileSystemCodexAuthReader(path: path)
        let creds = try await reader.loadCredentials()
        XCTAssertEqual(creds?.accessToken, "sentinel-access-token")
        XCTAssertEqual(creds?.accountId, "acct_SENTINEL")
    }

    func testUnreadableFileThrowsOtherReadError() async throws {
        // chmod 000 → the file exists but cannot be opened for reading.
        // Missing-file is the only read failure that hides the ring;
        // every other read failure surfaces as a fixed `.other(...)` so
        // the user sees an error row.
        let path = try writeAuth([
            "tokens": [
                "access_token": "sentinel-access-token",
                "account_id": "acct_SENTINEL"
            ] as [String: Any]
        ])
        // Skip on the impossible case where the process is root and chmod
        // 000 would still be readable.
        if getuid() == 0 {
            throw XCTSkip("chmod 000 does not restrict root")
        }
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0)], ofItemAtPath: path.path)
        defer {
            // Restore permissions so tearDown can remove the file.
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: path.path)
        }
        let reader = FileSystemCodexAuthReader(path: path)
        do {
            _ = try await reader.loadCredentials()
            XCTFail("expected other read error")
        } catch let error as FetchError {
            XCTAssertEqual(error, .other("Couldn't read Codex auth.json"))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testMalformedJSONThrowsParseError() async throws {
        let path = tempDir.appendingPathComponent("auth.json")
        try Data("{not valid json".utf8).write(to: path, options: .atomic)
        let reader = FileSystemCodexAuthReader(path: path)
        do {
            _ = try await reader.loadCredentials()
            XCTFail("expected parse error")
        } catch let error as FetchError {
            guard case .parse = error else {
                return XCTFail("expected .parse, got \(error)")
            }
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testRootNotAnObjectThrowsParseError() async throws {
        let path = tempDir.appendingPathComponent("auth.json")
        try Data("[]".utf8).write(to: path, options: .atomic)
        let reader = FileSystemCodexAuthReader(path: path)
        do {
            _ = try await reader.loadCredentials()
            XCTFail("expected parse error")
        } catch let error as FetchError {
            guard case .parse = error else {
                return XCTFail("expected .parse, got \(error)")
            }
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Default path resolution

    func testDefaultPathUsesHomeDirectoryByDefault() {
        let home = URL(fileURLWithPath: "/Users/test")
        let path = FileSystemCodexAuthReader.defaultPath(
            environment: [:],
            homeDirectory: home
        )
        XCTAssertEqual(path.path, "/Users/test/.codex/auth.json")
    }

    func testDefaultPathHonoursCODEX_HOME() {
        let home = URL(fileURLWithPath: "/Users/test")
        let path = FileSystemCodexAuthReader.defaultPath(
            environment: ["CODEX_HOME": "/custom/codex"],
            homeDirectory: home
        )
        XCTAssertEqual(path.path, "/custom/codex/auth.json")
    }

    func testDefaultPathIgnoresEmptyCODEX_HOME() {
        let home = URL(fileURLWithPath: "/Users/test")
        let path = FileSystemCodexAuthReader.defaultPath(
            environment: ["CODEX_HOME": ""],
            homeDirectory: home
        )
        XCTAssertEqual(path.path, "/Users/test/.codex/auth.json")
    }
}
