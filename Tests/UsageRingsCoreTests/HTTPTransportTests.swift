import XCTest
@testable import UsageRingsCore

/// Status- and URLError-mapping tests for the HTTP transport helpers.
///
/// The live `URLSessionTransport` is not exercised (that would need
/// network); we test the pure `HTTPErrorMapper` helpers that every provider
/// uses to classify outcomes.
final class HTTPErrorMapperStatusTests: XCTestCase {

    private func response(status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    func testTwoHundredIsNil() {
        XCTAssertNil(HTTPErrorMapper.mapStatus(200))
        XCTAssertNil(HTTPErrorMapper.mapStatus(204))
        XCTAssertNil(HTTPErrorMapper.mapStatus(299))
    }

    func testUnauthorisedMapsToSignedOutWithReason() {
        XCTAssertEqual(
            HTTPErrorMapper.mapStatus(401, signedOutReason: "Open Claude Code to refresh"),
            .signedOut("Open Claude Code to refresh")
        )
    }

    func testForbiddenMapsToSignedOut() {
        XCTAssertEqual(
            HTTPErrorMapper.mapStatus(403, signedOutReason: "Open Cursor to refresh"),
            .signedOut("Open Cursor to refresh")
        )
    }

    func testTooManyRequestsWithoutRetryAfter() {
        let mapped = HTTPErrorMapper.mapStatus(429, response: response(status: 429))
        XCTAssertEqual(mapped, .rateLimited(retryAfter: nil))
    }

    func testTooManyRequestsWithNumericRetryAfter() {
        let r = response(status: 429, headers: ["Retry-After": "120"])
        let mapped = HTTPErrorMapper.mapStatus(429, response: r)
        XCTAssertEqual(mapped, .rateLimited(retryAfter: 120))
    }

    func testTooManyRequestsWithHTTPDateRetryAfter() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let later = now.addingTimeInterval(90)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let httpDate = f.string(from: later)
        let r = response(status: 429, headers: ["Retry-After": httpDate])
        let mapped = HTTPErrorMapper.mapStatus(429, response: r, now: now)
        guard case .rateLimited(let seconds) = mapped else {
            return XCTFail("expected rateLimited, got \(String(describing: mapped))")
        }
        // The formatter has second precision, allow +/- 1 s.
        XCTAssertEqual(seconds ?? -1, 90, accuracy: 1.5)
    }

    func testRetryAfterHeaderIsCaseInsensitive() {
        // Custom transports or hand-crafted responses may store the header
        // with a different casing than URLSession would.
        let r = HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 429,
            httpVersion: "HTTP/1.1",
            headerFields: ["retry-after": "45"]
        )!
        XCTAssertEqual(
            HTTPErrorMapper.mapStatus(429, response: r),
            .rateLimited(retryAfter: 45)
        )
    }

    func testFiveHundredMapsToServer() {
        XCTAssertEqual(HTTPErrorMapper.mapStatus(500), .server(500))
        XCTAssertEqual(HTTPErrorMapper.mapStatus(503), .server(503))
        XCTAssertEqual(HTTPErrorMapper.mapStatus(599), .server(599))
    }

    func testUnknownStatusMapsToOther() {
        XCTAssertEqual(HTTPErrorMapper.mapStatus(302), .other("HTTP 302"))
        XCTAssertEqual(HTTPErrorMapper.mapStatus(418), .other("HTTP 418"))
    }

    func testRetryAfterIsCappedAtOneHour() {
        // Vendor endpoints have been observed sending day-scale (or
        // "infinity") Retry-After values that would ice a provider for
        // longer than any user expects. Cap at 3600 s.
        let big = response(status: 429, headers: ["Retry-After": "86400"])
        XCTAssertEqual(
            HTTPErrorMapper.mapStatus(429, response: big),
            .rateLimited(retryAfter: 3600)
        )

        let inf = response(status: 429, headers: ["Retry-After": "inf"])
        XCTAssertEqual(
            HTTPErrorMapper.mapStatus(429, response: inf),
            .rateLimited(retryAfter: nil),
            "'inf' is not a finite duration and must not become the cap"
        )

        // HTTP-date scenarios cap too.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let farFuture = now.addingTimeInterval(3 * 3600) // 3 h ahead
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let httpDate = f.string(from: farFuture)
        let r = response(status: 429, headers: ["Retry-After": httpDate])
        guard case .rateLimited(let capped) = HTTPErrorMapper.mapStatus(429, response: r, now: now) else {
            return XCTFail("expected rateLimited")
        }
        XCTAssertEqual(capped ?? -1, 3600, accuracy: 0.5,
                       "3 h HTTP-date must be clamped to the 1 h cap")
    }

    func testRetryAfterNegativeIsClampedToZero() {
        let r = response(status: 429, headers: ["Retry-After": "-30"])
        XCTAssertEqual(
            HTTPErrorMapper.mapStatus(429, response: r),
            .rateLimited(retryAfter: 0)
        )
    }
}

final class HTTPErrorMapperURLErrorTests: XCTestCase {

    func testNotConnectedIsOffline() {
        XCTAssertEqual(HTTPErrorMapper.mapURLError(URLError(.notConnectedToInternet)), .offline)
    }

    func testConnectionLostIsOffline() {
        XCTAssertEqual(HTTPErrorMapper.mapURLError(URLError(.networkConnectionLost)), .offline)
    }

    func testCannotFindHostIsOffline() {
        XCTAssertEqual(HTTPErrorMapper.mapURLError(URLError(.cannotFindHost)), .offline)
    }

    func testCannotConnectToHostIsOffline() {
        XCTAssertEqual(HTTPErrorMapper.mapURLError(URLError(.cannotConnectToHost)), .offline)
    }

    func testDNSLookupFailedIsOffline() {
        XCTAssertEqual(HTTPErrorMapper.mapURLError(URLError(.dnsLookupFailed)), .offline)
    }

    func testTimedOutMapsToTimeoutNotOffline() {
        // A slow but reachable endpoint must not push the popover to "No
        // internet connection" and drop the last value. Timeouts take the
        // stale path (`.timeout` -> keep last value, error if none).
        XCTAssertEqual(HTTPErrorMapper.mapURLError(URLError(.timedOut)), .timeout)
    }

    func testOtherURLErrorMapsToShortNetworkError() {
        // BadURL is a programmer error, not connectivity. The row must
        // read a short human sentence — NOT "URLError -1000" — so the
        // numeric code never surfaces to a shoulder-surfer.
        XCTAssertEqual(
            HTTPErrorMapper.mapURLError(URLError(.badURL)),
            .other("Network error")
        )
    }

    func testUnknownTLSErrorAlsoMapsToNetworkError() {
        // Guard against ever leaking a `.secureConnectionFailed` or
        // `.serverCertificateUntrusted` code into the row text.
        XCTAssertEqual(
            HTTPErrorMapper.mapURLError(URLError(.secureConnectionFailed)),
            .other("Network error")
        )
        XCTAssertEqual(
            HTTPErrorMapper.mapURLError(URLError(.serverCertificateUntrusted)),
            .other("Network error")
        )
    }
}

final class HTTPRedirectHostAllowedTests: XCTestCase {

    private func url(_ raw: String) -> URL { URL(string: raw)! }

    func testAllowsHTTPSAnthropic() {
        XCTAssertTrue(HTTPErrorMapper.isRedirectAllowed(target: url("https://api.anthropic.com/x")))
    }

    func testAllowsHTTPSChatGPT() {
        XCTAssertTrue(HTTPErrorMapper.isRedirectAllowed(target: url("https://chatgpt.com/x")))
    }

    func testAllowsHTTPSCursor() {
        XCTAssertTrue(HTTPErrorMapper.isRedirectAllowed(target: url("https://cursor.com/x")))
    }

    func testRejectsHTTP() {
        // A downgrade to HTTP is a fingerprintable request even for an
        // allowed host — refuse it. Tokens travel in every request; a
        // plaintext redirect would leak them.
        XCTAssertFalse(HTTPErrorMapper.isRedirectAllowed(target: url("http://api.anthropic.com/x")))
    }

    func testRejectsUnknownHost() {
        // A vendor endpoint sending us to a data-exfil host is exactly the
        // case this guard exists for. Refuse.
        XCTAssertFalse(HTTPErrorMapper.isRedirectAllowed(target: url("https://evil.example.com/x")))
    }

    func testRejectsSubdomainOfAllowedHost() {
        // Host allow-list is exact; a compromised `beta.chatgpt.com` must
        // not automatically inherit trust. Every allowed endpoint uses the
        // apex host with no wildcard.
        XCTAssertFalse(HTTPErrorMapper.isRedirectAllowed(target: url("https://beta.chatgpt.com/x")))
    }

    func testRejectsMissingHost() {
        // Some URLs (file:, mailto:, relative to a non-URL base) have no host.
        XCTAssertFalse(HTTPErrorMapper.isRedirectAllowed(target: url("file:///tmp/x")))
    }
}
