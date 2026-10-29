import XCTest
@testable import slopWidget

// MARK: - Test doubles

actor MockChatGPTNetworking: ChatGPTOAuthNetworking {
    private var exchangeQueue: [Result<ChatGPTOAuthTokenResponse, ChatGPTOAuthError>] = []
    private var refreshQueue: [Result<ChatGPTOAuthTokenResponse, ChatGPTOAuthError>] = []

    private(set) var exchangeRequests: [ChatGPTOAuthCodeExchange] = []
    private(set) var refreshRequests: [ChatGPTOAuthRefreshRequest] = []

    func enqueueExchange(_ result: Result<ChatGPTOAuthTokenResponse, ChatGPTOAuthError>) {
        exchangeQueue.append(result)
    }

    func enqueueRefresh(_ result: Result<ChatGPTOAuthTokenResponse, ChatGPTOAuthError>) {
        refreshQueue.append(result)
    }

    func exchangeAuthorizationCode(_ request: ChatGPTOAuthCodeExchange) async throws -> ChatGPTOAuthTokenResponse {
        exchangeRequests.append(request)
        guard !exchangeQueue.isEmpty else {
            throw ChatGPTOAuthError.invalidResponse("No exchange response queued")
        }
        return try exchangeQueue.removeFirst().get()
    }

    func refreshToken(_ request: ChatGPTOAuthRefreshRequest) async throws -> ChatGPTOAuthTokenResponse {
        refreshRequests.append(request)
        guard !refreshQueue.isEmpty else {
            throw ChatGPTOAuthError.invalidResponse("No refresh response queued")
        }
        return try refreshQueue.removeFirst().get()
    }
}

@MainActor
final class MockChatGPTAuthorizationPresenter: ChatGPTAuthorizationPresenting {
    var stateOverride: String?
    var errorToThrow: ChatGPTOAuthError?
    var throwCancellationError = false
    var presentedURLs: [URL] = []

    func authorize(context: ChatGPTAuthorizationContext) async throws -> URL {
        if throwCancellationError {
            throw CancellationError()
        }
        if let errorToThrow {
            throw errorToThrow
        }

        let url = try context.authorizationURL()
        presentedURLs.append(url)

        var components = URLComponents(
            url: context.configuration.redirectURI,
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "code", value: "auth-code-123"),
            URLQueryItem(name: "state", value: stateOverride ?? context.state),
        ]
        return components.url!
    }
}

// MARK: - Helpers

private func makeIDToken(
    email: String = "user@example.com",
    accountID: String = "acct-123",
    plan: String = "plus",
    exp: TimeInterval? = nil
) -> String {
    var payload: [String: Any] = [
        "https://api.openai.com/profile": ["email": email],
        "https://api.openai.com/auth": [
            "chatgpt_account_id": accountID,
            "chatgpt_user_id": "user-123",
            "chatgpt_plan_type": plan,
        ],
    ]
    if let exp {
        payload["exp"] = exp
    }
    let header = Data(#"{"alg":"none","typ":"JWT"}"#.utf8)
    let body = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    return "\(header.base64URLEncodedString).\(body.base64URLEncodedString).signature"
}

private func makeTokenResponse(
    accessToken: String = "access-token-1",
    refreshToken: String? = "refresh-token-1",
    expiresIn: TimeInterval? = 3600,
    email: String = "user@example.com",
    accountID: String = "acct-123"
) -> ChatGPTOAuthTokenResponse {
    ChatGPTOAuthTokenResponse(
        accessToken: accessToken,
        refreshToken: refreshToken,
        idToken: makeIDToken(email: email, accountID: accountID),
        expiresIn: expiresIn,
        tokenType: "Bearer"
    )
}

private func makeDefaults() -> UserDefaults {
    let suite = "ChatGPTOAuthTests.\(UUID().uuidString)"
    return UserDefaults(suiteName: suite)!
}

// MARK: - Tests

final class ChatGPTOAuthTests: XCTestCase {

    // MARK: PKCE

    func testPKCEMatchesRFC7636Vector() {
        // https://www.rfc-editor.org/rfc/rfc7636#appendix-B
        let pkce = PKCE(codeVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(pkce.codeChallenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testGeneratedPKCEIsURLSafeAndLongEnough() {
        let pkce = PKCE.generate()
        XCTAssertGreaterThanOrEqual(pkce.codeVerifier.count, 43)
        XCTAssertLessThanOrEqual(pkce.codeVerifier.count, 128)
        XCTAssertFalse(pkce.codeVerifier.contains("="))
        XCTAssertFalse(pkce.codeChallenge.contains("+"))
        XCTAssertFalse(pkce.codeChallenge.contains("/"))
        XCTAssertEqual(pkce.codeChallenge, PKCE.challenge(for: pkce.codeVerifier))
    }

    // MARK: Authorization URL

    func testAuthorizationURLContainsRequiredCodexParameters() throws {
        let configuration = ChatGPTOAuthConfiguration.codex()
        let pkce = PKCE(codeVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let context = ChatGPTAuthorizationContext(
            configuration: configuration,
            pkce: pkce,
            state: "state-abc-123"
        )

        let url = try context.authorizationURL()
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "auth.openai.com")
        XCTAssertEqual(components.path, "/oauth/authorize")
        XCTAssertEqual(query["response_type"], "code")
        XCTAssertEqual(query["client_id"], "app_EMoamEEZ73f0CkXaXp7hrann")
        XCTAssertEqual(query["redirect_uri"], "http://127.0.0.1:1455/auth/callback")
        XCTAssertEqual(
            query["scope"],
            "openid profile email offline_access api.connectors.read api.connectors.invoke"
        )
        XCTAssertEqual(query["code_challenge"], "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["state"], "state-abc-123")
        XCTAssertEqual(query["id_token_add_organizations"], "true")
        XCTAssertEqual(query["codex_cli_simplified_flow"], "true")
        XCTAssertEqual(query["originator"], "codex_cli_rs")
    }

    func testAuthorizationURLHonorsFallbackRedirectPort() throws {
        let context = ChatGPTAuthorizationContext(
            configuration: .codex(),
            pkce: PKCE(codeVerifier: "verifier"),
            state: "state"
        )
        let fallback = URL(string: "http://127.0.0.1:1457/auth/callback")!
        let url = try context.authorizationURL(redirectURI: fallback)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let redirect = components.queryItems?.first(where: { $0.name == "redirect_uri" })?.value
        XCTAssertEqual(redirect, "http://127.0.0.1:1457/auth/callback")
    }

    func testCallbackParsing() throws {
        let url = URL(string: "http://127.0.0.1:1455/auth/callback?code=abc&state=xyz")!
        let callback = try ChatGPTOAuthCallback(url: url)
        XCTAssertEqual(callback.code, "abc")
        XCTAssertEqual(callback.state, "xyz")
        XCTAssertNil(callback.error)
    }

    // MARK: Token parsing

    func testTokenResponseParsingIdentityAndExpiry() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tokens = try ChatGPTTokens(response: makeTokenResponse(), now: now)

        XCTAssertEqual(tokens.accessToken, "access-token-1")
        XCTAssertEqual(tokens.refreshToken, "refresh-token-1")
        XCTAssertEqual(tokens.tokenType, "Bearer")
        XCTAssertEqual(tokens.email, "user@example.com")
        XCTAssertEqual(tokens.accountID, "acct-123")
        XCTAssertEqual(tokens.userID, "user-123")
        XCTAssertEqual(tokens.planType, "plus")
        XCTAssertEqual(tokens.identifier, "user@example.com")
        XCTAssertEqual(tokens.expiresAt, now.addingTimeInterval(3600))
        XCTAssertFalse(tokens.isExpired(at: now.addingTimeInterval(3000)))
        XCTAssertTrue(tokens.isExpired(at: now.addingTimeInterval(3600 - 30)))
    }

    func testTokenResponsePreservesRefreshTokenAndFallsBackToIDTokenExpiry() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let previous = ChatGPTTokens(
            accessToken: "old",
            refreshToken: "refresh-old",
            idToken: makeIDToken(exp: now.addingTimeInterval(7200).timeIntervalSince1970),
            expiresAt: now
        )
        let response = ChatGPTOAuthTokenResponse(
            accessToken: "new",
            refreshToken: nil,
            idToken: previous.idToken,
            expiresIn: nil,
            tokenType: "bearer"
        )
        let tokens = try ChatGPTTokens(response: response, previous: previous, now: now)

        XCTAssertEqual(tokens.accessToken, "new")
        XCTAssertEqual(tokens.refreshToken, "refresh-old")
        XCTAssertEqual(tokens.expiresAt, now.addingTimeInterval(7200))
    }

    func testTokenResponseRejectsInvalidValues() {
        XCTAssertThrowsError(
            try ChatGPTTokens(response: ChatGPTOAuthTokenResponse(accessToken: "  "))
        )
        XCTAssertThrowsError(
            try ChatGPTTokens(
                response: ChatGPTOAuthTokenResponse(accessToken: "a", expiresIn: 0)
            )
        )
        XCTAssertThrowsError(
            try ChatGPTTokens(
                response: ChatGPTOAuthTokenResponse(accessToken: "a", tokenType: "mac")
            )
        )
    }

    func testTokenEndpointErrorParsingClassifiesInvalidGrant() {
        let nested = Data(
            #"{"error":{"message":"Refresh token revoked","type":"invalid_request_error","code":"invalid_grant"}}"#.utf8
        )
        let parsed = URLSessionChatGPTOAuthNetworking.parseError(from: nested)
        XCTAssertEqual(parsed?.code, "invalid_grant")
        XCTAssertEqual(parsed?.message, "Refresh token revoked")

        let flat = Data(#"{"error":"invalid_grant","error_description":"Token is expired"}"#.utf8)
        let flatParsed = URLSessionChatGPTOAuthNetworking.parseError(from: flat)
        XCTAssertEqual(flatParsed?.code, "invalid_grant")
        XCTAssertEqual(flatParsed?.message, "Token is expired")
    }

    func testTokensCodableRoundTrip() throws {
        let tokens = try ChatGPTTokens(response: makeTokenResponse())
        let data = try JSONEncoder().encode(tokens)
        let decoded = try JSONDecoder().decode(ChatGPTTokens.self, from: data)
        XCTAssertEqual(decoded, tokens)
    }

    // MARK: AuthManager state transitions

    @MainActor
    func testSignInSuccessStoresTokensAndPopulatesIdentifier() async throws {
        let defaults = makeDefaults()
        let store = InMemoryChatGPTCredentialStore()
        let networking = MockChatGPTNetworking()
        await networking.enqueueExchange(.success(makeTokenResponse()))
        let presenter = MockChatGPTAuthorizationPresenter()
        let client = ChatGPTOAuthClient(networking: networking, presenter: presenter)
        let auth = AuthManager(
            storage: defaults,
            chatGPTCredentialStore: store,
            chatGPTOAuthNetworking: networking
        )

        let success = await auth.signInWithChatGPT(using: client)

        XCTAssertTrue(success)
        XCTAssertEqual(auth.codexAuthMethod, .chatGPT)
        XCTAssertTrue(auth.chatGPTAuthState.isSignedIn)
        XCTAssertTrue(auth.codexCreds.isLoggedIn)
        XCTAssertEqual(auth.codexCreds.identifier, "user@example.com")
        XCTAssertEqual(auth.codexCreds.apiKey, "")

        let stored = try XCTUnwrap(try store.load())
        XCTAssertEqual(stored.accessToken, "access-token-1")
        XCTAssertEqual(stored.refreshToken, "refresh-token-1")
        XCTAssertEqual(stored.accountID, "acct-123")

        let requests = await networking.exchangeRequests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.code, "auth-code-123")
        XCTAssertEqual(request.redirectURI.absoluteString, "http://127.0.0.1:1455/auth/callback")
        let presented = try XCTUnwrap(presenter.presentedURLs.first)
        let challenge = URLComponents(url: presented, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code_challenge" })?.value
        XCTAssertEqual(challenge, PKCE.challenge(for: request.codeVerifier))
    }

    @MainActor
    func testSignInRejectsStateMismatch() async throws {
        let defaults = makeDefaults()
        let store = InMemoryChatGPTCredentialStore()
        let networking = MockChatGPTNetworking()
        let presenter = MockChatGPTAuthorizationPresenter()
        presenter.stateOverride = "not-the-state"
        let client = ChatGPTOAuthClient(networking: networking, presenter: presenter)
        let auth = AuthManager(
            storage: defaults,
            chatGPTCredentialStore: store,
            chatGPTOAuthNetworking: networking
        )

        let success = await auth.signInWithChatGPT(using: client)

        XCTAssertFalse(success)
        XCTAssertEqual(auth.codexAuthMethod, .apiKey)
        XCTAssertEqual(
            auth.chatGPTAuthState,
            .failed(ChatGPTOAuthError.stateMismatch.userMessage)
        )
        XCTAssertNil(try store.load())
        let exchanges = await networking.exchangeRequests
        XCTAssertTrue(exchanges.isEmpty)
    }

    @MainActor
    func testSignInCancellationDoesNotPersistCredentials() async throws {
        let defaults = makeDefaults()
        let store = InMemoryChatGPTCredentialStore()
        let networking = MockChatGPTNetworking()
        let presenter = MockChatGPTAuthorizationPresenter()
        presenter.errorToThrow = .cancelled
        let client = ChatGPTOAuthClient(networking: networking, presenter: presenter)
        let auth = AuthManager(
            storage: defaults,
            chatGPTCredentialStore: store,
            chatGPTOAuthNetworking: networking
        )

        let success = await auth.signInWithChatGPT(using: client)

        XCTAssertFalse(success)
        XCTAssertEqual(auth.chatGPTAuthState, .failed(ChatGPTOAuthError.cancelled.userMessage))
        XCTAssertNil(try store.load())
    }

    @MainActor
    func testSignInMapsCancellationError() async throws {
        let defaults = makeDefaults()
        let store = InMemoryChatGPTCredentialStore()
        let networking = MockChatGPTNetworking()
        let presenter = MockChatGPTAuthorizationPresenter()
        presenter.throwCancellationError = true
        let client = ChatGPTOAuthClient(networking: networking, presenter: presenter)
        let auth = AuthManager(
            storage: defaults,
            chatGPTCredentialStore: store,
            chatGPTOAuthNetworking: networking
        )

        let success = await auth.signInWithChatGPT(using: client)

        XCTAssertFalse(success)
        XCTAssertEqual(auth.chatGPTAuthState, .failed(ChatGPTOAuthError.cancelled.userMessage))
        XCTAssertNil(try store.load())
    }

    @MainActor
    func testSignInTokenExchangeFailureDoesNotPersistCredentials() async throws {
        let defaults = makeDefaults()
        let store = InMemoryChatGPTCredentialStore()
        let networking = MockChatGPTNetworking()
        await networking.enqueueExchange(
            .failure(.tokenExchangeFailed(statusCode: 400, message: "invalid_grant: bad code"))
        )
        let presenter = MockChatGPTAuthorizationPresenter()
        let client = ChatGPTOAuthClient(networking: networking, presenter: presenter)
        let auth = AuthManager(
            storage: defaults,
            chatGPTCredentialStore: store,
            chatGPTOAuthNetworking: networking
        )

        let success = await auth.signInWithChatGPT(using: client)

        XCTAssertFalse(success)
        XCTAssertEqual(auth.codexAuthMethod, .apiKey)
        XCTAssertNil(try store.load())
        guard case .failed(let message) = auth.chatGPTAuthState else {
            return XCTFail("Expected failed state")
        }
        XCTAssertTrue(message.contains("HTTP 400"))
    }

    @MainActor
    func testRefreshReplacesExpiredAccessToken() async throws {
        let defaults = makeDefaults()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let expired = ChatGPTTokens(
            accessToken: "expired-access",
            refreshToken: "refresh-old",
            idToken: makeIDToken(),
            expiresAt: now.addingTimeInterval(-10),
            accountID: "acct-123",
            email: "user@example.com"
        )
        let store = InMemoryChatGPTCredentialStore(tokens: expired)
        let networking = MockChatGPTNetworking()
        await networking.enqueueRefresh(
            .success(makeTokenResponse(accessToken: "fresh-access", refreshToken: "refresh-new"))
        )
        let auth = AuthManager(
            storage: defaults,
            chatGPTCredentialStore: store,
            chatGPTOAuthNetworking: networking
        )

        let refreshed = try await auth.refreshChatGPTTokensIfNeeded(now: now)

        XCTAssertEqual(refreshed.accessToken, "fresh-access")
        XCTAssertEqual(refreshed.refreshToken, "refresh-new")
        XCTAssertEqual(try store.load()?.accessToken, "fresh-access")
        XCTAssertEqual(try store.load()?.refreshToken, "refresh-new")
        XCTAssertTrue(auth.chatGPTAuthState.isSignedIn)
        XCTAssertEqual(auth.codexCreds.identifier, "user@example.com")

        let requests = await networking.refreshRequests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.refreshToken, "refresh-old")
        XCTAssertEqual(request.configuration.clientID, "app_EMoamEEZ73f0CkXaXp7hrann")
    }

    @MainActor
    func testRefreshSkipsValidToken() async throws {
        let defaults = makeDefaults()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let valid = ChatGPTTokens(
            accessToken: "still-good",
            refreshToken: "refresh",
            expiresAt: now.addingTimeInterval(3600)
        )
        let store = InMemoryChatGPTCredentialStore(tokens: valid)
        let networking = MockChatGPTNetworking()
        let auth = AuthManager(
            storage: defaults,
            chatGPTCredentialStore: store,
            chatGPTOAuthNetworking: networking
        )

        let tokens = try await auth.chatGPTAccessToken(now: now)

        XCTAssertEqual(tokens, "still-good")
        let refreshes = await networking.refreshRequests
        XCTAssertTrue(refreshes.isEmpty)
    }

    @MainActor
    func testInvalidGrantRefreshSignsOutAndClearsKeychain() async throws {
        let defaults = makeDefaults()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let expired = ChatGPTTokens(
            accessToken: "expired",
            refreshToken: "revoked",
            expiresAt: now.addingTimeInterval(-10)
        )
        let store = InMemoryChatGPTCredentialStore(tokens: expired)
        let networking = MockChatGPTNetworking()
        await networking.enqueueRefresh(.failure(.invalidGrant("invalid_grant")))
        let auth = AuthManager(
            storage: defaults,
            chatGPTCredentialStore: store,
            chatGPTOAuthNetworking: networking
        )

        do {
            _ = try await auth.refreshChatGPTTokensIfNeeded(now: now)
            XCTFail("Expected refresh to fail")
        } catch let error as ChatGPTOAuthError {
            guard case .invalidGrant = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertNil(try store.load())
        XCTAssertEqual(auth.chatGPTAuthState, .signedOut)
        XCTAssertEqual(auth.codexAuthMethod, .apiKey)
        XCTAssertFalse(auth.codexCreds.isLoggedIn)
    }

    @MainActor
    func testLogoutClearsChatGPTSession() async throws {
        let defaults = makeDefaults()
        let store = InMemoryChatGPTCredentialStore()
        let networking = MockChatGPTNetworking()
        await networking.enqueueExchange(.success(makeTokenResponse()))
        let presenter = MockChatGPTAuthorizationPresenter()
        let client = ChatGPTOAuthClient(networking: networking, presenter: presenter)
        let auth = AuthManager(
            storage: defaults,
            chatGPTCredentialStore: store,
            chatGPTOAuthNetworking: networking
        )

        let signedIn = await auth.signInWithChatGPT(using: client)
        XCTAssertTrue(signedIn)
        XCTAssertNotNil(try store.load())

        auth.logout(type: .codex)

        XCTAssertEqual(auth.chatGPTAuthState, .signedOut)
        XCTAssertEqual(auth.codexAuthMethod, .apiKey)
        XCTAssertNil(try store.load())
        XCTAssertFalse(auth.codexCreds.isLoggedIn)
        XCTAssertEqual(auth.codexCreds.identifier, "")
    }

    @MainActor
    func testManualLoginTakesPrecedenceOverOAuthWithoutDeletingTokens() async throws {
        let defaults = makeDefaults()
        let store = InMemoryChatGPTCredentialStore()
        let networking = MockChatGPTNetworking()
        await networking.enqueueExchange(.success(makeTokenResponse()))
        let presenter = MockChatGPTAuthorizationPresenter()
        let client = ChatGPTOAuthClient(networking: networking, presenter: presenter)
        let auth = AuthManager(
            storage: defaults,
            chatGPTCredentialStore: store,
            chatGPTOAuthNetworking: networking
        )

        let signedIn = await auth.signInWithChatGPT(using: client)
        XCTAssertTrue(signedIn)
        XCTAssertTrue(auth.login(type: .codex, apiKey: "sk-manual", identifier: "org-manual"))

        XCTAssertEqual(auth.codexAuthMethod, .apiKey)
        XCTAssertEqual(auth.chatGPTAuthState, .signedOut)
        XCTAssertEqual(auth.codexCreds.apiKey, "sk-manual")
        XCTAssertEqual(auth.codexCreds.identifier, "org-manual")
        // The secure item is ignored while the persisted method is apiKey.
        XCTAssertNotNil(try store.load())

        do {
            _ = try await auth.chatGPTAccessToken()
            XCTFail("Manual login should not expose the stale OAuth access token")
        } catch let error as ChatGPTOAuthError {
            XCTAssertEqual(error, .notSignedIn)
        }
    }
}
