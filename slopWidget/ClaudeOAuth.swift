import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(os)
import os
#endif

// MARK: - Configuration

/// Configuration for Anthropic's "Sign in with Claude" OAuth flow.
///
/// Every value below was read out of the installed Claude Code 2.1.312 binary
/// (its embedded OAuth config object), not from web sources:
/// - authorize: `https://claude.com/cai/oauth/authorize` (claude.ai accounts;
///   301/307s on to `claude.ai/oauth/authorize`)
/// - token: `https://platform.claude.com/v1/oauth/token`, **JSON** bodies only
/// - client: Claude Code's public PKCE client `9d1c250a-…`. This is NOT a client
///   registered for slopWidget; the app identifies to Anthropic as Claude Code.
/// - redirect: `http://localhost:<ephemeral port>/callback` (Claude Code binds
///   `127.0.0.1:0`), or the manual `https://platform.claude.com/oauth/code/callback`
///   page that displays a `code#state` string to paste back.
public struct ClaudeOAuthConfiguration: Sendable, Equatable {
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    public var clientID: String
    /// Only `user:profile` is needed for `/api/oauth/usage`; Claude Code itself
    /// asks for a larger set, but a narrower request is the least-privilege form.
    public var scopes: [String]
    public var manualRedirectURI: URL

    public static let loopbackHost = "localhost"
    public static let loopbackPath = "/callback"

    public init(
        authorizationEndpoint: URL = URL(string: "https://claude.com/cai/oauth/authorize")!,
        tokenEndpoint: URL = URL(string: "https://platform.claude.com/v1/oauth/token")!,
        clientID: String = "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
        scopes: [String] = ["user:profile"],
        manualRedirectURI: URL = URL(string: "https://platform.claude.com/oauth/code/callback")!
    ) {
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.clientID = clientID
        self.scopes = scopes
        self.manualRedirectURI = manualRedirectURI
    }

    public static func defaultConfiguration() -> ClaudeOAuthConfiguration {
        ClaudeOAuthConfiguration()
    }

    public var scopeString: String {
        scopes.joined(separator: " ")
    }
}

// MARK: - Authorization request

public struct ClaudeAuthorizationContext: Sendable, Equatable {
    public let configuration: ClaudeOAuthConfiguration
    public let pkce: PKCE
    public let state: String

    public init(
        configuration: ClaudeOAuthConfiguration = .defaultConfiguration(),
        pkce: PKCE = .generate(byteCount: 32),
        state: String = OAuthState.generate()
    ) {
        self.configuration = configuration
        self.pkce = pkce
        self.state = state
    }

    /// Builds the authorization URL for a loopback redirect (or the manual
    /// redirect when `redirectURI` is the configuration's manual page).
    public func authorizationURL(redirectURI: URL) throws -> URL {
        guard var components = URLComponents(
            url: configuration.authorizationEndpoint,
            resolvingAgainstBaseURL: false
        ) else {
            throw ClaudeOAuthError.invalidConfiguration("Invalid authorization endpoint")
        }
        components.queryItems = [
            // Claude Code sends `code=true` on every authorize request.
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: configuration.scopeString),
            URLQueryItem(name: "code_challenge", value: pkce.codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components.url else {
            throw ClaudeOAuthError.invalidConfiguration("Could not build authorization URL")
        }
        return url
    }

    /// The authorization URL for the paste-the-code variant.
    public func manualAuthorizationURL() throws -> URL {
        try authorizationURL(redirectURI: configuration.manualRedirectURI)
    }
}

// MARK: - Callback

public struct ClaudeOAuthCallback: Sendable, Equatable {
    public var code: String?
    public var state: String?
    public var error: String?
    public var errorDescription: String?

    public init(code: String? = nil, state: String? = nil, error: String? = nil, errorDescription: String? = nil) {
        self.code = code
        self.state = state
        self.error = error
        self.errorDescription = errorDescription
    }

    public init(url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ClaudeOAuthError.invalidCallback("Malformed callback URL")
        }
        let query = components.queryItems ?? []
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

    /// Parses the `code#state` string Claude's manual page displays.
    public static func parsePasted(_ pasted: String) throws -> ClaudeOAuthCallback {
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw ClaudeOAuthError.invalidPastedCode
        }
        return ClaudeOAuthCallback(code: String(parts[0]), state: String(parts[1]))
    }
}

// MARK: - Token response

public struct ClaudeOAuthTokenResponse: Codable, Sendable, Equatable {
    public struct Account: Codable, Sendable, Equatable {
        public var uuid: String?
        public var emailAddress: String?

        enum CodingKeys: String, CodingKey {
            case uuid
            case emailAddress = "email_address"
        }

        public init(uuid: String? = nil, emailAddress: String? = nil) {
            self.uuid = uuid
            self.emailAddress = emailAddress
        }
    }

    public struct Organization: Codable, Sendable, Equatable {
        public var uuid: String?
        public var name: String?

        public init(uuid: String? = nil, name: String? = nil) {
            self.uuid = uuid
            self.name = name
        }
    }

    public var accessToken: String
    public var refreshToken: String?
    public var expiresIn: TimeInterval?
    public var tokenType: String?
    public var scope: String?
    public var account: Account?
    public var organization: Organization?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
        case scope
        case account
        case organization
    }

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresIn: TimeInterval? = nil,
        tokenType: String? = nil,
        scope: String? = nil,
        account: Account? = nil,
        organization: Organization? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
        self.tokenType = tokenType
        self.scope = scope
        self.account = account
        self.organization = organization
    }
}

/// Durable OAuth credentials. This is the only value written to the Keychain.
public struct ClaudeTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var scopes: [String]
    public var email: String?
    public var accountUUID: String?
    public var organizationName: String?

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        scopes: [String] = [],
        email: String? = nil,
        accountUUID: String? = nil,
        organizationName: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.email = email
        self.accountUUID = accountUUID
        self.organizationName = organizationName
    }

    /// Converts a token endpoint response. A refresh response that omits a new
    /// refresh token keeps the previous one; account details persist likewise.
    public init(
        response: ClaudeOAuthTokenResponse,
        previous: ClaudeTokens? = nil,
        now: Date = Date()
    ) throws {
        let accessToken = response.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty else {
            throw ClaudeOAuthError.invalidResponse("The token response omitted an access token.")
        }
        if let tokenType = response.tokenType, tokenType.caseInsensitiveCompare("bearer") != .orderedSame {
            throw ClaudeOAuthError.invalidResponse("The token response returned an unsupported token type.")
        }
        if let expiresIn = response.expiresIn, expiresIn <= 0 {
            throw ClaudeOAuthError.invalidResponse("The token response returned a zero lifetime.")
        }

        let scopes = response.scope?.split(separator: " ").map(String.init) ?? previous?.scopes ?? []
        self.init(
            accessToken: accessToken,
            refreshToken: response.refreshToken?.nilIfEmpty ?? previous?.refreshToken,
            expiresAt: response.expiresIn.map { now.addingTimeInterval($0) } ?? previous?.expiresAt,
            scopes: scopes,
            email: response.account?.emailAddress ?? previous?.email,
            accountUUID: response.account?.uuid ?? previous?.accountUUID,
            organizationName: response.organization?.name ?? previous?.organizationName
        )
    }

    public var identifier: String {
        if let email, !email.isEmpty { return email }
        if let accountUUID, !accountUUID.isEmpty { return accountUUID }
        return "Claude account"
    }

    public func isExpired(at date: Date = Date(), skew: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= date.addingTimeInterval(skew)
    }
}

// MARK: - Errors

public enum ClaudeOAuthError: Error, LocalizedError, Equatable, Sendable {
    case cancelled
    case stateMismatch
    case missingAuthorizationCode
    case invalidPastedCode
    case providerError(code: String?, description: String?)
    case invalidConfiguration(String)
    case invalidCallback(String)
    case invalidResponse(String)
    case tokenExchangeFailed(statusCode: Int, message: String)
    case refreshFailed(statusCode: Int, message: String)
    case invalidGrant(String)
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
        case .stateMismatch:
            return "Sign-in failed: the authorization response did not match this request (state mismatch)."
        case .missingAuthorizationCode:
            return "Sign-in failed: the authorization response did not include a code."
        case .invalidPastedCode:
            return "That doesn't look like a Claude sign-in code. Paste the whole code, including the part after #."
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
            return "Sign-in failed while exchanging the code (HTTP \(statusCode)): \(message)"
        case let .refreshFailed(statusCode, message):
            return "Could not refresh the Claude session (HTTP \(statusCode)): \(message)"
        case let .invalidGrant(message):
            return "The Claude session expired or was revoked. Please sign in again. \(message)"
        case .notSignedIn:
            return "Not signed in with Claude."
        case .missingRefreshToken:
            return "The Claude session has expired and cannot be refreshed. Please sign in again."
        case .unsupportedPlatform:
            return "Sign in with Claude is only available on iOS."
        case .failedToStartCallbackListener:
            return "Sign-in failed: could not start the local callback listener. Use \"paste code\" instead."
        case let .browserFailed(message):
            return "Sign-in failed: \(message)"
        }
    }
}

// MARK: - Networking seam

public struct ClaudeOAuthCodeExchange: Sendable, Equatable {
    public let configuration: ClaudeOAuthConfiguration
    public let code: String
    public let codeVerifier: String
    public let redirectURI: URL
    /// Claude's token endpoint also takes the original `state` in the body.
    public let state: String

    public init(
        configuration: ClaudeOAuthConfiguration,
        code: String,
        codeVerifier: String,
        redirectURI: URL,
        state: String
    ) {
        self.configuration = configuration
        self.code = code
        self.codeVerifier = codeVerifier
        self.redirectURI = redirectURI
        self.state = state
    }
}

public struct ClaudeOAuthRefreshRequest: Sendable, Equatable {
    public let configuration: ClaudeOAuthConfiguration
    public let refreshToken: String

    public init(configuration: ClaudeOAuthConfiguration, refreshToken: String) {
        self.configuration = configuration
        self.refreshToken = refreshToken
    }
}

/// Injection point for unit tests; production uses `URLSessionClaudeOAuthNetworking`.
public protocol ClaudeOAuthNetworking: Sendable {
    func exchangeAuthorizationCode(_ request: ClaudeOAuthCodeExchange) async throws -> ClaudeOAuthTokenResponse
    func refreshToken(_ request: ClaudeOAuthRefreshRequest) async throws -> ClaudeOAuthTokenResponse
}

public struct URLSessionClaudeOAuthNetworking: ClaudeOAuthNetworking {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func exchangeAuthorizationCode(_ request: ClaudeOAuthCodeExchange) async throws -> ClaudeOAuthTokenResponse {
        try await post(
            request: Self.exchangeRequest(for: request),
            failure: { status, message, code in
                if code == "invalid_grant" {
                    return .invalidGrant(message)
                }
                return .tokenExchangeFailed(statusCode: status, message: message)
            }
        )
    }

    public func refreshToken(_ request: ClaudeOAuthRefreshRequest) async throws -> ClaudeOAuthTokenResponse {
        try await post(
            request: Self.refreshRequest(for: request),
            failure: { status, message, code in
                if code == "invalid_grant" {
                    return .invalidGrant(message)
                }
                return .refreshFailed(statusCode: status, message: message)
            }
        )
    }

    // The token endpoint rejects form-encoded bodies ("Invalid request format");
    // Claude Code posts JSON for both grants.

    static func exchangeRequest(for exchange: ClaudeOAuthCodeExchange) throws -> URLRequest {
        try jsonRequest(
            endpoint: exchange.configuration.tokenEndpoint,
            body: [
                "grant_type": "authorization_code",
                "code": exchange.code,
                "redirect_uri": exchange.redirectURI.absoluteString,
                "client_id": exchange.configuration.clientID,
                "code_verifier": exchange.codeVerifier,
                "state": exchange.state,
            ]
        )
    }

    static func refreshRequest(for refresh: ClaudeOAuthRefreshRequest) throws -> URLRequest {
        try jsonRequest(
            endpoint: refresh.configuration.tokenEndpoint,
            body: [
                "grant_type": "refresh_token",
                "refresh_token": refresh.refreshToken,
                "client_id": refresh.configuration.clientID,
                "scope": refresh.configuration.scopeString,
            ]
        )
    }

    private static func jsonRequest(endpoint: URL, body: [String: String]) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("slopWidget/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    private func post(
        request: URLRequest,
        failure: (Int, String, String?) -> ClaudeOAuthError
    ) async throws -> ClaudeOAuthTokenResponse {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw ClaudeOAuthError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw ClaudeOAuthError.cancelled
        } catch {
            throw ClaudeOAuthError.invalidResponse(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClaudeOAuthError.invalidResponse("The token endpoint returned a non-HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let parsed = Self.parseError(from: data)
            let detail = parsed?.message ?? "no usable error body"
            throw failure(http.statusCode, detail, parsed?.code)
        }

        do {
            return try JSONDecoder().decode(ClaudeOAuthTokenResponse.self, from: data)
        } catch {
            throw ClaudeOAuthError.invalidResponse("Could not decode the token response.")
        }
    }

    /// Understands both observed error shapes:
    /// `{"error":"invalid_grant","error_description":"…"}` and
    /// `{"type":"error","error":{"type":"rate_limit_error","message":"…"}}`.
    static func parseError(from data: Data) -> (code: String?, message: String)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let code = json["error"] as? String {
            return (code, json["error_description"] as? String ?? code)
        }
        if let error = json["error"] as? [String: Any] {
            let code = error["type"] as? String ?? error["code"] as? String
            let message = error["message"] as? String ?? error["error_description"] as? String ?? code
            return (code, message ?? "unknown_error")
        }
        return nil
    }
}

// MARK: - Authorizer seam

/// Presents the system browser and returns the redirect URL. The production
/// implementation also owns the loopback HTTP listener. Tests inject a mock.
public protocol ClaudeAuthorizationPresenting: Sendable {
    @MainActor
    func authorize(context: ClaudeAuthorizationContext) async throws -> URL
}

// MARK: - Client

public struct ClaudeOAuthClient: Sendable {
    public let configuration: ClaudeOAuthConfiguration
    public let networking: any ClaudeOAuthNetworking
    public let presenter: any ClaudeAuthorizationPresenting

    public init(
        configuration: ClaudeOAuthConfiguration = .defaultConfiguration(),
        networking: any ClaudeOAuthNetworking = URLSessionClaudeOAuthNetworking(),
        presenter: any ClaudeAuthorizationPresenting
    ) {
        self.configuration = configuration
        self.networking = networking
        self.presenter = presenter
    }

    /// Loopback flow: authorization + PKCE + token exchange.
    @MainActor
    public func authorize(
        pkce: PKCE = .generate(byteCount: 32),
        state: String = OAuthState.generate()
    ) async throws -> ClaudeTokens {
        let context = ClaudeAuthorizationContext(configuration: configuration, pkce: pkce, state: state)

        let callbackURL: URL
        do {
            callbackURL = try await presenter.authorize(context: context)
        } catch let error as ClaudeOAuthError {
            throw error
        } catch is CancellationError {
            throw ClaudeOAuthError.cancelled
        } catch {
            throw ClaudeOAuthError.browserFailed(error.localizedDescription)
        }

        let callback = try ClaudeOAuthCallback(url: callbackURL)
        return try await complete(callback: callback, context: context, redirectURI: Self.redirectURI(from: callbackURL))
    }

    /// Paste-the-code flow: exchanges a `code#state` string against the manual redirect.
    public func authorizeManually(pasted: String, context: ClaudeAuthorizationContext) async throws -> ClaudeTokens {
        let callback = try ClaudeOAuthCallback.parsePasted(pasted)
        return try await complete(callback: callback, context: context, redirectURI: configuration.manualRedirectURI)
    }

    private func complete(
        callback: ClaudeOAuthCallback,
        context: ClaudeAuthorizationContext,
        redirectURI: URL
    ) async throws -> ClaudeTokens {
        guard callback.state == context.state else {
            throw ClaudeOAuthError.stateMismatch
        }
        if let error = callback.error {
            throw ClaudeOAuthError.providerError(code: error, description: callback.errorDescription)
        }
        guard let code = callback.code, !code.isEmpty else {
            throw ClaudeOAuthError.missingAuthorizationCode
        }
        let response = try await networking.exchangeAuthorizationCode(
            ClaudeOAuthCodeExchange(
                configuration: configuration,
                code: code,
                codeVerifier: context.pkce.codeVerifier,
                redirectURI: redirectURI,
                state: context.state
            )
        )
        return try ClaudeTokens(response: response)
    }

    /// Refreshes an existing grant. The (rotated) refresh token is returned in the result.
    public func refresh(_ tokens: ClaudeTokens, now: Date = Date()) async throws -> ClaudeTokens {
        guard let refreshToken = tokens.refreshToken, !refreshToken.isEmpty else {
            throw ClaudeOAuthError.missingRefreshToken
        }
        let response = try await networking.refreshToken(
            ClaudeOAuthRefreshRequest(configuration: configuration, refreshToken: refreshToken)
        )
        return try ClaudeTokens(response: response, previous: tokens, now: now)
    }

    /// Reconstructs the loopback redirect actually used by the callback.
    private static func redirectURI(from callbackURL: URL) -> URL {
        guard var components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            return callbackURL
        }
        components.query = nil
        components.fragment = nil
        return components.url ?? callbackURL
    }
}
