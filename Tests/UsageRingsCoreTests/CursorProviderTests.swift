import XCTest
import SQLite3
@testable import UsageRingsCore

/// Tests for `CursorProvider`, `FileSystemCursorAuthReader`, and the
/// `CursorJWT` helper.
///
/// A real `state.vscdb` file is never read: the provider tests inject a
/// `FakeCursorAuthReader`, and the file-system reader tests build a tmp
/// SQLite DB with just an `ItemTable` schema. No network traffic is
/// generated: the transport is the shared `RecordingTransport`. The fixture
/// used is `Tests/UsageRingsCoreTests/Fixtures/cursor-usage.json`.
final class CursorProviderTests: XCTestCase {

    // MARK: - Test doubles

    /// Auth reader that returns whatever `Result<String?, Error>` the test
    /// wired up. `nil` on success means "DB missing OR key row absent" —
    /// both hide the ring.
    final class FakeCursorAuthReader: CursorAuthReader, @unchecked Sendable {
        private let lock = NSLock()
        private var _result: Result<String?, Error>
        private var _callCount = 0

        init(_ result: Result<String?, Error>) {
            self._result = result
        }

        var callCount: Int { withLock { _callCount } }

        private func withLock<T>(_ body: () -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            return body()
        }

        func loadAccessToken() async throws -> String? {
            let result: Result<String?, Error> = withLock {
                _callCount += 1
                return _result
            }
            switch result {
            case .success(let value): return value
            case .failure(let error): throw error
            }
        }
    }

    // MARK: - Helpers

    /// Sentinel userId — deliberately does not overlap the JWT-payload
    /// character set that fails validation, so we can round-trip it through
    /// the cookie construction path.
    static let sentinelUserId = "user_ABC123.-_valid"

    /// Sentinel `sub` claim — a real WorkOS-shaped sub like
    /// `auth0|user_ABC123` puts our userId after the last `|`.
    static let sentinelSub = "auth0|\(sentinelUserId)"

    /// Sentinel signature segment — anything base64url-shaped. Never verified.
    static let sentinelSignature = "signature-not-verified"

    /// Build a sentinel JWT with the given payload dictionary. Returns the
    /// full three-segment token as a String. The signature is a fixed
    /// placeholder — we never verify signatures.
    static func makeJWT(payload: [String: Any]) -> String {
        // Header is unused by the provider but must be a valid base64url segment.
        let headerData = try! JSONSerialization.data(withJSONObject: ["alg": "none"])
        let payloadData = try! JSONSerialization.data(withJSONObject: payload)
        let signatureData = Data(sentinelSignature.utf8)
        return [
            base64UrlEncode(headerData),
            base64UrlEncode(payloadData),
            base64UrlEncode(signatureData)
        ].joined(separator: ".")
    }

    /// Base64url-encode without padding (matches what a real JWT uses).
    static func base64UrlEncode(_ data: Data) -> String {
        var s = data.base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
             .replacingOccurrences(of: "/", with: "_")
        while s.hasSuffix("=") { s.removeLast() }
        return s
    }

    /// Standard sentinel JWT used by most tests. The payload has a `sub`
    /// after a `|`, and no other claims.
    static var sentinelJWT: String {
        makeJWT(payload: ["sub": sentinelSub])
    }

    private func fixture() throws -> Data {
        let url = Bundle.module.url(forResource: "cursor-usage", withExtension: "json", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "cursor-usage", withExtension: "json")
        guard let url else {
            XCTFail("cursor-usage.json fixture not found in test bundle")
            throw FetchError.other("fixture missing")
        }
        return try Data(contentsOf: url)
    }

    private func makeTransport() -> RecordingTransport {
        RecordingTransport(responseURL: CursorProvider.endpoint)
    }

    private func makeProvider(
        auth: CursorAuthReader,
        transport: HTTPTransport,
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_780_000_000) }
    ) -> CursorProvider {
        CursorProvider(transport: transport, auth: auth, now: now)
    }

    // MARK: - JWT parsing

    func testUserIdFromSubWithPipeReturnsSuffix() {
        let jwt = Self.makeJWT(payload: ["sub": "auth0|user_ABC123"])
        XCTAssertEqual(CursorJWT.userId(fromAccessToken: jwt), "user_ABC123")
    }

    func testUserIdFromSubWithMultiplePipesReturnsLastSegment() {
        let jwt = Self.makeJWT(payload: ["sub": "prefix|middle|user_XYZ"])
        XCTAssertEqual(CursorJWT.userId(fromAccessToken: jwt), "user_XYZ")
    }

    func testUserIdFromSubWithoutPipeReturnsWholeSub() {
        let jwt = Self.makeJWT(payload: ["sub": "user_NoPipe"])
        XCTAssertEqual(CursorJWT.userId(fromAccessToken: jwt), "user_NoPipe")
    }

    func testUserIdRejectsInvalidCharsetInSuffix() {
        // A colon after the `|` is not in [A-Za-z0-9._-]. Must be rejected —
        // otherwise a maliciously-crafted sub could inject header syntax.
        let jwt = Self.makeJWT(payload: ["sub": "auth0|bad:userId"])
        XCTAssertNil(CursorJWT.userId(fromAccessToken: jwt))
    }

    func testUserIdRejectsWhitespaceInSuffix() {
        let jwt = Self.makeJWT(payload: ["sub": "auth0|user id"])
        XCTAssertNil(CursorJWT.userId(fromAccessToken: jwt))
    }

    func testUserIdRejectsMissingSub() {
        let jwt = Self.makeJWT(payload: ["iss": "cursor"])
        XCTAssertNil(CursorJWT.userId(fromAccessToken: jwt))
    }

    func testUserIdRejectsSubNotAString() {
        let jwt = Self.makeJWT(payload: ["sub": 42])
        XCTAssertNil(CursorJWT.userId(fromAccessToken: jwt))
    }

    func testUserIdRejectsMalformedJWT() {
        XCTAssertNil(CursorJWT.userId(fromAccessToken: "not-a-jwt"))
        XCTAssertNil(CursorJWT.userId(fromAccessToken: ""))
        XCTAssertNil(CursorJWT.userId(fromAccessToken: "onlyonepart"))
        XCTAssertNil(CursorJWT.userId(fromAccessToken: "aaa.@@@not-base64@@@.bbb"))
    }

    func testUserIdRejectsEmptySuffix() {
        let jwt = Self.makeJWT(payload: ["sub": "auth0|"])
        XCTAssertNil(CursorJWT.userId(fromAccessToken: jwt))
    }

    // MARK: - Cookie construction

    func testCookieHeaderUsesUrlEncodedDoubleColon() {
        let provider = makeProvider(
            auth: FakeCursorAuthReader(.success(nil)),
            transport: makeTransport()
        )
        let header = provider.cookieHeader(userId: "u123", token: "aaa.bbb.ccc")
        XCTAssertEqual(header, "WorkosCursorSessionToken=u123%3A%3Aaaa.bbb.ccc")
    }

    // MARK: - Request construction

    func testFetchIssuesGETWithCookieAndAccept() async throws {
        let auth = FakeCursorAuthReader(.success(Self.sentinelJWT))
        let transport = makeTransport()
        transport.enqueue(status: 200, body: try fixture())
        let provider = makeProvider(auth: auth, transport: transport)

        _ = try await provider.fetch()

        XCTAssertEqual(transport.requests.count, 1)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://cursor.com/api/usage-summary")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Cookie"),
            "WorkosCursorSessionToken=\(Self.sentinelUserId)%3A%3A\(Self.sentinelJWT)"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Accept"),
            "application/json"
        )
        XCTAssertEqual(auth.callCount, 1, "one credentials load per fetch()")
    }

    // MARK: - Parsing

    func testParsesFixture() async throws {
        let auth = FakeCursorAuthReader(.success(Self.sentinelJWT))
        let transport = makeTransport()
        transport.enqueue(status: 200, body: try fixture())
        let fixedNow = Date(timeIntervalSince1970: 1_780_000_000)
        let provider = makeProvider(auth: auth, transport: transport, now: { fixedNow })

        let usage = try await provider.fetch()

        XCTAssertEqual(usage.id, .cursor)
        XCTAssertEqual(usage.plan, "enterprise")
        XCTAssertEqual(usage.fetchedAt, fixedNow)
        // Plan window plus on-demand window (enabled: true, limit: null).
        XCTAssertEqual(usage.windows.count, 2)

        let plan = try XCTUnwrap(usage.windows.first(where: { $0.kind == .billingCycle }))
        XCTAssertEqual(plan.label, "Monthly")
        XCTAssertEqual(plan.usedPercent, 100.0, accuracy: 0.0001)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(plan.resetsAt, iso.date(from: "2026-10-23T18:15:03.000Z"))

        let onDemand = try XCTUnwrap(usage.windows.first(where: { $0.kind == .onDemand }))
        XCTAssertEqual(onDemand.amountCents, 2083)
        XCTAssertNil(onDemand.limitCents, "fixture has limit: null")
        // On-demand never carries a percent — it is not the ring.
        XCTAssertEqual(onDemand.usedPercent, 0)
    }

    func testFallbackToTotalPercentUsedWhenLimitZero() async throws {
        let body: [String: Any] = [
            "billingCycleEnd": "2026-11-01T00:00:00.000Z",
            "membershipType": "pro",
            "individualUsage": [
                "plan": [
                    "used": 100,
                    "limit": 0,
                    "totalPercentUsed": 42
                ] as [String: Any]
            ] as [String: Any]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let auth = FakeCursorAuthReader(.success(Self.sentinelJWT))
        let transport = makeTransport()
        transport.enqueue(status: 200, body: data)
        let provider = makeProvider(auth: auth, transport: transport)

        let usage = try await provider.fetch()
        XCTAssertEqual(usage.windows.count, 1)
        let first = try XCTUnwrap(usage.windows.first)
        XCTAssertEqual(first.usedPercent, 42.0, accuracy: 0.0001)
    }

    func testFallbackToTotalPercentUsedWhenLimitAbsent() async throws {
        let body: [String: Any] = [
            "billingCycleEnd": "2026-11-01T00:00:00.000Z",
            "membershipType": "pro",
            "individualUsage": [
                "plan": [
                    "used": 100,
                    "totalPercentUsed": 33
                ] as [String: Any]
            ] as [String: Any]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let auth = FakeCursorAuthReader(.success(Self.sentinelJWT))
        let transport = makeTransport()
        transport.enqueue(status: 200, body: data)
        let provider = makeProvider(auth: auth, transport: transport)

        let usage = try await provider.fetch()
        let first = try XCTUnwrap(usage.windows.first)
        XCTAssertEqual(first.usedPercent, 33.0, accuracy: 0.0001)
    }

    func testOnDemandWithNumericLimitCarriesBothFields() async throws {
        let body: [String: Any] = [
            "billingCycleEnd": "2026-11-01T00:00:00.000Z",
            "membershipType": "pro",
            "individualUsage": [
                "plan": [
                    "used": 500,
                    "limit": 2000
                ] as [String: Any],
                "onDemand": [
                    "enabled": true,
                    "used": 2083,
                    "limit": 5000
                ] as [String: Any]
            ] as [String: Any]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let auth = FakeCursorAuthReader(.success(Self.sentinelJWT))
        let transport = makeTransport()
        transport.enqueue(status: 200, body: data)
        let provider = makeProvider(auth: auth, transport: transport)

        let usage = try await provider.fetch()
        let onDemand = try XCTUnwrap(usage.windows.first(where: { $0.kind == .onDemand }))
        XCTAssertEqual(onDemand.amountCents, 2083)
        XCTAssertEqual(onDemand.limitCents, 5000)
    }

    func testOnDemandDisabledIsOmitted() async throws {
        let body: [String: Any] = [
            "billingCycleEnd": "2026-11-01T00:00:00.000Z",
            "membershipType": "pro",
            "individualUsage": [
                "plan": [
                    "used": 500,
                    "limit": 2000
                ] as [String: Any],
                "onDemand": [
                    "enabled": false,
                    "used": 0,
                    "limit": NSNull()
                ] as [String: Any]
            ] as [String: Any]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let auth = FakeCursorAuthReader(.success(Self.sentinelJWT))
        let transport = makeTransport()
        transport.enqueue(status: 200, body: data)
        let provider = makeProvider(auth: auth, transport: transport)

        let usage = try await provider.fetch()
        XCTAssertEqual(usage.windows.count, 1, "disabled on-demand must not appear")
        XCTAssertEqual(usage.windows.first?.kind, .billingCycle)
    }

    func testOnDemandEnabledWithNullLimitStillIncluded() async throws {
        // enabled=true, limit=null → still shown as a secondary line.
        let body: [String: Any] = [
            "billingCycleEnd": "2026-11-01T00:00:00.000Z",
            "membershipType": "pro",
            "individualUsage": [
                "plan": [
                    "used": 500,
                    "limit": 2000
                ] as [String: Any],
                "onDemand": [
                    "enabled": true,
                    "used": 1234,
                    "limit": NSNull()
                ] as [String: Any]
            ] as [String: Any]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let auth = FakeCursorAuthReader(.success(Self.sentinelJWT))
        let transport = makeTransport()
        transport.enqueue(status: 200, body: data)
        let provider = makeProvider(auth: auth, transport: transport)

        let usage = try await provider.fetch()
        let onDemand = try XCTUnwrap(usage.windows.first(where: { $0.kind == .onDemand }))
        XCTAssertEqual(onDemand.amountCents, 1234)
        XCTAssertNil(onDemand.limitCents)
    }

    // MARK: - Strict-parsing failures

    func testMissingIndividualUsageYieldsParseError() async throws {
        let body: [String: Any] = ["membershipType": "pro"]
        let data = try JSONSerialization.data(withJSONObject: body)
        let auth = FakeCursorAuthReader(.success(Self.sentinelJWT))
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

    func testMissingPlanYieldsParseError() async throws {
        let body: [String: Any] = [
            "membershipType": "pro",
            "individualUsage": [String: Any]()
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let auth = FakeCursorAuthReader(.success(Self.sentinelJWT))
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

    func testPlanWithoutPercentSourceYieldsParseError() async throws {
        // No used/limit AND no totalPercentUsed → no way to derive a percent.
        let body: [String: Any] = [
            "membershipType": "pro",
            "individualUsage": [
                "plan": [
                    "someOtherField": "x"
                ] as [String: Any]
            ] as [String: Any]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let auth = FakeCursorAuthReader(.success(Self.sentinelJWT))
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
        let auth = FakeCursorAuthReader(.success(Self.sentinelJWT))
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
        let auth = FakeCursorAuthReader(.success(Self.sentinelJWT))
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

    func testPlanUsedBooleanRejectedThroughNumericJSON() async throws {
        // used: true should NOT be read as 1. If both used/limit are unreadable
        // and totalPercentUsed is absent, must fail with parse error.
        let body: [String: Any] = [
            "billingCycleEnd": "2026-11-01T00:00:00.000Z",
            "membershipType": "pro",
            "individualUsage": [
                "plan": [
                    "used": true,
                    "limit": true
                ] as [String: Any]
            ] as [String: Any]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let auth = FakeCursorAuthReader(.success(Self.sentinelJWT))
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

    // MARK: - Auth / isInstalled

    func testIsInstalledFalseWhenAuthReturnsNil() async {
        let auth = FakeCursorAuthReader(.success(nil))
        let installed = await makeProvider(auth: auth, transport: makeTransport()).isInstalled()
        XCTAssertFalse(installed)
    }

    func testIsInstalledTrueWhenTokenPresent() async {
        let auth = FakeCursorAuthReader(.success(Self.sentinelJWT))
        let installed = await makeProvider(auth: auth, transport: makeTransport()).isInstalled()
        XCTAssertTrue(installed)
    }

    func testIsInstalledTrueOnReaderError() async {
        // DB exists but is unreadable / corrupt. Do NOT silently hide the
        // ring — fetch will surface the "Couldn't read..." error row.
        let auth = FakeCursorAuthReader(.failure(FetchError.other("Couldn't read Cursor session database")))
        let installed = await makeProvider(auth: auth, transport: makeTransport()).isInstalled()
        XCTAssertTrue(installed)
    }

    func testFetchWithoutTokenThrowsSignedOut() async {
        let auth = FakeCursorAuthReader(.success(nil))
        let transport = makeTransport()
        let provider = makeProvider(auth: auth, transport: transport)

        do {
            _ = try await provider.fetch()
            XCTFail("expected signedOut")
        } catch let error as FetchError {
            XCTAssertEqual(error, .signedOut("Open Cursor to refresh"))
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertEqual(transport.requests.count, 0, "no request must fire when the token is missing")
    }

    func testFetchWithMalformedJWTThrowsSignedOut() async {
        let auth = FakeCursorAuthReader(.success("not-a-jwt"))
        let transport = makeTransport()
        let provider = makeProvider(auth: auth, transport: transport)

        do {
            _ = try await provider.fetch()
            XCTFail("expected signedOut")
        } catch let error as FetchError {
            XCTAssertEqual(error, .signedOut("Open Cursor to refresh"))
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertEqual(transport.requests.count, 0)
    }

    func testFetchWithReaderErrorPassesThrough() async {
        let auth = FakeCursorAuthReader(.failure(FetchError.other("Couldn't read Cursor session database")))
        let transport = makeTransport()
        let provider = makeProvider(auth: auth, transport: transport)

        do {
            _ = try await provider.fetch()
            XCTFail("expected other")
        } catch let error as FetchError {
            XCTAssertEqual(error, .other("Couldn't read Cursor session database"))
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertEqual(transport.requests.count, 0)
    }

    // MARK: - HTTP error paths

    func testHTTP401MapsToSignedOut() async throws {
        let auth = FakeCursorAuthReader(.success(Self.sentinelJWT))
        let transport = makeTransport()
        transport.enqueue(status: 401, body: Data())
        let provider = makeProvider(auth: auth, transport: transport)

        do {
            _ = try await provider.fetch()
            XCTFail("expected signedOut")
        } catch let error as FetchError {
            XCTAssertEqual(error, .signedOut("Open Cursor to refresh"))
        }
    }

    func testHTTP403MapsToSignedOut() async throws {
        let auth = FakeCursorAuthReader(.success(Self.sentinelJWT))
        let transport = makeTransport()
        transport.enqueue(status: 403, body: Data())
        let provider = makeProvider(auth: auth, transport: transport)

        do {
            _ = try await provider.fetch()
            XCTFail("expected signedOut")
        } catch let error as FetchError {
            XCTAssertEqual(error, .signedOut("Open Cursor to refresh"))
        }
    }

    func testHTTP429MapsToRateLimited() async throws {
        let auth = FakeCursorAuthReader(.success(Self.sentinelJWT))
        let transport = makeTransport()
        transport.enqueue(status: 429, body: Data(), headers: ["Retry-After": "20"])
        let provider = makeProvider(auth: auth, transport: transport)

        do {
            _ = try await provider.fetch()
            XCTFail("expected rateLimited")
        } catch let error as FetchError {
            XCTAssertEqual(error, .rateLimited(retryAfter: 20))
        }
    }

    func testHTTP500MapsToServer() async throws {
        let auth = FakeCursorAuthReader(.success(Self.sentinelJWT))
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
        let auth = FakeCursorAuthReader(.success(Self.sentinelJWT))
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
        let auth = FakeCursorAuthReader(.success(Self.sentinelJWT))
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

    // MARK: - No token leakage in error messages

    func testMalformedUsageJSONDoesNotLeakToken() async throws {
        let sentinelToken = "aaa.eyJzdWIiOiJzZW50aW5lbC1sZWFrLWNoZWNrIn0.bbb"
        let auth = FakeCursorAuthReader(.success(sentinelToken))
        let transport = makeTransport()
        transport.enqueue(status: 200, body: Data("<html>oops</html>".utf8))
        let provider = makeProvider(auth: auth, transport: transport)

        do {
            _ = try await provider.fetch()
            XCTFail("expected parse error")
        } catch let error as FetchError {
            switch error {
            case .parse(let message):
                XCTAssertFalse(message.contains(sentinelToken),
                               "token bytes must never appear in the error message")
            default:
                XCTFail("expected .parse, got \(error)")
            }
        }
    }
}

// MARK: - FileSystemCursorAuthReader (real SQLite)

/// Exercises `FileSystemCursorAuthReader` against a real SQLite database
/// built in a tmp directory. Never touches the real Cursor DB path.
final class FileSystemCursorAuthReaderTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cursor-auth-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
    }

    /// Build a tmp SQLite DB with an `ItemTable(key TEXT PRIMARY KEY, value BLOB)`
    /// schema and optionally seed one row for the Cursor access-token key.
    /// Returns the path to the DB file.
    ///
    /// Uses a read/write handle so the seed inserts land; the reader-under-test
    /// then opens the same file read-only.
    private func makeDB(seedToken: String? = nil) throws -> URL {
        let path = tempDir.appendingPathComponent("state.vscdb")
        var db: OpaquePointer?
        let openStatus = sqlite3_open_v2(
            path.path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        )
        guard openStatus == SQLITE_OK, let db else {
            XCTFail("failed to open tmp DB (status: \(openStatus))")
            throw FetchError.other("tmp DB open failed")
        }
        defer { sqlite3_close_v2(db) }

        let createSQL = "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB NOT NULL)"
        if sqlite3_exec(db, createSQL, nil, nil, nil) != SQLITE_OK {
            XCTFail("failed to create ItemTable")
            throw FetchError.other("tmp DB create failed")
        }

        if let token = seedToken {
            let insertSQL = "INSERT INTO ItemTable (key, value) VALUES (?, ?)"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil) == SQLITE_OK else {
                XCTFail("prepare failed")
                throw FetchError.other("tmp DB prepare failed")
            }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(
                OpaquePointer(bitPattern: -1),
                to: sqlite3_destructor_type.self
            )
            _ = FileSystemCursorAuthReader.itemKey.withCString { keyC in
                sqlite3_bind_text(statement, 1, keyC, -1, transient)
            }
            _ = token.withCString { valueC in
                sqlite3_bind_text(statement, 2, valueC, -1, transient)
            }
            guard sqlite3_step(statement) == SQLITE_DONE else {
                XCTFail("insert failed")
                throw FetchError.other("tmp DB insert failed")
            }
        }

        return path
    }

    func testMissingFileReturnsNil() async throws {
        let path = tempDir.appendingPathComponent("state.vscdb") // never created
        let reader = FileSystemCursorAuthReader(path: path)
        let token = try await reader.loadAccessToken()
        XCTAssertNil(token, "missing DB → hidden, not an error")
    }

    func testDBWithoutAccessTokenRowReturnsNil() async throws {
        // ItemTable exists but there's no row for our key.
        let path = try makeDB(seedToken: nil)
        let reader = FileSystemCursorAuthReader(path: path)
        let token = try await reader.loadAccessToken()
        XCTAssertNil(token, "DB present with no row → hidden (user logged out)")
    }

    func testDBWithAccessTokenReturnsIt() async throws {
        let sentinel = "aaa.eyJzdWIiOiJzZW50aW5lbF9zdWJfaW5fZGIifQ.bbb"
        let path = try makeDB(seedToken: sentinel)
        let reader = FileSystemCursorAuthReader(path: path)
        let token = try await reader.loadAccessToken()
        XCTAssertEqual(token, sentinel)
    }

    func testDBWithoutItemTableThrowsOtherReadError() async throws {
        // A DB file that opens but has no `ItemTable` schema — the schema
        // has changed. Surface as a fixed read error, not as "not installed".
        let path = tempDir.appendingPathComponent("state.vscdb")
        var db: OpaquePointer?
        _ = sqlite3_open_v2(
            path.path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        )
        // Create some unrelated table so the file is a valid SQLite DB but
        // lacks ItemTable.
        _ = sqlite3_exec(db, "CREATE TABLE OtherTable (x INTEGER)", nil, nil, nil)
        sqlite3_close_v2(db)

        let reader = FileSystemCursorAuthReader(path: path)
        do {
            _ = try await reader.loadAccessToken()
            XCTFail("expected other error")
        } catch let error as FetchError {
            XCTAssertEqual(error, .other("Couldn't read Cursor session database"))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testCorruptedFileThrowsOtherReadError() async throws {
        let path = tempDir.appendingPathComponent("state.vscdb")
        // Write garbage that is not a valid SQLite file — the header check
        // in sqlite3_open_v2 / sqlite3_prepare_v2 must reject it.
        try Data(repeating: 0xFF, count: 256).write(to: path)

        let reader = FileSystemCursorAuthReader(path: path)
        do {
            _ = try await reader.loadAccessToken()
            XCTFail("expected other error")
        } catch let error as FetchError {
            XCTAssertEqual(error, .other("Couldn't read Cursor session database"))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testDefaultPathIsUnderLibraryApplicationSupport() {
        let home = URL(fileURLWithPath: "/Users/test")
        let path = FileSystemCursorAuthReader.defaultPath(homeDirectory: home)
        XCTAssertEqual(
            path.path,
            "/Users/test/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
        )
    }

    func testReaderOpenFlagsIncludeReadOnlyAndExcludeReadWrite() {
        // Static-flag assertion: reader's open call MUST include
        // SQLITE_OPEN_READONLY and MUST NOT include SQLITE_OPEN_READWRITE.
        // A chmod-0400 filesystem check alone doesn't distinguish the two
        // — SQLite silently opens READWRITE as read-only when the file
        // has no write bit — so we assert on the flags directly.
        let flags = FileSystemCursorAuthReader.openFlags
        XCTAssertNotEqual(flags & SQLITE_OPEN_READONLY, 0,
                          "reader must set SQLITE_OPEN_READONLY")
        XCTAssertEqual(flags & SQLITE_OPEN_READWRITE, 0,
                       "reader must NOT set SQLITE_OPEN_READWRITE")
        XCTAssertNotEqual(flags & SQLITE_OPEN_URI, 0,
                          "reader must set SQLITE_OPEN_URI so the `file:...` scheme is honoured")
        XCTAssertEqual(flags & SQLITE_OPEN_CREATE, 0,
                       "reader must NOT set SQLITE_OPEN_CREATE")
    }

    func testReaderOpenURIContainsModeReadOnly() {
        // Belt for the SQLITE_OPEN_READONLY-only braces above: even if a
        // future refactor drops the flag, the URI's `mode=ro` parameter
        // still enforces read-only. Assert it is present in the URI the
        // reader will pass to sqlite3_open_v2.
        let uri = FileSystemCursorAuthReader.openURI(for: URL(fileURLWithPath: "/tmp/example/state.vscdb"))
        XCTAssertTrue(uri.hasPrefix("file:"), "URI must start with file: scheme")
        XCTAssertTrue(uri.contains("mode=ro"), "URI must carry the mode=ro query parameter")
    }

    func testReaderOpensDBWithSqlite3DbReadonlyOne() throws {
        // Runtime check on a normally-writable (0600) DB: replicate the
        // reader's open call and ask SQLite itself via
        // `sqlite3_db_readonly(db, "main")` — returns 1 if the handle is
        // read-only, 0 if writable, -1 if the name is unknown. Any
        // read-write open of a 0600 file would yield 0 here, so this
        // catches the READWRITE regression the 0400 test could not.
        let sentinel = "aaa.eyJzdWIiOiJzZW50aW5lbF9zdWJfaW5fZGIifQ.bbb"
        let path = try makeDB(seedToken: sentinel)
        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(
            FileSystemCursorAuthReader.openURI(for: path),
            &db,
            FileSystemCursorAuthReader.openFlags,
            nil
        )
        defer { if db != nil { sqlite3_close_v2(db) } }
        XCTAssertEqual(openResult, SQLITE_OK)
        // sqlite3_db_readonly signals: 1 = readonly, 0 = writable, -1 = unknown.
        let mainName = "main".withCString { sqlite3_db_readonly(db, $0) }
        XCTAssertEqual(mainName, 1,
                       "sqlite3_db_readonly(db, \"main\") must return 1 for the reader's flags on a 0600 file")
    }

    func testReaderWorksOnWALModeDBAfterCheckpoint() async throws {
        // Cursor writes its state DB in WAL mode; opening it read-only must
        // succeed even after Cursor quits (which checkpoints the WAL). We
        // build a DB, `PRAGMA journal_mode=WAL`, insert the key, checkpoint,
        // close, then hand the reader the path — matching the "Cursor is
        // not running right now" shape.
        let sentinel = "aaa.eyJzdWIiOiJ3YWxfbW9kZV9zdWJfaW5fZGIifQ.bbb"
        let path = tempDir.appendingPathComponent("state.vscdb")

        var db: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil),
            SQLITE_OK
        )
        var walResult: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "PRAGMA journal_mode=WAL", -1, &walResult, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(walResult), SQLITE_ROW)
        sqlite3_finalize(walResult)
        XCTAssertEqual(
            sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB NOT NULL)", nil, nil, nil),
            SQLITE_OK
        )
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO ItemTable (key, value) VALUES (?, ?)", -1, &stmt, nil), SQLITE_OK)
        let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        _ = FileSystemCursorAuthReader.itemKey.withCString { keyC in
            sqlite3_bind_text(stmt, 1, keyC, -1, transient)
        }
        _ = sentinel.withCString { valueC in
            sqlite3_bind_text(stmt, 2, valueC, -1, transient)
        }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
        sqlite3_finalize(stmt)
        // Checkpoint + close — Cursor's on-quit shape.
        sqlite3_wal_checkpoint(db, nil)
        sqlite3_close_v2(db)

        let reader = FileSystemCursorAuthReader(path: path)
        let token = try await reader.loadAccessToken()
        XCTAssertEqual(token, sentinel)
    }

    func testReaderWorksOnLiveWALWithUncheckpointedToken() async throws {
        // The realistic case: Cursor is currently running with the DB open
        // in WAL mode. The token INSERT lives only in the -wal file
        // (uncheckpointed). The reader must still return it — otherwise
        // "Cursor is running while the popover opens" would produce a
        // signed-out row.
        let sentinel = "aaa.eyJzdWIiOiJsaXZlX3dhbF9zZW50aW5lbCJ9.bbb"
        let path = tempDir.appendingPathComponent("state.vscdb")

        // Writer connection: keep it OPEN across the reader call so the
        // WAL is not automatically checkpointed by a `sqlite3_close_v2`.
        var writer: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(path.path, &writer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil),
            SQLITE_OK
        )
        defer {
            if writer != nil { sqlite3_close_v2(writer) }
        }
        // Enable WAL and disable automatic checkpointing so the -wal file
        // still has our INSERT when the reader looks.
        var walStmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(writer, "PRAGMA journal_mode=WAL", -1, &walStmt, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(walStmt), SQLITE_ROW)
        sqlite3_finalize(walStmt)
        XCTAssertEqual(sqlite3_exec(writer, "PRAGMA wal_autocheckpoint=0", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(writer, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB NOT NULL)", nil, nil, nil),
            SQLITE_OK
        )
        var insertStmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(writer, "INSERT INTO ItemTable (key, value) VALUES (?, ?)", -1, &insertStmt, nil), SQLITE_OK)
        let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        _ = FileSystemCursorAuthReader.itemKey.withCString { keyC in
            sqlite3_bind_text(insertStmt, 1, keyC, -1, transient)
        }
        _ = sentinel.withCString { valueC in
            sqlite3_bind_text(insertStmt, 2, valueC, -1, transient)
        }
        XCTAssertEqual(sqlite3_step(insertStmt), SQLITE_DONE)
        sqlite3_finalize(insertStmt)

        // Confirm the -wal sidecar is present with non-zero size — the
        // uncheckpointed shape we want to test.
        let walSidecarPath = path.path + "-wal"
        var walIsPopulated = false
        if let attrs = try? FileManager.default.attributesOfItem(atPath: walSidecarPath),
           let size = attrs[.size] as? NSNumber, size.intValue > 0 {
            walIsPopulated = true
        }
        XCTAssertTrue(walIsPopulated,
                      "test precondition: -wal sidecar must hold the uncheckpointed INSERT")

        // Read WITHOUT closing the writer — the reader sees the DB in WAL
        // mode with the token living in the -wal file only.
        let reader = FileSystemCursorAuthReader(path: path)
        let token = try await reader.loadAccessToken()
        XCTAssertEqual(token, sentinel,
                       "reader must return the token even when it is only in an uncheckpointed -wal")
    }

    func testReaderWorksOnPathContainingSpace() async throws {
        // The default install path already contains a space
        // (`Application Support`). The URI-encoding path inside the
        // reader must round-trip through SQLite's URI parser without loss.
        let spacedDir = tempDir.appendingPathComponent("with space")
        try FileManager.default.createDirectory(at: spacedDir, withIntermediateDirectories: true)
        let sentinel = "aaa.eyJzdWIiOiJzcGFjZWRfcGF0aF9zdWIifQ.bbb"
        let path = spacedDir.appendingPathComponent("state.vscdb")

        var db: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil),
            SQLITE_OK
        )
        XCTAssertEqual(
            sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB NOT NULL)", nil, nil, nil),
            SQLITE_OK
        )
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO ItemTable (key, value) VALUES (?, ?)", -1, &stmt, nil), SQLITE_OK)
        let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        _ = FileSystemCursorAuthReader.itemKey.withCString { keyC in
            sqlite3_bind_text(stmt, 1, keyC, -1, transient)
        }
        _ = sentinel.withCString { valueC in
            sqlite3_bind_text(stmt, 2, valueC, -1, transient)
        }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
        sqlite3_finalize(stmt)
        sqlite3_close_v2(db)

        let reader = FileSystemCursorAuthReader(path: path)
        let token = try await reader.loadAccessToken()
        XCTAssertEqual(token, sentinel,
                       "reader must handle a path containing a space (Application Support)")
    }
}
