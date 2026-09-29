import Foundation
import SQLite3

// MARK: - Credential reader

/// Read-only accessor for Cursor's `state.vscdb` SQLite database.
///
/// The real implementation opens the file with `SQLITE_OPEN_READONLY` (URI
/// form `file:<path>?mode=ro` so we also hit SQLite's own read-only enforcement
/// layer — the DB is never rewritten, WAL-checkpointed, or locked by us) and
/// runs a single `SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'`
/// before promptly closing the handle.
///
/// The returned string is the raw JWT the Cursor editor stores. Providers must
/// never log it, write it to disk, or include it in any error message —
/// anything derived from it (the `sub` claim, the userId, the cookie header
/// value) is likewise sensitive.
public protocol CursorAuthReader: Sendable {
    /// Return the access-token JWT string when the DB exists and carries a
    /// row for `cursorAuth/accessToken`; return `nil` when either the DB
    /// file is missing (Cursor is not installed on this Mac) or the DB
    /// exists but does not have the row (the user has logged out of
    /// Cursor). Both states are hidden — a provider without a token
    /// source is auto-hidden, matching Codex's "auth.json missing or has
    /// no tokens object" handling.
    ///
    /// Throw `FetchError.other(_)` when the DB file exists but SQLite
    /// cannot open it (permissions, corruption, unreadable schema). The
    /// message must be fixed — never echo the underlying SQLite error
    /// text, the query, or the file path.
    func loadAccessToken() async throws -> String?
}

/// Real `CursorAuthReader` backed by the SQLite C API against
/// `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`.
///
/// Notes:
///  - The path is injectable so tests can point at a tmp-directory DB.
///  - We open with `SQLITE_OPEN_READONLY | SQLITE_OPEN_URI` and a
///    `file:<path>?mode=ro` URI. The read-only flag is what SQLite
///    actually honours; the `mode=ro` URI parameter is defence-in-depth
///    against a future refactor that drops the flag. Either alone is
///    sufficient to guarantee the DB is not written.
///  - After a successful open we call `sqlite3_busy_timeout(db, 500)` so
///    a transient lock (Cursor writing at the same instant we read) does
///    not immediately return `SQLITE_BUSY` and surface as an error row.
///  - The connection is closed with `sqlite3_close_v2` immediately after
///    the single query; there is no long-lived handle.
///  - Statements are prepared with `sqlite3_prepare_v2`, and the `key`
///    value is bound as text via a parameter (`sqlite3_bind_text`) —
///    no user-supplied SQL is ever composed by concatenation, so the
///    SELECT is not injectable even in principle.
///  - The DB missing on disk is not an error; SQLite would return
///    `SQLITE_CANTOPEN` in that case, so we distinguish it explicitly via
///    `FileManager.fileExists(atPath:)` before opening.
public struct FileSystemCursorAuthReader: CursorAuthReader {

    /// Absolute path to `state.vscdb`. Tests inject this directly; the app
    /// resolves it once at construction via `defaultPath()`.
    public let path: URL

    /// SQLite key we read. The Cursor editor writes the JWT under this key
    /// in the `ItemTable` global storage table.
    public static let itemKey = "cursorAuth/accessToken"

    /// SQLite open flags used by `loadAccessToken`. Exposed at
    /// module-internal scope so tests can assert directly that the reader
    /// opens the DB read-only (not just "does not currently write") —
    /// SQLite's `SQLITE_OPEN_READWRITE` falls back to read-only on a file
    /// with no write bit, so a filesystem-permission check alone cannot
    /// distinguish the two.
    static let openFlags: Int32 = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI

    /// Build the SQLite URI the reader passes to `sqlite3_open_v2`. Same
    /// exposure rationale as `openFlags`: tests need to inspect the
    /// `mode=ro` query parameter directly.
    static func openURI(for path: URL) -> String {
        "file:\(uriEncoded(path.path))?mode=ro"
    }

    /// Explicit-path initialiser (used by tests and by the default init once
    /// it has resolved `defaultPath()`).
    public init(path: URL) {
        self.path = path
    }

    /// Default initialiser — resolves against the current user's home
    /// directory.
    public init() {
        self.path = Self.defaultPath()
    }

    /// Resolve the default path to `state.vscdb`.
    ///
    /// Injectable `homeDirectory` so the resolution is unit-testable without
    /// touching the process environment.
    public static func defaultPath(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Cursor", isDirectory: true)
            .appendingPathComponent("User", isDirectory: true)
            .appendingPathComponent("globalStorage", isDirectory: true)
            .appendingPathComponent("state.vscdb")
    }

    public func loadAccessToken() async throws -> String? {
        // Presence check first. If the DB is not on disk, hide the ring —
        // we do not attempt to open a non-existent file just to distinguish
        // "not installed" from "installed but no key row".
        guard FileManager.default.fileExists(atPath: path.path) else {
            return nil
        }

        // Open read-only, URI form. `SQLITE_OPEN_URI` is required for the
        // `file:...` scheme to be honoured; `SQLITE_OPEN_READONLY` is the
        // definitive read-only flag. Both the flag set and the URI are
        // exposed as internal statics (`Self.openFlags`, `Self.openURI(for:)`)
        // so tests can assert on them independently of any observable
        // filesystem behaviour.
        var db: OpaquePointer?
        let uri = Self.openURI(for: path)
        let openResult = sqlite3_open_v2(
            uri,
            &db,
            Self.openFlags,
            nil
        )
        defer {
            if db != nil {
                sqlite3_close_v2(db)
            }
        }
        guard openResult == SQLITE_OK, let db else {
            // Do NOT surface the SQLite error text — it can contain the
            // absolute file path (which is not sensitive but is not useful
            // in a popover row either) and, in some builds, the URI query
            // string. Fixed message.
            throw FetchError.other("Couldn't read Cursor session database")
        }
        // Cursor itself may be writing the DB the instant we look. 500 ms
        // of busy-retry (SQLite's own back-off) is comfortably shorter than
        // the 5-minute refresh interval and turns a transient `SQLITE_BUSY`
        // into a successful read instead of an error row.
        sqlite3_busy_timeout(db, 500)

        var statement: OpaquePointer?
        let sql = "SELECT value FROM ItemTable WHERE key = ?"
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        defer {
            if statement != nil {
                sqlite3_finalize(statement)
            }
        }
        guard prepareResult == SQLITE_OK, let statement else {
            // A prepared-statement failure means the schema has changed
            // (no ItemTable, no `value` column, etc.). Surface as a fixed
            // read error.
            throw FetchError.other("Couldn't read Cursor session database")
        }

        // Bind the key as text via a parameter — never composed into SQL.
        // `SQLITE_TRANSIENT` copies the buffer so the binding survives our
        // Swift string going out of scope.
        let key = Self.itemKey
        let bindResult = key.withCString { cString in
            sqlite3_bind_text(statement, 1, cString, -1, Self.SQLITE_TRANSIENT)
        }
        guard bindResult == SQLITE_OK else {
            throw FetchError.other("Couldn't read Cursor session database")
        }

        let stepResult = sqlite3_step(statement)
        switch stepResult {
        case SQLITE_ROW:
            // Column 0 is the JWT text.
            guard let cString = sqlite3_column_text(statement, 0) else {
                return nil
            }
            let text = String(cString: cString)
            return text.isEmpty ? nil : text
        case SQLITE_DONE:
            // No row for our key — the user logged out of Cursor. Hidden.
            return nil
        default:
            throw FetchError.other("Couldn't read Cursor session database")
        }
    }

    /// SQLite's `SQLITE_TRANSIENT` sentinel value, cast to the `sqlite3_destructor_type`
    /// expected by `sqlite3_bind_text`. The C constant is defined via a cast to
    /// `((sqlite3_destructor_type)-1)`, which Swift cannot import directly.
    private static let SQLITE_TRANSIENT = unsafeBitCast(
        OpaquePointer(bitPattern: -1),
        to: sqlite3_destructor_type.self
    )

    /// Minimal URI-encoding for the file-path portion of a `file:...` URI:
    /// leading `/` remains a `/`; the ASCII set `[A-Za-z0-9._~/-]` passes
    /// through; everything else is percent-encoded per RFC 3986. This is
    /// deliberately narrower than `URLComponents.percentEncoded*` so we do
    /// not depend on Foundation's URL-parsing quirks for a value that is
    /// fed straight into SQLite's URI parser.
    static func uriEncoded(_ path: String) -> String {
        var out = ""
        out.reserveCapacity(path.utf8.count)
        for byte in path.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, // A-Z a-z 0-9
                 0x2D, 0x2E, 0x5F, 0x7E,                // - . _ ~
                 0x2F:                                    // /
                out.append(Character(UnicodeScalar(byte)))
            default:
                out.append(String(format: "%%%02X", byte))
            }
        }
        return out
    }
}

// MARK: - JWT helpers

/// Small pure functions for parsing the Cursor JWT `sub` claim.
///
/// Kept as an internal namespace so the provider is testable at the level
/// of "given this token, does the userId come out right?" without hitting
/// SQLite or the network.
///
/// The Cursor JWT is used solely to build the cookie header the usage
/// endpoint expects. The signature is NOT verified — verification would
/// require Cursor's rotating public key and is outside our threat model:
/// the token was read directly out of Cursor's own read-only DB and is
/// consumed only by an HTTPS call to cursor.com. Everything else about the
/// payload is treated as opaque.
enum CursorJWT {

    /// Extract the userId from a JWT string.
    ///
    /// - Decodes the payload segment (base64url, no padding required).
    /// - Reads the `sub` claim as a string.
    /// - Returns the segment after the last `|` (or the whole `sub` when
    ///   `|` is absent).
    /// - Rejects any userId containing a character outside `[A-Za-z0-9._-]`.
    ///
    /// The token should already be trimmed by the caller — `CursorProvider`
    /// trims once in `loadToken()` so the exact same bytes flow into both
    /// this parser and the cookie header. Returns `nil` for any failure
    /// mode (malformed JWT, missing `sub`, invalid charset). Providers
    /// surface the failure as a signed-out row with the caller-supplied
    /// reason.
    static func userId(fromAccessToken token: String) -> String? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return nil }
        let payloadSegment = String(segments[1])
        guard let payloadData = base64UrlDecode(payloadSegment) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return nil
        }
        guard let sub = json["sub"] as? String, !sub.isEmpty else { return nil }
        let candidate: String
        if let pipeIndex = sub.lastIndex(of: "|") {
            candidate = String(sub[sub.index(after: pipeIndex)...])
        } else {
            candidate = sub
        }
        guard !candidate.isEmpty else { return nil }
        // Strict charset: only characters that are safe in an HTTP cookie
        // value and match the WorkOS user-id format we have observed.
        for scalar in candidate.unicodeScalars {
            switch scalar.value {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39: continue // A-Z a-z 0-9
            case 0x2E, 0x2D, 0x5F: continue                       // . - _
            default:
                return nil
            }
        }
        return candidate
    }

    /// Decode a base64url segment (no padding needed). Returns `nil` for
    /// any input the standard base64 decoder rejects.
    static func base64UrlDecode(_ segment: String) -> Data? {
        var normalised = segment.replacingOccurrences(of: "-", with: "+")
                                 .replacingOccurrences(of: "_", with: "/")
        // Pad to a multiple of 4.
        let remainder = normalised.count % 4
        if remainder > 0 {
            normalised.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: normalised)
    }
}

// MARK: - Provider

/// Fetches Cursor plan usage from `cursor.com`.
///
/// Behaviour:
///  - Cursor `used` / `limit` values are US cents (plan limit `2000` = the
///    Pro plan's included \$20).
///  - The on-demand secondary line is shown whenever
///    `individualUsage.onDemand.enabled` is true, including when `limit` is
///    null.
///  - `auto` never selects the `.onDemand` window as the ring (already
///    enforced in `selectWindows`).
///  - No client-side JWT `exp` check. Always call the endpoint; map HTTP
///    401/403 to signed-out.
///  - The Cursor DB is opened SQLite-read-only and is never written.
///
/// Parsing rules:
///  - `individualUsage.plan.used` / `.limit` → `.billingCycle` window; label
///    "Monthly"; percent = `used / limit * 100` when `limit > 0`, otherwise
///    fall back to `individualUsage.plan.totalPercentUsed`.
///  - `billingCycleEnd` → the plan window's `resetsAt`.
///  - `membershipType` → `ProviderUsage.plan`.
///  - `individualUsage.onDemand.enabled == true` → append an `.onDemand`
///    window with `amountCents = onDemand.used`, `limitCents = onDemand.limit`.
///    `usedPercent` on the on-demand window is left at 0 — it is never the
///    ring and never displays a percentage.
///  - If `individualUsage` is missing entirely, or `individualUsage.plan` is
///    missing, → `.parse(...)`. A silent rename of either field must not
///    render as a blank OK ring.
///
/// Error mapping:
///  - Auth reader returns `nil` (DB missing, or DB present with no row) →
///    `.signedOut("Open Cursor to refresh")` when called via `fetch()`;
///    `isInstalled()` reports `false` so the store hides the ring instead.
///  - Auth reader throws → passed through (a `.other` "Couldn't read Cursor
///    session database" surfaces as an error row).
///  - JWT could not be parsed / `sub` missing / invalid charset →
///    `.signedOut("Open Cursor to refresh")`.
///  - HTTP 401 / 403 → `.signedOut("Open Cursor to refresh")`.
///  - HTTP 429 → `.rateLimited(retryAfter:)`.
///  - HTTP 5xx → `.server(status)`.
///  - `URLError` connectivity codes → `.offline`; `.timedOut` → `.timeout`.
///  - Usage-response body not parseable → `.parse(_)`.
public struct CursorProvider: UsageProvider {
    public let id: ProviderID = .cursor

    private let transport: HTTPTransport
    private let auth: CursorAuthReader
    private let now: @Sendable () -> Date

    /// The endpoint URL is a literal — not user-configurable.
    public static let endpoint = URL(string: "https://cursor.com/api/usage-summary")!

    /// Row text for the signed-out state.
    public static let signedOutReason = "Open Cursor to refresh"

    public init(
        transport: HTTPTransport,
        auth: CursorAuthReader,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.transport = transport
        self.auth = auth
        self.now = now
    }

    public func isInstalled() async -> Bool {
        do {
            return try await auth.loadAccessToken() != nil
        } catch {
            // DB exists but is unreadable. Do NOT hide the ring —
            // `fetch()` will surface the fixed "Couldn't read..." row so the
            // user knows something's wrong.
            return true
        }
    }

    public func fetch() async throws -> ProviderUsage {
        let token = try await loadToken()
        guard let userId = CursorJWT.userId(fromAccessToken: token) else {
            // Malformed JWT / missing `sub` / charset violation. The user
            // needs to reopen Cursor so its login flow rewrites the DB.
            throw FetchError.signedOut(Self.signedOutReason)
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue(cookieHeader(userId: userId, token: token), forHTTPHeaderField: "Cookie")
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
            signedOutReason: Self.signedOutReason
        ) {
            throw mapped
        }

        return try parseUsage(data: data)
    }

    // MARK: - Credential handling

    private func loadToken() async throws -> String {
        let token: String?
        do {
            token = try await auth.loadAccessToken()
        } catch let fetchError as FetchError {
            throw fetchError
        } catch {
            throw FetchError.other("Couldn't read Cursor session database")
        }
        guard let raw = token, !raw.isEmpty else {
            // DB missing (already hidden by isInstalled) or key row absent —
            // a race between isInstalled and fetch will land here.
            throw FetchError.signedOut(Self.signedOutReason)
        }
        // Trim once, at the boundary between the reader and the rest of the
        // provider, so `CursorJWT.userId(...)` and `cookieHeader(...)` see
        // the exact same string. A stray newline at the end of the DB row
        // would otherwise decode as a valid JWT (parser trims) but then be
        // sent verbatim in the cookie (mismatch, 401 from Cursor).
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FetchError.signedOut(Self.signedOutReason)
        }
        return trimmed
    }

    /// Build the `Cookie: WorkosCursorSessionToken=<userId>%3A%3A<token>`
    /// header value. `%3A%3A` is the URL-encoded form of `::`, which the
    /// Cursor backend expects between the two fields.
    ///
    /// Neither `userId` nor `token` is URL-encoded further: the userId
    /// charset is validated to `[A-Za-z0-9._-]`, and the token is base64url
    /// dot-separated — both are already valid HTTP cookie values.
    func cookieHeader(userId: String, token: String) -> String {
        "WorkosCursorSessionToken=\(userId)%3A%3A\(token)"
    }

    // MARK: - Usage response parsing

    private func parseUsage(data: Data) throws -> ProviderUsage {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw FetchError.parse("Cursor usage response could not be parsed")
        }
        guard let root = json as? [String: Any] else {
            throw FetchError.parse("Cursor usage response was not a JSON object")
        }

        let plan = root["membershipType"] as? String

        guard let individual = root["individualUsage"] as? [String: Any] else {
            throw FetchError.parse("Cursor usage response missing individualUsage")
        }
        guard let planWindow = try billingCycleWindow(
            individual: individual,
            root: root
        ) else {
            throw FetchError.parse("Cursor usage response missing individualUsage.plan")
        }

        var windows: [UsageWindow] = [planWindow]
        if let onDemand = try onDemandWindow(individual: individual) {
            windows.append(onDemand)
        }

        return ProviderUsage(
            id: .cursor,
            plan: plan,
            windows: windows,
            fetchedAt: now()
        )
    }

    /// Build the billing-cycle (plan) window.
    ///
    /// Returns `nil` when `individualUsage.plan` is present but is `null` or
    /// not an object — the caller turns that into a parse error. When the
    /// key is absent, the caller catches the parse error too.
    private func billingCycleWindow(
        individual: [String: Any],
        root: [String: Any]
    ) throws -> UsageWindow? {
        guard let planRaw = individual["plan"] else {
            // Key absent → the shape has changed.
            throw FetchError.parse("Cursor usage response missing individualUsage.plan")
        }
        if planRaw is NSNull { return nil }
        guard let plan = planRaw as? [String: Any] else {
            throw FetchError.parse("Cursor usage response individualUsage.plan had unexpected shape")
        }

        let used = NumericJSON.number(from: plan["used"])
        let limit = NumericJSON.number(from: plan["limit"])
        let percent: Double
        if let used, let limit, limit > 0 {
            percent = used / limit * 100.0
        } else if let fallback = NumericJSON.number(from: plan["totalPercentUsed"]) {
            percent = fallback
        } else {
            throw FetchError.parse("Cursor usage response individualUsage.plan missing used/limit and totalPercentUsed")
        }

        let resetsAt = parseCycleEnd(root["billingCycleEnd"] as? String)

        return UsageWindow(
            label: "Monthly",
            usedPercent: percent,
            resetsAt: resetsAt,
            kind: .billingCycle
        )
    }

    /// Build the on-demand window when `individualUsage.onDemand.enabled` is
    /// true. Returns `nil` when on-demand is absent, disabled, or its shape
    /// is not an object — none of those are errors.
    ///
    /// Throws `.parse(_)` when `enabled` is true but `used` is missing, null,
    /// or a non-numeric value. Choice: **prefer a parse error over silently
    /// dropping the on-demand line**. Silently dropping would give the user
    /// no signal that Cursor's shape has changed (the plan ring would still
    /// render fine) — a parse error row makes the regression visible.
    ///
    /// The on-demand window carries `amountCents` and `limitCents` for the
    /// specialised secondary line; its `usedPercent` is left at 0 because
    /// on-demand is never the ring window and never renders a percentage.
    ///
    /// Guards against `Int` overflow: `Int(value.rounded())` traps on
    /// values beyond `Int.max`. We use `Formatting.safeInt(_:)` for both
    /// `used` and `limit` and surface unrepresentable amounts as `.parse`
    /// (used) or a nil `limitCents` (limit) — a huge finite limit is
    /// treated as "unknown limit" rather than a hard error since the
    /// secondary line has a graceful fallback for a nil limit.
    private func onDemandWindow(individual: [String: Any]) throws -> UsageWindow? {
        guard let onDemand = individual["onDemand"] as? [String: Any] else { return nil }
        // NumericJSON rejects JSON booleans; the `enabled` flag is a
        // genuine bool here so we must not read it through NumericJSON.
        guard let enabled = onDemand["enabled"] as? Bool, enabled else { return nil }
        // Only the `used` amount is required. `limit` may be null (per the
        // fixture) — the secondary line switches to the "$X.YZ on-demand"
        // shape in that case.
        guard let usedAmount = NumericJSON.number(from: onDemand["used"]) else {
            throw FetchError.parse(
                "Cursor usage response individualUsage.onDemand enabled but used missing"
            )
        }
        guard let usedCents = Formatting.safeInt(usedAmount) else {
            throw FetchError.parse(
                "Cursor usage response individualUsage.onDemand used out of range"
            )
        }
        let limitCents: Int? = {
            guard let value = NumericJSON.number(from: onDemand["limit"]) else { return nil }
            return Formatting.safeInt(value)
        }()
        return UsageWindow(
            label: "On-demand",
            usedPercent: 0,
            resetsAt: nil,
            kind: .onDemand,
            amountCents: usedCents,
            limitCents: limitCents
        )
    }

    /// Parse an ISO 8601 `billingCycleEnd` string. Accepts both the fixture's
    /// `.000Z` fractional-seconds form and the plain "no fractional" form.
    private func parseCycleEnd(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
