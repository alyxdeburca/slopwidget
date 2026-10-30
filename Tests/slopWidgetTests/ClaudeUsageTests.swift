import XCTest
@testable import slopWidget

private struct StubClaudeFetcher: ClaudeUsageFetching {
    var usage: ClaudeUsage
    func fetchUsage(accessToken: String) async throws -> ClaudeUsage { usage }
}

final class ClaudeUsageTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AuthManager.resetDefaults()
    }

    override func tearDown() {
        AuthManager.resetDefaults()
        super.tearDown()
    }

    func testDecodesWindowsAndIgnoresUnknownKeys() throws {
        let json = """
        {"five_hour":{"utilization":12.4,"resets_at":"2026-10-30T12:00:00Z"},
         "seven_day":{"utilization":61.6,"resets_at":null},
         "seven_day_opus":null,"extra_usage":{"is_enabled":false}}
        """
        let usage = try JSONDecoder().decode(ClaudeUsage.self, from: Data(json.utf8))
        XCTAssertEqual(usage.fiveHour?.utilization, 12.4)
        XCTAssertNil(usage.sevenDay?.resetsAt)
        // The weekly window is the most constrained one.
        XCTAssertEqual(usage.usedPercent, 62)
        XCTAssertEqual(usage.detail, "Weekly")
        XCTAssertEqual(usage.statusText, "Active")
        XCTAssertTrue(usage.hasUsageData)
    }

    func testNoUtilizationMeansNoData() throws {
        let usage = try JSONDecoder().decode(
            ClaudeUsage.self,
            from: Data(#"{"five_hour":null,"seven_day":{"utilization":null}}"#.utf8)
        )
        XCTAssertFalse(usage.hasUsageData)
        XCTAssertEqual(usage.statusText, "No data")
        XCTAssertFalse(usage.providerUsageItem.hasUsageData)
        XCTAssertEqual(usage.providerUsageItem.percentageText, "—")
    }

    func testHighAndLimitStatus() {
        XCTAssertEqual(ClaudeUsage(fiveHour: .init(utilization: 90)).statusText, "High")
        XCTAssertEqual(ClaudeUsage(fiveHour: .init(utilization: 100)).statusText, "Limit")
        XCTAssertEqual(ClaudeUsage(fiveHour: .init(utilization: 140)).usedPercent, 100)
    }

    @MainActor
    func testClaudeStartsDisconnectedAndLoginSavesToken() {
        let auth = AuthManager()
        XCTAssertFalse(auth.credentials(for: .claude).isLoggedIn)

        XCTAssertTrue(auth.login(type: .claude, apiKey: " sk-ant-oat01-x \n", identifier: "me"))
        XCTAssertEqual(auth.credentials(for: .claude).apiKey, "sk-ant-oat01-x")

        auth.logout(type: .claude)
        XCTAssertFalse(auth.credentials(for: .claude).isLoggedIn)
    }

    @MainActor
    func testRefreshWithoutTokenReportsError() async {
        let auth = AuthManager(claudeUsageService: StubClaudeFetcher(usage: ClaudeUsage()))
        let ok = await auth.refreshClaudeUsage()
        XCTAssertFalse(ok)
        XCTAssertNotNil(auth.claudeUsageError)
    }

    @MainActor
    func testRefreshPublishesUsage() async {
        let stub = StubClaudeFetcher(usage: ClaudeUsage(fiveHour: .init(utilization: 33)))
        let auth = AuthManager(claudeUsageService: stub)
        _ = auth.login(type: .claude, apiKey: "tok", identifier: "")
        let ok = await auth.refreshClaudeUsage()
        XCTAssertTrue(ok)
        XCTAssertEqual(auth.claudeUsage?.usedPercent, 33)
    }

    // MARK: Provider order

    func testOrderedSortsAndKeepsUnlistedItemsStable() {
        let items = ["a", "b", "c", "d"]
        XCTAssertEqual(UsageSnapshot.ordered(items, by: ["c", "a"], id: { $0 }), ["c", "a", "b", "d"])
        XCTAssertEqual(UsageSnapshot.ordered(items, by: nil, id: { $0 }), items)
        XCTAssertEqual(UsageSnapshot.ordered(items, by: [], id: { $0 }), items)
    }

    @MainActor
    func testNormalizedOrderDropsUnknownAndAppendsMissing() {
        let order = AuthManager.normalizedOrder(["claude", "bogus", "codex", "claude"])
        XCTAssertEqual(order, ["claude", "codex", "antigravity", "opencode-go"])
        XCTAssertEqual(AuthManager.normalizedOrder(nil), ServiceProviderType.allCases.map(\.rawValue))
    }

    @MainActor
    func testMoveProviderPersistsAndClampsAtEdges() {
        let auth = AuthManager()
        auth.moveProvider("claude", by: -1)
        XCTAssertEqual(auth.providerOrder, ["antigravity", "codex", "claude", "opencode-go"])

        auth.moveProvider("antigravity", by: -1) // already first
        auth.moveProvider("opencode-go", by: 1) // already last
        XCTAssertEqual(auth.providerOrder, ["antigravity", "codex", "claude", "opencode-go"])

        XCTAssertEqual(AuthManager().providerOrder, auth.providerOrder)

        auth.resetProviderOrder()
        XCTAssertEqual(auth.providerOrder, AuthManager.defaultProviderOrder)
    }
}

// MARK: - Desktop token sync

private struct StubSyncFetcher: ClaudeTokenSyncFetching {
    var result: Result<ClaudeSyncedToken, ClaudeTokenSyncError>
    func fetchToken(url: URL, secret: String) async throws -> ClaudeSyncedToken { try result.get() }
}

/// Fails after the first call so fallback-to-cache can be exercised.
private final class FlakySyncFetcher: ClaudeTokenSyncFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    let first: ClaudeSyncedToken
    init(first: ClaudeSyncedToken) { self.first = first }
    func fetchToken(url: URL, secret: String) async throws -> ClaudeSyncedToken {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        if calls == 1 { return first }
        throw ClaudeTokenSyncError.unreachable
    }
}

/// Records which token the usage call received.
private final class RecordingClaudeFetcher: ClaudeUsageFetching, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var tokens: [String] = []
    func fetchUsage(accessToken: String) async throws -> ClaudeUsage {
        lock.lock(); defer { lock.unlock() }
        tokens.append(accessToken)
        return ClaudeUsage(fiveHour: .init(utilization: 10))
    }
}

private func freshToken(_ value: String = "synced", validFor seconds: TimeInterval = 3600) -> ClaudeSyncedToken {
    ClaudeSyncedToken(accessToken: value, expiresAt: Date().addingTimeInterval(seconds), scopes: ["user:profile"])
}

final class ClaudeTokenSyncTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AuthManager.resetDefaults()
    }

    override func tearDown() {
        AuthManager.resetDefaults()
        super.tearDown()
    }

    @MainActor
    private func makeAuth(
        sync: any ClaudeTokenSyncFetching,
        usage: RecordingClaudeFetcher = RecordingClaudeFetcher(),
        store: InMemoryClaudeSyncSecretStore = InMemoryClaudeSyncSecretStore()
    ) -> AuthManager {
        let auth = AuthManager(
            claudeUsageService: usage,
            claudeTokenSync: sync,
            claudeSyncSecretStore: store
        )
        XCTAssertTrue(auth.configureClaudeSync(url: "100.110.102.104:8787", secret: " s3cret \n"))
        return auth
    }

    // MARK: URL + configuration

    func testNormalizedURLAddsSchemeAndTokenPath() {
        XCTAssertEqual(AuthManager.normalizedSyncURL("100.110.102.104:8787")?.absoluteString,
                       "http://100.110.102.104:8787/token")
        XCTAssertEqual(AuthManager.normalizedSyncURL(" https://box.ts.net/ ")?.absoluteString,
                       "https://box.ts.net/token")
        XCTAssertEqual(AuthManager.normalizedSyncURL("http://the-thinker:8787/custom")?.absoluteString,
                       "http://the-thinker:8787/custom")
        XCTAssertNil(AuthManager.normalizedSyncURL(""))
        XCTAssertNil(AuthManager.normalizedSyncURL("ftp://host/token"))
    }

    @MainActor
    func testConfigureStoresSecretInStoreNotDefaults() {
        let store = InMemoryClaudeSyncSecretStore()
        let auth = makeAuth(sync: StubSyncFetcher(result: .success(freshToken())), store: store)
        XCTAssertTrue(auth.claudeSyncConfigured)
        XCTAssertEqual(try store.load(), "s3cret")
        // The URL persists; the secret must not be anywhere in UserDefaults.
        XCTAssertEqual(UserDefaults.standard.string(forKey: "claude_sync_url"), "http://100.110.102.104:8787/token")
        let dump = UserDefaults.standard.dictionaryRepresentation().description
        XCTAssertFalse(dump.contains("s3cret"))

        // A new manager picks both back up.
        let reloaded = AuthManager(claudeSyncSecretStore: store)
        XCTAssertTrue(reloaded.claudeSyncConfigured)

        auth.clearClaudeSync()
        XCTAssertFalse(auth.claudeSyncConfigured)
        XCTAssertNil(try store.load())
        XCTAssertNil(UserDefaults.standard.string(forKey: "claude_sync_url"))
    }

    @MainActor
    func testConfigureRejectsBadInput() {
        let auth = AuthManager(claudeSyncSecretStore: InMemoryClaudeSyncSecretStore())
        XCTAssertFalse(auth.configureClaudeSync(url: "", secret: "x"))
        XCTAssertFalse(auth.configureClaudeSync(url: "host:1", secret: "  "))
        XCTAssertFalse(auth.claudeSyncConfigured)
    }

    // MARK: Refresh behaviour

    @MainActor
    func testSyncedTokenIsUsedAndNeverStoredAsManualCredential() async {
        let usage = RecordingClaudeFetcher()
        let auth = makeAuth(sync: StubSyncFetcher(result: .success(freshToken("from-desktop"))), usage: usage)
        let ok = await auth.refreshClaudeUsage()
        XCTAssertTrue(ok)
        XCTAssertEqual(usage.tokens, ["from-desktop"])
        XCTAssertEqual(auth.claudeTokenSource, .sync)
        XCTAssertNil(auth.claudeSyncWarning)
        XCTAssertFalse(auth.claudeCreds.isLoggedIn)
        XCTAssertTrue(auth.claudeCreds.apiKey.isEmpty)
        XCTAssertFalse(UserDefaults.standard.dictionaryRepresentation().description.contains("from-desktop"))
    }

    @MainActor
    func testSyncPreferredOverManualToken() async {
        let usage = RecordingClaudeFetcher()
        let auth = makeAuth(sync: StubSyncFetcher(result: .success(freshToken("from-desktop"))), usage: usage)
        _ = auth.login(type: .claude, apiKey: "manual", identifier: "")
        _ = await auth.refreshClaudeUsage()
        XCTAssertEqual(usage.tokens, ["from-desktop"])
    }

    @MainActor
    func testUnreachableFallsBackToManualWithWarning() async {
        let usage = RecordingClaudeFetcher()
        let auth = makeAuth(sync: StubSyncFetcher(result: .failure(.unreachable)), usage: usage)
        _ = auth.login(type: .claude, apiKey: "manual", identifier: "")
        let ok = await auth.refreshClaudeUsage()
        XCTAssertTrue(ok)
        XCTAssertEqual(usage.tokens, ["manual"])
        XCTAssertEqual(auth.claudeTokenSource, .manual)
        XCTAssertEqual(auth.claudeSyncWarning, "Can't reach the token sync server. Is Tailscale on?")
        XCTAssertNil(auth.claudeUsageError)
    }

    @MainActor
    func testUnreachableWithoutManualTokenSurfacesTailscaleHint() async {
        let usage = RecordingClaudeFetcher()
        let auth = makeAuth(sync: StubSyncFetcher(result: .failure(.unreachable)), usage: usage)
        let ok = await auth.refreshClaudeUsage()
        XCTAssertFalse(ok)
        XCTAssertTrue(usage.tokens.isEmpty)
        XCTAssertEqual(auth.claudeUsageError, "Can't reach the token sync server. Is Tailscale on?")
    }

    @MainActor
    func testExpiredSurfacesRunClaudeCodeHint() async {
        let auth = makeAuth(sync: StubSyncFetcher(result: .failure(.expired)))
        let ok = await auth.refreshClaudeUsage()
        XCTAssertFalse(ok)
        XCTAssertTrue(auth.claudeUsageError?.contains("Run Claude Code on your desktop") == true)
    }

    @MainActor
    func testServerTokenAlreadyPastExpiryIsTreatedAsExpired() async {
        let usage = RecordingClaudeFetcher()
        let auth = makeAuth(sync: StubSyncFetcher(result: .success(freshToken(validFor: -5))), usage: usage)
        let ok = await auth.refreshClaudeUsage()
        XCTAssertFalse(ok)
        XCTAssertTrue(usage.tokens.isEmpty)
        XCTAssertTrue(auth.claudeUsageError?.contains("Run Claude Code on your desktop") == true)
    }

    @MainActor
    func testUnauthorizedMessageMentionsSecret() async {
        let auth = makeAuth(sync: StubSyncFetcher(result: .failure(.unauthorized)))
        _ = await auth.refreshClaudeUsage()
        XCTAssertTrue(auth.claudeUsageError?.contains("secret") == true)
    }

    @MainActor
    func testCachedSyncedTokenCoversTransientOutage() async {
        let usage = RecordingClaudeFetcher()
        let auth = makeAuth(sync: FlakySyncFetcher(first: freshToken("cached")), usage: usage)
        _ = auth.login(type: .claude, apiKey: "manual", identifier: "")
        let first = await auth.refreshClaudeUsage()
        let second = await auth.refreshClaudeUsage() // server now unreachable
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(usage.tokens, ["cached", "cached"])
        XCTAssertEqual(auth.claudeTokenSource, .syncCached)
        XCTAssertNotNil(auth.claudeSyncWarning)
    }

    @MainActor
    func testManualOnlyBehaviourUnchangedWhenSyncNotConfigured() async {
        let usage = RecordingClaudeFetcher()
        let auth = AuthManager(claudeUsageService: usage, claudeSyncSecretStore: InMemoryClaudeSyncSecretStore())
        _ = auth.login(type: .claude, apiKey: "manual", identifier: "")
        XCTAssertTrue(auth.claudeConfigured)
        let ok = await auth.refreshClaudeUsage()
        XCTAssertTrue(ok)
        XCTAssertEqual(usage.tokens, ["manual"])
        XCTAssertEqual(auth.claudeTokenSource, .manual)
        XCTAssertNil(auth.claudeSyncWarning)
    }

    // MARK: HTTP fetcher status mapping

    func testHTTPStatusMapping() async throws {
        let url = URL(string: "http://sync.test/token")!
        for (status, expected) in [(401, ClaudeTokenSyncError.unauthorized),
                                   (409, .expired),
                                   (503, .noCredentials),
                                   (500, .http(500))] {
            let fetcher = URLSessionClaudeTokenSyncFetcher(session: StubURLProtocol.session(status: status, body: "{}"))
            do {
                _ = try await fetcher.fetchToken(url: url, secret: "s")
                XCTFail("expected error for \(status)")
            } catch {
                XCTAssertEqual(error as? ClaudeTokenSyncError, expected)
            }
        }
    }

    func testHTTPSuccessParsesMillisecondsAndSendsBearer() async throws {
        let ms = Int((Date().timeIntervalSince1970 + 3600) * 1000)
        let body = #"{"accessToken":"abc","expiresAt":\#(ms),"scopes":["user:profile"]}"#
        let fetcher = URLSessionClaudeTokenSyncFetcher(session: StubURLProtocol.session(status: 200, body: body))
        let token = try await fetcher.fetchToken(url: URL(string: "http://sync.test/token")!, secret: "s3cret")
        XCTAssertEqual(token.accessToken, "abc")
        XCTAssertEqual(token.scopes, ["user:profile"])
        XCTAssertTrue(token.isValid())
        XCTAssertEqual(StubURLProtocol.lastAuthorization, "Bearer s3cret")
    }

    func testHTTPMalformedBodyIsInvalidResponse() async {
        let fetcher = URLSessionClaudeTokenSyncFetcher(session: StubURLProtocol.session(status: 200, body: "nope"))
        do {
            _ = try await fetcher.fetchToken(url: URL(string: "http://sync.test/token")!, secret: "s")
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? ClaudeTokenSyncError, .invalidResponse)
        }
    }

    func testTransportFailureIsUnreachable() async {
        let fetcher = URLSessionClaudeTokenSyncFetcher(session: StubURLProtocol.session(status: nil, body: ""))
        do {
            _ = try await fetcher.fetchToken(url: URL(string: "http://sync.test/token")!, secret: "s")
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? ClaudeTokenSyncError, .unreachable)
        }
    }
}

/// Serves one canned response (or a transport error) without touching the network.
private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status: Int?
    nonisolated(unsafe) static var body = ""
    nonisolated(unsafe) static var lastAuthorization: String?

    static func session(status: Int?, body: String) -> URLSession {
        Self.status = status
        Self.body = body
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastAuthorization = request.value(forHTTPHeaderField: "Authorization")
        guard let status = Self.status else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
