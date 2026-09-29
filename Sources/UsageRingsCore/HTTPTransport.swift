import Foundation

/// A minimal HTTP transport surface used by every provider. Kept narrow so
/// tests can supply a fake without touching URLSession.
public protocol HTTPTransport: Sendable {
    /// Issue the supplied request and return the raw body plus the HTTP
    /// response. Implementations translate connectivity failures to
    /// `URLError`; status-code classification happens in the caller via
    /// `HTTPErrorMapper`.
    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Real transport used by the app. Uses an ephemeral `URLSession` with no
/// cookie or cache storage — providers pass their token as an `Authorization`
/// header or, for Cursor, a `Cookie` header they build themselves; nothing
/// URLSession stores across requests is desirable here.
///
/// Redirect handling: the session delegate refuses any redirect whose target
/// is not one of the three vendor hosts over HTTPS
/// (`api.anthropic.com`, `chatgpt.com`, `cursor.com`). Since providers set the
/// `Authorization` and `Cookie` headers on every request, an unrestricted
/// redirect could ship a token to any host of a hijacked vendor endpoint's
/// choosing. The pure host-allow decision lives on
/// `HTTPErrorMapper.isRedirectAllowed(target:)` so it is unit-tested.
public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession
    private let delegate: RedirectGuardDelegate

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        // Ephemeral already skips shared caches, but be explicit; no one
        // else on the box should be able to influence these requests.
        config.httpShouldSetCookies = false
        let delegate = RedirectGuardDelegate()
        self.delegate = delegate
        // A URLSession retains its delegate strongly; keep our own reference
        // so ARC does not drop it (the class is @unchecked Sendable and we
        // never mutate it after construction).
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    public func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FetchError.other("Non-HTTP response")
        }
        return (data, http)
    }
}

/// URLSession delegate that clamps redirect following to the three vendor
/// hosts we ever call, over HTTPS. Any other target is refused (the completion
/// handler is called with `nil`, which cancels the redirect and lets the
/// caller see the 3xx response as a terminal error).
///
/// Decision math lives on `HTTPErrorMapper.isRedirectAllowed(target:)` so
/// this class is a thin adapter and the policy is unit-tested.
final class RedirectGuardDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let target = request.url,
              HTTPErrorMapper.isRedirectAllowed(target: target) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

/// Pure helpers that classify HTTP status codes and `URLError` values into
/// `FetchError` cases. Kept as a namespace so providers can call these
/// without owning the mapping themselves.
public enum HTTPErrorMapper {

    /// Map an HTTP status code (and its response headers, for 429) to a
    /// `FetchError`, or `nil` if the status is a success (2xx).
    ///
    /// - 2xx → `nil`
    /// - 401 / 403 → `.signedOut(reason)` (reason supplied by the caller, so
    ///   each provider can say "Open Claude Code to refresh" etc.)
    /// - 429 → `.rateLimited(retryAfter:)` with `Retry-After` parsed if present
    /// - 5xx → `.server(status)`
    /// - anything else → `.other("HTTP <n>")`
    public static func mapStatus(
        _ status: Int,
        response: HTTPURLResponse? = nil,
        signedOutReason: String = "Sign in required",
        now: Date = Date()
    ) -> FetchError? {
        switch status {
        case 200...299:
            return nil
        case 401, 403:
            return .signedOut(signedOutReason)
        case 429:
            return .rateLimited(retryAfter: parseRetryAfter(response: response, now: now))
        case 500...599:
            return .server(status)
        default:
            return .other("HTTP \(status)")
        }
    }

    /// Map a `URLError` to a `FetchError`:
    ///  - connectivity failures (`notConnectedToInternet`,
    ///    `networkConnectionLost`, `cannotFindHost`, `cannotConnectToHost`,
    ///    `dnsLookupFailed`, `internationalRoamingOff`, `dataNotAllowed`)
    ///    → `.offline` (last value dropped, "No internet connection" row).
    ///  - `.timedOut` → `.timeout` (a slow but reachable endpoint should
    ///    keep the last usage value visible; falling back to `.offline`
    ///    would hide the previous ring behind a "No internet" state that
    ///    is not actually true).
    ///  - anything else → `.other("Network error")`. We deliberately do NOT
    ///    surface the numeric `URLError` code — a row reading "URLError -1200"
    ///    is user-hostile and, for some codes (e.g. `.badServerCertificate`
    ///    on a corporate MITM), could hint at the endpoint host to a
    ///    shoulder-surfer. A short, generic sentence suffices.
    public static func mapURLError(_ error: URLError) -> FetchError {
        switch error.code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .internationalRoamingOff,
             .dataNotAllowed:
            return .offline
        case .timedOut:
            return .timeout
        default:
            return .other("Network error")
        }
    }

    /// Upper bound on any Retry-After we honour. Vendor endpoints have been
    /// observed returning "infinity" or day-scale values that would keep a
    /// provider iced for far longer than the user expects. Above this cap
    /// the popover would show a stale value for hours while the app polls
    /// nothing — capping at one hour bounds the worst case; a manual
    /// refresh still respects the (capped) skip.
    public static let maximumRetryAfter: TimeInterval = 3600

    /// Parse the `Retry-After` header per RFC 7231 §7.1.3: either a decimal
    /// number of seconds, or an HTTP-date. Returns `nil` if the header is
    /// absent or unparseable. Any parsed value is clamped to
    /// `[0, maximumRetryAfter]`.
    ///
    /// `now` is threaded through only so tests can be deterministic when
    /// exercising the HTTP-date branch.
    public static func parseRetryAfter(response: HTTPURLResponse?, now: Date = Date()) -> TimeInterval? {
        guard let response else { return nil }
        // Header lookup on HTTPURLResponse is case-insensitive as of macOS
        // 10.15, but we walk the dictionary ourselves so the code is robust
        // to any surprises (custom transports, tests).
        let value: String? = {
            if let direct = response.value(forHTTPHeaderField: "Retry-After") {
                return direct
            }
            for (k, v) in response.allHeaderFields {
                if let key = k as? String, key.caseInsensitiveCompare("Retry-After") == .orderedSame {
                    return v as? String
                }
            }
            return nil
        }()
        guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return nil
        }
        if let seconds = TimeInterval(raw), seconds.isFinite {
            return clampRetryAfter(seconds)
        }
        if let date = httpDate(from: raw) {
            return clampRetryAfter(date.timeIntervalSince(now))
        }
        return nil
    }

    private static func clampRetryAfter(_ seconds: TimeInterval) -> TimeInterval {
        min(max(0, seconds), maximumRetryAfter)
    }

    private static let httpDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    private static func httpDate(from raw: String) -> Date? {
        httpDateFormatter.date(from: raw)
    }

    /// The three vendor hosts we ever call. The redirect allow-list matches
    /// them exactly (no subdomains) — a compromised `beta.chatgpt.com` must
    /// not automatically inherit trust. Every documented endpoint uses the
    /// apex host with no wildcard.
    public static let allowedRedirectHosts: Set<String> = [
        "api.anthropic.com",
        "chatgpt.com",
        "cursor.com",
    ]

    /// Should a redirect to `target` be followed?
    ///
    /// Kept as a pure function so the policy is directly unit-tested. The
    /// live `RedirectGuardDelegate` on `URLSessionTransport` calls this and
    /// refuses (returns `nil` from the completion handler) whenever it
    /// returns `false`.
    ///
    /// Rules:
    ///  - Scheme must be HTTPS. A downgrade to HTTP is refused even for an
    ///    allowed host — tokens travel in every request and a plaintext
    ///    redirect would leak them to any on-path observer.
    ///  - Host must be one of `allowedRedirectHosts` (exact match, case
    ///    insensitive).
    ///  - Missing host / non-URL schemes (`file:`, `mailto:`, …) are refused.
    public static func isRedirectAllowed(target: URL) -> Bool {
        guard let scheme = target.scheme?.lowercased(), scheme == "https" else {
            return false
        }
        guard let host = target.host?.lowercased(), !host.isEmpty else {
            return false
        }
        return allowedRedirectHosts.contains(host)
    }
}
