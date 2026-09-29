import Foundation
import XCTest
@testable import UsageRingsCore

/// Shared fake `HTTPTransport` used by every provider test file.
///
/// Each provider (Claude, Codex, Cursor) needs the same behaviour: enqueue
/// canned `(status, body)` or error responses, record the requests as they
/// arrive, and pop responses off in FIFO order. Consolidated here so
/// every provider test file uses the same type instead of duplicating
/// near-identical implementations.
///
/// Requests are recorded verbatim (including headers) so tests can assert
/// on the exact `Authorization`, `Cookie`, `Accept`, etc. values the
/// provider constructed. Nothing here writes to disk or performs any I/O.
final class RecordingTransport: HTTPTransport, @unchecked Sendable {

    /// URL used to build the `HTTPURLResponse` returned to the provider. Each
    /// provider passes its own endpoint URL so a caller inspecting the
    /// response can tell which endpoint fired.
    let responseURL: URL

    private let lock = NSLock()
    private var responses: [Result<(Data, HTTPURLResponse), Error>] = []
    private var _requests: [URLRequest] = []

    init(responseURL: URL) {
        self.responseURL = responseURL
    }

    /// All requests the transport has been asked to satisfy, in order.
    var requests: [URLRequest] {
        withLock { _requests }
    }

    /// Enqueue a canned HTTP response (status code + raw body).
    func enqueue(status: Int, body: Data, headers: [String: String] = [:]) {
        let response = HTTPURLResponse(
            url: responseURL,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        withLock { responses.append(.success((body, response))) }
    }

    /// Enqueue a canned error to be thrown from `get(_:)` — used to
    /// exercise `URLError` mapping.
    func enqueue(error: Error) {
        withLock { responses.append(.failure(error)) }
    }

    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let response = recordAndPop(request) else {
            XCTFail("No canned response for request \(request)")
            throw FetchError.other("no response")
        }
        switch response {
        case .success(let pair): return pair
        case .failure(let error): throw error
        }
    }

    private func recordAndPop(_ request: URLRequest) -> Result<(Data, HTTPURLResponse), Error>? {
        withLock {
            _requests.append(request)
            guard !responses.isEmpty else { return nil }
            return responses.removeFirst()
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}
