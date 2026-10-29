import Foundation
import SwiftUI

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

@MainActor
public class AuthManager: ObservableObject {
    public static let shared = AuthManager()

    @Published public var antigravityCreds: ServiceCredentials
    @Published public var codexCreds: ServiceCredentials
    @Published public var opencodeGoCreds: ServiceCredentials

    private let defaults = UserDefaults.standard
    private let agKey = "auth_creds_antigravity"
    private let codexKey = "auth_creds_codex"
    private let opencodeKey = "auth_creds_opencode_go"

    public init() {
        // Load stored credentials or pre-populate defaults
        self.antigravityCreds = AuthManager.load(from: defaults, key: agKey) ?? ServiceCredentials(
            apiKey: "ag_demo_74892304",
            identifier: "adam@alyx.site",
            isLoggedIn: true,
            lastVerified: Date()
        )
        self.codexCreds = AuthManager.load(from: defaults, key: codexKey) ?? ServiceCredentials(
            apiKey: "sk-proj-codex-sample",
            identifier: "org-personal",
            isLoggedIn: true,
            lastVerified: Date()
        )
        self.opencodeGoCreds = AuthManager.load(from: defaults, key: opencodeKey) ?? ServiceCredentials(
            apiKey: "ocg_pat_demo",
            identifier: "https://api.opencode.dev",
            isLoggedIn: true,
            lastVerified: Date()
        )
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
            codexCreds = cleared
            save(cleared, key: codexKey)
        case .opencodeGo:
            opencodeGoCreds = cleared
            save(cleared, key: opencodeKey)
        }
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
