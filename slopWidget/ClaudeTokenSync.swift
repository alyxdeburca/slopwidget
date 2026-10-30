import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif

/// A Claude Code access token handed over by the desktop sync server.
public struct ClaudeSyncedToken: Sendable, Equatable {
    public var accessToken: String
    public var expiresAt: Date
    public var scopes: [String]

    public init(accessToken: String, expiresAt: Date, scopes: [String] = []) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.scopes = scopes
    }

    /// True while at least `margin` seconds of validity remain.
    public func isValid(margin: TimeInterval = 60, now: Date = Date()) -> Bool {
        expiresAt.timeIntervalSince(now) > margin
    }
}

public enum ClaudeTokenSource: Sendable, Equatable {
    /// Fetched from the desktop sync server on this refresh.
    case sync
    /// An earlier synced token that has not expired yet (server unreachable now).
    case syncCached
    /// The token pasted into the app.
    case manual
}

public enum ClaudeTokenSyncError: Error, LocalizedError, Sendable, Equatable {
    case invalidURL
    case unreachable
    case unauthorized
    case expired
    case noCredentials
    case http(Int)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The token sync URL is not valid."
        case .unreachable:
            return "Can't reach the token sync server. Is Tailscale on?"
        case .unauthorized:
            return "The token sync server rejected the secret. Check the sync secret."
        case .expired:
            return "The desktop's Claude token has expired. Run Claude Code on your desktop to refresh it."
        case .noCredentials:
            return "The desktop isn't logged in to Claude Code."
        case let .http(status):
            return "The token sync server failed (HTTP \(status))."
        case .invalidResponse:
            return "The token sync server sent an unexpected response."
        }
    }
}

public protocol ClaudeTokenSyncFetching: Sendable {
    func fetchToken(url: URL, secret: String) async throws -> ClaudeSyncedToken
}

public struct URLSessionClaudeTokenSyncFetcher: ClaudeTokenSyncFetching {
    public let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            // A tailnet peer that is off should fail fast, not hang the refresh.
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 8
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    private struct Payload: Decodable {
        var accessToken: String
        var expiresAt: Double
        var scopes: [String]?
    }

    public func fetchToken(url: URL, secret: String) async throws -> ClaudeSyncedToken {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClaudeTokenSyncError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw ClaudeTokenSyncError.invalidResponse }

        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw ClaudeTokenSyncError.unauthorized
        case 409:
            throw ClaudeTokenSyncError.expired
        case 503:
            throw ClaudeTokenSyncError.noCredentials
        default:
            throw ClaudeTokenSyncError.http(http.statusCode)
        }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              !payload.accessToken.isEmpty else {
            throw ClaudeTokenSyncError.invalidResponse
        }
        // The server reports milliseconds since the epoch, like Claude Code's file.
        return ClaudeSyncedToken(
            accessToken: payload.accessToken,
            expiresAt: Date(timeIntervalSince1970: payload.expiresAt / 1000),
            scopes: payload.scopes ?? []
        )
    }
}

/// Secure persistence for the shared secret used to talk to the sync server.
/// The fetched access token is never persisted; it lives in memory only.
public protocol ClaudeSyncSecretStoring: Sendable {
    func load() throws -> String?
    func save(_ secret: String) throws
    func delete() throws
}

public enum ClaudeSyncSecretError: Error, LocalizedError, Sendable {
    case keychain(Int)
    case unsupportedPlatform

    public var errorDescription: String? {
        switch self {
        case let .keychain(status): return "Keychain operation failed (OSStatus \(status))."
        case .unsupportedPlatform: return "Secure storage is unavailable on this platform."
        }
    }
}

#if canImport(Security)
public struct KeychainClaudeSyncSecretStore: ClaudeSyncSecretStoring {
    public static let shared = KeychainClaudeSyncSecretStore()

    public let service: String
    public let account: String

    public init(
        service: String = "com.example.slopWidget.claude-sync",
        account: String = "claude-sync-secret"
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
            guard let data = result as? Data else { throw ClaudeSyncSecretError.keychain(Int(status)) }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw ClaudeSyncSecretError.keychain(Int(status))
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
            guard addStatus == errSecSuccess else { throw ClaudeSyncSecretError.keychain(Int(addStatus)) }
        default:
            throw ClaudeSyncSecretError.keychain(Int(updateStatus))
        }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ClaudeSyncSecretError.keychain(Int(status))
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
public struct KeychainClaudeSyncSecretStore: ClaudeSyncSecretStoring {
    public static let shared = KeychainClaudeSyncSecretStore()

    public init() {}

    public func load() throws -> String? { nil }
    public func save(_ secret: String) throws { throw ClaudeSyncSecretError.unsupportedPlatform }
    public func delete() throws {}
}
#endif

/// Thread-safe in-memory store for tests and previews.
public final class InMemoryClaudeSyncSecretStore: ClaudeSyncSecretStoring, @unchecked Sendable {
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
