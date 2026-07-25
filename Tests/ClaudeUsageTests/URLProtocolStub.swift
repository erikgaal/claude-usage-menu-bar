import Foundation

/// In-process network stub: a `URLProtocol` registered on an ephemeral
/// `URLSessionConfiguration`, so provider code exercises its real request
/// building and response handling without touching the network.
///
/// Usage:
///     URLProtocolStub.reset()   // in setUp
///     URLProtocolStub.handler = { request in
///         (URLProtocolStub.httpResponse(for: request, status: 200), body)
///     }
///     let session = URLProtocolStub.makeSession()
///
/// State is static (URLProtocol instances are created by the URL loading
/// system), guarded by a lock because loading happens off the test thread.
final class URLProtocolStub: URLProtocol {

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler:
        ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) private static var _requests: [URLRequest] = []

    /// Serves every request made through a `makeSession()` session.
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue } }
    }

    /// Every request seen since the last `reset()`, in arrival order.
    static var requests: [URLRequest] {
        lock.withLock { _requests }
    }

    static func reset() {
        lock.withLock {
            _handler = nil
            _requests = []
        }
    }

    /// A session that routes exclusively through this stub.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    /// Convenience for handlers: an HTTP response for the request's own URL.
    static func httpResponse(
        for request: URLRequest, status: Int, headers: [String: String]? = nil
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: headers)!
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self._requests.append(request) }
        do {
            guard let handler = Self.handler else {
                throw URLError(.unsupportedURL)  // no stub registered
            }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
