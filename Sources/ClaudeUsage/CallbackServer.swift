import Foundation
import Network

/// Minimal one-shot HTTP server that waits for the OAuth redirect on
/// `http://localhost:<port>/callback` and hands back the `code` + `state`.
final class CallbackServer: @unchecked Sendable {
    enum ServerError: LocalizedError {
        case portInUse(UInt16)
        case listener(Error)

        var errorDescription: String? {
            switch self {
            case .portInUse(let port):
                return "Port \(port) is already in use (is another login in progress?)."
            case .listener(let error):
                return "Callback server failed: \(error.localizedDescription)"
            }
        }
    }

    private let queue = DispatchQueue(label: "oauth-callback-server")
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var continuation: CheckedContinuation<(code: String, state: String), Error>?
    private var finished = false
    private var expectedPath = "/callback"

    func waitForCallback(
        port: UInt16, path: String = "/callback"
    ) async throws -> (code: String, state: String) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.queue.async {
                    self.continuation = continuation
                    self.expectedPath = path
                    self.startListener(port: port)
                }
            }
        } onCancel: {
            self.queue.async {
                self.finish(.failure(CancellationError()))
            }
        }
    }

    func stop() {
        queue.async {
            self.finish(.failure(CancellationError()))
        }
    }

    // MARK: - Internals (all on `queue`)

    private func startListener(port: UInt16) {
        guard !finished else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(
                using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                self?.queue.async { self?.handle(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .failed(let error) = state {
                    self.queue.async {
                        if case .posix(let code) = error, code == .EADDRINUSE {
                            self.finish(.failure(ServerError.portInUse(port)))
                        } else {
                            self.finish(.failure(ServerError.listener(error)))
                        }
                    }
                }
            }
            listener.start(queue: queue)
        } catch {
            finish(.failure(ServerError.listener(error)))
        }
    }

    private func handle(_ connection: NWConnection) {
        guard !finished else {
            connection.cancel()
            return
        }
        connections.append(connection)
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, _, _ in
            guard let self else { return }
            self.queue.async {
                self.processRequest(data: data, connection: connection)
            }
        }
    }

    private func processRequest(data: Data?, connection: NWConnection) {
        guard let data,
            let request = String(data: data, encoding: .utf8),
            let requestLine = request.components(separatedBy: "\r\n").first,
            requestLine.hasPrefix("GET ")
        else {
            connection.cancel()
            return
        }

        let path = requestLine.dropFirst(4).components(separatedBy: " ").first ?? ""
        guard path.hasPrefix(expectedPath), let components = URLComponents(string: path) else {
            respond(connection, status: "404 Not Found", body: "Not found")
            return
        }

        let query = { (name: String) in
            components.queryItems?.first(where: { $0.name == name })?.value
        }

        if let error = query("error") {
            respond(connection, status: "200 OK", body: Self.failureHTML)
            finish(.failure(OAuthError.authorizationDenied(error)))
            return
        }
        guard let code = query("code"), let state = query("state") else {
            respond(connection, status: "400 Bad Request", body: "Missing code or state")
            return
        }

        respond(connection, status: "200 OK", body: Self.successHTML)
        // Give the response a moment to flush before tearing the listener down.
        queue.asyncAfter(deadline: .now() + 0.3) {
            self.finish(.success((code, state)))
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let payload = Data(body.utf8)
        let header = """
            HTTP/1.1 \(status)\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(payload.count)\r
            Connection: close\r
            \r

            """
        connection.send(
            content: Data(header.utf8) + payload,
            completion: .contentProcessed { _ in
                connection.cancel()
            })
    }

    private func finish(_ result: Result<(code: String, state: String), Error>) {
        guard !finished else { return }
        finished = true
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
        }
    }

    private static let successHTML = """
        <!doctype html><meta charset="utf-8"><title>Claude Usage</title>
        <body style="font-family:-apple-system,sans-serif;display:grid;place-items:center;height:90vh">
        <div style="text-align:center"><h2>Signed in ✓</h2>
        <p>You can close this tab and return to the menu bar app.</p></div>
        """

    private static let failureHTML = """
        <!doctype html><meta charset="utf-8"><title>Claude Usage</title>
        <body style="font-family:-apple-system,sans-serif;display:grid;place-items:center;height:90vh">
        <div style="text-align:center"><h2>Sign-in failed</h2>
        <p>Authorization was not granted. You can close this tab.</p></div>
        """
}
