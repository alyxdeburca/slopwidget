import Foundation

#if canImport(Security)
import Security
#endif

/// Secure persistence for OpenCode OAuth credentials.
///
/// Manual OpenCode Go tokens continue to live in `ServiceCredentials` /
/// UserDefaults for compatibility. OAuth access and refresh tokens never do,
/// and use a Keychain item separate from the ChatGPT one.
public protocol OpenCodeCredentialStoring: Sendable {
    func load() throws -> OpenCodeTokens?
    func save(_ tokens: OpenCodeTokens) throws
    func delete() throws
}

#if canImport(Security)
/// Keychain-backed store used by the app. The item is device-only and available
/// after first unlock so a background refresh can read it after a reboot.
public struct KeychainOpenCodeCredentialStore: OpenCodeCredentialStoring {
    public static let shared = KeychainOpenCodeCredentialStore()

    public let service: String
    public let account: String

    public init(
        service: String = "com.example.slopWidget.opencode",
        account: String = "opencode-oauth-tokens"
    ) {
        self.service = service
        self.account = account
    }

    public func load() throws -> OpenCodeTokens? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw OpenCodeOAuthError.invalidResponse("Keychain item was not data.")
            }
            do {
                return try JSONDecoder().decode(OpenCodeTokens.self, from: data)
            } catch {
                throw OpenCodeOAuthError.invalidResponse("Stored OpenCode credentials could not be decoded.")
            }
        case errSecItemNotFound:
            return nil
        default:
            throw OpenCodeOAuthError.invalidResponse("Keychain read failed (OSStatus \(status)).")
        }
    }

    public func save(_ tokens: OpenCodeTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = baseQuery
            for (key, value) in attributes { addQuery[key] = value }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw OpenCodeOAuthError.invalidResponse("Keychain write failed (OSStatus \(addStatus)).")
            }
        default:
            throw OpenCodeOAuthError.invalidResponse("Keychain update failed (OSStatus \(updateStatus)).")
        }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OpenCodeOAuthError.invalidResponse("Keychain delete failed (OSStatus \(status)).")
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
#else
/// Fallback used only where the Security framework is unavailable (for example
/// a plain Linux `swift build`). The app always uses the Keychain implementation.
public struct KeychainOpenCodeCredentialStore: OpenCodeCredentialStoring {
    public static let shared = KeychainOpenCodeCredentialStore()

    public init() {}

    public func load() throws -> OpenCodeTokens? { nil }
    public func save(_ tokens: OpenCodeTokens) throws {
        throw OpenCodeOAuthError.unsupportedPlatform
    }
    public func delete() throws {}
}
#endif

/// Thread-safe in-memory store for tests and previews.
public final class InMemoryOpenCodeCredentialStore: OpenCodeCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: OpenCodeTokens?

    public init(tokens: OpenCodeTokens? = nil) {
        self.tokens = tokens
    }

    public func load() throws -> OpenCodeTokens? {
        lock.lock()
        defer { lock.unlock() }
        return tokens
    }

    public func save(_ tokens: OpenCodeTokens) throws {
        lock.lock()
        defer { lock.unlock() }
        self.tokens = tokens
    }

    public func delete() throws {
        lock.lock()
        defer { lock.unlock() }
        tokens = nil
    }
}
