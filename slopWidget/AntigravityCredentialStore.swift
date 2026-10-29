import Foundation

#if canImport(Security)
import Security
#endif

/// Secure persistence for Antigravity's Google OAuth credentials.
///
/// Manual API keys continue to live in `ServiceCredentials`/UserDefaults for
/// compatibility. Google access and refresh tokens never do, and they use a
/// different Keychain service/account from the ChatGPT OAuth session.
public protocol AntigravityCredentialStoring: Sendable {
    func load() throws -> AntigravityTokens?
    func save(_ tokens: AntigravityTokens) throws
    func delete() throws
}

#if canImport(Security)
/// Keychain-backed store used by the app. The item is device-only and available
/// after first unlock so a background refresh can read it after a reboot.
public struct KeychainAntigravityCredentialStore: AntigravityCredentialStoring {
    public static let shared = KeychainAntigravityCredentialStore()

    public let service: String
    public let account: String

    public init(
        service: String = "com.example.slopWidget.antigravity",
        account: String = "antigravity-google-oauth-tokens"
    ) {
        self.service = service
        self.account = account
    }

    public func load() throws -> AntigravityTokens? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw AntigravityOAuthError.invalidResponse("Keychain item was not data.")
            }
            do {
                return try JSONDecoder().decode(AntigravityTokens.self, from: data)
            } catch {
                throw AntigravityOAuthError.invalidResponse("Stored Antigravity credentials could not be decoded.")
            }
        case errSecItemNotFound:
            return nil
        default:
            throw AntigravityOAuthError.invalidResponse("Keychain read failed (OSStatus \(status)).")
        }
    }

    public func save(_ tokens: AntigravityTokens) throws {
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
                throw AntigravityOAuthError.invalidResponse("Keychain write failed (OSStatus \(addStatus)).")
            }
        default:
            throw AntigravityOAuthError.invalidResponse("Keychain update failed (OSStatus \(updateStatus)).")
        }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AntigravityOAuthError.invalidResponse("Keychain delete failed (OSStatus \(status)).")
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
public struct KeychainAntigravityCredentialStore: AntigravityCredentialStoring {
    public static let shared = KeychainAntigravityCredentialStore()

    public init() {}

    public func load() throws -> AntigravityTokens? { nil }
    public func save(_ tokens: AntigravityTokens) throws {
        throw AntigravityOAuthError.unsupportedPlatform
    }
    public func delete() throws {}
}
#endif

/// Thread-safe in-memory store for tests and previews.
public final class InMemoryAntigravityCredentialStore: AntigravityCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: AntigravityTokens?

    public init(tokens: AntigravityTokens? = nil) {
        self.tokens = tokens
    }

    public func load() throws -> AntigravityTokens? {
        lock.lock()
        defer { lock.unlock() }
        return tokens
    }

    public func save(_ tokens: AntigravityTokens) throws {
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
