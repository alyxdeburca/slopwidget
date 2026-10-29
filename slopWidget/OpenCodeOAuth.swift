import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(os)
import os
#endif

// MARK: - Configuration

/// Configuration for OpenCode Console's OAuth Device Authorization flow.
///
/// Verified against the installed OpenCode CLI (`opencode` v2.2.0) and the live
/// service, not guessed:
///
/// * The CLI's OpenCode Console integration uses auth method `device`
///   (`opencode auth list --format json` reports `"method": "oauth"` for the
///   stored `opencode` connection).
/// * The CLI requests `POST https://opencode.ai/console/auth/device/code` with
///   `{"client_id":"opencode-cli","supports_org_scope":true}`.
/// * It polls `POST https://opencode.ai/console/auth/device/token` with
///   `grant_type=urn:ietf:params:oauth:grant-type:device_code`, then refreshes
///   with `grant_type=refresh_token`; both send `client_id=opencode-cli`.
/// * `opencode-cli` is the public native client identifier embedded in the CLI
///   binary; no client secret is used (`token_endpoint_auth_method: "none"`).
/// * The device code response contains `verification_uri_complete` such as
///   `/console/device?user_code=…&client_id=opencode-cli`, relative to the
///   server, with `expires_in` (600s) and `interval` (5s).
/// * After approval the CLI calls `GET /api/user` and `GET /api/orgs` with the
///   access token to label the credential.
///
/// This is a device-code flow: there is no redirect URI, custom URL scheme or
/// loopback listener, so no Info.plist/xtool.yml registration is required.
public struct OpenCodeOAuthConfiguration: Sendable, Equatable {
    /// OpenCode Console origin. The CLI's stored credential records
    /// `metadata.server = "https://opencode.ai/console"`.
    public var server: URL
    /// Public native client ID from the CLI binary (`opencode-cli`).
    public var clientID: String
    /// The CLI asks for organization-scoped tokens so the returned grant carries
    /// `org_id`, which `/api/v2/config` and web search need.
    public var supportsOrgScope: Bool

    public init(
        server: URL = URL(string: "https://opencode.ai/console")!,
        clientID: String = "opencode-cli",
        supportsOrgScope: Bool = true
    ) {
        self.server = server
        self.clientID = clientID
        self.supportsOrgScope = supportsOrgScope
    }

    public var deviceCodeEndpoint: URL { endpoint("auth/device/code") }
    public var deviceTokenEndpoint: URL { endpoint("auth/device/token") }
    public var userEndpoint: URL { endpoint("api/user") }
    public var organizationsEndpoint: URL { endpoint("api/orgs") }

    /// Returns a copy pointed at another OpenCode server (self-hosted/enterprise).
    public func withServer(_ server: URL) -> OpenCodeOAuthConfiguration {
        var copy = self
        copy.server = server
        return copy
    }

    private func endpoint(_ suffix: String) -> URL {
        guard var components = URLComponents(url: server, resolvingAgainstBaseURL: false) else {
            return server
        }
        let base = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + ([base, suffix].filter { !$0.isEmpty }.joined(separator: "/"))
        components.query = nil
        components.fragment = nil
        return components.url ?? server
    }
}

// MARK: - Device code

/// The device authorization grant returned by `/auth/device/code`.
public struct OpenCodeDeviceCode: Sendable, Equatable {
    public var deviceCode: String
    public var userCode: String
    /// Absolute URL of the page where the user approves the code.
    public var verificationURL: URL
    /// Lifetime of the device code, in seconds.
    public var expiresIn: TimeInterval
    /// Minimum polling interval, in seconds.
    public var interval: TimeInterval

    public init(
        deviceCode: String,
        userCode: String,
        verificationURL: URL,
        expiresIn: TimeInterval,
        interval: TimeInterval
    ) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURL = verificationURL
        self.expiresIn = expiresIn
        self.interval = interval
    }

    /// Converts the console payload, resolving its relative verification path
    /// (`/console/device?user_code=…`) against the server the CLI uses.
    public init(payload: OpenCodeDeviceCodePayload, server: URL) throws {
        let deviceCode = payload.deviceCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let userCode = payload.userCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !deviceCode.isEmpty, !userCode.isEmpty else {
            throw OpenCodeOAuthError.invalidResponse("The device response omitted a code.")
        }
        guard let value = payload.verificationURIComplete ?? payload.verificationURI else {
            throw OpenCodeOAuthError.invalidResponse("The device response omitted a verification URL.")
        }
        guard let url = Self.resolve(value, relativeTo: server) else {
            throw OpenCodeOAuthError.invalidResponse("The device response contained an invalid verification URL.")
        }
        self.init(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURL: url,
            expiresIn: payload.expiresIn ?? 600,
            interval: payload.interval ?? 5
        )
    }

    /// Mirrors the CLI's `new URL(value, server + "/")` resolution.
    static func resolve(_ value: String, relativeTo server: URL) -> URL? {
        let base = server.absoluteString.hasSuffix("/")
            ? server.absoluteString
            : server.absoluteString + "/"
        guard let baseURL = URL(string: base) else { return nil }
        guard let url = URL(string: value, relativeTo: baseURL)?.absoluteURL else { return nil }
        guard url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }
}

/// Wire format of `POST /auth/device/code` (snake_case JSON).
public struct OpenCodeDeviceCodePayload: Codable, Sendable, Equatable {
    public var deviceCode: String
    public var userCode: String
    public var verificationURI: String?
    public var verificationURIComplete: String?
    public var expiresIn: TimeInterval?
    public var interval: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case verificationURIComplete = "verification_uri_complete"
        case expiresIn = "expires_in"
        case interval
    }

    public init(
        deviceCode: String,
        userCode: String,
        verificationURI: String? = nil,
        verificationURIComplete: String? = nil,
        expiresIn: TimeInterval? = nil,
        interval: TimeInterval? = nil
    ) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.verificationURIComplete = verificationURIComplete
        self.expiresIn = expiresIn
        self.interval = interval
    }
}

// MARK: - Token response and durable tokens

public struct OpenCodeOAuthTokenResponse: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresIn: TimeInterval?
    public var orgID: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case orgID = "org_id"
    }

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresIn: TimeInterval? = nil,
        orgID: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
        self.orgID = orgID
    }
}

/// Account identity fetched from `/api/user`.
public struct OpenCodeUser: Codable, Sendable, Equatable {
    public var id: String
    public var email: String?

    public init(id: String, email: String? = nil) {
        self.id = id
        self.email = email
    }
}

/// Organization fetched from `/api/orgs`.
public struct OpenCodeOrganization: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Durable OpenCode OAuth credentials. This is the only value written to the
/// Keychain; manual API tokens still live in `ServiceCredentials`.
public struct OpenCodeTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var server: URL
    public var accountID: String?
    public var email: String?
    public var orgID: String?
    public var orgName: String?

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        server: URL = OpenCodeOAuthConfiguration().server,
        accountID: String? = nil,
        email: String? = nil,
        orgID: String? = nil,
        orgName: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.server = server
        self.accountID = accountID
        self.email = email
        self.orgID = orgID
        self.orgName = orgName
    }

    /// Converts a token response plus the identity lookups the CLI performs.
    public init(
        response: OpenCodeOAuthTokenResponse,
        user: OpenCodeUser?,
        organizations: [OpenCodeOrganization],
        server: URL,
        previous: OpenCodeTokens? = nil,
        now: Date = Date()
    ) throws {
        let accessToken = response.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty else {
            throw OpenCodeOAuthError.invalidResponse("The token response omitted an access token.")
        }
        if response.expiresIn == 0 {
            throw OpenCodeOAuthError.invalidResponse("The token response returned a zero lifetime.")
        }

        let selected = Self.selectOrganization(id: response.orgID, from: organizations)
        if let orgID = response.orgID, selected == nil, previous?.orgID != orgID {
            throw OpenCodeOAuthError.invalidResponse("OpenCode organization not found: \(orgID)")
        }

        let expiration: Date?
        if let expiresIn = response.expiresIn {
            expiration = now.addingTimeInterval(expiresIn)
        } else {
            expiration = previous?.expiresAt
        }

        self.init(
            accessToken: accessToken,
            refreshToken: response.refreshToken ?? previous?.refreshToken,
            expiresAt: expiration,
            server: server,
            accountID: user?.id ?? previous?.accountID,
            email: user?.email ?? previous?.email,
            orgID: selected?.id ?? response.orgID ?? previous?.orgID,
            orgName: selected?.name
                ?? (response.orgID == nil || response.orgID == previous?.orgID ? previous?.orgName : nil)
        )
    }

    /// Merges a refresh response. Refresh does not re-fetch the account, and an
    /// organization change only replaces the ID until the next full sign-in.
    public init(
        refreshResponse response: OpenCodeOAuthTokenResponse,
        previous: OpenCodeTokens,
        now: Date = Date()
    ) throws {
        let accessToken = response.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty else {
            throw OpenCodeOAuthError.invalidResponse("The token response omitted an access token.")
        }
        if response.expiresIn == 0 {
            throw OpenCodeOAuthError.invalidResponse("The token response returned a zero lifetime.")
        }

        let expiration: Date?
        if let expiresIn = response.expiresIn {
            expiration = now.addingTimeInterval(expiresIn)
        } else {
            expiration = previous.expiresAt
        }

        let sameOrganization = response.orgID == nil || response.orgID == previous.orgID
        self.init(
            accessToken: accessToken,
            refreshToken: response.refreshToken ?? previous.refreshToken,
            expiresAt: expiration,
            server: previous.server,
            accountID: previous.accountID,
            email: previous.email,
            orgID: response.orgID ?? previous.orgID,
            orgName: sameOrganization ? previous.orgName : nil
        )
    }

    /// Matches the CLI: when the grant names an organization use it, otherwise
    /// use the alphabetically first organization (name, then ID).
    static func selectOrganization(id: String?, from organizations: [OpenCodeOrganization]) -> OpenCodeOrganization? {
        if let id {
            return organizations.first { $0.id == id }
        }
        return organizations.sorted {
            if $0.name == $1.name { return $0.id < $1.id }
            return $0.name.localizedCompare($1.name) == .orderedAscending
        }.first
    }

    /// Human-readable identity used for the provider identifier.
    public var identifier: String {
        if let email, !email.isEmpty { return email }
        if let accountID, !accountID.isEmpty { return accountID }
        return "OpenCode account"
    }

    public var organizationLabel: String? {
        guard let orgName, !orgName.isEmpty else { return nil }
        return orgName
    }

    public func isExpired(at date: Date = Date(), skew: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= date.addingTimeInterval(skew)
    }
}

// MARK: - Errors

public enum OpenCodeOAuthError: Error, LocalizedError, Equatable, Sendable {
    case cancelled
    case invalidConfiguration(String)
    case invalidResponse(String)
    case deviceAuthorizationFailed(statusCode: Int, message: String)
    case deviceTokenFailed(statusCode: Int, message: String)
    case authorizationPending
    case slowDown
    case accessDenied
    case expiredToken
    case invalidGrant(String)
    case refreshFailed(statusCode: Int, message: String)
    case notSignedIn
    case missingRefreshToken
    case unsupportedPlatform
    case browserFailed(String)

    public var errorDescription: String? { userMessage }

    public var userMessage: String {
        switch self {
        case .cancelled:
            return "Sign-in cancelled."
        case let .invalidConfiguration(message):
            return "Sign-in configuration error: \(message)"
        case let .invalidResponse(message):
            return "Sign-in failed: \(message)"
        case let .deviceAuthorizationFailed(statusCode, message):
            return "Could not start OpenCode sign-in (HTTP \(statusCode)): \(message)"
        case let .deviceTokenFailed(statusCode, message):
            return "OpenCode sign-in failed (HTTP \(statusCode)): \(message)"
        case .authorizationPending:
            return "Waiting for OpenCode approval…"
        case .slowDown:
            return "Waiting for OpenCode approval…"
        case .accessDenied:
            return "OpenCode sign-in was denied."
        case .expiredToken:
            return "The OpenCode sign-in code expired. Please try again."
        case let .invalidGrant(message):
            return "The OpenCode session expired or was revoked. Please sign in again. \(message)"
        case let .refreshFailed(statusCode, message):
            return "Could not refresh the OpenCode session (HTTP \(statusCode)): \(message)"
        case .notSignedIn:
            return "Not signed in with OpenCode."
        case .missingRefreshToken:
            return "The OpenCode session has expired and cannot be refreshed. Please sign in again."
        case .unsupportedPlatform:
            return "Sign in with OpenCode is only available on iOS."
        case let .browserFailed(message):
            return "Sign-in failed: \(message)"
        }
    }
}

// MARK: - Request construction

public struct OpenCodeDeviceCodeRequest: Sendable, Equatable {
    public let configuration: OpenCodeOAuthConfiguration
    public let supportsOrgScope: Bool

    public init(configuration: OpenCodeOAuthConfiguration = OpenCodeOAuthConfiguration(), supportsOrgScope: Bool? = nil) {
        self.configuration = configuration
        self.supportsOrgScope = supportsOrgScope ?? configuration.supportsOrgScope
    }
}

public struct OpenCodeDeviceTokenPollRequest: Sendable, Equatable {
    public let configuration: OpenCodeOAuthConfiguration
    public let deviceCode: String

    public init(configuration: OpenCodeOAuthConfiguration, deviceCode: String) {
        self.configuration = configuration
        self.deviceCode = deviceCode
    }
}

public struct OpenCodeRefreshRequest: Sendable, Equatable {
    public let configuration: OpenCodeOAuthConfiguration
    public let refreshToken: String

    public init(configuration: OpenCodeOAuthConfiguration, refreshToken: String) {
        self.configuration = configuration
        self.refreshToken = refreshToken
    }
}

/// Builds the exact requests the OpenCode CLI sends. Kept separate so tests can
/// assert the wire format without any network access.
public enum OpenCodeOAuthRequestBuilder {
    static let clientUserAgent = "opencode/2.2.0 slopWidget/1.0"

    public static func deviceCodeRequest(_ request: OpenCodeDeviceCodeRequest) throws -> URLRequest {
        try post(
            request.configuration.deviceCodeEndpoint,
            body: [
                "client_id": request.configuration.clientID,
                "supports_org_scope": request.supportsOrgScope,
            ]
        )
    }

    public static func deviceTokenPollRequest(_ request: OpenCodeDeviceTokenPollRequest) throws -> URLRequest {
        try post(
            request.configuration.deviceTokenEndpoint,
            body: [
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "device_code": request.deviceCode,
                "client_id": request.configuration.clientID,
            ]
        )
    }

    public static func refreshRequest(_ request: OpenCodeRefreshRequest) throws -> URLRequest {
        try post(
            request.configuration.deviceTokenEndpoint,
            body: [
                "grant_type": "refresh_token",
                "refresh_token": request.refreshToken,
                "client_id": request.configuration.clientID,
            ]
        )
    }

    public static func userRequest(
        accessToken: String,
        configuration: OpenCodeOAuthConfiguration
    ) throws -> URLRequest {
        try get(configuration.userEndpoint, accessToken: accessToken)
    }

    public static func organizationsRequest(
        accessToken: String,
        configuration: OpenCodeOAuthConfiguration
    ) throws -> URLRequest {
        try get(configuration.organizationsEndpoint, accessToken: accessToken)
    }

    private static func post(_ endpoint: URL, body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(clientUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func get(_ endpoint: URL, accessToken: String) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(clientUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }
}

// MARK: - Networking seam

/// Injection point for unit tests; production uses
/// `URLSessionOpenCodeOAuthNetworking`.
public protocol OpenCodeOAuthNetworking: Sendable {
    func requestDeviceCode(_ request: OpenCodeDeviceCodeRequest) async throws -> OpenCodeDeviceCode
    func pollDeviceToken(_ request: OpenCodeDeviceTokenPollRequest) async throws -> OpenCodeOAuthTokenResponse
    func refreshToken(_ request: OpenCodeRefreshRequest) async throws -> OpenCodeOAuthTokenResponse
    func fetchUser(accessToken: String, configuration: OpenCodeOAuthConfiguration) async throws -> OpenCodeUser
    func fetchOrganizations(accessToken: String, configuration: OpenCodeOAuthConfiguration) async throws -> [OpenCodeOrganization]
}

public struct URLSessionOpenCodeOAuthNetworking: OpenCodeOAuthNetworking {
    public let session: URLSession

    #if canImport(os)
    private static let logger = Logger(subsystem: "com.example.slopWidget", category: "OpenCodeAuth")
    #endif

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func requestDeviceCode(_ request: OpenCodeDeviceCodeRequest) async throws -> OpenCodeDeviceCode {
        let urlRequest = try OpenCodeOAuthRequestBuilder.deviceCodeRequest(request)
        let data = try await send(urlRequest, failure: { status, message in
            .deviceAuthorizationFailed(statusCode: status, message: message.message)
        })
        do {
            let payload = try JSONDecoder().decode(OpenCodeDeviceCodePayload.self, from: data)
            return try OpenCodeDeviceCode(payload: payload, server: request.configuration.server)
        } catch let error as OpenCodeOAuthError {
            throw error
        } catch {
            throw OpenCodeOAuthError.invalidResponse("Could not decode the device authorization response.")
        }
    }

    public func pollDeviceToken(_ request: OpenCodeDeviceTokenPollRequest) async throws -> OpenCodeOAuthTokenResponse {
        let urlRequest = try OpenCodeOAuthRequestBuilder.deviceTokenPollRequest(request)
        let data = try await send(urlRequest) { status, parsed in
            switch parsed.code {
            case "authorization_pending", "device_code_pending":
                return .authorizationPending
            case "slow_down":
                return .slowDown
            case "access_denied", "authorization_denied":
                return .accessDenied
            case "expired_token":
                return .expiredToken
            case "invalid_grant":
                return .invalidGrant(parsed.message)
            default:
                return .deviceTokenFailed(statusCode: status, message: parsed.message)
            }
        }
        return try decodeTokenResponse(data)
    }

    public func refreshToken(_ request: OpenCodeRefreshRequest) async throws -> OpenCodeOAuthTokenResponse {
        let urlRequest = try OpenCodeOAuthRequestBuilder.refreshRequest(request)
        let data = try await send(urlRequest) { status, parsed in
            if parsed.code == "invalid_grant" {
                return .invalidGrant(parsed.message)
            }
            return .refreshFailed(statusCode: status, message: parsed.message)
        }
        return try decodeTokenResponse(data)
    }

    public func fetchUser(
        accessToken: String,
        configuration: OpenCodeOAuthConfiguration
    ) async throws -> OpenCodeUser {
        let urlRequest = try OpenCodeOAuthRequestBuilder.userRequest(accessToken: accessToken, configuration: configuration)
        let data = try await send(urlRequest) { status, parsed in
            .invalidResponse("Could not load the OpenCode account (HTTP \(status)): \(parsed.message)")
        }
        do {
            return try JSONDecoder().decode(OpenCodeUser.self, from: data)
        } catch {
            throw OpenCodeOAuthError.invalidResponse("Could not decode the OpenCode account.")
        }
    }

    public func fetchOrganizations(
        accessToken: String,
        configuration: OpenCodeOAuthConfiguration
    ) async throws -> [OpenCodeOrganization] {
        let urlRequest = try OpenCodeOAuthRequestBuilder.organizationsRequest(accessToken: accessToken, configuration: configuration)
        let data = try await send(urlRequest) { status, parsed in
            .invalidResponse("Could not load OpenCode organizations (HTTP \(status)): \(parsed.message)")
        }
        do {
            return try JSONDecoder().decode([OpenCodeOrganization].self, from: data)
        } catch {
            throw OpenCodeOAuthError.invalidResponse("Could not decode the OpenCode organizations.")
        }
    }

    private func decodeTokenResponse(_ data: Data) throws -> OpenCodeOAuthTokenResponse {
        do {
            return try JSONDecoder().decode(OpenCodeOAuthTokenResponse.self, from: data)
        } catch {
            throw OpenCodeOAuthError.invalidResponse("Could not decode the token response.")
        }
    }

    private func send(
        _ request: URLRequest,
        failure: (Int, (code: String?, message: String)) -> OpenCodeOAuthError
    ) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw OpenCodeOAuthError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw OpenCodeOAuthError.cancelled
        } catch {
            throw OpenCodeOAuthError.invalidResponse(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OpenCodeOAuthError.invalidResponse("OpenCode returned a non-HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let parsed = Self.parseError(from: data)
            #if canImport(os)
            Self.logger.error(
                "OpenCode request \(http.statusCode) at \(request.url?.absoluteString ?? "?", privacy: .public): \(parsed.message, privacy: .public)"
            )
            #endif
            throw failure(http.statusCode, parsed)
        }
        return data
    }

    /// OpenCode returns `{"error": "...", "error_description": "..."}` (plus an
    /// internal `_tag`), so a flat error string is the common shape.
    static func parseError(from data: Data) -> (code: String?, message: String) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(decoding: data, as: UTF8.self)
            return (nil, text.isEmpty ? "no response body" : text)
        }
        if let code = json["error"] as? String {
            let description = json["error_description"] as? String
            return (code, description ?? code)
        }
        if let error = json["error"] as? [String: Any] {
            let code = error["code"] as? String ?? error["type"] as? String
            let message = error["message"] as? String
                ?? error["error_description"] as? String
                ?? code
                ?? "unknown_error"
            return (code, message)
        }
        if let message = json["message"] as? String {
            return (json["code"] as? String, message)
        }
        return (nil, "no response body")
    }
}

// MARK: - Presenter seam

/// Opens the device verification page. Unlike the ChatGPT flow there is no
/// redirect back into the app, so the presenter is fire-and-forget: the client
/// polls the token endpoint until the user approves in the browser.
@MainActor
public protocol OpenCodeDeviceAuthorizationPresenting: Sendable {
    func present(verificationURL: URL) async throws
    func dismiss() async
}

// MARK: - Client

public struct OpenCodeOAuthClient: Sendable {
    public let configuration: OpenCodeOAuthConfiguration
    public let networking: any OpenCodeOAuthNetworking
    public let presenter: any OpenCodeDeviceAuthorizationPresenting

    private let sleeper: @Sendable (TimeInterval) async throws -> Void
    private let now: @Sendable () -> Date

    public init(
        configuration: OpenCodeOAuthConfiguration = OpenCodeOAuthConfiguration(),
        networking: any OpenCodeOAuthNetworking = URLSessionOpenCodeOAuthNetworking(),
        presenter: any OpenCodeDeviceAuthorizationPresenting,
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = OpenCodeOAuthClient.sleep,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.networking = networking
        self.presenter = presenter
        self.sleeper = sleeper
        self.now = now
    }

    /// Runs the device authorization grant end to end: request a code, show it,
    /// poll until approved, then resolve the account and organization.
    @MainActor
    public func signIn(
        progress: @escaping @MainActor @Sendable (OpenCodeDeviceCode) -> Void = { _ in }
    ) async throws -> OpenCodeTokens {
        let device: OpenCodeDeviceCode
        do {
            device = try await networking.requestDeviceCode(
                OpenCodeDeviceCodeRequest(configuration: configuration)
            )
        } catch let error as OpenCodeOAuthError {
            throw error
        } catch is CancellationError {
            throw OpenCodeOAuthError.cancelled
        } catch {
            throw OpenCodeOAuthError.invalidResponse(error.localizedDescription)
        }

        progress(device)

        do {
            try await presenter.present(verificationURL: device.verificationURL)
        } catch {
            // The code is still shown in the UI, so a failed browser launch is
            // not fatal: the user can open the URL on another device.
            #if canImport(os)
            Logger(subsystem: "com.example.slopWidget", category: "OpenCodeAuth")
                .error("Could not present OpenCode verification page: \(String(describing: error), privacy: .public)")
            #endif
        }

        let deadline = now().addingTimeInterval(max(device.expiresIn, 1))
        var interval = max(device.interval, 1)

        do {
            while true {
                guard now() < deadline else {
                    throw OpenCodeOAuthError.expiredToken
                }
                try await sleeper(interval)
                guard now() < deadline else {
                    throw OpenCodeOAuthError.expiredToken
                }

                do {
                    let response = try await networking.pollDeviceToken(
                        OpenCodeDeviceTokenPollRequest(
                            configuration: configuration,
                            deviceCode: device.deviceCode
                        )
                    )
                    let tokens = try await resolveTokens(response)
                    await presenter.dismiss()
                    return tokens
                } catch OpenCodeOAuthError.authorizationPending {
                    continue
                } catch OpenCodeOAuthError.slowDown {
                    interval += 5
                    continue
                }
            }
        } catch {
            await presenter.dismiss()
            if error is CancellationError {
                throw OpenCodeOAuthError.cancelled
            }
            throw error
        }
    }

    /// Refreshes an existing grant. OpenCode does not always rotate refresh
    /// tokens, so the previous one is preserved when omitted.
    public func refresh(_ tokens: OpenCodeTokens) async throws -> OpenCodeTokens {
        guard let refreshToken = tokens.refreshToken, !refreshToken.isEmpty else {
            throw OpenCodeOAuthError.missingRefreshToken
        }
        let serverConfiguration = self.configuration.withServer(tokens.server)
        let response: OpenCodeOAuthTokenResponse
        do {
            response = try await networking.refreshToken(
                OpenCodeRefreshRequest(configuration: serverConfiguration, refreshToken: refreshToken)
            )
        } catch let error as OpenCodeOAuthError {
            throw error
        } catch is CancellationError {
            throw OpenCodeOAuthError.cancelled
        } catch {
            throw OpenCodeOAuthError.invalidResponse(error.localizedDescription)
        }
        return try OpenCodeTokens(
            refreshResponse: response,
            previous: tokens,
            now: now()
        )
    }

    private func resolveTokens(_ response: OpenCodeOAuthTokenResponse) async throws -> OpenCodeTokens {
        async let user = networking.fetchUser(
            accessToken: response.accessToken,
            configuration: configuration
        )
        async let organizations = networking.fetchOrganizations(
            accessToken: response.accessToken,
            configuration: configuration
        )

        let resolvedUser: OpenCodeUser
        let resolvedOrganizations: [OpenCodeOrganization]
        do {
            (resolvedUser, resolvedOrganizations) = try await (user, organizations)
        } catch let error as OpenCodeOAuthError {
            throw error
        } catch is CancellationError {
            throw OpenCodeOAuthError.cancelled
        } catch {
            throw OpenCodeOAuthError.invalidResponse(error.localizedDescription)
        }

        return try OpenCodeTokens(
            response: response,
            user: resolvedUser,
            organizations: resolvedOrganizations,
            server: configuration.server,
            now: now()
        )
    }

    public static func sleep(seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

// MARK: - Factory

public enum OpenCodeOAuthClientFactory {
    /// Production client: real device-code endpoints and an in-app browser.
    @MainActor
    public static func makeDefault(
        configuration: OpenCodeOAuthConfiguration = OpenCodeOAuthConfiguration(),
        networking: any OpenCodeOAuthNetworking = URLSessionOpenCodeOAuthNetworking()
    ) -> OpenCodeOAuthClient {
        OpenCodeOAuthClient(
            configuration: configuration,
            networking: networking,
            presenter: SFSafariOpenCodePresenter()
        )
    }
}
