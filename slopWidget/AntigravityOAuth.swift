import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(os)
import os
#endif

// MARK: - Configuration

/// Configuration for Antigravity's "Sign in with Google" OAuth flow.
///
/// The client ID, installed-app secret, and scopes are not guesses. They were
/// verified from the Antigravity ACP server 1.3.0 that is installed on this
/// machine at
/// `~/.t3/tools/antigravity-acp/linux-x64/versions/.../agy_acp_server.par`.
/// The embedded Python module
/// `google3/cloud/developer_experience/antigravity_extensions/acp_server/ccpa_connection/oauth_manager.py`
/// declares them as "Default OAuth Client Credentials and Scopes" and notes that
/// they were copied from the Go Antigravity CLI's `constants.go`. The same
/// `client_id` and three scopes are present in the live Antigravity ACP token
/// file (`<GEMINI_HOME or ~/.gemini>/antigravity-acp/acp_token.json`; on this
/// machine the provider launcher scopes GEMINI_HOME under
/// `~/.t3/userdata/providers/antigravity/`).
///
/// This is a Google "installed application" client. Its secret is shipped in
/// every copy of the Antigravity CLI and is not a user secret; PKCE is still
/// used to protect the authorization code. The app never writes this value into
/// user preferences or the Keychain.
///
/// Google's installed-app clients accept any loopback IP and port for the
/// redirect, which is why the flow binds `127.0.0.1:0` and advertises the port
/// the OS actually assigned. The ACP server's reference implementation does the
/// same (`http://127.0.0.1:<ephemeral>/`).
public struct AntigravityOAuthConfiguration: Sendable, Equatable {
    /// Verified from `ccpa_connection/oauth_manager.py` (Antigravity ACP 1.3.0).
    public static let verifiedClientID = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    /// Public installed-app credential shipped with the Antigravity CLI.
    public static let verifiedClientSecret = "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"
    /// Verified from the same module and from the live token file.
    public static let verifiedScopes = [
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/aicode",
    ]
    public static let loopbackHost = "127.0.0.1"
    public static let loopbackPath = "/"
    public static let callbackPort: UInt16 = 0

    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    public var userInfoEndpoint: URL
    public var clientID: String
    public var clientSecret: String?
    public var scopes: [String]

    public init(
        clientID: String = AntigravityOAuthConfiguration.verifiedClientID,
        clientSecret: String? = AntigravityOAuthConfiguration.verifiedClientSecret,
        scopes: [String] = AntigravityOAuthConfiguration.verifiedScopes,
        authorizationEndpoint: URL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
        tokenEndpoint: URL = URL(string: "https://oauth2.googleapis.com/token")!,
        userInfoEndpoint: URL = URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.scopes = scopes
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.userInfoEndpoint = userInfoEndpoint
    }

    public var isConfigured: Bool {
        !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var scopeString: String {
        scopes.joined(separator: " ")
    }

    /// Builds the production configuration, allowing an app bundle to override
    /// the verified values with `AntigravityGoogleOAuthClientID` and
    /// `AntigravityGoogleOAuthClientSecret`. A missing key keeps the verified
    /// default; an explicitly empty client ID disables the flow so the UI can
    /// show the precise "Google OAuth is not configured" error.
    public static func defaultConfiguration(bundle: Bundle = .main) -> AntigravityOAuthConfiguration {
        let info = bundle.infoDictionary ?? [:]
        let clientID = (info["AntigravityGoogleOAuthClientID"] as? String)
            ?? verifiedClientID
        let clientSecret: String?
        if let override = info["AntigravityGoogleOAuthClientSecret"] as? String {
            let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
            clientSecret = trimmed.isEmpty ? nil : trimmed
        } else {
            clientSecret = verifiedClientSecret
        }
        return AntigravityOAuthConfiguration(clientID: clientID, clientSecret: clientSecret)
    }
}

// MARK: - Authorization request

public struct AntigravityAuthorizationContext: Sendable, Equatable {
    public let configuration: AntigravityOAuthConfiguration
    public let pkce: PKCE
    public let state: String

    public init(
        configuration: AntigravityOAuthConfiguration = .defaultConfiguration(),
        pkce: PKCE = .generate(),
        state: String = OAuthState.generate()
    ) {
        self.configuration = configuration
        self.pkce = pkce
        self.state = state
    }

    /// Builds the Google authorization URL using the loopback redirect that the
    /// listener actually bound.
    public func authorizationURL(redirectURI: URL) throws -> URL {
        try AntigravityOAuthRequestBuilder.authorizationURL(
            configuration: configuration,
            redirectURI: redirectURI,
            pkce: pkce,
            state: state
        )
    }
}

public enum AntigravityOAuthRequestBuilder {
    public static func authorizationURL(
        configuration: AntigravityOAuthConfiguration,
        redirectURI: URL,
        pkce: PKCE,
        state: String
    ) throws -> URL {
        guard configuration.isConfigured else {
            throw AntigravityOAuthError.notConfigured
        }
        guard var components = URLComponents(
            url: configuration.authorizationEndpoint,
            resolvingAgainstBaseURL: false
        ) else {
            throw AntigravityOAuthError.invalidConfiguration("Invalid authorization endpoint")
        }

        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: configuration.scopeString),
            URLQueryItem(name: "code_challenge", value: pkce.codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            // Match the Antigravity ACP server: offline access supplies a
            // refresh token, and an explicit consent prompt makes Google return
            // one even when the user has authorized the app before.
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]

        guard let url = components.url else {
            throw AntigravityOAuthError.invalidConfiguration("Could not build authorization URL")
        }
        return url
    }
}

// MARK: - Callback

public struct AntigravityOAuthCallback: Sendable, Equatable {
    public var code: String?
    public var state: String?
    public var error: String?
    public var errorDescription: String?

    public init(
        code: String? = nil,
        state: String? = nil,
        error: String? = nil,
        errorDescription: String? = nil
    ) {
        self.code = code
        self.state = state
        self.error = error
        self.errorDescription = errorDescription
    }

    public init(url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw AntigravityOAuthError.invalidCallback("Malformed callback URL")
        }
        var query = components.queryItems ?? []
        if query.isEmpty, let fragment = components.fragment,
           let fragmentComponents = URLComponents(string: "?\(fragment)") {
            query = fragmentComponents.queryItems ?? []
        }
        func value(_ name: String) -> String? {
            query.first(where: { $0.name == name })?.value
        }
        self.init(
            code: value("code"),
            state: value("state"),
            error: value("error"),
            errorDescription: value("error_description")
        )
    }
}

// MARK: - Token response

public struct AntigravityOAuthTokenResponse: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresIn: TimeInterval?
    public var scope: String?
    public var tokenType: String?
    public var idToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
        case tokenType = "token_type"
        case idToken = "id_token"
    }

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresIn: TimeInterval? = nil,
        scope: String? = nil,
        tokenType: String? = nil,
        idToken: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
        self.scope = scope
        self.tokenType = tokenType
        self.idToken = idToken
    }
}

/// Minimal Google userinfo payload used to label the signed-in account.
public struct AntigravityUserInfo: Codable, Sendable, Equatable {
    public var email: String?
    public var subject: String?
    public var name: String?

    enum CodingKeys: String, CodingKey {
        case email
        case subject = "sub"
        case name
    }

    public init(email: String? = nil, subject: String? = nil, name: String? = nil) {
        self.email = email
        self.subject = subject
        self.name = name
    }
}

/// Durable Google OAuth credentials. This is the only value written to secure
/// storage for Antigravity; manual API keys remain in `ServiceCredentials`.
public struct AntigravityTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var tokenType: String
    public var scope: String?
    public var email: String?

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        tokenType: String = "Bearer",
        scope: String? = nil,
        email: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.tokenType = tokenType
        self.scope = scope
        self.email = email
    }

    /// Converts a Google token response, preserving a rotated or unchanged
    /// refresh token and the previously known account email when omitted.
    public init(
        response: AntigravityOAuthTokenResponse,
        previous: AntigravityTokens? = nil,
        email: String? = nil,
        now: Date = Date()
    ) throws {
        let accessToken = response.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty else {
            throw AntigravityOAuthError.invalidResponse("The token response omitted an access token.")
        }
        if let tokenType = response.tokenType,
           tokenType.caseInsensitiveCompare("bearer") != .orderedSame {
            throw AntigravityOAuthError.invalidResponse("The token response returned an unsupported token type.")
        }
        if response.expiresIn == 0 {
            throw AntigravityOAuthError.invalidResponse("The token response returned a zero lifetime.")
        }

        let expiration: Date?
        if let expiresIn = response.expiresIn {
            expiration = now.addingTimeInterval(expiresIn)
        } else {
            expiration = previous?.expiresAt
        }

        let trimmedEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            accessToken: accessToken,
            refreshToken: Self.nonEmpty(response.refreshToken) ?? previous?.refreshToken,
            expiresAt: expiration,
            tokenType: response.tokenType ?? previous?.tokenType ?? "Bearer",
            scope: Self.nonEmpty(response.scope) ?? previous?.scope,
            email: (trimmedEmail?.isEmpty == false ? trimmedEmail : nil) ?? previous?.email
        )
    }

    /// Human-readable identity used to populate the provider identifier.
    public var identifier: String {
        if let email, !email.isEmpty { return email }
        return "Google account"
    }

    public func isExpired(at date: Date = Date(), skew: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= date.addingTimeInterval(skew)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}

// MARK: - Errors

public enum AntigravityOAuthError: Error, LocalizedError, Equatable, Sendable {
    case cancelled
    case notConfigured
    case stateMismatch
    case missingAuthorizationCode
    case providerError(code: String?, description: String?)
    case invalidConfiguration(String)
    case invalidCallback(String)
    case invalidResponse(String)
    case tokenExchangeFailed(statusCode: Int, message: String)
    case refreshFailed(statusCode: Int, message: String)
    case invalidGrant(String)
    case userInfoFailed(statusCode: Int, message: String)
    case notSignedIn
    case missingRefreshToken
    case unsupportedPlatform
    case failedToStartCallbackListener
    case browserFailed(String)

    public var errorDescription: String? {
        userMessage
    }

    public var userMessage: String {
        switch self {
        case .cancelled:
            return "Sign-in cancelled."
        case .notConfigured:
            return "Google OAuth is not configured."
        case .stateMismatch:
            return "Sign-in failed: the authorization response did not match this request (state mismatch)."
        case .missingAuthorizationCode:
            return "Sign-in failed: the authorization response did not include a code."
        case let .providerError(code, description):
            if let description, !description.isEmpty {
                return "Sign-in failed: \(description)"
            }
            return "Sign-in failed: \(code ?? "unknown_error")"
        case let .invalidConfiguration(message):
            return "Sign-in configuration error: \(message)"
        case let .invalidCallback(message):
            return "Sign-in failed: \(message)"
        case let .invalidResponse(message):
            return "Sign-in failed: \(message)"
        case let .tokenExchangeFailed(statusCode, message):
            return "Sign-in failed while exchanging the Google code (HTTP \(statusCode)): \(message)"
        case let .refreshFailed(statusCode, message):
            return "Could not refresh the Google session (HTTP \(statusCode)): \(message)"
        case let .invalidGrant(message):
            return "The Google session expired or was revoked. Please sign in again. \(message)"
        case let .userInfoFailed(statusCode, message):
            return "Could not read the Google account profile (HTTP \(statusCode)): \(message)"
        case .notSignedIn:
            return "Not signed in with Google."
        case .missingRefreshToken:
            return "The Google session has expired and cannot be refreshed. Please sign in again."
        case .unsupportedPlatform:
            return "Sign in with Google is only available on iOS."
        case .failedToStartCallbackListener:
            return "Sign-in failed: could not start the local callback listener."
        case let .browserFailed(message):
            return "Sign-in failed: \(message)"
        }
    }
}

// MARK: - Networking seam

public struct AntigravityOAuthCodeExchange: Sendable, Equatable {
    public let configuration: AntigravityOAuthConfiguration
    public let code: String
    public let codeVerifier: String
    public let redirectURI: URL

    public init(
        configuration: AntigravityOAuthConfiguration,
        code: String,
        codeVerifier: String,
        redirectURI: URL
    ) {
        self.configuration = configuration
        self.code = code
        self.codeVerifier = codeVerifier
        self.redirectURI = redirectURI
    }
}

public struct AntigravityOAuthRefreshRequest: Sendable, Equatable {
    public let configuration: AntigravityOAuthConfiguration
    public let refreshToken: String

    public init(configuration: AntigravityOAuthConfiguration, refreshToken: String) {
        self.configuration = configuration
        self.refreshToken = refreshToken
    }
}

public struct AntigravityUserInfoRequest: Sendable, Equatable {
    public let endpoint: URL
    public let accessToken: String

    public init(endpoint: URL, accessToken: String) {
        self.endpoint = endpoint
        self.accessToken = accessToken
    }
}

/// Injection point for unit tests; production uses
/// `URLSessionAntigravityOAuthNetworking`.
public protocol AntigravityOAuthNetworking: Sendable {
    func exchangeAuthorizationCode(_ request: AntigravityOAuthCodeExchange) async throws -> AntigravityOAuthTokenResponse
    func refreshToken(_ request: AntigravityOAuthRefreshRequest) async throws -> AntigravityOAuthTokenResponse
    func userInfo(_ request: AntigravityUserInfoRequest) async throws -> AntigravityUserInfo
}

public struct URLSessionAntigravityOAuthNetworking: AntigravityOAuthNetworking {
    public let session: URLSession

    #if canImport(os)
    private static let logger = Logger(subsystem: "com.example.slopWidget", category: "AntigravityAuth")
    #endif

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func exchangeAuthorizationCode(
        _ request: AntigravityOAuthCodeExchange
    ) async throws -> AntigravityOAuthTokenResponse {
        #if canImport(os)
        Self.logger.info(
            "Exchanging Google code: redirect=\(request.redirectURI.absoluteString, privacy: .public) codeLen=\(request.code.count) verifierLen=\(request.codeVerifier.count)"
        )
        #endif
        var parameters: [(String, String)] = [
            ("grant_type", "authorization_code"),
            ("client_id", request.configuration.clientID),
            ("code", request.code),
            ("redirect_uri", request.redirectURI.absoluteString),
            ("code_verifier", request.codeVerifier),
        ]
        if let secret = request.configuration.clientSecret, !secret.isEmpty {
            parameters.append(("client_secret", secret))
        }
        return try await post(
            endpoint: request.configuration.tokenEndpoint,
            parameters: parameters,
            failure: { status, message, code in
                if code == "invalid_grant" || message.contains("invalid_grant") {
                    return .invalidGrant(message)
                }
                return .tokenExchangeFailed(statusCode: status, message: message)
            }
        )
    }

    public func refreshToken(
        _ request: AntigravityOAuthRefreshRequest
    ) async throws -> AntigravityOAuthTokenResponse {
        var parameters: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("client_id", request.configuration.clientID),
            ("refresh_token", request.refreshToken),
        ]
        if let secret = request.configuration.clientSecret, !secret.isEmpty {
            parameters.append(("client_secret", secret))
        }
        return try await post(
            endpoint: request.configuration.tokenEndpoint,
            parameters: parameters,
            failure: { status, message, code in
                if code == "invalid_grant" || message.contains("invalid_grant") {
                    return .invalidGrant(message)
                }
                return .refreshFailed(statusCode: status, message: message)
            }
        )
    }

    public func userInfo(_ request: AntigravityUserInfoRequest) async throws -> AntigravityUserInfo {
        var urlRequest = URLRequest(url: request.endpoint)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("Bearer \(request.accessToken)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch is CancellationError {
            throw AntigravityOAuthError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw AntigravityOAuthError.cancelled
        } catch {
            throw AntigravityOAuthError.invalidResponse(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AntigravityOAuthError.invalidResponse("The userinfo endpoint returned a non-HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(decoding: data, as: UTF8.self)
            let parsed = Self.parseError(from: data)
            throw AntigravityOAuthError.userInfoFailed(
                statusCode: http.statusCode,
                message: parsed?.message ?? (body.isEmpty ? "no response body" : body)
            )
        }

        do {
            return try JSONDecoder().decode(AntigravityUserInfo.self, from: data)
        } catch {
            throw AntigravityOAuthError.invalidResponse("Could not decode the Google account profile.")
        }
    }

    private func post(
        endpoint: URL,
        parameters: [(String, String)],
        failure: (Int, String, String?) -> AntigravityOAuthError
    ) async throws -> AntigravityOAuthTokenResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("slopWidget/1.0 (iOS; Antigravity Google OAuth)", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(Self.formEncode(parameters).utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw AntigravityOAuthError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw AntigravityOAuthError.cancelled
        } catch {
            throw AntigravityOAuthError.invalidResponse(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AntigravityOAuthError.invalidResponse("The token endpoint returned a non-HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let parsed = Self.parseError(from: data)
            let body = String(decoding: data, as: UTF8.self)
            #if canImport(os)
            Self.logger.error(
                "Google token endpoint \(http.statusCode) at \(endpoint.absoluteString, privacy: .public): \(body, privacy: .public)"
            )
            #endif
            let detail = parsed?.message ?? (body.isEmpty ? "no response body" : body)
            throw failure(http.statusCode, detail, parsed?.code)
        }

        do {
            return try JSONDecoder().decode(AntigravityOAuthTokenResponse.self, from: data)
        } catch {
            throw AntigravityOAuthError.invalidResponse("Could not decode the Google token response.")
        }
    }

    private static func formEncode(_ parameters: [(String, String)]) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return parameters.map { name, value in
            let encodedName = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedName)=\(encodedValue)"
        }
        .joined(separator: "&")
    }

    static func parseError(from data: Data) -> (code: String?, message: String)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
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
            return (code, message ?? "unknown_error")
        }
        return nil
    }
}

// MARK: - Authorizer seam

/// Presents the system browser and returns the redirect URL. The production
/// implementation also owns the loopback listener. Tests inject a mock.
public protocol AntigravityAuthorizationPresenting: Sendable {
    @MainActor
    func authorize(context: AntigravityAuthorizationContext) async throws -> URL
}

// MARK: - Client

public struct AntigravityOAuthClient: Sendable {
    public let configuration: AntigravityOAuthConfiguration
    public let networking: any AntigravityOAuthNetworking
    public let presenter: any AntigravityAuthorizationPresenting

    public init(
        configuration: AntigravityOAuthConfiguration = .defaultConfiguration(),
        networking: any AntigravityOAuthNetworking = URLSessionAntigravityOAuthNetworking(),
        presenter: any AntigravityAuthorizationPresenting
    ) {
        self.configuration = configuration
        self.networking = networking
        self.presenter = presenter
    }

    /// Runs authorization + PKCE + token exchange and returns durable tokens.
    @MainActor
    public func authorize(
        pkce: PKCE = .generate(),
        state: String = OAuthState.generate()
    ) async throws -> AntigravityTokens {
        guard configuration.isConfigured else {
            throw AntigravityOAuthError.notConfigured
        }

        let context = AntigravityAuthorizationContext(
            configuration: configuration,
            pkce: pkce,
            state: state
        )

        let callbackURL: URL
        do {
            callbackURL = try await presenter.authorize(context: context)
        } catch let error as AntigravityOAuthError {
            throw error
        } catch is CancellationError {
            throw AntigravityOAuthError.cancelled
        } catch {
            throw AntigravityOAuthError.browserFailed(error.localizedDescription)
        }

        let callback = try AntigravityOAuthCallback(url: callbackURL)
        guard callback.state == state else {
            throw AntigravityOAuthError.stateMismatch
        }
        if let error = callback.error {
            throw AntigravityOAuthError.providerError(
                code: error,
                description: callback.errorDescription
            )
        }
        guard let code = callback.code, !code.isEmpty else {
            throw AntigravityOAuthError.missingAuthorizationCode
        }
        guard let redirectURI = Self.redirectURI(from: callbackURL) else {
            throw AntigravityOAuthError.invalidCallback("Could not determine the loopback redirect URI.")
        }

        let response = try await networking.exchangeAuthorizationCode(
            AntigravityOAuthCodeExchange(
                configuration: configuration,
                code: code,
                codeVerifier: pkce.codeVerifier,
                redirectURI: redirectURI
            )
        )

        // `userinfo.email` is requested, so resolve the account label. A
        // transient failure here must not discard an otherwise valid grant.
        let email: String?
        do {
            let info = try await networking.userInfo(
                AntigravityUserInfoRequest(
                    endpoint: configuration.userInfoEndpoint,
                    accessToken: response.accessToken
                )
            )
            email = info.email
        } catch {
            email = nil
        }

        return try AntigravityTokens(response: response, email: email)
    }

    /// Refreshes an existing grant. A new refresh token is preserved when present.
    public func refresh(_ tokens: AntigravityTokens, now: Date = Date()) async throws -> AntigravityTokens {
        guard let refreshToken = tokens.refreshToken, !refreshToken.isEmpty else {
            throw AntigravityOAuthError.missingRefreshToken
        }
        let response = try await networking.refreshToken(
            AntigravityOAuthRefreshRequest(
                configuration: configuration,
                refreshToken: refreshToken
            )
        )
        return try AntigravityTokens(response: response, previous: tokens, now: now)
    }

    /// Reconstructs the loopback redirect actually used by the callback, keeping
    /// the exact port the listener bound so the token exchange matches.
    private static func redirectURI(from callbackURL: URL) -> URL? {
        guard var components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.query = nil
        components.fragment = nil
        return components.url
    }
}
