import Foundation

#if canImport(Security)
import Security
#endif

/// Secure persistence for the shared secret of the desktop usage relay.
///
/// The relay URL is not secret and lives in UserDefaults; the secret is a
/// bearer credential for the relay and lives in the Keychain.
public protocol ClaudeRelaySecretStoring: Sendable {
    func load() throws -> String?
    func save(_ secret: String) throws
    func delete() throws
}

public enum ClaudeRelayStoreError: Error, LocalizedError, Sendable {
    case keychain(String)
    case unsupportedPlatform

    public var errorDescription: String? {
        switch self {
        case let .keychain(message): return message
        case .unsupportedPlatform: return "Secure storage is unavailable on this platform."
        }
    }
}

#if canImport(Security)
/// Keychain-backed store used by the app. The item is device-only and available
/// after first unlock so a background refresh can read it after a reboot.
public struct KeychainClaudeRelaySecretStore: ClaudeRelaySecretStoring {
    public static let shared = KeychainClaudeRelaySecretStore()

    public let service: String
    public let account: String

    public init(
        service: String = "com.example.slopWidget.claude-relay",
        account: String = "claude-relay-secret"
    ) {
        self.service = service
        self.account = account
    }

    public func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let secret = String(data: data, encoding: .utf8) else {
                throw ClaudeRelayStoreError.keychain("Stored relay secret could not be decoded.")
            }
            return secret
        case errSecItemNotFound:
            return nil
        default:
            throw ClaudeRelayStoreError.keychain("Keychain read failed (OSStatus \(status)).")
        }
    }

    public func save(_ secret: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(secret.utf8),
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
                throw ClaudeRelayStoreError.keychain("Keychain write failed (OSStatus \(addStatus)).")
            }
        default:
            throw ClaudeRelayStoreError.keychain("Keychain update failed (OSStatus \(updateStatus)).")
        }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ClaudeRelayStoreError.keychain("Keychain delete failed (OSStatus \(status)).")
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
public struct KeychainClaudeRelaySecretStore: ClaudeRelaySecretStoring {
    public static let shared = KeychainClaudeRelaySecretStore()

    public init() {}

    public func load() throws -> String? { nil }
    public func save(_ secret: String) throws { throw ClaudeRelayStoreError.unsupportedPlatform }
    public func delete() throws {}
}
#endif

/// Thread-safe in-memory store for tests and previews.
public final class InMemoryClaudeRelaySecretStore: ClaudeRelaySecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var secret: String?

    public init(secret: String? = nil) {
        self.secret = secret
    }

    public func load() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return secret
    }

    public func save(_ secret: String) throws {
        lock.lock()
        defer { lock.unlock() }
        self.secret = secret
    }

    public func delete() throws {
        lock.lock()
        defer { lock.unlock() }
        secret = nil
    }
}
