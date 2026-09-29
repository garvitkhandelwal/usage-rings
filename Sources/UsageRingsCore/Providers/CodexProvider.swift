import Foundation

// MARK: - Credentials + reader

/// The two fields the Codex usage endpoint needs. Held only in memory; never
/// logged, printed, or written to disk. Providers must never surface either
/// value in an error message.
public struct CodexCredentials: Sendable, Hashable {
    public let accessToken: String
    public let accountId: String

    public init(accessToken: String, accountId: String) {
        self.accessToken = accessToken
        self.accountId = accountId
    }
}

/// Read-only accessor for `~/.codex/auth.json`.
///
/// The real implementation opens the file (read-only), parses it as JSON, and
/// returns the `tokens.access_token` / `tokens.account_id` pair — or `nil`
/// when the file exists but has no `tokens` object (the API-key-only auth
/// mode, which has no plan limits and therefore no ring to draw).
///
/// Implementations must never write to the auth file, hold a token beyond
/// one call, or include the token or account id in any error message.
public protocol CodexAuthReader: Sendable {
    /// Return the credentials if `auth.json` exists and carries a valid
    /// `tokens` object; return `nil` when the file is missing or the file
    /// exists but has no usable `tokens` object (either because the user is
    /// in API-key-only mode, or because the fields we need are absent).
    ///
    /// Throw `FetchError.parse(_)` when the file exists but its contents
    /// cannot be parsed as a JSON object at all — that state means "the
    /// installation is broken" rather than "not installed", and the ring
    /// should surface a parse error row rather than silently disappearing.
    /// The thrown message must never echo file contents.
    func loadCredentials() async throws -> CodexCredentials?
}

/// Real `CodexAuthReader` backed by the filesystem.
///
/// Defaults to `~/.codex/auth.json`; honours `CODEX_HOME` if set (matching
/// the Codex CLI's own precedence) so users who relocate the config
/// directory still see their ring.
///
/// The file is read with `Data(contentsOf:)` — the underlying system call is
/// read-only; no lock is acquired and the file is not truncated or
/// rewritten. Tests inject an explicit path pointing at a tmp directory so
/// the real `~/.codex` is never touched.
public struct FileSystemCodexAuthReader: CodexAuthReader {

    /// Absolute path to `auth.json`. Tests inject this directly; the app
    /// resolves it once at construction via `defaultPath()`.
    public let path: URL

    /// Explicit-path initialiser (used by tests and by the default init once
    /// it has resolved `defaultPath()`).
    public init(path: URL) {
        self.path = path
    }

    /// Default initialiser — resolves against `CODEX_HOME` / the current
    /// user's home directory.
    public init() {
        self.path = Self.defaultPath()
    }

    /// Resolve the default path to `auth.json`.
    ///
    /// - If `CODEX_HOME` is set to a non-empty value, use
    ///   `<CODEX_HOME>/auth.json`.
    /// - Otherwise use `<homeDirectory>/.codex/auth.json`.
    ///
    /// Both `environment` and `homeDirectory` are injectable so the
    /// resolution is unit-testable without touching the process environment.
    public static func defaultPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
            return URL(fileURLWithPath: (codexHome as NSString).expandingTildeInPath)
                .appendingPathComponent("auth.json")
        }
        return homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json")
    }

    public func loadCredentials() async throws -> CodexCredentials? {
        let data: Data
        do {
            // `.uncached` avoids Foundation caching the mapped file in
            // process memory across polls — the file is tiny and we do not
            // want a stale copy after the CLI rewrites it.
            data = try Data(contentsOf: path, options: [.uncached])
        } catch let error as NSError {
            // File-not-found is the only read failure that means "not
            // installed" — the machine simply does not have Codex. Any other
            // read failure (permission denied, IO error, …) is surfaced as a
            // fixed-message `.other` so the user sees an error row rather
            // than a silently vanished ring.
            let isMissing =
                (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError) ||
                (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
            if isMissing { return nil }
            throw FetchError.other("Couldn't read Codex auth.json")
        }
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            // File exists but is not valid JSON. Surface as a parse error
            // so the ring shows an error row rather than silently vanishing.
            // Do NOT echo the file contents — the message is fixed.
            throw FetchError.parse("Codex auth.json could not be parsed")
        }
        guard let root = json as? [String: Any] else {
            throw FetchError.parse("Codex auth.json was not a JSON object")
        }
        // Distinguish "key absent" and `"tokens": null` (both hidden — the
        // API-key-only shape has no plan limits) from `"tokens": <something
        // else>` (malformed — the ring shows a parse-error row).
        let tokensRaw = root["tokens"]
        if tokensRaw == nil || tokensRaw is NSNull {
            return nil
        }
        guard let tokens = tokensRaw as? [String: Any] else {
            throw FetchError.parse("Codex auth.json tokens missing required fields")
        }
        guard
            let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty,
            let accountId = tokens["account_id"] as? String, !accountId.isEmpty
        else {
            // `tokens` object is present but the fields we need are missing,
            // renamed, or empty. Do NOT silently hide the ring — a broken
            // Codex install must be visible so the user knows to fix it.
            throw FetchError.parse("Codex auth.json tokens missing required fields")
        }
        return CodexCredentials(accessToken: accessToken, accountId: accountId)
    }
}

// MARK: - Provider

/// Fetches Codex plan usage from `chatgpt.com`.
///
/// Behaviour:
///  - We do NOT read any Codex session logs or caches — only `auth.json`.
///  - We do NOT run a client-side token-expiry check. Always call the
///    endpoint; map HTTP 401/403 to the signed-out state.
///  - If `auth.json` exists but has no `tokens` object (API-key-only mode),
///    the ring is hidden — API-key users have no plan limits.
///
/// Parsing rules:
///  - `plan_type` → `ProviderUsage.plan`.
///  - `rate_limit.primary_window` → window kind `.primary`.
///  - `rate_limit.secondary_window` → window kind `.secondary`.
///  - A key present with `null` → skip (window absent, not an error).
///  - If `rate_limit` is missing, or is present but has neither
///    `primary_window` nor `secondary_window` as a key, → `.parse(...)`.
///    Otherwise a silently-renamed field would give an `.ok` state with no
///    windows and a blank ring.
///  - Label from `limit_window_seconds`: 18000 → "5h", 604800 → "Weekly",
///    2592000 → "Monthly", other multiples of 86400 → "Nd", other multiples
///    of 3600 → "Nh", anything else → "Nh" rounded down.
///
/// Error mapping:
///  - Auth reader returns `nil` (file missing or no `tokens`) →
///    `.signedOut("Open Codex to refresh")` when called via `fetch()`;
///    `isInstalled()` reports `false` so the store hides the ring instead.
///  - Auth reader throws → passed through (a parse error surfaces as a
///    parse-error row).
///  - HTTP 401 / 403 → `.signedOut("Open Codex to refresh")`.
///  - HTTP 429 → `.rateLimited(retryAfter:)`.
///  - HTTP 5xx → `.server(status)`.
///  - `URLError` connectivity codes → `.offline`; `.timedOut` → `.timeout`.
///  - Usage-response body not parseable → `.parse(_)`.
public struct CodexProvider: UsageProvider {
    public let id: ProviderID = .codex

    private let transport: HTTPTransport
    private let auth: CodexAuthReader
    private let now: @Sendable () -> Date

    /// The endpoint URL is a literal — not user-configurable.
    public static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    public init(
        transport: HTTPTransport,
        auth: CodexAuthReader,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.transport = transport
        self.auth = auth
        self.now = now
    }

    public func isInstalled() async -> Bool {
        do {
            return try await auth.loadCredentials() != nil
        } catch {
            // Auth file exists but is malformed. Do NOT hide the ring —
            // `fetch()` will surface the parse error row so the user knows
            // something's wrong.
            return true
        }
    }

    public func fetch() async throws -> ProviderUsage {
        let credentials = try await loadCredentials()

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

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
            signedOutReason: "Open Codex to refresh"
        ) {
            throw mapped
        }

        return try parseUsage(data: data)
    }

    // MARK: - Credential handling

    private func loadCredentials() async throws -> CodexCredentials {
        let credentials: CodexCredentials?
        do {
            credentials = try await auth.loadCredentials()
        } catch let fetchError as FetchError {
            throw fetchError
        } catch {
            // Any other reader failure: sanitised message.
            throw FetchError.other("Couldn't read Codex auth.json")
        }
        guard let credentials else {
            // File missing, or no `tokens` object — either way, the user
            // has no session to talk to the endpoint with. Row says
            // "Open Codex to refresh"; the ring itself is normally hidden
            // via isInstalled() but a race between isInstalled/fetch will
            // land here.
            throw FetchError.signedOut("Open Codex to refresh")
        }
        return credentials
    }

    // MARK: - Usage response parsing

    private func parseUsage(data: Data) throws -> ProviderUsage {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw FetchError.parse("Codex usage response could not be parsed")
        }
        guard let root = json as? [String: Any] else {
            throw FetchError.parse("Codex usage response was not a JSON object")
        }

        let plan = root["plan_type"] as? String

        guard let rateLimit = root["rate_limit"] as? [String: Any] else {
            throw FetchError.parse("Codex usage response missing rate_limit")
        }

        // The primary window is required. Either "key absent" (silent rename)
        // or "key present but null" (all windows unusable) must surface as a
        // parse error — otherwise the ring would sit at .ok with no value.
        // The secondary window is genuinely optional and may be null.
        guard let primaryRaw = rateLimit["primary_window"] else {
            throw FetchError.parse("Codex rate_limit missing primary_window")
        }
        guard let primary = try window(from: primaryRaw, kind: .primary) else {
            throw FetchError.parse("Codex rate_limit primary_window is null")
        }
        var windows: [UsageWindow] = [primary]
        // Secondary: only append when the key is present with a usable object.
        // Absent or null are both fine.
        if let secondaryRaw = rateLimit["secondary_window"],
           let secondary = try window(from: secondaryRaw, kind: .secondary) {
            windows.append(secondary)
        }

        return ProviderUsage(
            id: .codex,
            plan: plan,
            windows: windows,
            fetchedAt: now()
        )
    }

    /// Build a `UsageWindow` from a raw JSON value, or return `nil` for a
    /// null / missing entry.
    ///
    /// Throws `.parse` when the value is an object (not null) but lacks a
    /// numeric `used_percent` — that shape is the API silently renaming a
    /// field, which we must not treat as "0 % used".
    private func window(from raw: Any?, kind: UsageWindowKind) throws -> UsageWindow? {
        if raw == nil { return nil }
        if raw is NSNull { return nil }
        guard let dict = raw as? [String: Any] else {
            throw FetchError.parse("Codex \(kindDescription(kind)) window had unexpected shape")
        }
        let usedPercent = numeric(dict["used_percent"])
        guard let percent = usedPercent, percent.isFinite else {
            throw FetchError.parse("Codex \(kindDescription(kind)) window missing used_percent")
        }
        let resetsAt: Date? = {
            guard let seconds = numeric(dict["reset_at"]), seconds.isFinite, seconds > 0 else {
                return nil
            }
            return Date(timeIntervalSince1970: seconds)
        }()
        let label = labelForWindow(seconds: numeric(dict["limit_window_seconds"]), kind: kind)
        return UsageWindow(label: label, usedPercent: percent, resetsAt: resetsAt, kind: kind)
    }

    /// Extract a numeric value from a JSON leaf, accepting Double / Int /
    /// NSNumber. Returns `nil` for missing, null, boolean, or non-numeric
    /// values.
    ///
    /// Boolean rejection matters because `JSONSerialization` decodes JSON
    /// `true` / `false` as an `NSNumber` wrapping a `CFBooleanRef`; casting
    /// that to `Double` succeeds and yields 1 / 0. A field like
    /// `used_percent: true` must be a parse error, not "1%".
    private func numeric(_ raw: Any?) -> Double? {
        NumericJSON.number(from: raw)
    }

    /// Map `limit_window_seconds` to the display label. The three known
    /// window constants (5h / weekly / monthly) come first; unknown values
    /// fall back to "Nd" for whole-day
    /// durations, "Nh" for whole-hour durations, or "Nm" for sub-hour
    /// durations so a 1800-second window reads "30m", not "1h". A broken
    /// value falls back to a generic per-kind label rather than a blank
    /// secondary line.
    ///
    /// Guards against `Int` overflow: `Int(seconds.rounded())` traps on
    /// values beyond `Int.max` (a provider could return 1e20 through a
    /// silently-renamed field), so we use `Formatting.safeInt(_:)`.
    private func labelForWindow(seconds: Double?, kind: UsageWindowKind) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else {
            return fallbackLabel(for: kind)
        }
        guard let whole = Formatting.safeInt(seconds), whole > 0 else {
            // Huge finite value or rounds to zero: fall back to per-kind
            // label. In particular sub-second values (`seconds == 0.3`
            // rounds to 0) must not slip past the sub-hour branch below
            // (where `max(1, whole / 60)` would render "1m") and, worse,
            // must not fall into the whole-day branch, since `0 % 86_400
            // == 0` would otherwise render "0d".
            return fallbackLabel(for: kind)
        }
        switch whole {
        case 18_000: return "5h"
        case 604_800: return "Weekly"
        case 2_592_000: return "Monthly"
        default:
            // Sub-hour first: 3570-3599 s must render as "59m", not "60m"
            // (60 minutes IS one hour — call it that if the value crosses
            // the boundary). Floor to whole minutes so values slightly
            // below one hour never round up into a bogus "60m" label.
            if whole < 3_600 {
                let minutes = max(1, whole / 60)
                return "\(minutes)m"
            }
            if whole % 86_400 == 0 {
                return "\(whole / 86_400)d"
            }
            if whole % 3_600 == 0 {
                return "\(whole / 3_600)h"
            }
            // Between hours and days but not a whole hour — round down to
            // hours so the label is always short.
            let hours = max(1, whole / 3_600)
            return "\(hours)h"
        }
    }

    private func fallbackLabel(for kind: UsageWindowKind) -> String {
        switch kind {
        case .primary: return "Primary"
        case .secondary: return "Secondary"
        default: return "Window"
        }
    }

    private func kindDescription(_ kind: UsageWindowKind) -> String {
        switch kind {
        case .primary: return "primary"
        case .secondary: return "secondary"
        default: return "\(kind)"
        }
    }
}
