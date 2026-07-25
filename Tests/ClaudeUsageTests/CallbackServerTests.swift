import Darwin
import XCTest

@testable import ClaudeUsage

/// Exercises `CallbackServer` over real loopback sockets. Every test picks a
/// fresh ephemeral port so runs never collide with each other or with a live
/// app instance on 54545/1455.
final class CallbackServerTests: XCTestCase {

    private struct TestError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: - Socket helpers

    private func makeAddress(port: UInt16, loopback: Bool) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: loopback ? inet_addr("127.0.0.1") : INADDR_ANY)
        return address
    }

    private func bindSocket(port: UInt16) throws -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TestError("socket() failed: errno \(errno)") }
        var address = makeAddress(port: port, loopback: false)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            throw TestError("bind() failed: errno \(errno)")
        }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else {
            close(fd)
            throw TestError("getsockname() failed: errno \(errno)")
        }
        return (fd, UInt16(bigEndian: assigned.sin_port))
    }

    /// A port the OS considered free a moment ago. The probe socket is closed
    /// before returning; the reuse race is negligible on loopback in tests.
    private func freePort() throws -> UInt16 {
        let (fd, port) = try bindSocket(port: 0)
        close(fd)
        return port
    }

    /// Binds *and listens* on an ephemeral port and keeps the socket open, so
    /// a subsequent `CallbackServer` on the same port must fail.
    private func occupyPort() throws -> (fd: Int32, port: UInt16) {
        let (fd, port) = try bindSocket(port: 0)
        guard listen(fd, 4) == 0 else {
            close(fd)
            throw TestError("listen() failed: errno \(errno)")
        }
        return (fd, port)
    }

    /// One connection attempt; nil when the port refuses. Reads on the
    /// returned socket are bounded so a silent server can't hang a test.
    private func connectOnce(port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = makeAddress(port: port, loopback: true)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            return nil
        }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    /// Connects, retrying briefly — `waitForCallback` binds asynchronously,
    /// so the very first request of a test may beat the listener.
    private func connect(port: UInt16, retryFor seconds: TimeInterval = 2) throws -> Int32 {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            if let fd = connectOnce(port: port) { return fd }
            guard Date() < deadline else {
                throw TestError("could not connect to 127.0.0.1:\(port)")
            }
            usleep(20_000)
        }
    }

    /// Sends raw bytes and returns everything the server writes back until it
    /// closes the connection (or the bounded read times out).
    private func exchange(_ payload: Data, port: UInt16) throws -> String {
        let fd = try connect(port: port)
        defer { close(fd) }
        let written = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == payload.count else { throw TestError("short write to \(port)") }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            received.append(contentsOf: buffer[0..<count])
        }
        return String(data: received, encoding: .utf8) ?? ""
    }

    private func get(_ pathAndQuery: String, port: UInt16) throws -> String {
        try exchange(
            Data("GET \(pathAndQuery) HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8), port: port)
    }

    /// The listener tears down asynchronously after the result is delivered;
    /// poll until connections are refused (well under the deadline in practice).
    private func assertPortStopsAccepting(
        _ port: UInt16, within seconds: TimeInterval = 2,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            guard let fd = connectOnce(port: port) else { return }
            close(fd)
            usleep(20_000)
        }
        XCTFail("port \(port) still accepts connections", file: file, line: line)
    }

    /// Awaits the server task, failing fast instead of hanging the suite: on
    /// timeout the task is cancelled, which unblocks `waitForCallback`.
    private func result<T: Sendable>(
        of task: Task<T, Error>, timeout: TimeInterval = 4
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await task.value }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                task.cancel()
                throw TestError("timed out after \(timeout)s waiting for the callback result")
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    // MARK: - Happy path

    func testCallbackDeliversCodeAndStateThenStopsAccepting() async throws {
        let port = try freePort()
        let server = CallbackServer()
        let task = Task { try await server.waitForCallback(port: port) }

        let response = try get("/callback?code=the-code&state=the-state", port: port)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200 OK"), response)
        XCTAssertTrue(response.contains("Signed in"), "success page expected: \(response)")

        let callback = try await result(of: task)
        XCTAssertEqual(callback.code, "the-code")
        XCTAssertEqual(callback.state, "the-state")

        // One-shot server: once the result is delivered the listener is gone.
        assertPortStopsAccepting(port)
    }

    func testCallbackDecodesPercentEncodedValues() async throws {
        let port = try freePort()
        let server = CallbackServer()
        let task = Task { try await server.waitForCallback(port: port) }

        _ = try get("/callback?code=a%2Fb%3Dc&state=s%20t", port: port)

        let callback = try await result(of: task)
        XCTAssertEqual(callback.code, "a/b=c")
        XCTAssertEqual(callback.state, "s t")
    }

    /// The Codex flow listens on a different path; the injected path must be
    /// honored and the default one rejected.
    func testCustomCallbackPathIsHonored() async throws {
        let port = try freePort()
        let server = CallbackServer()
        let task = Task {
            try await server.waitForCallback(port: port, path: "/auth/callback")
        }

        let miss = try get("/callback?code=c&state=s", port: port)
        XCTAssertTrue(miss.hasPrefix("HTTP/1.1 404"), miss)

        let hit = try get("/auth/callback?code=codex-code&state=codex-state", port: port)
        XCTAssertTrue(hit.hasPrefix("HTTP/1.1 200 OK"), hit)

        let callback = try await result(of: task)
        XCTAssertEqual(callback.code, "codex-code")
        XCTAssertEqual(callback.state, "codex-state")
    }

    // MARK: - Error paths

    func testMissingCodeOrStateGets400AndServerKeepsWaiting() async throws {
        let port = try freePort()
        let server = CallbackServer()
        let task = Task { try await server.waitForCallback(port: port) }

        let missingState = try get("/callback?code=only-code", port: port)
        XCTAssertTrue(missingState.hasPrefix("HTTP/1.1 400"), missingState)
        XCTAssertTrue(missingState.contains("Missing code or state"), missingState)

        let missingCode = try get("/callback?state=only-state", port: port)
        XCTAssertTrue(missingCode.hasPrefix("HTTP/1.1 400"), missingCode)

        // The wait survives bad redirects; a complete one still lands.
        _ = try get("/callback?code=c&state=s", port: port)
        let callback = try await result(of: task)
        XCTAssertEqual(callback.code, "c")
    }

    func testProviderErrorFailsTheWaitWithAuthorizationDenied() async throws {
        let port = try freePort()
        let server = CallbackServer()
        let task = Task { try await server.waitForCallback(port: port) }

        // Unlike the success path, the error path tears the connection down
        // right after enqueueing the failure page (no flush delay), so the
        // body typically never reaches the client. The pinned contract is the
        // thrown error; the response just must not claim success.
        let response = try get("/callback?error=access_denied", port: port)
        XCTAssertFalse(response.contains("Signed in"), response)

        do {
            _ = try await result(of: task)
            XCTFail("expected authorizationDenied")
        } catch OAuthError.authorizationDenied(let reason) {
            XCTAssertEqual(reason, "access_denied")
        }
    }

    func testUnknownPathGets404AndServerKeepsWaiting() async throws {
        let port = try freePort()
        let server = CallbackServer()
        let task = Task { try await server.waitForCallback(port: port) }

        let response = try get("/favicon.ico", port: port)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 404 Not Found"), response)
        XCTAssertTrue(response.contains("Not found"), response)

        _ = try get("/callback?code=c&state=s", port: port)
        let callback = try await result(of: task)
        XCTAssertEqual(callback.code, "c")
    }

    /// Non-GET requests are dropped without a response (connection closed),
    /// and the server keeps waiting for the real redirect.
    func testNonGETRequestIsDroppedWithoutResponse() async throws {
        let port = try freePort()
        let server = CallbackServer()
        let task = Task { try await server.waitForCallback(port: port) }

        let response = try exchange(
            Data("POST /callback?code=c&state=s HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8),
            port: port)
        XCTAssertEqual(response, "")

        _ = try get("/callback?code=c&state=s", port: port)
        let callback = try await result(of: task)
        XCTAssertEqual(callback.code, "c")
    }

    func testMalformedRequestIsDroppedWithoutResponse() async throws {
        let port = try freePort()
        let server = CallbackServer()
        let task = Task { try await server.waitForCallback(port: port) }

        // 0xff/0xfe are never valid UTF-8: the request can't even be decoded.
        let response = try exchange(Data([0xff, 0xfe, 0x0d, 0x0a, 0x0d, 0x0a]), port: port)
        XCTAssertEqual(response, "")

        _ = try get("/callback?code=c&state=s", port: port)
        let callback = try await result(of: task)
        XCTAssertEqual(callback.code, "c")
    }

    /// A connection that closes without sending anything (port scan, browser
    /// preconnect) must not consume the one-shot wait.
    func testConnectionWithoutRequestKeepsServerWaiting() async throws {
        let port = try freePort()
        let server = CallbackServer()
        let task = Task { try await server.waitForCallback(port: port) }

        let fd = try connect(port: port)
        close(fd)

        _ = try get("/callback?code=c&state=s", port: port)
        let callback = try await result(of: task)
        XCTAssertEqual(callback.code, "c")
    }

    // MARK: - Cancellation & teardown

    func testCancellingTheWaitTearsDownListenerForImmediateRebind() async throws {
        let port = try freePort()
        let server = CallbackServer()
        let task = Task { try await server.waitForCallback(port: port) }
        // Prove the listener is up before cancelling.
        close(try connect(port: port))

        task.cancel()
        do {
            _ = try await result(of: task)
            XCTFail("expected CancellationError")
        } catch is CancellationError {}

        // Teardown completes asynchronously after the wait is rejected: the
        // listener socket closes within a beat, and from then on a fresh
        // login can rebind the port.
        assertPortStopsAccepting(port)
        let second = CallbackServer()
        let secondTask = Task { try await second.waitForCallback(port: port) }
        let response = try get("/callback?code=again&state=s", port: port)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200 OK"), response)
        let callback = try await result(of: secondTask)
        XCTAssertEqual(callback.code, "again")
    }

    /// `OAuthClient.login()` relies on `defer { server.stop() }` resolving an
    /// abandoned wait; stop() must reject it with `CancellationError`.
    func testStopRejectsPendingWaitWithCancellationError() async throws {
        let port = try freePort()
        let server = CallbackServer()
        let task = Task { try await server.waitForCallback(port: port) }
        close(try connect(port: port))

        server.stop()
        do {
            _ = try await result(of: task)
            XCTFail("expected CancellationError")
        } catch is CancellationError {}
    }

    // MARK: - Port conflicts

    func testPortAlreadyInUseSurfacesPortInUseError() async throws {
        let (fd, port) = try occupyPort()
        defer { close(fd) }

        let server = CallbackServer()
        let task = Task { try await server.waitForCallback(port: port) }
        do {
            _ = try await result(of: task)
            XCTFail("expected portInUse")
        } catch CallbackServer.ServerError.portInUse(let conflicted) {
            XCTAssertEqual(conflicted, port)
        }
    }
}
