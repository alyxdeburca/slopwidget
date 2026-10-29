import XCTest
@testable import slopWidget

// MARK: - Test doubles

actor MockAntigravityNetworking: AntigravityOAuthNetworking {
    private var exchangeQueue: [Result<AntigravityOAuthTokenResponse, AntigravityOAuthError>] = []
    private var refreshQueue: [Result<AntigravityOAuthTokenResponse, AntigravityOAuthError>] = []
    private var userInfoResult: Result<AntigravityUserInfo, AntigravityOAuthError> =
        .success(AntigravityUserInfo(email: "user@gmail.com", subject: "google-user-1"))

    private(set) var exchangeRequests: [AntigravityOAuthCodeExchange] = []
    private(set) var refreshRequests: [AntigravityOAuthRefreshRequest] = []
    private(set) var userInfoRequests: [AntigravityUserInfoRequest] = []

    func enqueueExchange(_ result: Result<AntigravityOAuthTokenResponse, AntigravityOAuthError>) {
        exchangeQueue.append(result)
    }

    func enqueueRefresh(_ result: Result<AntigravityOAuthTokenResponse, AntigravityOAuthError>) {
        refreshQueue.append(result)
    }

    func setUserInfoResult(_ result: Result<AntigravityUserInfo, AntigravityOAuthError>) {
        userInfoResult = result
    }

    func exchangeAuthorizationCode(
        _ request: AntigravityOAuthCodeExchange
    ) async throws -> AntigravityOAuthTokenResponse {
        exchangeRequests.append(request)
        guard !exchangeQueue.isEmpty else {
            throw AntigravityOAuthError.invalidResponse("No exchange response queued")
        }
        return try exchangeQueue.removeFirst().get()
    }

    func refreshToken(
        _ request: AntigravityOAuthRefreshRequest
    ) async throws -> AntigravityOAuthTokenResponse {
        refreshRequests.append(request)
        guard !refreshQueue.isEmpty else {
            throw AntigravityOAuthError.invalidResponse("No refresh response queued")
        }
        return try refreshQueue.removeFirst().get()
    }

    func userInfo(_ request: AntigravityUserInfoRequest) async throws -> AntigravityUserInfo {
        userInfoRequests.append(request)
        return try userInfoResult.get()
    }
}

@MainActor
final class MockAntigravityAuthorizationPresenter: AntigravityAuthorizationPresenting {
    var stateOverride: String?
    var errorToThrow: AntigravityOAuthError?
    var throwCancellationError = false
    var redirectURI = URL(string: "http://127.0.0.1:54321/")!
    var presentedURLs: [URL] = []

    func authorize(context: AntigravityAuthorizationContext) async throws -> URL {
        if throwCancellationError {
            throw CancellationError()
        }
        if let errorToThrow {
            throw errorToThrow
        }

        let url = try context.authorizationURL(redirectURI: redirectURI)
        presentedURLs.append(url)

        var components = URLComponents(url: redirectURI, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "google-auth-code-123"),
            URLQueryItem(name: "state", value: stateOverride ?? context.state),
        ]
        return components.url!
    }
}

// MARK: - Helpers

private func makeDefaults() -> UserDefaults {
    let suite = "AntigravityOAuthTests.\(UUID().uuidString)"
    return UserDefaults(suiteName: suite)!
}

private func makeTokenResponse(
    accessToken: String = "google-access-1",
    refreshToken: String? = "google-refresh-1",
    expiresIn: TimeInterval? = 3600,
    scope: String? = AntigravityOAuthConfiguration.verifiedScopes.joined(separator: " ")
) -> AntigravityOAuthTokenResponse {
    AntigravityOAuthTokenResponse(
        accessToken: accessToken,
        refreshToken: refreshToken,
        expiresIn: expiresIn,
        scope: scope,
        tokenType: "Bearer"
    )
}

// MARK: - Tests

final class AntigravityOAuthTests: XCTestCase {

    // MARK: Configuration and authorization URL

    func testDefaultConfigurationUsesVerifiedAntigravityClientAndScopes() {
        let configuration = AntigravityOAuthConfiguration.defaultConfiguration(bundle: .main)

        XCTAssertEqual(
            configuration.clientID,
            "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
        )
        XCTAssertEqual(
            configuration.scopeString,
            "https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/aicode"
        )
        XCTAssertTrue(configuration.isConfigured)
        XCTAssertEqual(configuration.authorizationEndpoint.host, "accounts.google.com")
        XCTAssertEqual(configuration.tokenEndpoint.host, "oauth2.googleapis.com")
        XCTAssertEqual(configuration.userInfoEndpoint.host, "www.googleapis.com")
    }

    func testAuthorizationURLContainsGoogleCodePKCEParameters() throws {
        let configuration = AntigravityOAuthConfiguration()
        let pkce = PKCE(codeVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let context = AntigravityAuthorizationContext(
            configuration: configuration,
            pkce: pkce,
            state: "google-state-abc"
        )
        let redirect = URL(string: "http://127.0.0.1:54321/")!

        let url = try context.authorizationURL(redirectURI: redirect)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "accounts.google.com")
        XCTAssertEqual(components.path, "/o/oauth2/v2/auth")
        XCTAssertEqual(query["response_type"], "code")
        XCTAssertEqual(query["client_id"], configuration.clientID)
        XCTAssertEqual(query["redirect_uri"], "http://127.0.0.1:54321/")
        XCTAssertEqual(query["scope"], configuration.scopeString)
        XCTAssertEqual(query["code_challenge"], "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["state"], "google-state-abc")
        XCTAssertEqual(query["access_type"], "offline")
        XCTAssertEqual(query["prompt"], "consent")
    }

    func testNotConfiguredConfigurationFailsWithPreciseMessage() async {
        let configuration = AntigravityOAuthConfiguration(clientID: "   ")
        let client = AntigravityOAuthClient(
            configuration: configuration,
            networking: MockAntigravityNetworking(),
            presenter: MockAntigravityAuthorizationPresenter()
        )

        do {
            _ = try await client.authorize()
            XCTFail("Expected authorization to fail without a client ID")
        } catch let error as AntigravityOAuthError {
            XCTAssertEqual(error, .notConfigured)
            XCTAssertEqual(error.userMessage, "Google OAuth is not configured.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCallbackParsingHandlesLoopbackRootPath() throws {
        let url = URL(string: "http://127.0.0.1:54321/?code=abc&state=xyz")!
        let callback = try AntigravityOAuthCallback(url: url)
        XCTAssertEqual(callback.code, "abc")
        XCTAssertEqual(callback.state, "xyz")
        XCTAssertNil(callback.error)

        let denied = try AntigravityOAuthCallback(
            url: URL(string: "http://127.0.0.1:54321/?error=access_denied&error_description=Denied")!
        )
        XCTAssertEqual(denied.error, "access_denied")
        XCTAssertEqual(denied.errorDescription, "Denied")
    }

    // MARK: Token parsing and refresh

    func testTokenResponseParsingSetsExpiryAndEmail() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tokens = try AntigravityTokens(
            response: makeTokenResponse(),
            email: "user@gmail.com",
            now: now
        )

        XCTAssertEqual(tokens.accessToken, "google-access-1")
        XCTAssertEqual(tokens.refreshToken, "google-refresh-1")
        XCTAssertEqual(tokens.tokenType, "Bearer")
        XCTAssertEqual(tokens.scope, AntigravityOAuthConfiguration.verifiedScopes.joined(separator: " "))
        XCTAssertEqual(tokens.email, "user@gmail.com")
        XCTAssertEqual(tokens.identifier, "user@gmail.com")
        XCTAssertEqual(tokens.expiresAt, now.addingTimeInterval(3600))
        XCTAssertFalse(tokens.isExpired(at: now.addingTimeInterval(3000)))
        XCTAssertTrue(tokens.isExpired(at: now.addingTimeInterval(3600 - 30)))
    }

    func testRefreshPreservesRefreshTokenAndEmailWhenOmitted() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let previous = AntigravityTokens(
            accessToken: "old",
            refreshToken: "refresh-old",
            expiresAt: now,
            scope: "old-scope",
            email: "user@gmail.com"
        )
        let response = AntigravityOAuthTokenResponse(
            accessToken: "new",
            refreshToken: nil,
            expiresIn: 1200,
            scope: nil,
            tokenType: "bearer"
        )

        let tokens = try AntigravityTokens(response: response, previous: previous, now: now)
        XCTAssertEqual(tokens.accessToken, "new")
        XCTAssertEqual(tokens.refreshToken, "refresh-old")
        XCTAssertEqual(tokens.scope, "old-scope")
        XCTAssertEqual(tokens.email, "user@gmail.com")
        XCTAssertEqual(tokens.expiresAt, now.addingTimeInterval(1200))
    }

    func testTokenResponseRejectsInvalidValues() {
        XCTAssertThrowsError(
            try AntigravityTokens(response: AntigravityOAuthTokenResponse(accessToken: "  "))
        )
        XCTAssertThrowsError(
            try AntigravityTokens(
                response: AntigravityOAuthTokenResponse(accessToken: "a", expiresIn: 0)
            )
        )
        XCTAssertThrowsError(
            try AntigravityTokens(
                response: AntigravityOAuthTokenResponse(accessToken: "a", tokenType: "mac")
            )
        )
    }

    func testTokenEndpointErrorParsingClassifiesInvalidGrant() {
        let flat = Data(#"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#.utf8)
        let parsed = URLSessionAntigravityOAuthNetworking.parseError(from: flat)
        XCTAssertEqual(parsed?.code, "invalid_grant")
        XCTAssertEqual(parsed?.message, "Token has been expired or revoked.")

        let nested = Data(
            #"{"error":{"code":"invalid_grant","message":"Bad refresh token"}}"#.utf8
        )
        let nestedParsed = URLSessionAntigravityOAuthNetworking.parseError(from: nested)
        XCTAssertEqual(nestedParsed?.code, "invalid_grant")
        XCTAssertEqual(nestedParsed?.message, "Bad refresh token")
    }

    func testTokensCodableRoundTrip() throws {
        let tokens = try AntigravityTokens(response: makeTokenResponse(), email: "user@gmail.com")
        let data = try JSONEncoder().encode(tokens)
        let decoded = try JSONDecoder().decode(AntigravityTokens.self, from: data)
        XCTAssertEqual(decoded, tokens)
    }

    // MARK: Client exchange

    @MainActor
    func testAuthorizeExchangesCodeWithPKCEAndPreservesLoopbackPort() async throws {
        let networking = MockAntigravityNetworking()
        await networking.enqueueExchange(.success(makeTokenResponse()))
        let presenter = MockAntigravityAuthorizationPresenter()
        presenter.redirectURI = URL(string: "http://127.0.0.1:61234/")!
        let client = AntigravityOAuthClient(networking: networking, presenter: presenter)

        let tokens = try await client.authorize()

        XCTAssertEqual(tokens.email, "user@gmail.com")
        let presented = try XCTUnwrap(presenter.presentedURLs.first)
        let challenge = URLComponents(url: presented, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code_challenge" })?.value

        let requests = await networking.exchangeRequests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.code, "google-auth-code-123")
        XCTAssertEqual(request.redirectURI.absoluteString, "http://127.0.0.1:61234/")
        XCTAssertEqual(request.configuration.clientID, AntigravityOAuthConfiguration.verifiedClientID)
        XCTAssertEqual(challenge, PKCE.challenge(for: request.codeVerifier))

        let userInfoRequests = await networking.userInfoRequests
        let userInfoRequest = try XCTUnwrap(userInfoRequests.first)
        XCTAssertEqual(userInfoRequest.accessToken, "google-access-1")
        XCTAssertEqual(userInfoRequest.endpoint.host, "www.googleapis.com")
    }

    @MainActor
    func testAuthorizeRejectsStateMismatchBeforeExchanging() async {
        let networking = MockAntigravityNetworking()
        let presenter = MockAntigravityAuthorizationPresenter()
        presenter.stateOverride = "not-the-state"
        let client = AntigravityOAuthClient(networking: networking, presenter: presenter)

        do {
            _ = try await client.authorize()
            XCTFail("Expected state mismatch")
        } catch let error as AntigravityOAuthError {
            XCTAssertEqual(error, .stateMismatch)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let exchanges = await networking.exchangeRequests
        XCTAssertTrue(exchanges.isEmpty)
    }

    // MARK: AuthManager transitions

    @MainActor
    func testSignInSuccessStoresTokensSeparatelyAndPopulatesIdentifier() async throws {
        let defaults = makeDefaults()
        let store = InMemoryAntigravityCredentialStore()
        let networking = MockAntigravityNetworking()
        await networking.enqueueExchange(.success(makeTokenResponse()))
        let presenter = MockAntigravityAuthorizationPresenter()
        let client = AntigravityOAuthClient(networking: networking, presenter: presenter)
        let auth = AuthManager(
            storage: defaults,
            antigravityCredentialStore: store,
            antigravityOAuthNetworking: networking
        )

        let success = await auth.signInWithGoogle(using: client)

        XCTAssertTrue(success)
        XCTAssertEqual(auth.antigravityAuthMethod, .google)
        XCTAssertTrue(auth.antigravityAuthState.isSignedIn)
        XCTAssertTrue(auth.antigravityCreds.isLoggedIn)
        XCTAssertEqual(auth.antigravityCreds.identifier, "user@gmail.com")
        XCTAssertEqual(auth.antigravityCreds.apiKey, "")

        let stored = try XCTUnwrap(try store.load())
        XCTAssertEqual(stored.accessToken, "google-access-1")
        XCTAssertEqual(stored.refreshToken, "google-refresh-1")
        XCTAssertEqual(stored.email, "user@gmail.com")

        // A second manager sees the Google session from the Keychain.
        let reloaded = AuthManager(
            storage: defaults,
            antigravityCredentialStore: store,
            antigravityOAuthNetworking: networking
        )
        XCTAssertEqual(reloaded.antigravityAuthMethod, .google)
        XCTAssertEqual(reloaded.antigravityCreds.identifier, "user@gmail.com")
    }

    @MainActor
    func testSignInCancellationDoesNotPersistCredentials() async throws {
        let defaults = makeDefaults()
        let store = InMemoryAntigravityCredentialStore()
        let networking = MockAntigravityNetworking()
        let presenter = MockAntigravityAuthorizationPresenter()
        presenter.errorToThrow = .cancelled
        let client = AntigravityOAuthClient(networking: networking, presenter: presenter)
        let auth = AuthManager(
            storage: defaults,
            antigravityCredentialStore: store,
            antigravityOAuthNetworking: networking
        )

        let success = await auth.signInWithGoogle(using: client)

        XCTAssertFalse(success)
        XCTAssertEqual(
            auth.antigravityAuthState,
            .failed(AntigravityOAuthError.cancelled.userMessage)
        )
        XCTAssertNil(try store.load())
    }

    @MainActor
    func testSignInMapsCancellationError() async throws {
        let defaults = makeDefaults()
        let store = InMemoryAntigravityCredentialStore()
        let networking = MockAntigravityNetworking()
        let presenter = MockAntigravityAuthorizationPresenter()
        presenter.throwCancellationError = true
        let client = AntigravityOAuthClient(networking: networking, presenter: presenter)
        let auth = AuthManager(
            storage: defaults,
            antigravityCredentialStore: store,
            antigravityOAuthNetworking: networking
        )

        let success = await auth.signInWithGoogle(using: client)

        XCTAssertFalse(success)
        XCTAssertEqual(
            auth.antigravityAuthState,
            .failed(AntigravityOAuthError.cancelled.userMessage)
        )
        XCTAssertNil(try store.load())
    }

    @MainActor
    func testSignInWithoutClientIDShowsPreciseConfigurationError() async throws {
        let defaults = makeDefaults()
        let store = InMemoryAntigravityCredentialStore()
        let networking = MockAntigravityNetworking()
        let client = AntigravityOAuthClient(
            configuration: AntigravityOAuthConfiguration(clientID: ""),
            networking: networking,
            presenter: MockAntigravityAuthorizationPresenter()
        )
        let auth = AuthManager(
            storage: defaults,
            antigravityCredentialStore: store,
            antigravityOAuthNetworking: networking
        )

        let success = await auth.signInWithGoogle(using: client)

        XCTAssertFalse(success)
        XCTAssertEqual(auth.antigravityAuthState, .failed("Google OAuth is not configured."))
        XCTAssertNil(try store.load())
    }

    @MainActor
    func testSignInTokenExchangeFailureDoesNotPersistCredentials() async throws {
        let defaults = makeDefaults()
        let store = InMemoryAntigravityCredentialStore()
        let networking = MockAntigravityNetworking()
        await networking.enqueueExchange(
            .failure(.tokenExchangeFailed(statusCode: 400, message: "invalid_grant: bad code"))
        )
        let client = AntigravityOAuthClient(
            networking: networking,
            presenter: MockAntigravityAuthorizationPresenter()
        )
        let auth = AuthManager(
            storage: defaults,
            antigravityCredentialStore: store,
            antigravityOAuthNetworking: networking
        )

        let success = await auth.signInWithGoogle(using: client)

        XCTAssertFalse(success)
        XCTAssertEqual(auth.antigravityAuthMethod, .apiKey)
        XCTAssertNil(try store.load())
        guard case .failed(let message) = auth.antigravityAuthState else {
            return XCTFail("Expected failed state")
        }
        XCTAssertTrue(message.contains("HTTP 400"))
    }

    @MainActor
    func testRefreshReplacesExpiredAccessToken() async throws {
        let defaults = makeDefaults()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let expired = AntigravityTokens(
            accessToken: "expired-access",
            refreshToken: "refresh-old",
            expiresAt: now.addingTimeInterval(-10),
            email: "user@gmail.com"
        )
        let store = InMemoryAntigravityCredentialStore(tokens: expired)
        let networking = MockAntigravityNetworking()
        await networking.enqueueRefresh(
            .success(makeTokenResponse(accessToken: "fresh-access", refreshToken: "refresh-new"))
        )
        let auth = AuthManager(
            storage: defaults,
            antigravityCredentialStore: store,
            antigravityOAuthNetworking: networking
        )

        let refreshed = try await auth.refreshAntigravityTokensIfNeeded(now: now)

        XCTAssertEqual(refreshed.accessToken, "fresh-access")
        XCTAssertEqual(refreshed.refreshToken, "refresh-new")
        XCTAssertEqual(refreshed.email, "user@gmail.com")
        XCTAssertEqual(try store.load()?.accessToken, "fresh-access")
        XCTAssertEqual(try store.load()?.refreshToken, "refresh-new")
        XCTAssertTrue(auth.antigravityAuthState.isSignedIn)
        XCTAssertEqual(auth.antigravityCreds.identifier, "user@gmail.com")

        let requests = await networking.refreshRequests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.refreshToken, "refresh-old")
        XCTAssertEqual(request.configuration.clientID, AntigravityOAuthConfiguration.verifiedClientID)
    }

    @MainActor
    func testRefreshSkipsValidToken() async throws {
        let defaults = makeDefaults()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let valid = AntigravityTokens(
            accessToken: "still-good",
            refreshToken: "refresh",
            expiresAt: now.addingTimeInterval(3600)
        )
        let store = InMemoryAntigravityCredentialStore(tokens: valid)
        let networking = MockAntigravityNetworking()
        let auth = AuthManager(
            storage: defaults,
            antigravityCredentialStore: store,
            antigravityOAuthNetworking: networking
        )

        let token = try await auth.antigravityAccessToken(now: now)

        XCTAssertEqual(token, "still-good")
        let refreshes = await networking.refreshRequests
        XCTAssertTrue(refreshes.isEmpty)
    }

    @MainActor
    func testInvalidGrantRefreshSignsOutAndClearsKeychain() async throws {
        let defaults = makeDefaults()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let expired = AntigravityTokens(
            accessToken: "expired",
            refreshToken: "revoked",
            expiresAt: now.addingTimeInterval(-10)
        )
        let store = InMemoryAntigravityCredentialStore(tokens: expired)
        let networking = MockAntigravityNetworking()
        await networking.enqueueRefresh(.failure(.invalidGrant("invalid_grant")))
        let auth = AuthManager(
            storage: defaults,
            antigravityCredentialStore: store,
            antigravityOAuthNetworking: networking
        )

        do {
            _ = try await auth.refreshAntigravityTokensIfNeeded(now: now)
            XCTFail("Expected refresh to fail")
        } catch let error as AntigravityOAuthError {
            guard case .invalidGrant = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertNil(try store.load())
        XCTAssertEqual(auth.antigravityAuthState, .signedOut)
        XCTAssertEqual(auth.antigravityAuthMethod, .apiKey)
        XCTAssertFalse(auth.antigravityCreds.isLoggedIn)
    }

    @MainActor
    func testLogoutClearsGoogleSession() async throws {
        let defaults = makeDefaults()
        let store = InMemoryAntigravityCredentialStore()
        let networking = MockAntigravityNetworking()
        await networking.enqueueExchange(.success(makeTokenResponse()))
        let client = AntigravityOAuthClient(
            networking: networking,
            presenter: MockAntigravityAuthorizationPresenter()
        )
        let auth = AuthManager(
            storage: defaults,
            antigravityCredentialStore: store,
            antigravityOAuthNetworking: networking
        )

        let signedIn = await auth.signInWithGoogle(using: client)
        XCTAssertTrue(signedIn)
        XCTAssertNotNil(try store.load())

        auth.logout(type: .antigravity)

        XCTAssertEqual(auth.antigravityAuthState, .signedOut)
        XCTAssertEqual(auth.antigravityAuthMethod, .apiKey)
        XCTAssertNil(try store.load())
        XCTAssertFalse(auth.antigravityCreds.isLoggedIn)
        XCTAssertEqual(auth.antigravityCreds.identifier, "")
    }

    @MainActor
    func testManualLoginTakesPrecedenceOverGoogleWithoutDeletingTokens() async throws {
        let defaults = makeDefaults()
        let store = InMemoryAntigravityCredentialStore()
        let networking = MockAntigravityNetworking()
        await networking.enqueueExchange(.success(makeTokenResponse()))
        let client = AntigravityOAuthClient(
            networking: networking,
            presenter: MockAntigravityAuthorizationPresenter()
        )
        let auth = AuthManager(
            storage: defaults,
            antigravityCredentialStore: store,
            antigravityOAuthNetworking: networking
        )

        let signedIn = await auth.signInWithGoogle(using: client)
        XCTAssertTrue(signedIn)
        XCTAssertTrue(auth.login(type: .antigravity, apiKey: "ag-manual", identifier: "manual@example.com"))

        XCTAssertEqual(auth.antigravityAuthMethod, .apiKey)
        XCTAssertEqual(auth.antigravityAuthState, .signedOut)
        XCTAssertEqual(auth.antigravityCreds.apiKey, "ag-manual")
        XCTAssertEqual(auth.antigravityCreds.identifier, "manual@example.com")
        // The secure item is ignored while the persisted method is apiKey.
        XCTAssertNotNil(try store.load())

        do {
            _ = try await auth.antigravityAccessToken()
            XCTFail("Manual login should not expose the stale Google access token")
        } catch let error as AntigravityOAuthError {
            XCTAssertEqual(error, .notSignedIn)
        }
    }
}
