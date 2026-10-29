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

    private let defaults: UserDefaults
    private let agKey = "auth_creds_antigravity"
    private let codexKey = "auth_creds_codex"
    private let opencodeKey = "auth_creds_opencode_go"
    private let codexMethodKey = "auth_method_codex"

    private let chatGPTCredentialStore: any ChatGPTCredentialStoring
    private let chatGPTOAuthNetworking: any ChatGPTOAuthNetworking
    private let chatGPTUsageService: any ChatGPTUsageFetching
    private var chatGPTTokens: ChatGPTTokens?

    public init(
        storage: UserDefaults = .standard,
        chatGPTCredentialStore: any ChatGPTCredentialStoring = KeychainChatGPTCredentialStore.shared,
        chatGPTOAuthNetworking: any ChatGPTOAuthNetworking = URLSessionChatGPTOAuthNetworking(),
        chatGPTUsageService: any ChatGPTUsageFetching = URLSessionChatGPTUsageFetcher()
    ) {
        self.defaults = storage
        self.chatGPTCredentialStore = chatGPTCredentialStore
        self.chatGPTOAuthNetworking = chatGPTOAuthNetworking
        self.chatGPTUsageService = chatGPTUsageService
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
    }

    nonisolated public static func resetDefaults(in storage: UserDefaults = .standard) {
        storage.removeObject(forKey: "auth_creds_antigravity")
        storage.removeObject(forKey: "auth_creds_codex")
        storage.removeObject(forKey: "auth_creds_opencode_go")
        storage.removeObject(forKey: "auth_method_codex")
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
        }
        return true
    }

    public func logout(type: ServiceProviderType) {
        let cleared = ServiceCredentials(apiKey: "", identifier: "", isLoggedIn: false, lastVerified: nil)
        switch type {
        case .antigravity:
            antigravityCreds = cleared
            save(cleared, key: agKey)
        case .codex:
            signOutChatGPT()
            codexCreds = cleared
            save(cleared, key: codexKey)
        case .opencodeGo:
            opencodeGoCreds = cleared
            save(cleared, key: opencodeKey)
        }
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
                status: usage.statusText
            )
            snapshot.updatedAt = Date()
            try? SharedUsageStore.save(snapshot)
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadAllTimelines()
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
