import Foundation
import SwiftUI
#if canImport(WidgetKit)
import WidgetKit
#endif
#if canImport(WidgetKit)
import WidgetKit
#endif

public enum ServiceProviderType: String, CaseIterable, Identifiable {
    case antigravity = "antigravity"
    case codex = "codex"
    case opencodeGo = "opencode-go"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .antigravity: return "Antigravity"
        case .codex: return "Codex"
        case .opencodeGo: return "OpenCode Go"
        }
    }

    public var icon: String {
        switch self {
        case .antigravity: return "sparkles"
        case .codex: return "terminal.fill"
        case .opencodeGo: return "bolt.fill"
        }
    }

    public var brandColor: Color {
        switch self {
        case .antigravity: return Color(red: 0.65, green: 0.40, blue: 0.98)
        case .codex: return Color(red: 0.20, green: 0.80, blue: 0.58)
        case .opencodeGo: return Color(red: 0.25, green: 0.65, blue: 0.98)
        }
    }

    public var placeholderKey: String {
        switch self {
        case .antigravity: return "ag_live_..."
        case .codex: return "sk-proj-..."
        case .opencodeGo: return "ocg_pat_..."
        }
    }
}

public struct ServiceCredentials: Codable, Equatable, Sendable {
    public var apiKey: String
    public var identifier: String // Email, Org ID, or Server URL
    public var isLoggedIn: Bool
    public var lastVerified: Date?

    public init(apiKey: String = "", identifier: String = "", isLoggedIn: Bool = false, lastVerified: Date? = nil) {
        self.apiKey = apiKey
        self.identifier = identifier
        self.isLoggedIn = isLoggedIn
        self.lastVerified = lastVerified
    }
}

/// How the Codex provider is currently authenticated.
public enum ChatGPTAuthMethod: String, Codable, Sendable {
    /// A manually pasted API key/token stored in `ServiceCredentials`.
    case apiKey
    /// A ChatGPT OAuth session whose tokens live in the Keychain.
    case chatGPT
}

/// Observable state of the "Sign in with ChatGPT" flow.
public enum ChatGPTAuthState: Equatable, Sendable {
    case signedOut
    case authorizing
    case exchanging
    case signedIn(identifier: String, expiresAt: Date?)
    case failed(String)

    public var isSignedIn: Bool {
        if case .signedIn = self { return true }
        return false
    }

    public var isBusy: Bool {
        switch self {
        case .authorizing, .exchanging: return true
        default: return false
        }
    }

    public var statusText: String {
        switch self {
        case .signedOut:
            return "Not signed in with ChatGPT."
        case .authorizing:
            return "Waiting for ChatGPT sign-in in the browser…"
        case .exchanging:
            return "Finishing sign-in…"
        case let .signedIn(identifier, expiresAt):
            if let expiresAt {
                let formatter = DateFormatter()
                formatter.dateStyle = .short
                formatter.timeStyle = .short
                return "Signed in as \(identifier). Token valid until \(formatter.string(from: expiresAt))."
            }
            return "Signed in as \(identifier)."
        case let .failed(message):
            return message
        }
    }
}

/// How the Antigravity provider is currently authenticated.
public enum AntigravityAuthMethod: String, Codable, Sendable {
    /// A manually pasted API key/token stored in `ServiceCredentials`.
    case apiKey
    /// A Google OAuth session whose tokens live in the Keychain.
    case google
}

/// Observable state of the Antigravity "Sign in with Google" flow.
public enum AntigravityAuthState: Equatable, Sendable {
    case signedOut
    case authorizing
    case exchanging
    case signedIn(identifier: String, expiresAt: Date?)
    case failed(String)

    public var isSignedIn: Bool {
        if case .signedIn = self { return true }
        return false
    }

    public var isBusy: Bool {
        switch self {
        case .authorizing, .exchanging: return true
        default: return false
        }
    }

    public var statusText: String {
        switch self {
        case .signedOut:
            return "Not signed in with Google."
        case .authorizing:
            return "Waiting for Google sign-in in the browser…"
        case .exchanging:
            return "Finishing sign-in…"
        case let .signedIn(identifier, expiresAt):
            if let expiresAt {
                let formatter = DateFormatter()
                formatter.dateStyle = .short
                formatter.timeStyle = .short
                return "Signed in as \(identifier). Token valid until \(formatter.string(from: expiresAt))."
            }
            return "Signed in as \(identifier)."
        case let .failed(message):
            return message
        }
    }
}

/// How the OpenCode Go provider is currently authenticated.
public enum OpenCodeAuthMethod: String, Codable, Sendable {
    /// A manually pasted token/endpoint stored in `ServiceCredentials`.
    case apiKey
    /// An OpenCode Console OAuth session whose tokens live in the Keychain.
    case oauth
}

/// Observable state of the "Sign in with OpenCode" device flow.
public enum OpenCodeAuthState: Equatable, Sendable {
    case signedOut
    case requestingCode
    case waitingForApproval(userCode: String, verificationURL: URL)
    case exchanging
    case signedIn(identifier: String, expiresAt: Date?)
    case failed(String)

    public var isSignedIn: Bool {
        if case .signedIn = self { return true }
        return false
    }

    public var isBusy: Bool {
        switch self {
        case .requestingCode, .waitingForApproval, .exchanging: return true
        default: return false
        }
    }

    /// Code the user types into the verification page, when available.
    public var userCode: String? {
        if case let .waitingForApproval(userCode, _) = self { return userCode }
        return nil
    }

    /// Page where the code is approved, when available.
    public var verificationURL: URL? {
        if case let .waitingForApproval(_, url) = self { return url }
        return nil
    }

    public var statusText: String {
        switch self {
        case .signedOut:
            return "Not signed in with OpenCode."
        case .requestingCode:
            return "Requesting an OpenCode sign-in code…"
        case let .waitingForApproval(userCode, url):
            let location = [url.host, url.path].compactMap { $0 }.joined()
            return "Enter code \(userCode) at \(location) or finish signing in in the browser."
        case .exchanging:
            return "Finishing sign-in…"
        case let .signedIn(identifier, expiresAt):
            if let expiresAt {
                let formatter = DateFormatter()
                formatter.dateStyle = .short
                formatter.timeStyle = .short
                return "Signed in as \(identifier). Token valid until \(formatter.string(from: expiresAt))."
            }
            return "Signed in as \(identifier)."
        case let .failed(message):
            return message
        }
    }
}

@MainActor
public class AuthManager: ObservableObject {
    public static let shared = AuthManager()

    @Published public var antigravityCreds: ServiceCredentials
    @Published public var codexCreds: ServiceCredentials
    @Published public var opencodeGoCreds: ServiceCredentials

    /// Drives the ChatGPT sign-in button/status in `LoginSheetView`.
    @Published public private(set) var chatGPTAuthState: ChatGPTAuthState = .signedOut
    /// Distinguishes the OAuth session from a manually pasted Codex token.
    @Published public private(set) var codexAuthMethod: ChatGPTAuthMethod = .apiKey
    /// Latest ChatGPT usage fetched from the Codex usage endpoint.
    @Published public private(set) var chatGPTUsage: ChatGPTUsage?
    @Published public private(set) var chatGPTUsageError: String?

    /// Drives the Antigravity Google sign-in button/status in `LoginSheetView`.
    @Published public private(set) var antigravityAuthState: AntigravityAuthState = .signedOut
    /// Distinguishes the Google OAuth session from a manually pasted key.
    @Published public private(set) var antigravityAuthMethod: AntigravityAuthMethod = .apiKey

    /// Drives the OpenCode sign-in button/status in `LoginSheetView`.
    @Published public private(set) var openCodeAuthState: OpenCodeAuthState = .signedOut
    /// Distinguishes the OpenCode device grant from a manually pasted token.
    @Published public private(set) var openCodeAuthMethod: OpenCodeAuthMethod = .apiKey
    /// Latest OpenCode Go allowance.
    @Published public private(set) var openCodeUsage: OpenCodeUsage?
    @Published public private(set) var openCodeUsageError: String?

    private let defaults: UserDefaults
    private let agKey = "auth_creds_antigravity"
    private let codexKey = "auth_creds_codex"
    private let opencodeKey = "auth_creds_opencode_go"
    private let codexMethodKey = "auth_method_codex"
    private let antigravityMethodKey = "auth_method_antigravity"
    private let openCodeMethodKey = "auth_method_opencode"

    private let chatGPTCredentialStore: any ChatGPTCredentialStoring
    private let chatGPTOAuthNetworking: any ChatGPTOAuthNetworking
    private let chatGPTUsageService: any ChatGPTUsageFetching
    private var chatGPTTokens: ChatGPTTokens?

    private let antigravityCredentialStore: any AntigravityCredentialStoring
    private let antigravityOAuthNetworking: any AntigravityOAuthNetworking
    private var antigravityTokens: AntigravityTokens?
    private let openCodeCredentialStore: any OpenCodeCredentialStoring
    private let openCodeOAuthNetworking: any OpenCodeOAuthNetworking
    private let openCodeUsageService: any OpenCodeUsageFetching
    private var openCodeTokens: OpenCodeTokens?

    public init(
        storage: UserDefaults = .standard,
        chatGPTCredentialStore: any ChatGPTCredentialStoring = KeychainChatGPTCredentialStore.shared,
        chatGPTOAuthNetworking: any ChatGPTOAuthNetworking = URLSessionChatGPTOAuthNetworking(),
        chatGPTUsageService: any ChatGPTUsageFetching = URLSessionChatGPTUsageFetcher(),
        antigravityCredentialStore: any AntigravityCredentialStoring = KeychainAntigravityCredentialStore.shared,
        antigravityOAuthNetworking: any AntigravityOAuthNetworking = URLSessionAntigravityOAuthNetworking(),
        openCodeCredentialStore: any OpenCodeCredentialStoring = KeychainOpenCodeCredentialStore.shared,
        openCodeOAuthNetworking: any OpenCodeOAuthNetworking = URLSessionOpenCodeOAuthNetworking(),
        openCodeUsageService: any OpenCodeUsageFetching = URLSessionOpenCodeUsageFetcher()
    ) {
        self.defaults = storage
        self.chatGPTCredentialStore = chatGPTCredentialStore
        self.chatGPTOAuthNetworking = chatGPTOAuthNetworking
        self.chatGPTUsageService = chatGPTUsageService
        self.antigravityCredentialStore = antigravityCredentialStore
        self.antigravityOAuthNetworking = antigravityOAuthNetworking
        self.openCodeCredentialStore = openCodeCredentialStore
        self.openCodeOAuthNetworking = openCodeOAuthNetworking
        self.openCodeUsageService = openCodeUsageService
        // Load stored credentials or pre-populate defaults
        self.antigravityCreds = AuthManager.load(from: storage, key: agKey) ?? ServiceCredentials(
            apiKey: "ag_demo_74892304",
            identifier: "adam@alyx.site",
            isLoggedIn: true,
            lastVerified: Date()
        )
        self.codexCreds = AuthManager.load(from: storage, key: codexKey) ?? ServiceCredentials(
            apiKey: "sk-proj-codex-sample",
            identifier: "org-personal",
            isLoggedIn: true,
            lastVerified: Date()
        )
        self.opencodeGoCreds = AuthManager.load(from: storage, key: opencodeKey) ?? ServiceCredentials(
            apiKey: "ocg_pat_demo",
            identifier: "https://api.opencode.dev",
            isLoggedIn: true,
            lastVerified: Date()
        )

        // OAuth tokens live only in secure storage. Never let a stale keychain
        // item override an explicitly saved manual API-key login.
        let storedMethod = storage.string(forKey: codexMethodKey).flatMap(ChatGPTAuthMethod.init(rawValue:))
        if storedMethod == .apiKey {
            self.codexAuthMethod = .apiKey
        } else if let storedTokens = try? chatGPTCredentialStore.load() {
            self.chatGPTTokens = storedTokens
            self.codexAuthMethod = .chatGPT
            self.chatGPTAuthState = .signedIn(
                identifier: storedTokens.identifier,
                expiresAt: storedTokens.expiresAt
            )
        } else {
            self.codexAuthMethod = storedMethod ?? .apiKey
        }

        // Same precedence rule for Antigravity: an explicitly saved manual key
        // wins over a stale Keychain grant.
        let storedAntigravityMethod = storage.string(forKey: antigravityMethodKey)
            .flatMap(AntigravityAuthMethod.init(rawValue:))
        if storedAntigravityMethod == .apiKey {
            self.antigravityAuthMethod = .apiKey
        } else if let storedTokens = try? antigravityCredentialStore.load() {
            self.antigravityTokens = storedTokens
            self.antigravityAuthMethod = .google
            self.antigravityCreds = ServiceCredentials(
                apiKey: "",
                identifier: storedTokens.identifier,
                isLoggedIn: true,
                lastVerified: storedTokens.expiresAt ?? Date()
            )
            self.antigravityAuthState = .signedIn(
                identifier: storedTokens.identifier,
                expiresAt: storedTokens.expiresAt
            )
        } else {
            self.antigravityAuthMethod = storedAntigravityMethod ?? .apiKey
        }

        // Same precedence rules for the OpenCode Go device grant.
        let storedOpenCodeMethod = storage.string(forKey: "auth_method_opencode")
            .flatMap(OpenCodeAuthMethod.init(rawValue:))
        if storedOpenCodeMethod == .apiKey {
            self.openCodeAuthMethod = .apiKey
        } else if let storedTokens = try? openCodeCredentialStore.load() {
            self.openCodeTokens = storedTokens
            self.openCodeAuthMethod = .oauth
            self.openCodeAuthState = .signedIn(
                identifier: storedTokens.identifier,
                expiresAt: storedTokens.expiresAt
            )
            self.opencodeGoCreds = ServiceCredentials(
                apiKey: "",
                identifier: storedTokens.identifier,
                isLoggedIn: true,
                lastVerified: storedTokens.expiresAt ?? Date()
            )
        } else {
            self.openCodeAuthMethod = storedOpenCodeMethod ?? .apiKey
        }
    }

    nonisolated public static func resetDefaults(in storage: UserDefaults = .standard) {
        storage.removeObject(forKey: "auth_creds_antigravity")
        storage.removeObject(forKey: "auth_creds_codex")
        storage.removeObject(forKey: "auth_creds_opencode_go")
        storage.removeObject(forKey: "auth_method_codex")
        storage.removeObject(forKey: "auth_method_antigravity")
        storage.removeObject(forKey: "auth_method_opencode")
    }

    public func credentials(for type: ServiceProviderType) -> ServiceCredentials {
        switch type {
        case .antigravity: return antigravityCreds
        case .codex: return codexCreds
        case .opencodeGo: return opencodeGoCreds
        }
    }

    public func login(type: ServiceProviderType, apiKey: String, identifier: String) -> Bool {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanId = identifier.trimmingCharacters(in: .whitespacesAndNewlines)

        let newCreds = ServiceCredentials(
            apiKey: cleanKey,
            identifier: cleanId,
            isLoggedIn: true,
            lastVerified: Date()
        )

        switch type {
        case .antigravity:
            antigravityCreds = newCreds
            save(newCreds, key: agKey)
            // Manual credentials take precedence over any previous Google
            // session. The Keychain item is intentionally left intact but is
            // ignored while the persisted method is `.apiKey`.
            antigravityTokens = nil
            antigravityAuthState = .signedOut
            setAntigravityAuthMethod(.apiKey)
        case .codex:
            codexCreds = newCreds
            save(newCreds, key: codexKey)
            // Manual credentials take precedence over any previous OAuth session.
            // The Keychain item is intentionally left intact but is ignored while
            // the persisted method is `.apiKey`.
            chatGPTTokens = nil
            chatGPTAuthState = .signedOut
            setCodexAuthMethod(.apiKey)
        case .opencodeGo:
            opencodeGoCreds = newCreds
            save(newCreds, key: opencodeKey)
            // Manual credentials take precedence over the device grant. The
            // Keychain item is intentionally left intact but ignored while the
            // persisted method is `.apiKey`.
            openCodeTokens = nil
            openCodeAuthState = .signedOut
            setOpenCodeAuthMethod(.apiKey)
        }
        return true
    }

    public func logout(type: ServiceProviderType) {
        let cleared = ServiceCredentials(apiKey: "", identifier: "", isLoggedIn: false, lastVerified: nil)
        switch type {
        case .antigravity:
            signOutAntigravity()
            antigravityCreds = cleared
            save(cleared, key: agKey)
        case .codex:
            signOutChatGPT()
            codexCreds = cleared
            save(cleared, key: codexKey)
        case .opencodeGo:
            signOutOpenCode()
            opencodeGoCreds = cleared
            save(cleared, key: opencodeKey)
        }
    }

    // MARK: - Antigravity Google OAuth

    /// Runs the real Google Authorization Code + PKCE flow through the supplied
    /// client. On success the access/refresh tokens are stored in the Keychain
    /// and the Google account email (or a generic label) becomes the
    /// Antigravity provider identifier.
    @discardableResult
    public func signInWithGoogle(using client: AntigravityOAuthClient) async -> Bool {
        guard !antigravityAuthState.isBusy else { return false }

        antigravityAuthState = .authorizing
        do {
            let tokens = try await client.authorize()
            antigravityAuthState = .exchanging
            try antigravityCredentialStore.save(tokens)
            applyAntigravityTokens(tokens)
            return true
        } catch is CancellationError {
            antigravityAuthState = .failed(AntigravityOAuthError.cancelled.userMessage)
            return false
        } catch let error as AntigravityOAuthError {
            antigravityAuthState = .failed(error.userMessage)
            return false
        } catch {
            antigravityAuthState = .failed("Sign-in failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Returns a usable Google access token, refreshing it when it is within the
    /// 60-second expiry skew. Throws `.notSignedIn` when no OAuth session exists.
    public func antigravityAccessToken(now: Date = Date()) async throws -> String {
        try await refreshAntigravityTokensIfNeeded(now: now).accessToken
    }

    /// Refreshes the Google grant if required. A rejected refresh token signs the
    /// user out rather than silently reusing expired credentials.
    @discardableResult
    public func refreshAntigravityTokensIfNeeded(
        now: Date = Date(),
        force: Bool = false
    ) async throws -> AntigravityTokens {
        let current: AntigravityTokens
        if let tokens = antigravityTokens {
            current = tokens
        } else if antigravityAuthMethod == .google,
                  let stored = try antigravityCredentialStore.load() {
            current = stored
            antigravityTokens = stored
        } else {
            throw AntigravityOAuthError.notSignedIn
        }

        if !force, !current.isExpired(at: now) {
            return current
        }
        guard let refreshToken = current.refreshToken, !refreshToken.isEmpty else {
            throw AntigravityOAuthError.missingRefreshToken
        }

        antigravityAuthState = .exchanging
        do {
            let response = try await antigravityOAuthNetworking.refreshToken(
                AntigravityOAuthRefreshRequest(
                    configuration: .defaultConfiguration(),
                    refreshToken: refreshToken
                )
            )
            let refreshed = try AntigravityTokens(
                response: response,
                previous: current,
                now: now
            )
            try antigravityCredentialStore.save(refreshed)
            applyAntigravityTokens(refreshed)
            return refreshed
        } catch let error as AntigravityOAuthError {
            if case .invalidGrant = error {
                clearAntigravitySession()
            } else {
                antigravityAuthState = .failed(error.userMessage)
            }
            throw error
        }
    }

    /// Clears the Google OAuth session and its Keychain item. Manual credentials
    /// are cleared separately by `logout(type: .antigravity)`.
    public func signOutAntigravity() {
        antigravityTokens = nil
        try? antigravityCredentialStore.delete()
        antigravityAuthState = .signedOut
        if antigravityAuthMethod == .google {
            setAntigravityAuthMethod(.apiKey)
        }
    }

    private func applyAntigravityTokens(_ tokens: AntigravityTokens) {
        antigravityTokens = tokens
        setAntigravityAuthMethod(.google)
        antigravityCreds = ServiceCredentials(
            apiKey: "",
            identifier: tokens.identifier,
            isLoggedIn: true,
            lastVerified: tokens.expiresAt ?? Date()
        )
        save(antigravityCreds, key: agKey)
        antigravityAuthState = .signedIn(
            identifier: tokens.identifier,
            expiresAt: tokens.expiresAt
        )
    }

    private func clearAntigravitySession() {
        antigravityTokens = nil
        try? antigravityCredentialStore.delete()
        setAntigravityAuthMethod(.apiKey)
        antigravityAuthState = .signedOut
        let cleared = ServiceCredentials(apiKey: "", identifier: "", isLoggedIn: false, lastVerified: nil)
        antigravityCreds = cleared
        save(cleared, key: agKey)
    }

    private func setAntigravityAuthMethod(_ method: AntigravityAuthMethod) {
        antigravityAuthMethod = method
        defaults.set(method.rawValue, forKey: antigravityMethodKey)
    }

    // MARK: - ChatGPT OAuth

    /// Runs the real Authorization Code + PKCE flow through the supplied client.
    /// On success the refresh/access tokens are stored in the Keychain and the
    /// account email (or account ID) becomes the Codex provider identifier.
    @discardableResult
    public func signInWithChatGPT(using client: ChatGPTOAuthClient) async -> Bool {
        guard !chatGPTAuthState.isBusy else { return false }

        chatGPTAuthState = .authorizing
        do {
            let tokens = try await client.authorize()
            chatGPTAuthState = .exchanging
            try chatGPTCredentialStore.save(tokens)
            applyChatGPTTokens(tokens)
            return true
        } catch is CancellationError {
            chatGPTAuthState = .failed(ChatGPTOAuthError.cancelled.userMessage)
            return false
        } catch let error as ChatGPTOAuthError {
            chatGPTAuthState = .failed(error.userMessage)
            return false
        } catch {
            chatGPTAuthState = .failed("Sign-in failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Fetch ChatGPT/Codex rate-limit usage, persist it for the widget, and
    /// refresh the widget timelines. Safe to call repeatedly.
    @discardableResult
    public func refreshChatGPTUsage() async -> Bool {
        do {
            let tokens = try await refreshChatGPTTokensIfNeeded()
            guard let accountID = tokens.accountID, !accountID.isEmpty else {
                throw ChatGPTUsageError.missingAccountID
            }
            let usage = try await chatGPTUsageService.fetchUsage(tokens: tokens)
            chatGPTUsage = usage
            chatGPTUsageError = nil
            var snapshot = SharedUsageStore.load() ?? UsageSnapshot()
            snapshot.records["codex"] = UsageSnapshot.Record(
                id: "codex",
                usedPercent: Double(usage.usedPercent),
                detail: usage.planLabel,
                status: usage.statusText,
                hasRequestCount: false
            )
            snapshot.updatedAt = Date()
            try? SharedUsageStore.save(snapshot)
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadAllTimelines()
            WidgetCenter.shared.reloadTimelines(ofKind: "slopWidget")
            #endif
            return true
        } catch {
            chatGPTUsageError = error.localizedDescription
            return false
        }
    }

    /// Returns a usable access token, refreshing it when it is within the
    /// 60-second expiry skew. Throws `.notSignedIn` when no OAuth session exists.
    public func chatGPTAccessToken(now: Date = Date()) async throws -> String {
        try await refreshChatGPTTokensIfNeeded(now: now).accessToken
    }

    /// Refreshes the OAuth grant if required. A rejected refresh token signs the
    /// user out rather than silently reusing expired credentials.
    @discardableResult
    public func refreshChatGPTTokensIfNeeded(now: Date = Date(), force: Bool = false) async throws -> ChatGPTTokens {
        let current: ChatGPTTokens
        if let tokens = chatGPTTokens {
            current = tokens
        } else if codexAuthMethod == .chatGPT, let stored = try chatGPTCredentialStore.load() {
            current = stored
            chatGPTTokens = stored
        } else {
            throw ChatGPTOAuthError.notSignedIn
        }

        if !force, !current.isExpired(at: now) {
            return current
        }
        guard let refreshToken = current.refreshToken, !refreshToken.isEmpty else {
            throw ChatGPTOAuthError.missingRefreshToken
        }

        chatGPTAuthState = .exchanging
        do {
            let response = try await chatGPTOAuthNetworking.refreshToken(
                ChatGPTOAuthRefreshRequest(
                    configuration: .codex(),
                    refreshToken: refreshToken
                )
            )
            let refreshed = try ChatGPTTokens(response: response, previous: current, now: now)
            try chatGPTCredentialStore.save(refreshed)
            applyChatGPTTokens(refreshed)
            return refreshed
        } catch let error as ChatGPTOAuthError {
            if case .invalidGrant = error {
                clearChatGPTSession()
            } else {
                chatGPTAuthState = .failed(error.userMessage)
            }
            throw error
        }
    }

    /// Clears the OAuth session and its Keychain item. Manual credentials are
    /// cleared separately by `logout(type: .codex)`.
    public func signOutChatGPT() {
        chatGPTTokens = nil
        try? chatGPTCredentialStore.delete()
        chatGPTAuthState = .signedOut
        if codexAuthMethod == .chatGPT {
            setCodexAuthMethod(.apiKey)
        }
    }

    private func applyChatGPTTokens(_ tokens: ChatGPTTokens) {
        chatGPTTokens = tokens
        setCodexAuthMethod(.chatGPT)
        codexCreds = ServiceCredentials(
            apiKey: "",
            identifier: tokens.identifier,
            isLoggedIn: true,
            lastVerified: tokens.expiresAt ?? Date()
        )
        save(codexCreds, key: codexKey)
        chatGPTAuthState = .signedIn(identifier: tokens.identifier, expiresAt: tokens.expiresAt)
    }

    private func clearChatGPTSession() {
        chatGPTTokens = nil
        try? chatGPTCredentialStore.delete()
        setCodexAuthMethod(.apiKey)
        chatGPTAuthState = .signedOut
        let cleared = ServiceCredentials(apiKey: "", identifier: "", isLoggedIn: false, lastVerified: nil)
        codexCreds = cleared
        save(cleared, key: codexKey)
    }

    private func setCodexAuthMethod(_ method: ChatGPTAuthMethod) {
        codexAuthMethod = method
        defaults.set(method.rawValue, forKey: codexMethodKey)
    }

    // MARK: - OpenCode OAuth (device grant)

    /// Runs the real OpenCode Console device authorization grant through the
    /// supplied client. On success the access/refresh tokens are stored in a
    /// Keychain item separate from the ChatGPT session, and the account email
    /// (or user ID) becomes the OpenCode Go provider identifier.
    @discardableResult
    public func signInWithOpenCode(using client: OpenCodeOAuthClient) async -> Bool {
        guard !openCodeAuthState.isBusy else { return false }

        openCodeAuthState = .requestingCode
        do {
            let tokens = try await client.signIn { [weak self] device in
                guard let self else { return }
                self.openCodeAuthState = .waitingForApproval(
                    userCode: device.userCode,
                    verificationURL: device.verificationURL
                )
            }
            openCodeAuthState = .exchanging
            try openCodeCredentialStore.save(tokens)
            applyOpenCodeTokens(tokens)
            return true
        } catch is CancellationError {
            openCodeAuthState = .failed(OpenCodeOAuthError.cancelled.userMessage)
            return false
        } catch let error as OpenCodeOAuthError {
            openCodeAuthState = .failed(error.userMessage)
            return false
        } catch {
            openCodeAuthState = .failed("Sign-in failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Fetch the OpenCode Go allowance and publish it to the widget.
    @discardableResult
    public func refreshOpenCodeUsage() async -> Bool {
        do {
            let tokens = try await refreshOpenCodeTokensIfNeeded()
            let usage = try await openCodeUsageService.fetchUsage(tokens: tokens)
            openCodeUsage = usage
            openCodeUsageError = nil

            var snapshot = SharedUsageStore.load() ?? UsageSnapshot()
            snapshot.records["opencode-go"] = UsageSnapshot.Record(
                id: "opencode-go",
                usedPercent: Double(usage.displayPercent),
                detail: usage.detail,
                status: usage.statusText,
                hasRequestCount: false,
                hasUsageData: true
            )
            snapshot.updatedAt = Date()
            try? SharedUsageStore.save(snapshot)
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadAllTimelines()
            WidgetCenter.shared.reloadTimelines(ofKind: "slopWidget")
            #endif
            return true
        } catch {
            openCodeUsageError = error.localizedDescription
            return false
        }
    }

    /// Returns a usable access token, refreshing it when it is within the
    /// 60-second expiry skew. Throws `.notSignedIn` when no OAuth session exists.
    public func openCodeAccessToken(now: Date = Date()) async throws -> String {
        try await refreshOpenCodeTokensIfNeeded(now: now).accessToken
    }

    /// Refreshes the device grant if required. A rejected refresh token signs the
    /// user out rather than silently reusing expired credentials.
    @discardableResult
    public func refreshOpenCodeTokensIfNeeded(now: Date = Date(), force: Bool = false) async throws -> OpenCodeTokens {
        let current: OpenCodeTokens
        if let tokens = openCodeTokens {
            current = tokens
        } else if openCodeAuthMethod == .oauth, let stored = try openCodeCredentialStore.load() {
            current = stored
            openCodeTokens = stored
        } else {
            throw OpenCodeOAuthError.notSignedIn
        }

        if !force, !current.isExpired(at: now) {
            return current
        }
        guard let refreshToken = current.refreshToken, !refreshToken.isEmpty else {
            throw OpenCodeOAuthError.missingRefreshToken
        }

        openCodeAuthState = .exchanging
        do {
            let response = try await openCodeOAuthNetworking.refreshToken(
                OpenCodeRefreshRequest(
                    configuration: OpenCodeOAuthConfiguration().withServer(current.server),
                    refreshToken: refreshToken
                )
            )
            let refreshed = try OpenCodeTokens(
                refreshResponse: response,
                previous: current,
                now: now
            )
            try openCodeCredentialStore.save(refreshed)
            applyOpenCodeTokens(refreshed)
            return refreshed
        } catch let error as OpenCodeOAuthError {
            if case .invalidGrant = error {
                clearOpenCodeSession()
            } else {
                openCodeAuthState = .failed(error.userMessage)
            }
            throw error
        }
    }

    /// Clears the device-grant session and its Keychain item. Manual credentials
    /// are cleared separately by `logout(type: .opencodeGo)`.
    public func signOutOpenCode() {
        openCodeTokens = nil
        try? openCodeCredentialStore.delete()
        openCodeAuthState = .signedOut
        if openCodeAuthMethod == .oauth {
            setOpenCodeAuthMethod(.apiKey)
        }
    }

    private func applyOpenCodeTokens(_ tokens: OpenCodeTokens) {
        openCodeTokens = tokens
        setOpenCodeAuthMethod(.oauth)
        opencodeGoCreds = ServiceCredentials(
            apiKey: "",
            identifier: tokens.identifier,
            isLoggedIn: true,
            lastVerified: tokens.expiresAt ?? Date()
        )
        save(opencodeGoCreds, key: opencodeKey)
        openCodeAuthState = .signedIn(identifier: tokens.identifier, expiresAt: tokens.expiresAt)
    }

    private func clearOpenCodeSession() {
        openCodeTokens = nil
        try? openCodeCredentialStore.delete()
        setOpenCodeAuthMethod(.apiKey)
        openCodeAuthState = .signedOut
        let cleared = ServiceCredentials(apiKey: "", identifier: "", isLoggedIn: false, lastVerified: nil)
        opencodeGoCreds = cleared
        save(cleared, key: opencodeKey)
    }

    private func setOpenCodeAuthMethod(_ method: OpenCodeAuthMethod) {
        openCodeAuthMethod = method
        defaults.set(method.rawValue, forKey: openCodeMethodKey)
    }

    private func save(_ creds: ServiceCredentials, key: String) {
        if let data = try? JSONEncoder().encode(creds),
           let str = String(data: data, encoding: .utf8) {
            defaults.set(str, forKey: key)
        }
    }

    private static func load(from storage: UserDefaults, key: String) -> ServiceCredentials? {
        guard let str = storage.string(forKey: key),
              let data = str.data(using: .utf8),
              let creds = try? JSONDecoder().decode(ServiceCredentials.self, from: data) else {
            return nil
        }
        return creds
    }
}
