import XCTest
@testable import slopWidget

// MARK: - Test doubles

actor DelayRecorder {
    private(set) var delays: [TimeInterval] = []

    func record(_ delay: TimeInterval) {
        delays.append(delay)
    }
}

/// Deterministic clock so the polling loop never touches real time.
final class OpenCodeFakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        date = date.addingTimeInterval(seconds)
        lock.unlock()
    }
}

actor MockOpenCodeNetworking: OpenCodeOAuthNetworking {
    private var deviceQueue: [Result<OpenCodeDeviceCode, OpenCodeOAuthError>] = []
    private var pollQueue: [Result<OpenCodeOAuthTokenResponse, OpenCodeOAuthError>] = []
    private var refreshQueue: [Result<OpenCodeOAuthTokenResponse, OpenCodeOAuthError>] = []
    private var userQueue: [Result<OpenCodeUser, OpenCodeOAuthError>] = []
    private var organizationQueue: [Result<[OpenCodeOrganization], OpenCodeOAuthError>] = []

    private(set) var deviceRequests: [OpenCodeDeviceCodeRequest] = []
    private(set) var pollRequests: [OpenCodeDeviceTokenPollRequest] = []
    private(set) var refreshRequests: [OpenCodeRefreshRequest] = []
    private(set) var identityCalls: [(token: String, endpoint: URL)] = []

    func enqueueDevice(_ result: Result<OpenCodeDeviceCode, OpenCodeOAuthError>) {
        deviceQueue.append(result)
    }

    func enqueuePoll(_ result: Result<OpenCodeOAuthTokenResponse, OpenCodeOAuthError>) {
        pollQueue.append(result)
    }

    func enqueueRefresh(_ result: Result<OpenCodeOAuthTokenResponse, OpenCodeOAuthError>) {
        refreshQueue.append(result)
    }

    func enqueueUser(_ result: Result<OpenCodeUser, OpenCodeOAuthError>) {
        userQueue.append(result)
    }

    func enqueueOrganizations(_ result: Result<[OpenCodeOrganization], OpenCodeOAuthError>) {
        organizationQueue.append(result)
    }

    func requestDeviceCode(_ request: OpenCodeDeviceCodeRequest) async throws -> OpenCodeDeviceCode {
        deviceRequests.append(request)
        guard !deviceQueue.isEmpty else {
            throw OpenCodeOAuthError.invalidResponse("No device response queued")
        }
        return try deviceQueue.removeFirst().get()
    }

    func pollDeviceToken(_ request: OpenCodeDeviceTokenPollRequest) async throws -> OpenCodeOAuthTokenResponse {
        pollRequests.append(request)
        guard !pollQueue.isEmpty else {
            throw OpenCodeOAuthError.invalidResponse("No poll response queued")
        }
        return try pollQueue.removeFirst().get()
    }

    func refreshToken(_ request: OpenCodeRefreshRequest) async throws -> OpenCodeOAuthTokenResponse {
        refreshRequests.append(request)
        guard !refreshQueue.isEmpty else {
            throw OpenCodeOAuthError.invalidResponse("No refresh response queued")
        }
        return try refreshQueue.removeFirst().get()
    }

    func fetchUser(accessToken: String, configuration: OpenCodeOAuthConfiguration) async throws -> OpenCodeUser {
        identityCalls.append((accessToken, configuration.userEndpoint))
        guard !userQueue.isEmpty else {
            throw OpenCodeOAuthError.invalidResponse("No user response queued")
        }
        return try userQueue.removeFirst().get()
    }

    func fetchOrganizations(
        accessToken: String,
        configuration: OpenCodeOAuthConfiguration
    ) async throws -> [OpenCodeOrganization] {
        identityCalls.append((accessToken, configuration.organizationsEndpoint))
        guard !organizationQueue.isEmpty else {
            throw OpenCodeOAuthError.invalidResponse("No organizations response queued")
        }
        return try organizationQueue.removeFirst().get()
    }
}

@MainActor
final class MockOpenCodePresenter: OpenCodeDeviceAuthorizationPresenting {
    var presentedURLs: [URL] = []
    var dismissCount = 0
    var errorToThrow: OpenCodeOAuthError?
    var onPresent: (@MainActor () -> Void)?

    func present(verificationURL: URL) async throws {
        onPresent?()
        if let errorToThrow { throw errorToThrow }
        presentedURLs.append(verificationURL)
    }

    func dismiss() async {
        dismissCount += 1
    }
}

// MARK: - Helpers

private let openCodeTestServer = URL(string: "https://opencode.ai/console")!
private let openCodeTestNow = Date(timeIntervalSince1970: 1_700_000_000)

private func makeOpenCodeDefaults() -> UserDefaults {
    UserDefaults(suiteName: "OpenCodeOAuthTests.\(UUID().uuidString)")!
}

private func makeDeviceCode(
    userCode: String = "ABCD-EFGH",
    expiresIn: TimeInterval = 600,
    interval: TimeInterval = 5
) -> OpenCodeDeviceCode {
    OpenCodeDeviceCode(
        deviceCode: "device-code-123",
        userCode: userCode,
        verificationURL: URL(
            string: "https://opencode.ai/console/device?user_code=ABCD-EFGH&client_id=opencode-cli"
        )!,
        expiresIn: expiresIn,
        interval: interval
    )
}

private func makeTokenResponse(
    accessToken: String = "st_access_1",
    refreshToken: String? = "rt_refresh_1",
    expiresIn: TimeInterval? = 3600,
    orgID: String? = "org_personal"
) -> OpenCodeOAuthTokenResponse {
    OpenCodeOAuthTokenResponse(
        accessToken: accessToken,
        refreshToken: refreshToken,
        expiresIn: expiresIn,
        orgID: orgID
    )
}

private func makeStoredTokens(
    accessToken: String = "st_access_1",
    refreshToken: String? = "rt_refresh_1",
    expiresAt: Date? = openCodeTestNow.addingTimeInterval(3600)
) -> OpenCodeTokens {
    OpenCodeTokens(
        accessToken: accessToken,
        refreshToken: refreshToken,
        expiresAt: expiresAt,
        server: openCodeTestServer,
        accountID: "user_123",
        email: "dev@example.com",
        orgID: "org_personal",
        orgName: "Personal"
    )
}

/// Wires a client with no real sleeping and a fixed clock.
private func makeClient(
    networking: MockOpenCodeNetworking,
    presenter: MockOpenCodePresenter,
    clock: OpenCodeFakeClock,
    delays: DelayRecorder
) -> OpenCodeOAuthClient {
    OpenCodeOAuthClient(
        configuration: OpenCodeOAuthConfiguration(server: openCodeTestServer),
        networking: networking,
        presenter: presenter,
        sleeper: { seconds in
            clock.advance(seconds)
            await delays.record(seconds)
        },
        now: { clock.now }
    )
}

// MARK: - Configuration and request construction

final class OpenCodeOAuthRequestTests: XCTestCase {

    func testConfigurationEndpointsMatchCLI() {
        let configuration = OpenCodeOAuthConfiguration()
        XCTAssertEqual(configuration.server.absoluteString, "https://opencode.ai/console")
        XCTAssertEqual(configuration.clientID, "opencode-cli")
        XCTAssertTrue(configuration.supportsOrgScope)
        XCTAssertEqual(
            configuration.deviceCodeEndpoint.absoluteString,
            "https://opencode.ai/console/auth/device/code"
        )
        XCTAssertEqual(
            configuration.deviceTokenEndpoint.absoluteString,
            "https://opencode.ai/console/auth/device/token"
        )
        XCTAssertEqual(configuration.userEndpoint.absoluteString, "https://opencode.ai/console/api/user")
        XCTAssertEqual(
            configuration.organizationsEndpoint.absoluteString,
            "https://opencode.ai/console/api/orgs"
        )
    }

    func testConfigurationSupportsSelfHostedServerPath() {
        let configuration = OpenCodeOAuthConfiguration()
            .withServer(URL(string: "https://opencode.internal/console/")!)
        XCTAssertEqual(
            configuration.deviceCodeEndpoint.absoluteString,
            "https://opencode.internal/console/auth/device/code"
        )
    }

    func testDeviceCodeRequestMatchesCLIWireFormat() throws {
        let request = try OpenCodeOAuthRequestBuilder.deviceCodeRequest(
            OpenCodeDeviceCodeRequest(configuration: OpenCodeOAuthConfiguration())
        )

        XCTAssertEqual(request.url?.absoluteString, "https://opencode.ai/console/auth/device/code")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.contains("opencode") == true)

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["client_id"] as? String, "opencode-cli")
        XCTAssertEqual(json["supports_org_scope"] as? Bool, true)
        XCTAssertEqual(json.count, 2)
    }

    func testDeviceTokenPollRequestMatchesCLIWireFormat() throws {
        let request = try OpenCodeOAuthRequestBuilder.deviceTokenPollRequest(
            OpenCodeDeviceTokenPollRequest(
                configuration: OpenCodeOAuthConfiguration(),
                deviceCode: "device-code-123"
            )
        )

        XCTAssertEqual(request.url?.absoluteString, "https://opencode.ai/console/auth/device/token")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(
            json["grant_type"] as? String,
            "urn:ietf:params:oauth:grant-type:device_code"
        )
        XCTAssertEqual(json["device_code"] as? String, "device-code-123")
        XCTAssertEqual(json["client_id"] as? String, "opencode-cli")
    }

    func testRefreshRequestMatchesCLIWireFormat() throws {
        let request = try OpenCodeOAuthRequestBuilder.refreshRequest(
            OpenCodeRefreshRequest(
                configuration: OpenCodeOAuthConfiguration(),
                refreshToken: "rt_refresh_1"
            )
        )

        XCTAssertEqual(request.url?.absoluteString, "https://opencode.ai/console/auth/device/token")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["grant_type"] as? String, "refresh_token")
        XCTAssertEqual(json["refresh_token"] as? String, "rt_refresh_1")
        XCTAssertEqual(json["client_id"] as? String, "opencode-cli")
    }

    func testIdentityRequestsCarryBearerToken() throws {
        let configuration = OpenCodeOAuthConfiguration()
        let user = try OpenCodeOAuthRequestBuilder.userRequest(
            accessToken: "st_access_1",
            configuration: configuration
        )
        let orgs = try OpenCodeOAuthRequestBuilder.organizationsRequest(
            accessToken: "st_access_1",
            configuration: configuration
        )

        for request in [user, orgs] {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer st_access_1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        }
        XCTAssertEqual(user.url?.absoluteString, "https://opencode.ai/console/api/user")
        XCTAssertEqual(orgs.url?.absoluteString, "https://opencode.ai/console/api/orgs")
    }

    func testDeviceCodePayloadResolvesRelativeVerificationURL() throws {
        let payload = OpenCodeDeviceCodePayload(
            deviceCode: " device-1 ",
            userCode: " CODE-1 ",
            verificationURI: "/console/device",
            verificationURIComplete: "/console/device?user_code=CODE-1&client_id=opencode-cli",
            expiresIn: 600,
            interval: 5
        )

        let code = try OpenCodeDeviceCode(payload: payload, server: openCodeTestServer)
        XCTAssertEqual(code.deviceCode, "device-1")
        XCTAssertEqual(code.userCode, "CODE-1")
        XCTAssertEqual(
            code.verificationURL.absoluteString,
            "https://opencode.ai/console/device?user_code=CODE-1&client_id=opencode-cli"
        )
        XCTAssertEqual(code.expiresIn, 600)
        XCTAssertEqual(code.interval, 5)
    }

    func testDeviceCodePayloadRejectsMissingURL() {
        let payload = OpenCodeDeviceCodePayload(deviceCode: "d", userCode: "u")
        XCTAssertThrowsError(try OpenCodeDeviceCode(payload: payload, server: openCodeTestServer))
    }

    func testErrorParsingHandlesOpenCodeShape() {
        let pending = Data(
            #"{"_tag":"DeviceTokenError","error":"authorization_pending","error_description":"The authorization request is still pending"}"#.utf8
        )
        let parsed = URLSessionOpenCodeOAuthNetworking.parseError(from: pending)
        XCTAssertEqual(parsed.code, "authorization_pending")
        XCTAssertEqual(parsed.message, "The authorization request is still pending")

        let invalidGrant = Data(
            #"{"_tag":"DeviceTokenError","error":"invalid_grant","error_description":"The grant is invalid"}"#.utf8
        )
        let invalid = URLSessionOpenCodeOAuthNetworking.parseError(from: invalidGrant)
        XCTAssertEqual(invalid.code, "invalid_grant")
        XCTAssertEqual(invalid.message, "The grant is invalid")
    }
}

// MARK: - Tokens

final class OpenCodeTokenTests: XCTestCase {

    func testTokenParsingSelectsRequestedOrganization() throws {
        let organizations = [
            OpenCodeOrganization(id: "org_team", name: "Team"),
            OpenCodeOrganization(id: "org_personal", name: "Personal"),
        ]
        let tokens = try OpenCodeTokens(
            response: makeTokenResponse(orgID: "org_personal"),
            user: OpenCodeUser(id: "user_123", email: "dev@example.com"),
            organizations: organizations,
            server: openCodeTestServer,
            now: openCodeTestNow
        )

        XCTAssertEqual(tokens.accessToken, "st_access_1")
        XCTAssertEqual(tokens.refreshToken, "rt_refresh_1")
        XCTAssertEqual(tokens.identifier, "dev@example.com")
        XCTAssertEqual(tokens.accountID, "user_123")
        XCTAssertEqual(tokens.orgID, "org_personal")
        XCTAssertEqual(tokens.orgName, "Personal")
        XCTAssertEqual(tokens.expiresAt, openCodeTestNow.addingTimeInterval(3600))
        XCTAssertFalse(tokens.isExpired(at: openCodeTestNow.addingTimeInterval(3000)))
        XCTAssertTrue(tokens.isExpired(at: openCodeTestNow.addingTimeInterval(3600 - 30)))
    }

    func testTokenParsingFallsBackToAlphabeticallyFirstOrganization() throws {
        let tokens = try OpenCodeTokens(
            response: makeTokenResponse(orgID: nil),
            user: OpenCodeUser(id: "user_123", email: "dev@example.com"),
            organizations: [
                OpenCodeOrganization(id: "org_b", name: "Zeta"),
                OpenCodeOrganization(id: "org_a", name: "Alpha"),
            ],
            server: openCodeTestServer,
            now: openCodeTestNow
        )

        XCTAssertEqual(tokens.orgID, "org_a")
        XCTAssertEqual(tokens.orgName, "Alpha")
    }

    func testTokenParsingRejectsMissingOrganization() {
        XCTAssertThrowsError(
            try OpenCodeTokens(
                response: makeTokenResponse(orgID: "org_missing"),
                user: OpenCodeUser(id: "user_123"),
                organizations: [OpenCodeOrganization(id: "org_a", name: "Alpha")],
                server: openCodeTestServer,
                now: openCodeTestNow
            )
        )
    }

    func testTokenParsingRejectsInvalidValues() {
        XCTAssertThrowsError(
            try OpenCodeTokens(
                response: makeTokenResponse(accessToken: "  "),
                user: nil,
                organizations: [],
                server: openCodeTestServer
            )
        )
        XCTAssertThrowsError(
            try OpenCodeTokens(
                response: makeTokenResponse(expiresIn: 0),
                user: nil,
                organizations: [],
                server: openCodeTestServer
            )
        )
    }

    func testRefreshResponsePreservesIdentityAndRotatesTokens() throws {
        let previous = makeStoredTokens()
        let refreshed = try OpenCodeTokens(
            refreshResponse: makeTokenResponse(
                accessToken: "st_access_2",
                refreshToken: "rt_refresh_2",
                expiresIn: 7200,
                orgID: nil
            ),
            previous: previous,
            now: openCodeTestNow
        )

        XCTAssertEqual(refreshed.accessToken, "st_access_2")
        XCTAssertEqual(refreshed.refreshToken, "rt_refresh_2")
        XCTAssertEqual(refreshed.email, "dev@example.com")
        XCTAssertEqual(refreshed.orgID, "org_personal")
        XCTAssertEqual(refreshed.orgName, "Personal")
        XCTAssertEqual(refreshed.expiresAt, openCodeTestNow.addingTimeInterval(7200))
    }

    func testTokensCodableRoundTrip() throws {
        let tokens = makeStoredTokens()
        let data = try JSONEncoder().encode(tokens)
        let decoded = try JSONDecoder().decode(OpenCodeTokens.self, from: data)
        XCTAssertEqual(decoded, tokens)
    }
}

// MARK: - Device flow client

final class OpenCodeDeviceFlowTests: XCTestCase {

    @MainActor
    func testSignInPollsUntilApprovedAndResolvesIdentity() async throws {
        let networking = MockOpenCodeNetworking()
        await networking.enqueueDevice(.success(makeDeviceCode()))
        await networking.enqueuePoll(.failure(.authorizationPending))
        await networking.enqueuePoll(.failure(.authorizationPending))
        await networking.enqueuePoll(.success(makeTokenResponse(orgID: "org_personal")))
        await networking.enqueueUser(.success(OpenCodeUser(id: "user_123", email: "dev@example.com")))
        await networking.enqueueOrganizations(.success([
            OpenCodeOrganization(id: "org_personal", name: "Personal"),
            OpenCodeOrganization(id: "org_team", name: "Team"),
        ]))

        let presenter = MockOpenCodePresenter()
        let clock = OpenCodeFakeClock(openCodeTestNow)
        let delays = DelayRecorder()
        let client = makeClient(networking: networking, presenter: presenter, clock: clock, delays: delays)

        var codes: [OpenCodeDeviceCode] = []
        let tokens = try await client.signIn { codes.append($0) }

        XCTAssertEqual(codes.count, 1)
        XCTAssertEqual(codes.first?.userCode, "ABCD-EFGH")
        XCTAssertEqual(presenter.presentedURLs.first, codes.first?.verificationURL)
        XCTAssertEqual(presenter.dismissCount, 1)
        XCTAssertEqual(tokens.accessToken, "st_access_1")
        XCTAssertEqual(tokens.email, "dev@example.com")
        XCTAssertEqual(tokens.orgID, "org_personal")
        XCTAssertEqual(tokens.orgName, "Personal")
        XCTAssertEqual(tokens.expiresAt, clock.now.addingTimeInterval(3600))

        let recordedDelays = await delays.delays
        XCTAssertEqual(recordedDelays, [5, 5, 5])

        let polls = await networking.pollRequests
        XCTAssertEqual(polls.count, 3)
        XCTAssertEqual(polls.first?.deviceCode, "device-code-123")
        XCTAssertEqual(polls.first?.configuration.clientID, "opencode-cli")
        let calls = await networking.identityCalls
        XCTAssertEqual(Set(calls.map { $0.token }), ["st_access_1"])
        XCTAssertEqual(
            Set(calls.map { $0.endpoint.absoluteString }),
            [
                "https://opencode.ai/console/api/user",
                "https://opencode.ai/console/api/orgs",
            ]
        )
    }

    @MainActor
    func testSlowDownIncreasesPollingInterval() async throws {
        let networking = MockOpenCodeNetworking()
        await networking.enqueueDevice(.success(makeDeviceCode()))
        await networking.enqueuePoll(.failure(.slowDown))
        await networking.enqueuePoll(.success(makeTokenResponse()))
        await networking.enqueueUser(.success(OpenCodeUser(id: "user_123", email: "dev@example.com")))
        await networking.enqueueOrganizations(.success([
            OpenCodeOrganization(id: "org_personal", name: "Personal"),
        ]))

        let presenter = MockOpenCodePresenter()
        let clock = OpenCodeFakeClock(openCodeTestNow)
        let delays = DelayRecorder()
        let client = makeClient(networking: networking, presenter: presenter, clock: clock, delays: delays)

        _ = try await client.signIn()

        let recordedDelays = await delays.delays
        XCTAssertEqual(recordedDelays, [5, 10])
        XCTAssertEqual(presenter.dismissCount, 1)
    }

    @MainActor
    func testExpiredDeviceCodeStopsPollingAndDismisses() async throws {
        let networking = MockOpenCodeNetworking()
        await networking.enqueueDevice(.success(makeDeviceCode(expiresIn: 3, interval: 5)))
        await networking.enqueuePoll(.failure(.authorizationPending))

        let presenter = MockOpenCodePresenter()
        let clock = OpenCodeFakeClock(openCodeTestNow)
        let delays = DelayRecorder()
        let client = makeClient(networking: networking, presenter: presenter, clock: clock, delays: delays)

        do {
            _ = try await client.signIn()
            XCTFail("Expected the device code to expire")
        } catch let error as OpenCodeOAuthError {
            XCTAssertEqual(error, .expiredToken)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let polls = await networking.pollRequests
        XCTAssertTrue(polls.isEmpty)
        XCTAssertEqual(presenter.dismissCount, 1)
    }

    @MainActor
    func testAccessDeniedSurfacesAndDismisses() async throws {
        let networking = MockOpenCodeNetworking()
        await networking.enqueueDevice(.success(makeDeviceCode()))
        await networking.enqueuePoll(.failure(.accessDenied))

        let presenter = MockOpenCodePresenter()
        let clock = OpenCodeFakeClock(openCodeTestNow)
        let delays = DelayRecorder()
        let client = makeClient(networking: networking, presenter: presenter, clock: clock, delays: delays)

        do {
            _ = try await client.signIn()
            XCTFail("Expected access denied")
        } catch let error as OpenCodeOAuthError {
            XCTAssertEqual(error, .accessDenied)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(presenter.dismissCount, 1)
    }

    @MainActor
    func testBrowserFailureDoesNotAbortDeviceFlow() async throws {
        let networking = MockOpenCodeNetworking()
        await networking.enqueueDevice(.success(makeDeviceCode()))
        await networking.enqueuePoll(.success(makeTokenResponse()))
        await networking.enqueueUser(.success(OpenCodeUser(id: "user_123", email: "dev@example.com")))
        await networking.enqueueOrganizations(.success([
            OpenCodeOrganization(id: "org_personal", name: "Personal"),
        ]))

        let presenter = MockOpenCodePresenter()
        presenter.errorToThrow = .browserFailed("no window")
        let clock = OpenCodeFakeClock(openCodeTestNow)
        let delays = DelayRecorder()
        let client = makeClient(networking: networking, presenter: presenter, clock: clock, delays: delays)

        let tokens = try await client.signIn()
        XCTAssertEqual(tokens.accessToken, "st_access_1")
        XCTAssertEqual(presenter.dismissCount, 1)
    }

    func testRefreshRotatesTokensWithoutIdentityLookup() async throws {
        let networking = MockOpenCodeNetworking()
        await networking.enqueueRefresh(.success(
            makeTokenResponse(accessToken: "st_access_2", refreshToken: nil, expiresIn: 1200, orgID: nil)
        ))
        let presenter = MockOpenCodePresenter()
        let clock = OpenCodeFakeClock(openCodeTestNow)
        let delays = DelayRecorder()
        let client = makeClient(networking: networking, presenter: presenter, clock: clock, delays: delays)

        let refreshed = try await client.refresh(makeStoredTokens())

        XCTAssertEqual(refreshed.accessToken, "st_access_2")
        XCTAssertEqual(refreshed.refreshToken, "rt_refresh_1")
        XCTAssertEqual(refreshed.email, "dev@example.com")
        XCTAssertEqual(refreshed.expiresAt, openCodeTestNow.addingTimeInterval(1200))

        let requests = await networking.refreshRequests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.refreshToken, "rt_refresh_1")
        XCTAssertEqual(requests.first?.configuration.clientID, "opencode-cli")
        let calls = await networking.identityCalls
        XCTAssertTrue(calls.isEmpty)
    }

    @MainActor
    func testCancellationDuringPollMapsToCancelledAndDismisses() async throws {
        let networking = MockOpenCodeNetworking()
        await networking.enqueueDevice(.success(makeDeviceCode()))
        let presenter = MockOpenCodePresenter()
        let client = OpenCodeOAuthClient(
            configuration: OpenCodeOAuthConfiguration(server: openCodeTestServer),
            networking: networking,
            presenter: presenter,
            sleeper: { _ in throw CancellationError() },
            now: { openCodeTestNow }
        )

        do {
            _ = try await client.signIn()
            XCTFail("Expected cancellation")
        } catch let error as OpenCodeOAuthError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(presenter.dismissCount, 1)
        let polls = await networking.pollRequests
        XCTAssertTrue(polls.isEmpty)
    }

    func testRefreshRequiresRefreshToken() async {
        let networking = MockOpenCodeNetworking()
        let presenter = MockOpenCodePresenter()
        let client = makeClient(
            networking: networking,
            presenter: presenter,
            clock: OpenCodeFakeClock(openCodeTestNow),
            delays: DelayRecorder()
        )
        let tokens = makeStoredTokens(refreshToken: nil)

        do {
            _ = try await client.refresh(tokens)
            XCTFail("Expected missing refresh token")
        } catch let error as OpenCodeOAuthError {
            XCTAssertEqual(error, .missingRefreshToken)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

// MARK: - AuthManager state transitions

final class OpenCodeAuthManagerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AuthManager.resetDefaults()
    }

    override func tearDown() {
        AuthManager.resetDefaults()
        super.tearDown()
    }

    @MainActor
    private func makeSuccessFixture(
        defaults: UserDefaults
    ) async -> (auth: AuthManager, client: OpenCodeOAuthClient, store: InMemoryOpenCodeCredentialStore, networking: MockOpenCodeNetworking) {
        let store = InMemoryOpenCodeCredentialStore()
        let networking = MockOpenCodeNetworking()
        await networking.enqueueDevice(.success(makeDeviceCode()))
        await networking.enqueuePoll(.success(makeTokenResponse()))
        await networking.enqueueUser(.success(OpenCodeUser(id: "user_123", email: "dev@example.com")))
        await networking.enqueueOrganizations(.success([
            OpenCodeOrganization(id: "org_personal", name: "Personal"),
        ]))
        let presenter = MockOpenCodePresenter()
        let clock = OpenCodeFakeClock(openCodeTestNow)
        let client = makeClient(
            networking: networking,
            presenter: presenter,
            clock: clock,
            delays: DelayRecorder()
        )
        let auth = AuthManager(
            storage: defaults,
            chatGPTCredentialStore: InMemoryChatGPTCredentialStore(),
            chatGPTOAuthNetworking: MockChatGPTNetworking(),
            openCodeCredentialStore: store,
            openCodeOAuthNetworking: networking
        )
        return (auth, client, store, networking)
    }

    @MainActor
    func testSignInStoresTokensAndPopulatesIdentifier() async throws {
        let defaults = makeOpenCodeDefaults()
        let fixture = await makeSuccessFixture(defaults: defaults)

        let success = await fixture.auth.signInWithOpenCode(using: fixture.client)

        XCTAssertTrue(success)
        XCTAssertEqual(fixture.auth.openCodeAuthMethod, .oauth)
        XCTAssertTrue(fixture.auth.openCodeAuthState.isSignedIn)
        XCTAssertTrue(fixture.auth.opencodeGoCreds.isLoggedIn)
        XCTAssertEqual(fixture.auth.opencodeGoCreds.identifier, "dev@example.com")
        XCTAssertEqual(fixture.auth.opencodeGoCreds.apiKey, "")

        let stored = try XCTUnwrap(try fixture.store.load())
        XCTAssertEqual(stored.accessToken, "st_access_1")
        XCTAssertEqual(stored.refreshToken, "rt_refresh_1")
        XCTAssertEqual(stored.email, "dev@example.com")
        XCTAssertEqual(stored.orgName, "Personal")
        XCTAssertEqual(stored.server, openCodeTestServer)
    }

    @MainActor
    func testSignInExposesDeviceCodeWhileWaiting() async throws {
        let defaults = makeOpenCodeDefaults()
        let store = InMemoryOpenCodeCredentialStore()
        let networking = MockOpenCodeNetworking()
        await networking.enqueueDevice(.success(makeDeviceCode()))
        await networking.enqueuePoll(.success(makeTokenResponse()))
        await networking.enqueueUser(.success(OpenCodeUser(id: "user_123", email: "dev@example.com")))
        await networking.enqueueOrganizations(.success([
            OpenCodeOrganization(id: "org_personal", name: "Personal"),
        ]))
        let auth = AuthManager(
            storage: defaults,
            chatGPTCredentialStore: InMemoryChatGPTCredentialStore(),
            chatGPTOAuthNetworking: MockChatGPTNetworking(),
            openCodeCredentialStore: store,
            openCodeOAuthNetworking: networking
        )
        let presenter = MockOpenCodePresenter()
        let clock = OpenCodeFakeClock(openCodeTestNow)
        let client = makeClient(
            networking: networking,
            presenter: presenter,
            clock: clock,
            delays: DelayRecorder()
        )

        var observed: [OpenCodeAuthState] = []
        presenter.onPresent = { [weak auth] in
            if let state = auth?.openCodeAuthState { observed.append(state) }
        }

        let success = await auth.signInWithOpenCode(using: client)
        XCTAssertTrue(success)
        XCTAssertEqual(observed.count, 1)
        let waiting = try XCTUnwrap(observed.first)
        XCTAssertEqual(waiting.userCode, "ABCD-EFGH")
        XCTAssertEqual(
            waiting.verificationURL?.absoluteString,
            "https://opencode.ai/console/device?user_code=ABCD-EFGH&client_id=opencode-cli"
        )
        XCTAssertEqual(auth.openCodeAuthState, .signedIn(
            identifier: "dev@example.com",
            expiresAt: clock.now.addingTimeInterval(3600)
        ))
    }

    @MainActor
    func testSignInDeviceRequestFailureLeavesManualMethod() async throws {
        let defaults = makeOpenCodeDefaults()
        let store = InMemoryOpenCodeCredentialStore()
        let networking = MockOpenCodeNetworking()
        await networking.enqueueDevice(.failure(.deviceAuthorizationFailed(statusCode: 403, message: "blocked")))
        let presenter = MockOpenCodePresenter()
        let client = makeClient(
            networking: networking,
            presenter: presenter,
            clock: OpenCodeFakeClock(openCodeTestNow),
            delays: DelayRecorder()
        )
        let auth = AuthManager(
            storage: defaults,
            chatGPTCredentialStore: InMemoryChatGPTCredentialStore(),
            chatGPTOAuthNetworking: MockChatGPTNetworking(),
            openCodeCredentialStore: store,
            openCodeOAuthNetworking: networking
        )

        let success = await auth.signInWithOpenCode(using: client)

        XCTAssertFalse(success)
        XCTAssertEqual(auth.openCodeAuthMethod, .apiKey)
        XCTAssertNil(try store.load())
        guard case let .failed(message) = auth.openCodeAuthState else {
            return XCTFail("Expected failed state")
        }
        XCTAssertTrue(message.contains("HTTP 403"))
    }

    @MainActor
    func testSignInAccessDeniedDoesNotPersistCredentials() async throws {
        let defaults = makeOpenCodeDefaults()
        let store = InMemoryOpenCodeCredentialStore()
        let networking = MockOpenCodeNetworking()
        await networking.enqueueDevice(.success(makeDeviceCode()))
        await networking.enqueuePoll(.failure(.accessDenied))
        let presenter = MockOpenCodePresenter()
        let client = makeClient(
            networking: networking,
            presenter: presenter,
            clock: OpenCodeFakeClock(openCodeTestNow),
            delays: DelayRecorder()
        )
        let auth = AuthManager(
            storage: defaults,
            chatGPTCredentialStore: InMemoryChatGPTCredentialStore(),
            chatGPTOAuthNetworking: MockChatGPTNetworking(),
            openCodeCredentialStore: store,
            openCodeOAuthNetworking: networking
        )

        let success = await auth.signInWithOpenCode(using: client)

        XCTAssertFalse(success)
        XCTAssertEqual(auth.openCodeAuthState, .failed(OpenCodeOAuthError.accessDenied.userMessage))
        XCTAssertNil(try store.load())
        XCTAssertEqual(auth.openCodeAuthMethod, .apiKey)
    }

    @MainActor
    func testRefreshSkipsValidToken() async throws {
        let defaults = makeOpenCodeDefaults()
        let valid = makeStoredTokens(expiresAt: openCodeTestNow.addingTimeInterval(3600))
        let store = InMemoryOpenCodeCredentialStore(tokens: valid)
        let networking = MockOpenCodeNetworking()
        let auth = AuthManager(
            storage: defaults,
            chatGPTCredentialStore: InMemoryChatGPTCredentialStore(),
            chatGPTOAuthNetworking: MockChatGPTNetworking(),
            openCodeCredentialStore: store,
            openCodeOAuthNetworking: networking
        )

        let token = try await auth.openCodeAccessToken(now: openCodeTestNow)

        XCTAssertEqual(token, "st_access_1")
        let refreshes = await networking.refreshRequests
        XCTAssertTrue(refreshes.isEmpty)
    }

    @MainActor
    func testExpiredTokenIsRefreshedAndPersisted() async throws {
        let defaults = makeOpenCodeDefaults()
        let expired = makeStoredTokens(expiresAt: openCodeTestNow.addingTimeInterval(-10))
        let store = InMemoryOpenCodeCredentialStore(tokens: expired)
        let networking = MockOpenCodeNetworking()
        await networking.enqueueRefresh(.success(
            makeTokenResponse(accessToken: "st_access_2", refreshToken: "rt_refresh_2", orgID: "org_personal")
        ))
        let auth = AuthManager(
            storage: defaults,
            chatGPTCredentialStore: InMemoryChatGPTCredentialStore(),
            chatGPTOAuthNetworking: MockChatGPTNetworking(),
            openCodeCredentialStore: store,
            openCodeOAuthNetworking: networking
        )

        let refreshed = try await auth.refreshOpenCodeTokensIfNeeded(now: openCodeTestNow)

        XCTAssertEqual(refreshed.accessToken, "st_access_2")
        XCTAssertEqual(refreshed.refreshToken, "rt_refresh_2")
        XCTAssertEqual(refreshed.orgName, "Personal")
        XCTAssertEqual(try store.load()?.accessToken, "st_access_2")
        XCTAssertTrue(auth.openCodeAuthState.isSignedIn)
        XCTAssertEqual(auth.opencodeGoCreds.identifier, "dev@example.com")

        let requests = await networking.refreshRequests
        XCTAssertEqual(requests.first?.refreshToken, "rt_refresh_1")
        XCTAssertEqual(requests.first?.configuration.server, openCodeTestServer)
    }

    @MainActor
    func testInvalidGrantRefreshClearsSession() async throws {
        let defaults = makeOpenCodeDefaults()
        let expired = makeStoredTokens(expiresAt: openCodeTestNow.addingTimeInterval(-10))
        let store = InMemoryOpenCodeCredentialStore(tokens: expired)
        let networking = MockOpenCodeNetworking()
        await networking.enqueueRefresh(.failure(.invalidGrant("invalid_grant: revoked")))
        let auth = AuthManager(
            storage: defaults,
            chatGPTCredentialStore: InMemoryChatGPTCredentialStore(),
            chatGPTOAuthNetworking: MockChatGPTNetworking(),
            openCodeCredentialStore: store,
            openCodeOAuthNetworking: networking
        )

        do {
            _ = try await auth.refreshOpenCodeTokensIfNeeded(now: openCodeTestNow)
            XCTFail("Expected refresh to fail")
        } catch let error as OpenCodeOAuthError {
            guard case .invalidGrant = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertNil(try store.load())
        XCTAssertEqual(auth.openCodeAuthState, .signedOut)
        XCTAssertEqual(auth.openCodeAuthMethod, .apiKey)
        XCTAssertFalse(auth.opencodeGoCreds.isLoggedIn)
    }

    @MainActor
    func testLogoutClearsOpenCodeSessionAndKeychain() async throws {
        let defaults = makeOpenCodeDefaults()
        let fixture = await makeSuccessFixture(defaults: defaults)
        let signedIn = await fixture.auth.signInWithOpenCode(using: fixture.client)
        XCTAssertTrue(signedIn)
        XCTAssertNotNil(try fixture.store.load())

        fixture.auth.logout(type: .opencodeGo)

        XCTAssertEqual(fixture.auth.openCodeAuthState, .signedOut)
        XCTAssertEqual(fixture.auth.openCodeAuthMethod, .apiKey)
        XCTAssertNil(try fixture.store.load())
        XCTAssertFalse(fixture.auth.opencodeGoCreds.isLoggedIn)
        XCTAssertEqual(fixture.auth.opencodeGoCreds.identifier, "")
    }

    @MainActor
    func testManualLoginTakesPrecedenceWithoutDeletingKeychain() async throws {
        let defaults = makeOpenCodeDefaults()
        let fixture = await makeSuccessFixture(defaults: defaults)
        let signedIn = await fixture.auth.signInWithOpenCode(using: fixture.client)
        XCTAssertTrue(signedIn)

        let manual = fixture.auth.login(
            type: .opencodeGo,
            apiKey: "ocg_manual_token",
            identifier: "https://api.opencode.dev"
        )
        XCTAssertTrue(manual)

        XCTAssertEqual(fixture.auth.openCodeAuthMethod, .apiKey)
        XCTAssertEqual(fixture.auth.openCodeAuthState, .signedOut)
        XCTAssertEqual(fixture.auth.opencodeGoCreds.apiKey, "ocg_manual_token")
        XCTAssertEqual(fixture.auth.opencodeGoCreds.identifier, "https://api.opencode.dev")
        // The secure item is ignored while the persisted method is apiKey.
        XCTAssertNotNil(try fixture.store.load())

        do {
            _ = try await fixture.auth.openCodeAccessToken()
            XCTFail("Manual login should not expose the stale OAuth access token")
        } catch let error as OpenCodeOAuthError {
            XCTAssertEqual(error, .notSignedIn)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testStoredSessionRestoresAcrossInstances() async throws {
        let defaults = makeOpenCodeDefaults()
        let store = InMemoryOpenCodeCredentialStore()
        let fixture = await makeSuccessFixture(defaults: defaults)
        // Use the shared store so the second manager can read it.
        let auth = AuthManager(
            storage: defaults,
            chatGPTCredentialStore: InMemoryChatGPTCredentialStore(),
            chatGPTOAuthNetworking: MockChatGPTNetworking(),
            openCodeCredentialStore: store,
            openCodeOAuthNetworking: fixture.networking
        )
        let clock = OpenCodeFakeClock(openCodeTestNow)
        let client = makeClient(
            networking: fixture.networking,
            presenter: MockOpenCodePresenter(),
            clock: clock,
            delays: DelayRecorder()
        )
        let signedIn = await auth.signInWithOpenCode(using: client)
        XCTAssertTrue(signedIn)

        let restored = AuthManager(
            storage: defaults,
            chatGPTCredentialStore: InMemoryChatGPTCredentialStore(),
            chatGPTOAuthNetworking: MockChatGPTNetworking(),
            openCodeCredentialStore: store,
            openCodeOAuthNetworking: MockOpenCodeNetworking()
        )

        XCTAssertEqual(restored.openCodeAuthMethod, .oauth)
        XCTAssertEqual(
            restored.openCodeAuthState,
            .signedIn(identifier: "dev@example.com", expiresAt: clock.now.addingTimeInterval(3600))
        )
        XCTAssertEqual(restored.opencodeGoCreds.identifier, "dev@example.com")
        XCTAssertTrue(restored.opencodeGoCreds.isLoggedIn)
    }

    @MainActor
    func testManualCodexLoginDoesNotAffectOpenCodeSession() async throws {
        let defaults = makeOpenCodeDefaults()
        let fixture = await makeSuccessFixture(defaults: defaults)
        let signedIn = await fixture.auth.signInWithOpenCode(using: fixture.client)
        XCTAssertTrue(signedIn)

        XCTAssertTrue(fixture.auth.login(type: .codex, apiKey: "sk-manual", identifier: "org"))

        XCTAssertEqual(fixture.auth.openCodeAuthMethod, .oauth)
        XCTAssertTrue(fixture.auth.openCodeAuthState.isSignedIn)
        XCTAssertNotNil(try fixture.store.load())
    }
}
