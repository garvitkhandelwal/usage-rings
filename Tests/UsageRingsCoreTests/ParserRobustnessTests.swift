import XCTest
@testable import UsageRingsCore

/// Cross-provider robustness sweep — parsers must tolerate missing keys,
/// renamed keys, wrong types, and empty bodies by surfacing `.parse(_)`
/// (i.e. an error row in the popover) rather than crashing.
///
/// Provider-specific parse coverage (renamed windows, boolean utilization,
/// missing plan objects, …) already lives in each provider's own test
/// file. This file adds cross-cutting checks: totally empty response
/// bodies and huge finite percentages that must not trap.
final class ParserRobustnessTests: XCTestCase {

    // MARK: - Fake auth readers (bring the file-local doubles into scope)

    final class FixedClaudeCredentialReader: ClaudeCredentialReader, @unchecked Sendable {
        let body: Data
        init(_ body: Data) { self.body = body }
        func isPresent() async -> Bool { true }
        func read() async throws -> Data { body }
    }

    final class FixedCodexAuthReader: CodexAuthReader, @unchecked Sendable {
        let credentials: CodexCredentials
        init(_ credentials: CodexCredentials) { self.credentials = credentials }
        func loadCredentials() async throws -> CodexCredentials? { credentials }
    }

    final class FixedCursorAuthReader: CursorAuthReader, @unchecked Sendable {
        let token: String
        init(_ token: String) { self.token = token }
        func loadAccessToken() async throws -> String? { token }
    }

    // MARK: - Sentinels

    private static let claudeCredential: Data = {
        let dict: [String: Any] = [
            "claudeAiOauth": [
                "accessToken": "sentinel-claude-token",
                "expiresAt": 4_102_444_800_000
            ] as [String: Any]
        ]
        return try! JSONSerialization.data(withJSONObject: dict)
    }()

    private static let codexCredentials = CodexCredentials(
        accessToken: "sentinel-codex-token",
        accountId: "acct_SENTINEL"
    )

    /// Cursor sentinel JWT — a plain `sub` with no pipe, valid charset.
    private static let cursorJWT: String = {
        let header = try! JSONSerialization.data(withJSONObject: ["alg": "none"])
        let payload = try! JSONSerialization.data(withJSONObject: ["sub": "user_ABC123"])
        let signature = Data("nope".utf8)
        func b64(_ d: Data) -> String {
            var s = d.base64EncodedString()
            s = s.replacingOccurrences(of: "+", with: "-")
                 .replacingOccurrences(of: "/", with: "_")
            while s.hasSuffix("=") { s.removeLast() }
            return s
        }
        return "\(b64(header)).\(b64(payload)).\(b64(signature))"
    }()

    // MARK: - Empty body -> parse error (never a crash)

    func testEmptyBodyThroughClaudeYieldsParseError() async {
        let creds = FixedClaudeCredentialReader(Self.claudeCredential)
        let transport = RecordingTransport(responseURL: ClaudeProvider.endpoint)
        transport.enqueue(status: 200, body: Data())
        let provider = ClaudeProvider(transport: transport, credentials: creds)
        do {
            _ = try await provider.fetch()
            XCTFail("expected .parse for empty body")
        } catch let error as FetchError {
            guard case .parse = error else { return XCTFail("expected .parse, got \(error)") }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testEmptyBodyThroughCodexYieldsParseError() async {
        let auth = FixedCodexAuthReader(Self.codexCredentials)
        let transport = RecordingTransport(responseURL: CodexProvider.endpoint)
        transport.enqueue(status: 200, body: Data())
        let provider = CodexProvider(transport: transport, auth: auth)
        do {
            _ = try await provider.fetch()
            XCTFail("expected .parse for empty body")
        } catch let error as FetchError {
            guard case .parse = error else { return XCTFail("expected .parse, got \(error)") }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testEmptyBodyThroughCursorYieldsParseError() async {
        let auth = FixedCursorAuthReader(Self.cursorJWT)
        let transport = RecordingTransport(responseURL: CursorProvider.endpoint)
        transport.enqueue(status: 200, body: Data())
        let provider = CursorProvider(transport: transport, auth: auth)
        do {
            _ = try await provider.fetch()
            XCTFail("expected .parse for empty body")
        } catch let error as FetchError {
            guard case .parse = error else { return XCTFail("expected .parse, got \(error)") }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    // MARK: - Wrong-type root (already covered per-provider; sanity check here)

    func testStringRootAcrossProvidersYieldsParseError() async {
        let stringBody = Data("\"just a string\"".utf8)
        // Claude
        do {
            let creds = FixedClaudeCredentialReader(Self.claudeCredential)
            let transport = RecordingTransport(responseURL: ClaudeProvider.endpoint)
            transport.enqueue(status: 200, body: stringBody)
            let provider = ClaudeProvider(transport: transport, credentials: creds)
            do {
                _ = try await provider.fetch()
                XCTFail("Claude: expected .parse")
            } catch let error as FetchError {
                guard case .parse = error else { return XCTFail("Claude: expected .parse, got \(error)") }
            } catch { XCTFail("Claude: wrong error: \(error)") }
        }
        // Codex
        do {
            let auth = FixedCodexAuthReader(Self.codexCredentials)
            let transport = RecordingTransport(responseURL: CodexProvider.endpoint)
            transport.enqueue(status: 200, body: stringBody)
            let provider = CodexProvider(transport: transport, auth: auth)
            do {
                _ = try await provider.fetch()
                XCTFail("Codex: expected .parse")
            } catch let error as FetchError {
                guard case .parse = error else { return XCTFail("Codex: expected .parse, got \(error)") }
            } catch { XCTFail("Codex: wrong error: \(error)") }
        }
        // Cursor
        do {
            let auth = FixedCursorAuthReader(Self.cursorJWT)
            let transport = RecordingTransport(responseURL: CursorProvider.endpoint)
            transport.enqueue(status: 200, body: stringBody)
            let provider = CursorProvider(transport: transport, auth: auth)
            do {
                _ = try await provider.fetch()
                XCTFail("Cursor: expected .parse")
            } catch let error as FetchError {
                guard case .parse = error else { return XCTFail("Cursor: expected .parse, got \(error)") }
            } catch { XCTFail("Cursor: wrong error: \(error)") }
        }
    }

    // MARK: - Percentages outside 0..100 — clamp display, allow > 100 (second lap)

    func testPercentAbove100StillRenders() {
        // Second lap: 145% must display "145%". Above 100% wraps into
        // a second lap; the numeric label matches.
        XCTAssertEqual(Formatting.percentText(145.0), "145%")
    }

    func testHugeFinitePercentRendersPlaceholderAndDoesNotCrash() {
        // A provider that divides an enormous used by a tiny limit can hand
        // us values beyond `Int.max`. Must not trap AND must render the
        // "–%" placeholder — assert the exact strings, not just no-crash.
        XCTAssertEqual(Formatting.percentText(1e20), "–%")
        XCTAssertEqual(Formatting.percentText(-1e20), "–%")
        XCTAssertEqual(Formatting.percentText(1e308), "–%")
        XCTAssertEqual(Formatting.percentText(-1e308), "–%")
        // Double.greatestFiniteMagnitude ≈ 1.79e308 — the actual upper
        // bound of finite Doubles.
        XCTAssertEqual(Formatting.percentText(.greatestFiniteMagnitude), "–%")
        XCTAssertEqual(Formatting.percentText(-.greatestFiniteMagnitude), "–%")
    }

    func testNegativeFinitePercentClampsToZero() {
        // Providers can hand us -1 as an "unknown" sentinel, or a
        // subtraction can nudge just below zero. Row text and ring must
        // agree — the ring clamps at 0, so the row must too.
        XCTAssertEqual(Formatting.percentText(-1), "0%")
        XCTAssertEqual(Formatting.percentText(-0.4), "0%")
        // -0.5 rounds to -1 under .toNearestOrAwayFromZero → clamped.
        XCTAssertEqual(Formatting.percentText(-0.5), "0%")
        XCTAssertEqual(Formatting.percentText(-50), "0%")
    }

    func testHugeIconTintRendersNormalAndDoesNotCrash() {
        // Non-finite AND huge-finite values must be ignored by the tint
        // logic, not treated as extremely-high percentages. Assert exact
        // levels, including 1e308.
        XCTAssertEqual(Formatting.iconTintLevel(visiblePercents: [1e20]), .normal)
        XCTAssertEqual(Formatting.iconTintLevel(visiblePercents: [1e308]), .normal)
        XCTAssertEqual(
            Formatting.iconTintLevel(visiblePercents: [.greatestFiniteMagnitude]),
            .normal
        )
        // Realistic value alongside a huge one still drives the tint.
        XCTAssertEqual(Formatting.iconTintLevel(visiblePercents: [1e20, 96]), .red)
        XCTAssertEqual(Formatting.iconTintLevel(visiblePercents: [1e308, 82]), .amber)
    }

    // MARK: - Huge finite durations (reset / updated) must not trap

    func testHugeFinitePastFetchedAtDoesNotCrash() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let farPast = now.addingTimeInterval(-1e20)
        _ = Formatting.updatedText(fetchedAt: farPast, now: now)
    }

    func testHugeFiniteFutureResetDoesNotCrash() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let farFuture = now.addingTimeInterval(1e20)
        _ = Formatting.resetText(resetsAt: farFuture, now: now)
    }

    // MARK: - safeInt boundary

    func testSafeIntRejectsNonFiniteAndOutOfRange() {
        XCTAssertNil(Formatting.safeInt(.nan))
        XCTAssertNil(Formatting.safeInt(.infinity))
        XCTAssertNil(Formatting.safeInt(-.infinity))
        XCTAssertNil(Formatting.safeInt(1e20))
        XCTAssertNil(Formatting.safeInt(-1e20))
        XCTAssertEqual(Formatting.safeInt(0), 0)
        XCTAssertEqual(Formatting.safeInt(42.4), 42)
        XCTAssertEqual(Formatting.safeInt(42.6), 43)
        XCTAssertEqual(Formatting.safeInt(-5.5), -6)
    }

    // MARK: - Codex label robustness

    func testCodexLabelForSubSecondValueDoesNotYieldZeroDay() async throws {
        // A 0.3-second window rounds to 0 under `.toNearestOrAwayFromZero`.
        // Older behaviour: `Int(0.3.rounded()) == 0`, then the switch's
        // default took `whole % 86_400 == 0 → 0/86400 → "0d"` — visibly
        // bogus.
        //
        // Post-fix: `Formatting.safeInt(0.3)` returns 0, the `whole > 0`
        // guard rejects it, and the label falls back to the per-kind
        // "Primary". Assert the exact "Primary" string.
        //
        // (0.5 would round *up* to 1 under `.toNearestOrAwayFromZero` and
        // land in the "1m" branch under the new code, so it does NOT
        // exercise the pre-fix regression at all.)
        let auth = FixedCodexAuthReader(Self.codexCredentials)
        let transport = RecordingTransport(responseURL: CodexProvider.endpoint)
        let body: [String: Any] = [
            "plan_type": "pro",
            "rate_limit": [
                "primary_window": [
                    "used_percent": 5,
                    "limit_window_seconds": 0.3,
                    "reset_at": 1_800_000_000
                ] as [String: Any]
            ] as [String: Any]
        ]
        transport.enqueue(status: 200, body: try JSONSerialization.data(withJSONObject: body))
        let usage = try await CodexProvider(transport: transport, auth: auth).fetch()
        let label = try XCTUnwrap(usage.windows.first?.label)
        XCTAssertEqual(label, "Primary",
                       "0.3s must render as the per-kind fallback; older code returned '0d'")
    }

    func testCodexLabelFor3570SecondsIsNot60m() async throws {
        // Old behaviour rounded 3570 s up to "60m" via `(whole + 30) / 60`.
        // Must floor to 59m instead.
        let auth = FixedCodexAuthReader(Self.codexCredentials)
        let transport = RecordingTransport(responseURL: CodexProvider.endpoint)
        let body: [String: Any] = [
            "plan_type": "pro",
            "rate_limit": [
                "primary_window": [
                    "used_percent": 5,
                    "limit_window_seconds": 3570,
                    "reset_at": 1_800_000_000
                ] as [String: Any]
            ] as [String: Any]
        ]
        transport.enqueue(status: 200, body: try JSONSerialization.data(withJSONObject: body))
        let usage = try await CodexProvider(transport: transport, auth: auth).fetch()
        XCTAssertEqual(usage.windows.first?.label, "59m")
    }

    func testCodexLabelForHugeFiniteSecondsDoesNotCrash() async throws {
        // limit_window_seconds = 1e20 previously trapped in
        // `Int(seconds.rounded())`. Must fall back gracefully.
        let auth = FixedCodexAuthReader(Self.codexCredentials)
        let transport = RecordingTransport(responseURL: CodexProvider.endpoint)
        let body: [String: Any] = [
            "plan_type": "pro",
            "rate_limit": [
                "primary_window": [
                    "used_percent": 5,
                    "limit_window_seconds": 1e20,
                    "reset_at": 1_800_000_000
                ] as [String: Any]
            ] as [String: Any]
        ]
        transport.enqueue(status: 200, body: try JSONSerialization.data(withJSONObject: body))
        let usage = try await CodexProvider(transport: transport, auth: auth).fetch()
        // No crash; label falls back to per-kind default.
        XCTAssertEqual(usage.windows.first?.label, "Primary")
    }

    // MARK: - Cursor on-demand robustness

    func testCursorOnDemandEnabledMissingUsedYieldsParseError() async {
        // enabled=true but `used` absent → must surface as a parse error so
        // the user sees a visible signal that Cursor's shape has changed,
        // rather than silently dropping the on-demand line.
        let body: [String: Any] = [
            "billingCycleEnd": "2026-11-01T00:00:00.000Z",
            "membershipType": "pro",
            "individualUsage": [
                "plan": ["used": 500, "limit": 2000] as [String: Any],
                "onDemand": ["enabled": true] as [String: Any]
            ] as [String: Any]
        ]
        let auth = FixedCursorAuthReader(Self.cursorJWT)
        let transport = RecordingTransport(responseURL: CursorProvider.endpoint)
        transport.enqueue(status: 200, body: try! JSONSerialization.data(withJSONObject: body))
        let provider = CursorProvider(transport: transport, auth: auth)
        do {
            _ = try await provider.fetch()
            XCTFail("expected parse error")
        } catch let error as FetchError {
            guard case .parse = error else { return XCTFail("expected .parse, got \(error)") }
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testCursorOnDemandEnabledUsedNullYieldsParseError() async {
        let body: [String: Any] = [
            "billingCycleEnd": "2026-11-01T00:00:00.000Z",
            "membershipType": "pro",
            "individualUsage": [
                "plan": ["used": 500, "limit": 2000] as [String: Any],
                "onDemand": ["enabled": true, "used": NSNull()] as [String: Any]
            ] as [String: Any]
        ]
        let auth = FixedCursorAuthReader(Self.cursorJWT)
        let transport = RecordingTransport(responseURL: CursorProvider.endpoint)
        transport.enqueue(status: 200, body: try! JSONSerialization.data(withJSONObject: body))
        let provider = CursorProvider(transport: transport, auth: auth)
        do {
            _ = try await provider.fetch()
            XCTFail("expected parse error")
        } catch let error as FetchError {
            guard case .parse = error else { return XCTFail("expected .parse, got \(error)") }
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testCursorOnDemandHugeUsedYieldsParseError() async {
        // A huge finite `used` cents value must not trap on the Int(x.rounded())
        // conversion. Surfaces as a parse error (chose parse over silent drop).
        let body: [String: Any] = [
            "billingCycleEnd": "2026-11-01T00:00:00.000Z",
            "membershipType": "pro",
            "individualUsage": [
                "plan": ["used": 500, "limit": 2000] as [String: Any],
                "onDemand": ["enabled": true, "used": 1e20] as [String: Any]
            ] as [String: Any]
        ]
        let auth = FixedCursorAuthReader(Self.cursorJWT)
        let transport = RecordingTransport(responseURL: CursorProvider.endpoint)
        transport.enqueue(status: 200, body: try! JSONSerialization.data(withJSONObject: body))
        let provider = CursorProvider(transport: transport, auth: auth)
        do {
            _ = try await provider.fetch()
            XCTFail("expected parse error for huge used")
        } catch let error as FetchError {
            guard case .parse = error else { return XCTFail("expected .parse, got \(error)") }
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testCursorOnDemandHugeLimitFallsBackToNilLimit() async throws {
        // A huge finite `limit` should NOT trap; instead it decays to a nil
        // limit and the secondary line uses the "$X on-demand" shape.
        let body: [String: Any] = [
            "billingCycleEnd": "2026-11-01T00:00:00.000Z",
            "membershipType": "pro",
            "individualUsage": [
                "plan": ["used": 500, "limit": 2000] as [String: Any],
                "onDemand": ["enabled": true, "used": 1234, "limit": 1e20] as [String: Any]
            ] as [String: Any]
        ]
        let auth = FixedCursorAuthReader(Self.cursorJWT)
        let transport = RecordingTransport(responseURL: CursorProvider.endpoint)
        transport.enqueue(status: 200, body: try JSONSerialization.data(withJSONObject: body))
        let provider = CursorProvider(transport: transport, auth: auth)
        let usage = try await provider.fetch()
        let onDemand = try XCTUnwrap(usage.windows.first(where: { $0.kind == .onDemand }))
        XCTAssertEqual(onDemand.amountCents, 1234)
        XCTAssertNil(onDemand.limitCents, "huge finite limit → treated as unknown, not a trap")
    }

    // MARK: - Cursor token trimming

    func testCursorTrimmedTokenFlowsIntoCookieVerbatim() async throws {
        // A DB row could plausibly contain a trailing newline. The provider
        // must strip it exactly once in `loadToken` so both the JWT parser
        // and the cookie header see the same bytes — otherwise the userId
        // decodes but the cookie carries a stray newline (which Cursor's
        // backend rejects). Fixture cursor-usage body wired up so we can
        // observe the actual header.
        let raw = Self.cursorJWT + "\n"
        let auth = FixedCursorAuthReader(raw)
        let transport = RecordingTransport(responseURL: CursorProvider.endpoint)
        transport.enqueue(status: 200, body: Data("{\"membershipType\":\"pro\",\"individualUsage\":{\"plan\":{\"used\":10,\"limit\":100}}}".utf8))
        let provider = CursorProvider(transport: transport, auth: auth)
        _ = try await provider.fetch()
        let cookie = try XCTUnwrap(transport.requests.first?.value(forHTTPHeaderField: "Cookie"))
        XCTAssertFalse(cookie.contains("\n"), "cookie must not contain the DB-row trailing newline")
        // The cookie must carry the trimmed token verbatim after the userId.
        XCTAssertTrue(cookie.hasSuffix(Self.cursorJWT))
    }
}
