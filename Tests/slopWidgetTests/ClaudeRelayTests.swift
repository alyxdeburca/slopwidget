import XCTest
@testable import slopWidget

/// Serves canned responses to a `URLSession` so the relay fetcher can be tested
/// without a network.
private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case http(Int, String)
        case failure(URLError.Code)
    }

    nonisolated(unsafe) static var reply: Reply = .http(200, "{}")
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        switch Self.reply {
        case let .http(status, body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}
}

private struct StubFetcher: ClaudeUsageFetching {
    var result: Result<ClaudeUsage, ClaudeUsageError>
    func fetchUsage(accessToken: String) async throws -> ClaudeUsage { try result.get() }
}

/// Records which secret/URL it was built with.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL] = []
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return _urls }
    func record(_ url: URL) { lock.lock(); _urls.append(url); lock.unlock() }
}

final class ClaudeRelayTests: XCTestCase {
    private let relayURL = URL(string: "http://100.64.0.1:8787")!

    override func setUp() {
        super.setUp()
        AuthManager.resetDefaults()
        StubURLProtocol.reply = .http(200, "{}")
        StubURLProtocol.lastRequest = nil
    }

    override func tearDown() {
        AuthManager.resetDefaults()
        super.tearDown()
    }

    private func fetcher() -> RelayClaudeUsageFetcher {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return RelayClaudeUsageFetcher(baseURL: relayURL, session: URLSession(configuration: configuration))
    }

    // MARK: Fetcher

    func testSuccessDecodesUsageAndSendsBearerSecret() async throws {
        StubURLProtocol.reply = .http(200, #"""
        {"status":"ok","fetched_at":1,"five_hour":{"utilization":11.0,"resets_at":"2026-10-30T16:00:00Z"},
         "seven_day":{"utilization":4.0,"resets_at":null},"limits":[]}
        """#)
        let usage = try await fetcher().fetchUsage(accessToken: " s3cret \n")
        XCTAssertEqual(usage.fiveHour?.utilization, 11)
        XCTAssertEqual(usage.usedPercent, 11)

        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "http://100.64.0.1:8787/usage")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer s3cret")
    }

    func testUnauthorizedMapsToRelayUnauthorized() async {
        StubURLProtocol.reply = .http(401, #"{"status":"unauthorized"}"#)
        await assertFetchError(.relayUnauthorized)
    }

    func testTokenExpiredIsReportedFromEnvelope() async {
        StubURLProtocol.reply = .http(503, #"{"status":"token_expired","message":"expired"}"#)
        do {
            _ = try await fetcher().fetchUsage(accessToken: "s")
            XCTFail("expected an error")
        } catch let ClaudeUsageError.relay(status, _) {
            XCTAssertEqual(status, "token_expired")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testOkStatusRequiredEvenOn200() async {
        StubURLProtocol.reply = .http(200, #"{"status":"error","message":"boom"}"#)
        do {
            _ = try await fetcher().fetchUsage(accessToken: "s")
            XCTFail("expected an error")
        } catch let ClaudeUsageError.relay(status, message) {
            XCTAssertEqual(status, "error")
            XCTAssertEqual(message, "boom")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testUnreachableMentionsTailscale() async {
        StubURLProtocol.reply = .failure(.cannotConnectToHost)
        await assertFetchError(.relayUnreachable)
        XCTAssertTrue(ClaudeUsageError.relayUnreachable.localizedDescription.contains("Tailscale"))

        StubURLProtocol.reply = .failure(.timedOut)
        await assertFetchError(.relayUnreachable)
    }

    func testEmptySecretIsRejectedWithoutRequest() async {
        do {
            _ = try await fetcher().fetchUsage(accessToken: "  ")
            XCTFail("expected an error")
        } catch ClaudeUsageError.missingToken {
            XCTAssertNil(StubURLProtocol.lastRequest)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testNormalizedURL() {
        XCTAssertEqual(RelayClaudeUsageFetcher.normalizedURL(from: "100.1.2.3:8787")?.absoluteString, "http://100.1.2.3:8787")
        XCTAssertEqual(RelayClaudeUsageFetcher.normalizedURL(from: " https://x.ts.net/ ")?.absoluteString, "https://x.ts.net/")
        XCTAssertNil(RelayClaudeUsageFetcher.normalizedURL(from: ""))
        XCTAssertNil(RelayClaudeUsageFetcher.normalizedURL(from: "ftp://host"))
        XCTAssertNil(RelayClaudeUsageFetcher.normalizedURL(from: "http://"))
    }

    private func assertFetchError(_ expected: ClaudeUsageError, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await fetcher().fetchUsage(accessToken: "s")
            XCTFail("expected an error", file: file, line: line)
        } catch {
            XCTAssertEqual(error.localizedDescription, expected.localizedDescription, file: file, line: line)
        }
    }

    // MARK: AuthManager routing and fallback

    @MainActor
    private func makeAuth(
        relay: Result<ClaudeUsage, ClaudeUsageError>,
        direct: Result<ClaudeUsage, ClaudeUsageError>,
        recorder: Recorder = Recorder()
    ) -> AuthManager {
        AuthManager(
            claudeUsageService: StubFetcher(result: direct),
            claudeRelaySecretStore: InMemoryClaudeRelaySecretStore(),
            claudeRelayFetcherFactory: { url in
                recorder.record(url)
                return StubFetcher(result: relay)
            }
        )
    }

    @MainActor
    func testSaveRelayValidatesAndPersistsSecretOutsideDefaults() throws {
        let auth = makeAuth(relay: .success(ClaudeUsage()), direct: .success(ClaudeUsage()))
        XCTAssertThrowsError(try auth.saveClaudeRelay(url: "", secret: "x"))
        XCTAssertThrowsError(try auth.saveClaudeRelay(url: "100.1.1.1:8787", secret: " "))
        XCTAssertFalse(auth.isClaudeRelayConfigured)

        try auth.saveClaudeRelay(url: "100.1.1.1:8787", secret: " abc ")
        XCTAssertTrue(auth.isClaudeRelayConfigured)
        XCTAssertTrue(auth.isClaudeConnected)
        XCTAssertEqual(auth.claudeRelayURL?.absoluteString, "http://100.1.1.1:8787")
        XCTAssertEqual(auth.claudeRelaySecret(), "abc")
        XCTAssertNil(UserDefaults.standard.string(forKey: "claude_relay_url")?.range(of: "abc"))

        auth.clearClaudeRelay()
        XCTAssertFalse(auth.isClaudeRelayConfigured)
        XCTAssertEqual(auth.claudeRelaySecret(), "")
    }

    @MainActor
    func testRelayIsUsedWhenConfigured() async throws {
        let recorder = Recorder()
        let auth = makeAuth(
            relay: .success(ClaudeUsage(fiveHour: .init(utilization: 21))),
            direct: .success(ClaudeUsage(fiveHour: .init(utilization: 99))),
            recorder: recorder
        )
        try auth.saveClaudeRelay(url: "http://100.1.1.1:8787", secret: "s")
        _ = auth.login(type: .claude, apiKey: "direct-token", identifier: "")

        let ok = await auth.refreshClaudeUsage()
        XCTAssertTrue(ok)
        XCTAssertEqual(auth.claudeUsage?.usedPercent, 21)
        XCTAssertEqual(recorder.urls.map(\.absoluteString), ["http://100.1.1.1:8787"])
    }

    @MainActor
    func testRelayOnlyWorksWithoutDirectToken() async throws {
        let auth = makeAuth(relay: .success(ClaudeUsage(fiveHour: .init(utilization: 7))), direct: .failure(.missingToken))
        try auth.saveClaudeRelay(url: "100.1.1.1:8787", secret: "s")
        let ok = await auth.refreshClaudeUsage()
        XCTAssertTrue(ok)
        XCTAssertEqual(auth.claudeUsage?.usedPercent, 7)
    }

    @MainActor
    func testFallsBackToDirectTokenWhenRelayFails() async throws {
        let auth = makeAuth(
            relay: .failure(.relayUnreachable),
            direct: .success(ClaudeUsage(fiveHour: .init(utilization: 45)))
        )
        try auth.saveClaudeRelay(url: "100.1.1.1:8787", secret: "s")
        _ = auth.login(type: .claude, apiKey: "direct-token", identifier: "")

        let ok = await auth.refreshClaudeUsage()
        XCTAssertTrue(ok)
        XCTAssertEqual(auth.claudeUsage?.usedPercent, 45)
        XCTAssertNil(auth.claudeUsageError)
    }

    @MainActor
    func testRelayErrorSurfacesWhenNoFallbackExists() async throws {
        let auth = makeAuth(relay: .failure(.relayUnreachable), direct: .success(ClaudeUsage()))
        try auth.saveClaudeRelay(url: "100.1.1.1:8787", secret: "s")

        let ok = await auth.refreshClaudeUsage()
        XCTAssertFalse(ok)
        XCTAssertTrue(auth.claudeUsageError?.contains("Tailscale") == true)
    }

    @MainActor
    func testRelayErrorWinsWhenBothFail() async throws {
        let auth = makeAuth(relay: .failure(.relayUnauthorized), direct: .failure(.http(401, "")))
        try auth.saveClaudeRelay(url: "100.1.1.1:8787", secret: "s")
        _ = auth.login(type: .claude, apiKey: "direct-token", identifier: "")

        let ok = await auth.refreshClaudeUsage()
        XCTAssertFalse(ok)
        XCTAssertEqual(auth.claudeUsageError, ClaudeUsageError.relayUnauthorized.localizedDescription)
    }

    @MainActor
    func testDirectPathUnchangedWithoutRelay() async {
        let recorder = Recorder()
        let auth = makeAuth(
            relay: .failure(.relayUnreachable),
            direct: .success(ClaudeUsage(fiveHour: .init(utilization: 33))),
            recorder: recorder
        )
        _ = auth.login(type: .claude, apiKey: "direct-token", identifier: "")
        let ok = await auth.refreshClaudeUsage()
        XCTAssertTrue(ok)
        XCTAssertTrue(recorder.urls.isEmpty)
    }
}
