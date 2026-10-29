import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(CryptoKit)
import CryptoKit
#endif

#if canImport(os)
import os
#endif

// MARK: - Configuration

/// Configuration for OpenAI's native-app ("Sign in with ChatGPT") OAuth flow.
///
/// These values mirror the public Codex CLI client: the authorization and token
/// endpoints live on `auth.openai.com`, the client is a public PKCE client, and
/// the only registered redirect URIs are loopback callbacks on ports 1455/1457.
public struct ChatGPTOAuthConfiguration: Sendable, Equatable {
    public var issuer: URL
    public var clientID: String
    public var scopes: [String]
    public var redirectURI: URL
    public var originator: String

    public init(
        issuer: URL = URL(string: "https://auth.openai.com")!,
        clientID: String = "app_EMoamEEZ73f0CkXaXp7hrann",
        scopes: [String] = [
            "openid",
            "profile",
            "email",
            "offline_access",
            "api.connectors.read",
            "api.connectors.invoke",
        ],
        redirectURI: URL = URL(string: "http://127.0.0.1:1455/auth/callback")!,
        originator: String = "codex_cli_rs"
    ) {
        self.issuer = issuer
        self.clientID = clientID
        self.scopes = scopes
        self.redirectURI = redirectURI
        self.originator = originator
    }

    /// The Codex/ChatGPT login configuration registered for OpenAI's native client.
    public static func codex(redirectPort: UInt16 = 1455) -> ChatGPTOAuthConfiguration {
        ChatGPTOAuthConfiguration(
            redirectURI: URL(string: "http://127.0.0.1:\(redirectPort)/auth/callback")!
        )
    }

    public var authorizationEndpoint: URL {
        issuer.appendingPathComponent("oauth/authorize")
    }

    public var tokenEndpoint: URL {
        issuer.appendingPathComponent("oauth/token")
    }

    public var scopeString: String {
        scopes.joined(separator: " ")
    }

    /// Returns a copy whose redirect URI points at a freshly bound loopback port.
    public func withRedirectURI(_ redirectURI: URL) -> ChatGPTOAuthConfiguration {
        var copy = self
        copy.redirectURI = redirectURI
        return copy
    }
}

// MARK: - PKCE

/// Proof Key for Code Exchange (RFC 7636) values.
public struct PKCE: Sendable, Equatable {
    public let codeVerifier: String
    public let codeChallenge: String

    public init(codeVerifier: String) {
        self.codeVerifier = codeVerifier
        self.codeChallenge = Self.challenge(for: codeVerifier)
    }

    /// Creates a high-entropy verifier (64 random bytes, base64url, no padding).
    public static func generate(byteCount: Int = 64) -> PKCE {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<max(32, byteCount)).map { _ in
            UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        }
        return PKCE(codeVerifier: Data(bytes).base64URLEncodedString)
    }

    /// `BASE64URL(SHA256(ASCII(code_verifier)))` without padding.
    public static func challenge(for codeVerifier: String) -> String {
        let digest = sha256(Data(codeVerifier.utf8))
        return digest.base64URLEncodedString
    }

    private static func sha256(_ data: Data) -> Data {
        #if canImport(CryptoKit)
        return Data(SHA256.hash(data: data))
        #else
        return SHA256Fallback.hash(data)
        #endif
    }
}

/// Generates opaque OAuth state values.
public enum OAuthState {
    public static func generate(byteCount: Int = 32) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<max(16, byteCount)).map { _ in
            UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        }
        return Data(bytes).base64URLEncodedString
    }
}

// MARK: - Authorization request

public struct ChatGPTAuthorizationContext: Sendable, Equatable {
    public let configuration: ChatGPTOAuthConfiguration
    public let pkce: PKCE
    public let state: String

    public init(
        configuration: ChatGPTOAuthConfiguration = .codex(),
        pkce: PKCE = .generate(),
        state: String = OAuthState.generate()
    ) {
        self.configuration = configuration
        self.pkce = pkce
        self.state = state
    }

    /// Builds the authorization URL. A custom redirect is used when the loopback
    /// listener had to fall back from port 1455 to 1457.
    public func authorizationURL(redirectURI: URL? = nil) throws -> URL {
        try ChatGPTOAuthRequestBuilder.authorizationURL(
            configuration: configuration,
            redirectURI: redirectURI ?? configuration.redirectURI,
            pkce: pkce,
            state: state
        )
    }
}

public enum ChatGPTOAuthRequestBuilder {
    public static func authorizationURL(
        configuration: ChatGPTOAuthConfiguration,
        redirectURI: URL? = nil,
        pkce: PKCE,
        state: String
    ) throws -> URL {
        guard var components = URLComponents(
            url: configuration.authorizationEndpoint,
            resolvingAgainstBaseURL: false
        ) else {
            throw ChatGPTOAuthError.invalidConfiguration("Invalid authorization endpoint")
        }

        var items = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: (redirectURI ?? configuration.redirectURI).absoluteString),
            URLQueryItem(name: "scope", value: configuration.scopeString),
            URLQueryItem(name: "code_challenge", value: pkce.codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            // Matches the parameters the Codex CLI sends so the registered
            // native client issues an ID token with organization claims.
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: configuration.originator),
        ]
        items.removeAll { $0.value == nil }
        components.queryItems = items

        guard let url = components.url else {
            throw ChatGPTOAuthError.invalidConfiguration("Could not build authorization URL")
        }
        return url
    }
}

// MARK: - Callback

public struct ChatGPTOAuthCallback: Sendable, Equatable {
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
            throw ChatGPTOAuthError.invalidCallback("Malformed callback URL")
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

public struct ChatGPTOAuthTokenResponse: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var idToken: String?
    public var expiresIn: TimeInterval?
    public var tokenType: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        idToken: String? = nil,
        expiresIn: TimeInterval? = nil,
        tokenType: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.expiresIn = expiresIn
        self.tokenType = tokenType
    }
}

/// Identity claims carried by OpenAI's ID token.
public struct ChatGPTIdentity: Sendable, Equatable {
    public var email: String?
    public var accountID: String?
    public var userID: String?
    public var planType: String?

    public init(email: String? = nil, accountID: String? = nil, userID: String? = nil, planType: String? = nil) {
        self.email = email
        self.accountID = accountID
        self.userID = userID
        self.planType = planType
    }

    /// Parses (but deliberately does not cryptographically verify) the ID token
    /// payload. The token is received directly from the issuer over TLS, matching
    /// the Codex CLI's local claim parsing.
    public static func parse(idToken: String?) -> ChatGPTIdentity {
        guard let idToken, let payload = JWT.payload(idToken) else {
            return ChatGPTIdentity()
        }
        let profile = payload["https://api.openai.com/profile"] as? [String: Any]
        let auth = payload["https://api.openai.com/auth"] as? [String: Any]

        let email = (payload["email"] as? String)
            ?? (profile?["email"] as? String)
        let accountID = (auth?["chatgpt_account_id"] as? String)
            ?? (payload["chatgpt_account_id"] as? String)
        let userID = (auth?["chatgpt_user_id"] as? String)
            ?? (payload["chatgpt_user_id"] as? String)
        let planType = (auth?["chatgpt_plan_type"] as? String)
            ?? (payload["chatgpt_plan_type"] as? String)

        return ChatGPTIdentity(
            email: email,
            accountID: accountID,
            userID: userID,
            planType: planType
        )
    }
}

/// Durable OAuth credentials. This is the only value written to secure storage.
public struct ChatGPTTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var idToken: String?
    public var expiresAt: Date?
    public var tokenType: String
    public var accountID: String?
    public var email: String?
    public var userID: String?
    public var planType: String?

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        idToken: String? = nil,
        expiresAt: Date? = nil,
        tokenType: String = "Bearer",
        accountID: String? = nil,
        email: String? = nil,
        userID: String? = nil,
        planType: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.expiresAt = expiresAt
        self.tokenType = tokenType
        self.accountID = accountID
        self.email = email
        self.userID = userID
        self.planType = planType
    }

    /// Converts a token endpoint response, preserving a rotated or unchanged
    /// refresh token when the endpoint omits one.
    public init(
        response: ChatGPTOAuthTokenResponse,
        previous: ChatGPTTokens? = nil,
        now: Date = Date()
    ) throws {
        let accessToken = response.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty else {
            throw ChatGPTOAuthError.invalidResponse("The token response omitted an access token.")
        }
        if let tokenType = response.tokenType, tokenType.caseInsensitiveCompare("bearer") != .orderedSame {
            throw ChatGPTOAuthError.invalidResponse("The token response returned an unsupported token type.")
        }
        if response.expiresIn == 0 {
            throw ChatGPTOAuthError.invalidResponse("The token response returned a zero lifetime.")
        }

        let identity = ChatGPTIdentity.parse(idToken: response.idToken ?? previous?.idToken)
        let expiration: Date?
        if let expiresIn = response.expiresIn {
            expiration = now.addingTimeInterval(expiresIn)
        } else if let idToken = response.idToken, let exp = JWT.expiration(idToken) {
            expiration = exp
        } else {
            expiration = previous?.expiresAt
        }

        self.init(
            accessToken: accessToken,
            refreshToken: response.refreshToken ?? previous?.refreshToken,
            idToken: response.idToken ?? previous?.idToken,
            expiresAt: expiration,
            tokenType: response.tokenType ?? previous?.tokenType ?? "Bearer",
            accountID: identity.accountID,
            email: identity.email,
            userID: identity.userID,
            planType: identity.planType
        )
    }

    /// Human-readable identity used to populate the provider identifier.
    public var identifier: String {
        if let email, !email.isEmpty { return email }
        if let accountID, !accountID.isEmpty { return accountID }
        return "ChatGPT account"
    }

    public func isExpired(at date: Date = Date(), skew: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= date.addingTimeInterval(skew)
    }
}

// MARK: - Errors

public enum ChatGPTOAuthError: Error, LocalizedError, Equatable, Sendable {
    case cancelled
    case stateMismatch
    case missingAuthorizationCode
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
            return "Could not refresh the ChatGPT session (HTTP \(statusCode)): \(message)"
        case let .invalidGrant(message):
            return "The ChatGPT session expired or was revoked. Please sign in again. \(message)"
        case .notSignedIn:
            return "Not signed in with ChatGPT."
        case .missingRefreshToken:
            return "The ChatGPT session has expired and cannot be refreshed. Please sign in again."
        case .unsupportedPlatform:
            return "Sign in with ChatGPT is only available on iOS."
        case .failedToStartCallbackListener:
            return "Sign-in failed: could not start the local callback listener on port 1455 or 1457."
        case let .browserFailed(message):
            return "Sign-in failed: \(message)"
        }
    }
}

// MARK: - Networking seam

public struct ChatGPTOAuthCodeExchange: Sendable, Equatable {
    public let configuration: ChatGPTOAuthConfiguration
    public let code: String
    public let codeVerifier: String
    public let redirectURI: URL

    public init(configuration: ChatGPTOAuthConfiguration, code: String, codeVerifier: String, redirectURI: URL) {
        self.configuration = configuration
        self.code = code
        self.codeVerifier = codeVerifier
        self.redirectURI = redirectURI
    }
}

public struct ChatGPTOAuthRefreshRequest: Sendable, Equatable {
    public let configuration: ChatGPTOAuthConfiguration
    public let refreshToken: String

    public init(configuration: ChatGPTOAuthConfiguration, refreshToken: String) {
        self.configuration = configuration
        self.refreshToken = refreshToken
    }
}

/// Injection point for unit tests; production uses `URLSessionChatGPTOAuthNetworking`.
public protocol ChatGPTOAuthNetworking: Sendable {
    func exchangeAuthorizationCode(_ request: ChatGPTOAuthCodeExchange) async throws -> ChatGPTOAuthTokenResponse
    func refreshToken(_ request: ChatGPTOAuthRefreshRequest) async throws -> ChatGPTOAuthTokenResponse
}

public struct URLSessionChatGPTOAuthNetworking: ChatGPTOAuthNetworking {
    public let session: URLSession

    #if canImport(os)
    private static let logger = Logger(subsystem: "com.example.slopWidget", category: "ChatGPTAuth")
    #endif

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func exchangeAuthorizationCode(_ request: ChatGPTOAuthCodeExchange) async throws -> ChatGPTOAuthTokenResponse {
        #if canImport(os)
        Self.logger.info("Exchanging ChatGPT code: redirect=\(request.redirectURI.absoluteString, privacy: .public) codeLen=\(request.code.count) verifierLen=\(request.codeVerifier.count)")
        #endif
        return try await post(
            endpoint: request.configuration.tokenEndpoint,
            parameters: [
                ("grant_type", "authorization_code"),
                ("client_id", request.configuration.clientID),
                ("code", request.code),
                ("redirect_uri", request.redirectURI.absoluteString),
                ("code_verifier", request.codeVerifier),
            ],
            failure: { status, message, code in
                if code == "invalid_grant" || message.contains("invalid_grant") {
                    return .invalidGrant(message)
                }
                return .tokenExchangeFailed(statusCode: status, message: message)
            }
        )
    }

    public func refreshToken(_ request: ChatGPTOAuthRefreshRequest) async throws -> ChatGPTOAuthTokenResponse {
        try await post(
            endpoint: request.configuration.tokenEndpoint,
            parameters: [
                ("grant_type", "refresh_token"),
                ("client_id", request.configuration.clientID),
                ("refresh_token", request.refreshToken),
            ],
            json: true,
            failure: { status, message, code in
                if code == "invalid_grant" || message.contains("invalid_grant") {
                    return .invalidGrant(message)
                }
                return .refreshFailed(statusCode: status, message: message)
            }
        )
    }

    private func post(
        endpoint: URL,
        parameters: [(String, String)],
        json: Bool = false,
        failure: (Int, String, String?) -> ChatGPTOAuthError
    ) async throws -> ChatGPTOAuthTokenResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        if json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(
                withJSONObject: Dictionary(uniqueKeysWithValues: parameters)
            )
        } else {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(Self.formEncode(parameters).utf8)
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // The token endpoint is the registered Codex native client. Match the
        // CLI's identifying headers as well as its client_id/redirect_uri.
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        request.setValue("codex_cli_rs/0.164.0 (Linux; x86_64) slopWidget/1.0", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw ChatGPTOAuthError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw ChatGPTOAuthError.cancelled
        } catch {
            throw ChatGPTOAuthError.invalidResponse(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ChatGPTOAuthError.invalidResponse("The token endpoint returned a non-HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let parsed = Self.parseError(from: data)
            let body = String(decoding: data, as: UTF8.self)
            #if canImport(os)
            Self.logger.error("Token endpoint \(http.statusCode) at \(endpoint.absoluteString, privacy: .public): \(body, privacy: .public)")
            #endif
            let detail = parsed?.message ?? (body.isEmpty ? "no response body" : body)
            throw failure(http.statusCode, detail, parsed?.code)
        }

        do {
            return try JSONDecoder().decode(ChatGPTOAuthTokenResponse.self, from: data)
        } catch {
            throw ChatGPTOAuthError.invalidResponse("Could not decode the token response.")
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
/// implementation also owns the loopback HTTP listener. Tests inject a mock.
public protocol ChatGPTAuthorizationPresenting: Sendable {
    @MainActor
    func authorize(context: ChatGPTAuthorizationContext) async throws -> URL
}

// MARK: - Client

public struct ChatGPTOAuthClient: Sendable {
    public let configuration: ChatGPTOAuthConfiguration
    public let networking: any ChatGPTOAuthNetworking
    public let presenter: any ChatGPTAuthorizationPresenting

    public init(
        configuration: ChatGPTOAuthConfiguration = .codex(),
        networking: any ChatGPTOAuthNetworking = URLSessionChatGPTOAuthNetworking(),
        presenter: any ChatGPTAuthorizationPresenting
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
    ) async throws -> ChatGPTTokens {
        let context = ChatGPTAuthorizationContext(configuration: configuration, pkce: pkce, state: state)

        let callbackURL: URL
        do {
            callbackURL = try await presenter.authorize(context: context)
        } catch let error as ChatGPTOAuthError {
            throw error
        } catch is CancellationError {
            throw ChatGPTOAuthError.cancelled
        } catch {
            throw ChatGPTOAuthError.browserFailed(error.localizedDescription)
        }

        let callback = try ChatGPTOAuthCallback(url: callbackURL)
        guard callback.state == state else {
            throw ChatGPTOAuthError.stateMismatch
        }
        if let error = callback.error {
            throw ChatGPTOAuthError.providerError(code: error, description: callback.errorDescription)
        }
        guard let code = callback.code, !code.isEmpty else {
            throw ChatGPTOAuthError.missingAuthorizationCode
        }

        let redirectURI = Self.redirectURI(from: callbackURL) ?? configuration.redirectURI
        let response = try await networking.exchangeAuthorizationCode(
            ChatGPTOAuthCodeExchange(
                configuration: configuration,
                code: code,
                codeVerifier: pkce.codeVerifier,
                redirectURI: redirectURI
            )
        )
        return try ChatGPTTokens(response: response)
    }

    /// Refreshes an existing grant. A new refresh token is preserved when present.
    public func refresh(_ tokens: ChatGPTTokens, now: Date = Date()) async throws -> ChatGPTTokens {
        guard let refreshToken = tokens.refreshToken, !refreshToken.isEmpty else {
            throw ChatGPTOAuthError.missingRefreshToken
        }
        let response = try await networking.refreshToken(
            ChatGPTOAuthRefreshRequest(configuration: configuration, refreshToken: refreshToken)
        )
        return try ChatGPTTokens(response: response, previous: tokens, now: now)
    }

    /// Reconstructs the loopback redirect actually used by the callback.
    private static func redirectURI(from callbackURL: URL) -> URL? {
        guard var components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

// MARK: - JWT helpers

enum JWT {
    static func payload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, let data = base64URLDecode(String(parts[1])) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func expiration(_ token: String) -> Date? {
        guard let exp = payload(token)?["exp"] as? TimeInterval else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    static func base64URLDecode(_ value: String) -> Data? {
        var string = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = string.count % 4
        if remainder > 0 {
            string += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: string)
    }
}

extension Data {
    var base64URLEncodedString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

#if !canImport(CryptoKit)
enum SHA256Fallback {
    static func hash(data: Data) -> Data {
        var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
        ]

        var message = [UInt8](data)
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        let bitLength = UInt64(data.count) * 8
        message += withUnsafeBytes(of: bitLength.bigEndian) { Array($0) }

        func rotate(_ value: UInt32, _ amount: UInt32) -> UInt32 {
            (value >> amount) | (value << (32 - amount))
        }

        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let offset = chunkStart + i * 4
                w[i] = (UInt32(message[offset]) << 24)
                    | (UInt32(message[offset + 1]) << 16)
                    | (UInt32(message[offset + 2]) << 8)
                    | UInt32(message[offset + 3])
            }
            for i in 16..<64 {
                let s0 = rotate(w[i - 15], 7) ^ rotate(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotate(w[i - 2], 17) ^ rotate(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }

            var a = h[0], b = h[1], c = h[2], d = h[3]
            var e = h[4], f = h[5], g = h[6], hh = h[7]

            for i in 0..<64 {
                let s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
                let ch = (e & f) ^ (~e & g)
                let temp1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj
                hh = g; g = f; f = e
                e = d &+ temp1
                d = c; c = b; b = a
                a = temp1 &+ temp2
            }

            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }

        var output = Data()
        for value in h {
            output.append(contentsOf: withUnsafeBytes(of: value.bigEndian) { Array($0) })
        }
        return output
    }
}
#endif
