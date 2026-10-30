import XCTest
@testable import slopWidget

// MARK: - Test doubles

actor MockClaudeNetworking: ClaudeOAuthNetworking {
    private var exchangeQueue: [Result<ClaudeOAuthTokenResponse, ClaudeOAuthError>] = []
    private var refreshQueue: [Result<ClaudeOAuthTokenResponse, ClaudeOAuthError>] = []

    private(set) var exchangeRequests: [ClaudeOAuthCodeExchange] = []
    private(set) var refreshRequests: [ClaudeOAuthRefreshRequest] = []

    func enqueueExchange(_ result: Result<ClaudeOAuthTokenResponse, ClaudeOAuthError>) {
        exchangeQueue.append(result)
    }

    func enqueueRefresh(_ result: Result<ClaudeOAuthTokenResponse, ClaudeOAuthError>) {
        refreshQueue.append(result)
    }

    func exchangeAuthorizationCode(_ request: ClaudeOAuthCodeExchange) async throws -> ClaudeOAuthTokenResponse {
        exchangeRequests.append(request)
        guard !exchangeQueue.isEmpty else {
            throw ClaudeOAuthError.invalidResponse("No exchange response queued")
        }
        return try exchangeQueue.removeFirst().get()
    }

    func refreshToken(_ request: ClaudeOAuthRefreshRequest) async throws -> ClaudeOAuthTokenResponse {
        refreshRequests.append(request)
        guard !refreshQueue.isEmpty else {
            throw ClaudeOAuthError.invalidResponse("No refresh response queued")
        }
        return try refreshQueue.removeFirst().get()
    }
}

@MainActor
final class MockClaudeAuthorizationPresenter: ClaudeAuthorizationPresenting {
    var stateOverride: String?
    var errorToThrow: ClaudeOAuthError?
    var presentedURLs: [URL] = []
    let redirect = URL(string: "http://localhost:54321/callback")!

    func authorize(context: ClaudeAuthorizationContext) async throws -> URL {
        if let errorToThrow {
            throw errorToThrow
        }
        presentedURLs.append(try context.authorizationURL(redirectURI: redirect))

        var components = URLComponents(url: redirect, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "auth-code-123"),
            URLQueryItem(name: "state", value: stateOverride ?? context.state),
        ]
        return components.url!
    }
}

/// Fails the test if a usage request is made.
private struct RecordingClaudeFetcher: ClaudeUsageFetching {
    let tokens: TokenLog

    final class TokenLog: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        var all: [String] { lock.lock(); defer { lock.unlock() }; return values }
        func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    }

    var failFirstWith401 = false

    func fetchUsage(accessToken: String) async throws -> ClaudeUsage {
        let first = tokens.all.isEmpty
        tokens.append(accessToken)
        if failFirstWith401, first {
            throw ClaudeUsageError.http(401, "expired")
        }
        return ClaudeUsage(fiveHour: .init(utilization: 12))
    }
}

// MARK: - Helpers

private func makeTokenResponse(
    accessToken: String = "access-token-1",
    refreshToken: String? = "refresh-token-1",
    expiresIn: TimeInterval? = 28_800,
    email: String? = "user@example.com"
) -> ClaudeOAuthTokenResponse {
    ClaudeOAuthTokenResponse(
        accessToken: accessToken,
        refreshToken: refreshToken,
        expiresIn: expiresIn,
        tokenType: "Bearer",
        scope: "user:profile",
        account: .init(uuid: "acct-uuid", emailAddress: email),
        organization: .init(uuid: "org-uuid", name: "Org")
    )
}

private func makeDefaults() -> UserDefaults {
    UserDefaults(suiteName: "ClaudeOAuthTests.\(UUID().uuidString)")!
}

private func queryItems(_ url: URL) throws -> [String: String] {
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    return Dictionary(
        uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        }
    )
}

// MARK: - Tests

final class ClaudeOAuthTests: XCTestCase {

    // MARK: Authorization URL

    func testAuthorizationURLMatchesClaudeCodeLoopbackRequest() throws {
        let context = ClaudeAuthorizationContext(
            pkce: PKCE(codeVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            state: "state-abc-123"
        )
        let url = try context.authorizationURL(redirectURI: URL(string: "http://localhost:54321/callback")!)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = try queryItems(url)

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "claude.com")
        XCTAssertEqual(components.path, "/cai/oauth/authorize")
        XCTAssertEqual(query["code"], "true")
        XCTAssertEqual(query["response_type"], "code")
        XCTAssertEqual(query["client_id"], "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        XCTAssertEqual(query["redirect_uri"], "http://localhost:54321/callback")
        XCTAssertEqual(query["scope"], "user:profile")
        XCTAssertEqual(query["code_challenge"], "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["state"], "state-abc-123")
    }

    func testManualAuthorizationURLUsesClaudeHostedRedirect() throws {
        let context = ClaudeAuthorizationContext(pkce: PKCE(codeVerifier: "verifier"), state: "s")
        let query = try queryItems(try context.manualAuthorizationURL())
        XCTAssertEqual(query["redirect_uri"], "https://platform.claude.com/oauth/code/callback")
    }

    func testGeneratedPKCEMatchesClaudeCodeVerifierLength() {
        // Claude Code uses 32 random bytes → a 43-character base64url verifier.
        let context = ClaudeAuthorizationContext()
        XCTAssertEqual(context.pkce.codeVerifier.count, 43)
        XCTAssertEqual(context.pkce.codeChallenge, PKCE.challenge(for: context.pkce.codeVerifier))
    }

    // MARK: Callback parsing

    func testCallbackParsing() throws {
        let url = URL(string: "http://localhost:54321/callback?code=abc&state=xyz")!
        let callback = try ClaudeOAuthCallback(url: url)
        XCTAssertEqual(callback.code, "abc")
        XCTAssertEqual(callback.state, "xyz")
        XCTAssertNil(callback.error)
    }

    func testPastedCodeParsing() throws {
        let callback = try ClaudeOAuthCallback.parsePasted("  the-code#the-state \n")
        XCTAssertEqual(callback.code, "the-code")
        XCTAssertEqual(callback.state, "the-state")

        for bad in ["", "no-hash", "#only-state", "only-code#"] {
            XCTAssertThrowsError(try ClaudeOAuthCallback.parsePasted(bad)) { error in
                XCTAssertEqual(error as? ClaudeOAuthError, .invalidPastedCode)
            }
        }
    }

    // MARK: Request bodies

    func testCodeExchangeRequestIsJSONWithClaudeCodeFields() throws {
        let exchange = ClaudeOAuthCodeExchange(
            configuration: .defaultConfiguration(),
            code: "auth-code",
            codeVerifier: "verifier",
            redirectURI: URL(string: "http://localhost:54321/callback")!,
            state: "the-state"
        )
        let request = try URLSessionClaudeOAuthNetworking.exchangeRequest(for: exchange)

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://platform.claude.com/v1/oauth/token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: String]
        )
        XCTAssertEqual(body, [
            "grant_type": "authorization_code",
            "code": "auth-code",
            "redirect_uri": "http://localhost:54321/callback",
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
            "code_verifier": "verifier",
            "state": "the-state",
        ])
    }

    func testRefreshRequestIsJSONWithScope() throws {
        let request = try URLSessionClaudeOAuthNetworking.refreshRequest(
            for: ClaudeOAuthRefreshRequest(configuration: .defaultConfiguration(), refreshToken: "rt")
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: String]
        )
        XCTAssertEqual(body, [
            "grant_type": "refresh_token",
            "refresh_token": "rt",
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
            "scope": "user:profile",
        ])
    }

    // MARK: Token parsing

    func testTokenResponseDecodesAndParsesAccount() throws {
        let json = """
        {"token_type":"Bearer","access_token":"at","expires_in":28800,"refresh_token":"rt",
         "scope":"user:profile user:inference",
         "account":{"uuid":"a-1","email_address":"me@example.com"},
         "organization":{"uuid":"o-1","name":"Me's Org"}}
        """
        let response = try JSONDecoder().decode(ClaudeOAuthTokenResponse.self, from: Data(json.utf8))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tokens = try ClaudeTokens(response: response, now: now)

        XCTAssertEqual(tokens.accessToken, "at")
        XCTAssertEqual(tokens.refreshToken, "rt")
        XCTAssertEqual(tokens.expiresAt, now.addingTimeInterval(28_800))
        XCTAssertEqual(tokens.scopes, ["user:profile", "user:inference"])
        XCTAssertEqual(tokens.identifier, "me@example.com")
        XCTAssertEqual(tokens.organizationName, "Me's Org")
    }

    func testTokenResponsePreservesPreviousRefreshTokenAndIdentity() throws {
        let previous = ClaudeTokens(
            accessToken: "old", refreshToken: "keep-me", scopes: ["user:profile"], email: "me@example.com"
        )
        let response = ClaudeOAuthTokenResponse(accessToken: "new", refreshToken: nil, expiresIn: 60)
        let tokens = try ClaudeTokens(response: response, previous: previous)
        XCTAssertEqual(tokens.refreshToken, "keep-me")
        XCTAssertEqual(tokens.email, "me@example.com")
        XCTAssertEqual(tokens.scopes, ["user:profile"])
    }

    func testTokenResponseRejectsInvalidValues() {
        XCTAssertThrowsError(try ClaudeTokens(response: .init(accessToken: "  ")))
        XCTAssertThrowsError(try ClaudeTokens(response: .init(accessToken: "x", tokenType: "mac")))
        XCTAssertThrowsError(try ClaudeTokens(response: .init(accessToken: "x", expiresIn: 0)))
    }

    func testExpiryUsesSixtySecondSkew() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(ClaudeTokens(accessToken: "a", expiresAt: now.addingTimeInterval(59)).isExpired(at: now))
        XCTAssertFalse(ClaudeTokens(accessToken: "a", expiresAt: now.addingTimeInterval(61)).isExpired(at: now))
    }

    func testTokenEndpointErrorParsingHandlesBothObservedShapes() throws {
        let flat = Data(#"{"error": "invalid_grant", "error_description": "Invalid 'code' in request."}"#.utf8)
        let flatParsed = try XCTUnwrap(URLSessionClaudeOAuthNetworking.parseError(from: flat))
        XCTAssertEqual(flatParsed.code, "invalid_grant")
        XCTAssertEqual(flatParsed.message, "Invalid 'code' in request.")

        let nested = Data(#"{"type":"error","error":{"type":"rate_limit_error","message":"Rate limited."}}"#.utf8)
        let nestedParsed = try XCTUnwrap(URLSessionClaudeOAuthNetworking.parseError(from: nested))
        XCTAssertEqual(nestedParsed.code, "rate_limit_error")
        XCTAssertEqual(nestedParsed.message, "Rate limited.")

        XCTAssertNil(URLSessionClaudeOAuthNetworking.parseError(from: Data("<html>".utf8)))
    }

    // MARK: Keychain store contract

    func testStoreRoundTripAndDelete() throws {
        let store = InMemoryClaudeCredentialStore()
        XCTAssertNil(try store.load())

        let tokens = ClaudeTokens(
            accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 1_700_000_000),
            scopes: ["user:profile"], email: "me@example.com"
        )
        let decoded = try JSONDecoder().decode(ClaudeTokens.self, from: JSONEncoder().encode(tokens))
        XCTAssertEqual(decoded, tokens)

        try store.save(tokens)
        XCTAssertEqual(try store.load(), tokens)
        try store.delete()
        XCTAssertNil(try store.load())
    }

    // MARK: Sign-in

    @MainActor
    func testSignInSuccessStoresTokensAndPopulatesIdentifier() async throws {
        let store = InMemoryClaudeCredentialStore()
        let networking = MockClaudeNetworking()
        await networking.enqueueExchange(.success(makeTokenResponse()))
        let presenter = MockClaudeAuthorizationPresenter()
        let client = ClaudeOAuthClient(networking: networking, presenter: presenter)
        let auth = AuthManager(
            storage: makeDefaults(),
            claudeCredentialStore: store,
            claudeOAuthNetworking: networking
        )

        let success = await auth.signInWithClaude(using: client)

        XCTAssertTrue(success)
        XCTAssertEqual(auth.claudeAuthMethod, .oauth)
        XCTAssertTrue(auth.claudeAuthState.isSignedIn)
        XCTAssertTrue(auth.claudeCreds.isLoggedIn)
        XCTAssertEqual(auth.claudeCreds.identifier, "user@example.com")
        XCTAssertEqual(auth.claudeCreds.apiKey, "", "tokens must not be mirrored into UserDefaults credentials")

        let stored = try XCTUnwrap(try store.load())
        XCTAssertEqual(stored.accessToken, "access-token-1")
        XCTAssertEqual(stored.refreshToken, "refresh-token-1")

        let exchanges = await networking.exchangeRequests
        let request = try XCTUnwrap(exchanges.first)
        XCTAssertEqual(request.code, "auth-code-123")
        XCTAssertEqual(request.redirectURI.absoluteString, "http://localhost:54321/callback")
        let presented = try queryItems(try XCTUnwrap(presenter.presentedURLs.first))
        XCTAssertEqual(presented["code_challenge"], PKCE.challenge(for: request.codeVerifier))
        XCTAssertEqual(presented["state"], request.state)
    }

    @MainActor
    func testSignInRejectsStateMismatch() async throws {
        let store = InMemoryClaudeCredentialStore()
        let networking = MockClaudeNetworking()
        let presenter = MockClaudeAuthorizationPresenter()
        presenter.stateOverride = "not-the-state"
        let client = ClaudeOAuthClient(networking: networking, presenter: presenter)
        let auth = AuthManager(
            storage: makeDefaults(),
            claudeCredentialStore: store,
            claudeOAuthNetworking: networking
        )

        let success = await auth.signInWithClaude(using: client)

        XCTAssertFalse(success)
        XCTAssertEqual(auth.claudeAuthState, .failed(ClaudeOAuthError.stateMismatch.userMessage))
        XCTAssertNil(try store.load())
        let exchanges = await networking.exchangeRequests
        XCTAssertTrue(exchanges.isEmpty, "the code must not be exchanged after a state mismatch")
    }

    @MainActor
    func testSignInCancellationDoesNotPersistCredentials() async throws {
        let store = InMemoryClaudeCredentialStore()
        let networking = MockClaudeNetworking()
        let presenter = MockClaudeAuthorizationPresenter()
        presenter.errorToThrow = .cancelled
        let auth = AuthManager(
            storage: makeDefaults(),
            claudeCredentialStore: store,
            claudeOAuthNetworking: networking
        )

        let success = await auth.signInWithClaude(
            using: ClaudeOAuthClient(networking: networking, presenter: presenter)
        )

        XCTAssertFalse(success)
        XCTAssertEqual(auth.claudeAuthState, .failed(ClaudeOAuthError.cancelled.userMessage))
        XCTAssertNil(try store.load())
        XCTAssertEqual(auth.claudeAuthMethod, .apiKey)
    }

    @MainActor
    func testExchangeFailureDoesNotPersistCredentials() async throws {
        let store = InMemoryClaudeCredentialStore()
        let networking = MockClaudeNetworking()
        await networking.enqueueExchange(.failure(.invalidGrant("Invalid 'code' in request.")))
        let auth = AuthManager(
            storage: makeDefaults(),
            claudeCredentialStore: store,
            claudeOAuthNetworking: networking
        )

        let success = await auth.signInWithClaude(
            using: ClaudeOAuthClient(networking: networking, presenter: MockClaudeAuthorizationPresenter())
        )

        XCTAssertFalse(success)
        XCTAssertNil(try store.load())
        XCTAssertFalse(auth.claudeCreds.isLoggedIn)
    }

    // MARK: Manual (paste-code) sign-in

    @MainActor
    func testManualSignInExchangesAgainstManualRedirect() async throws {
        let store = InMemoryClaudeCredentialStore()
        let networking = MockClaudeNetworking()
        await networking.enqueueExchange(.success(makeTokenResponse()))
        let client = ClaudeOAuthClient(networking: networking, presenter: MockClaudeAuthorizationPresenter())
        let auth = AuthManager(
            storage: makeDefaults(),
            claudeCredentialStore: store,
            claudeOAuthNetworking: networking
        )

        let url = try auth.beginClaudeManualSignIn()
        let query = try queryItems(url)
        XCTAssertEqual(query["redirect_uri"], "https://platform.claude.com/oauth/code/callback")

        let success = await auth.completeClaudeManualSignIn(
            pastedCode: "pasted-code#\(try XCTUnwrap(query["state"]))",
            using: client
        )

        XCTAssertTrue(success)
        XCTAssertEqual(try store.load()?.accessToken, "access-token-1")
        let exchanges = await networking.exchangeRequests
        let request = try XCTUnwrap(exchanges.first)
        XCTAssertEqual(request.code, "pasted-code")
        XCTAssertEqual(request.redirectURI.absoluteString, "https://platform.claude.com/oauth/code/callback")
        XCTAssertEqual(PKCE.challenge(for: request.codeVerifier), query["code_challenge"])
    }

    @MainActor
    func testManualSignInRejectsWrongStateAndGarbage() async throws {
        let store = InMemoryClaudeCredentialStore()
        let networking = MockClaudeNetworking()
        let client = ClaudeOAuthClient(networking: networking, presenter: MockClaudeAuthorizationPresenter())
        let auth = AuthManager(
            storage: makeDefaults(),
            claudeCredentialStore: store,
            claudeOAuthNetworking: networking
        )
        _ = try auth.beginClaudeManualSignIn()

        let garbage = await auth.completeClaudeManualSignIn(pastedCode: "no-hash-here", using: client)
        XCTAssertFalse(garbage)
        XCTAssertEqual(auth.claudeAuthState, .failed(ClaudeOAuthError.invalidPastedCode.userMessage))

        let wrongState = await auth.completeClaudeManualSignIn(pastedCode: "code#other-state", using: client)
        XCTAssertFalse(wrongState)
        XCTAssertEqual(auth.claudeAuthState, .failed(ClaudeOAuthError.stateMismatch.userMessage))

        XCTAssertNil(try store.load())
        let exchanges = await networking.exchangeRequests
        XCTAssertTrue(exchanges.isEmpty)
    }

    // MARK: Refresh

    @MainActor
    func testRefreshRotatesAndPersistsRefreshToken() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let expired = ClaudeTokens(
            accessToken: "expired-access", refreshToken: "refresh-old",
            expiresAt: now.addingTimeInterval(-10), email: "user@example.com"
        )
        let store = InMemoryClaudeCredentialStore(tokens: expired)
        let networking = MockClaudeNetworking()
        await networking.enqueueRefresh(
            .success(makeTokenResponse(accessToken: "fresh-access", refreshToken: "refresh-new"))
        )
        let auth = AuthManager(
            storage: makeDefaults(),
            claudeCredentialStore: store,
            claudeOAuthNetworking: networking
        )

        let refreshed = try await auth.refreshClaudeTokensIfNeeded(now: now)

        XCTAssertEqual(refreshed.accessToken, "fresh-access")
        XCTAssertEqual(refreshed.refreshToken, "refresh-new")
        XCTAssertEqual(try store.load()?.refreshToken, "refresh-new")
        XCTAssertEqual(try store.load()?.accessToken, "fresh-access")
        XCTAssertTrue(auth.claudeAuthState.isSignedIn)

        let refreshRequests = await networking.refreshRequests
        let request = try XCTUnwrap(refreshRequests.first)
        XCTAssertEqual(request.refreshToken, "refresh-old")
    }

    @MainActor
    func testRefreshSkipsTokenValidBeyondSkew() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = InMemoryClaudeCredentialStore(
            tokens: ClaudeTokens(accessToken: "still-good", refreshToken: "r", expiresAt: now.addingTimeInterval(3600))
        )
        let networking = MockClaudeNetworking()
        let auth = AuthManager(
            storage: makeDefaults(),
            claudeCredentialStore: store,
            claudeOAuthNetworking: networking
        )

        let token = try await auth.claudeAccessToken(now: now)

        XCTAssertEqual(token, "still-good")
        let refreshes = await networking.refreshRequests
        XCTAssertTrue(refreshes.isEmpty)
    }

    @MainActor
    func testRefreshWithinSixtySecondsOfExpiryRefreshes() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = InMemoryClaudeCredentialStore(
            tokens: ClaudeTokens(accessToken: "almost", refreshToken: "r", expiresAt: now.addingTimeInterval(30))
        )
        let networking = MockClaudeNetworking()
        await networking.enqueueRefresh(.success(makeTokenResponse(accessToken: "renewed")))
        let auth = AuthManager(
            storage: makeDefaults(),
            claudeCredentialStore: store,
            claudeOAuthNetworking: networking
        )

        let token = try await auth.claudeAccessToken(now: now)
        XCTAssertEqual(token, "renewed")
    }

    @MainActor
    func testConcurrentRefreshesShareOneRequest() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = InMemoryClaudeCredentialStore(
            tokens: ClaudeTokens(accessToken: "x", refreshToken: "r", expiresAt: now.addingTimeInterval(-1))
        )
        let networking = MockClaudeNetworking()
        await networking.enqueueRefresh(.success(makeTokenResponse(accessToken: "once", refreshToken: "r2")))
        let auth = AuthManager(
            storage: makeDefaults(),
            claudeCredentialStore: store,
            claudeOAuthNetworking: networking
        )

        async let first = auth.claudeAccessToken(now: now)
        async let second = auth.claudeAccessToken(now: now)
        let tokens = try await [first, second]

        XCTAssertEqual(tokens, ["once", "once"])
        let refreshes = await networking.refreshRequests
        XCTAssertEqual(refreshes.count, 1, "rotating refresh tokens must not be redeemed twice")
    }

    @MainActor
    func testInvalidGrantRefreshSignsOutAndClearsKeychain() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = InMemoryClaudeCredentialStore(
            tokens: ClaudeTokens(accessToken: "expired", refreshToken: "revoked", expiresAt: now.addingTimeInterval(-10))
        )
        let networking = MockClaudeNetworking()
        await networking.enqueueRefresh(.failure(.invalidGrant("Refresh token not found or invalid")))
        let auth = AuthManager(
            storage: makeDefaults(),
            claudeCredentialStore: store,
            claudeOAuthNetworking: networking
        )

        do {
            _ = try await auth.refreshClaudeTokensIfNeeded(now: now)
            XCTFail("Expected refresh to fail")
        } catch let error as ClaudeOAuthError {
            guard case .invalidGrant = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertNil(try store.load())
        XCTAssertEqual(auth.claudeAuthState, .signedOut)
        XCTAssertEqual(auth.claudeAuthMethod, .apiKey)
        XCTAssertFalse(auth.claudeCreds.isLoggedIn)
    }

    @MainActor
    func testTransientRefreshFailureKeepsSession() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tokens = ClaudeTokens(accessToken: "expired", refreshToken: "r", expiresAt: now.addingTimeInterval(-10))
        let store = InMemoryClaudeCredentialStore(tokens: tokens)
        let networking = MockClaudeNetworking()
        await networking.enqueueRefresh(.failure(.refreshFailed(statusCode: 429, message: "Rate limited.")))
        let auth = AuthManager(
            storage: makeDefaults(),
            claudeCredentialStore: store,
            claudeOAuthNetworking: networking
        )

        do {
            _ = try await auth.refreshClaudeTokensIfNeeded(now: now)
            XCTFail("Expected refresh to fail")
        } catch {}

        XCTAssertEqual(try store.load(), tokens, "a 429 must not discard the refresh token")
        XCTAssertEqual(auth.claudeAuthMethod, .oauth)
    }

    // MARK: Usage integration

    @MainActor
    func testUsageUsesOAuthAccessTokenNotManualToken() async throws {
        let store = InMemoryClaudeCredentialStore(
            tokens: ClaudeTokens(
                accessToken: "oauth-access", refreshToken: "r",
                expiresAt: Date().addingTimeInterval(3600), email: "me@example.com"
            )
        )
        let log = RecordingClaudeFetcher.TokenLog()
        let auth = AuthManager(
            storage: makeDefaults(),
            claudeUsageService: RecordingClaudeFetcher(tokens: log),
            claudeCredentialStore: store
        )

        let ok = await auth.refreshClaudeUsage()

        XCTAssertTrue(ok)
        XCTAssertEqual(log.all, ["oauth-access"])
        XCTAssertEqual(auth.claudeUsage?.usedPercent, 12)
    }

    @MainActor
    func testUsage401TriggersOneForcedRefreshAndRetry() async throws {
        let store = InMemoryClaudeCredentialStore(
            tokens: ClaudeTokens(
                accessToken: "revoked-access", refreshToken: "r-old",
                expiresAt: Date().addingTimeInterval(3600)
            )
        )
        let networking = MockClaudeNetworking()
        await networking.enqueueRefresh(
            .success(makeTokenResponse(accessToken: "new-access", refreshToken: "r-new"))
        )
        let log = RecordingClaudeFetcher.TokenLog()
        var fetcher = RecordingClaudeFetcher(tokens: log)
        fetcher.failFirstWith401 = true
        let auth = AuthManager(
            storage: makeDefaults(),
            claudeUsageService: fetcher,
            claudeCredentialStore: store,
            claudeOAuthNetworking: networking
        )

        let ok = await auth.refreshClaudeUsage()

        XCTAssertTrue(ok)
        XCTAssertEqual(log.all, ["revoked-access", "new-access"])
        XCTAssertEqual(try store.load()?.refreshToken, "r-new")
    }

    // MARK: Sign-out and precedence

    @MainActor
    func testLogoutClearsClaudeSession() async throws {
        let store = InMemoryClaudeCredentialStore()
        let networking = MockClaudeNetworking()
        await networking.enqueueExchange(.success(makeTokenResponse()))
        let auth = AuthManager(
            storage: makeDefaults(),
            claudeCredentialStore: store,
            claudeOAuthNetworking: networking
        )
        let signedIn = await auth.signInWithClaude(
            using: ClaudeOAuthClient(networking: networking, presenter: MockClaudeAuthorizationPresenter())
        )
        XCTAssertTrue(signedIn)
        XCTAssertNotNil(try store.load())

        auth.logout(type: .claude)

        XCTAssertEqual(auth.claudeAuthState, .signedOut)
        XCTAssertEqual(auth.claudeAuthMethod, .apiKey)
        XCTAssertNil(try store.load())
        XCTAssertFalse(auth.claudeCreds.isLoggedIn)
        XCTAssertEqual(auth.claudeCreds.identifier, "")
    }

    @MainActor
    func testManualLoginTakesPrecedenceOverOAuthWithoutDeletingTokens() async throws {
        let store = InMemoryClaudeCredentialStore()
        let networking = MockClaudeNetworking()
        await networking.enqueueExchange(.success(makeTokenResponse()))
        let auth = AuthManager(
            storage: makeDefaults(),
            claudeCredentialStore: store,
            claudeOAuthNetworking: networking
        )
        let signedIn = await auth.signInWithClaude(
            using: ClaudeOAuthClient(networking: networking, presenter: MockClaudeAuthorizationPresenter())
        )
        XCTAssertTrue(signedIn)

        XCTAssertTrue(auth.login(type: .claude, apiKey: "sk-ant-oat01-manual", identifier: "me"))

        XCTAssertEqual(auth.claudeAuthMethod, .apiKey)
        XCTAssertEqual(auth.claudeAuthState, .signedOut)
        XCTAssertEqual(auth.claudeCreds.apiKey, "sk-ant-oat01-manual")
        XCTAssertNotNil(try store.load(), "the Keychain item is ignored, not deleted")

        do {
            _ = try await auth.claudeAccessToken()
            XCTFail("A manual login must not expose the stale OAuth access token")
        } catch let error as ClaudeOAuthError {
            XCTAssertEqual(error, .notSignedIn)
        }
    }

    @MainActor
    func testStoredOAuthSessionRestoredOnLaunchUnlessManualMethodSaved() async throws {
        let defaults = makeDefaults()
        let tokens = ClaudeTokens(accessToken: "a", refreshToken: "r", email: "me@example.com")
        let store = InMemoryClaudeCredentialStore(tokens: tokens)

        let restored = AuthManager(storage: defaults, claudeCredentialStore: store)
        XCTAssertEqual(restored.claudeAuthMethod, .oauth)
        XCTAssertEqual(restored.claudeCreds.identifier, "me@example.com")
        XCTAssertTrue(restored.claudeAuthState.isSignedIn)

        _ = restored.login(type: .claude, apiKey: "manual", identifier: "")
        let relaunched = AuthManager(storage: defaults, claudeCredentialStore: store)
        XCTAssertEqual(relaunched.claudeAuthMethod, .apiKey)
        XCTAssertFalse(relaunched.claudeAuthState.isSignedIn)
    }
}
