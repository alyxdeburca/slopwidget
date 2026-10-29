import Foundation

#if canImport(Security)
import Security
#endif

/// A small, provider-neutral usage snapshot shared with the widget extension.
///
/// The app and widget are separate processes. On a free provisioning team an
/// App Group is unavailable, so the snapshot travels through a Keychain item
/// with a team-scoped access group (the free profile grants `<TEAM>.*`).
public struct UsageSnapshot: Codable, Sendable, Equatable {
    public struct Record: Codable, Sendable, Equatable {
        public var id: String
        public var usedPercent: Double
        public var detail: String
        public var status: String
        public var updatedAt: Date
        /// nil/false means the provider reports a percentage but no request total.
        public var hasRequestCount: Bool?
        /// False until the provider has supplied any live usage at all.
        public var hasUsageData: Bool?

        public init(id: String, usedPercent: Double, detail: String, status: String, updatedAt: Date = Date(), hasRequestCount: Bool? = nil, hasUsageData: Bool? = nil) {
            self.id = id
            self.usedPercent = usedPercent
            self.detail = detail
            self.status = status
            self.updatedAt = updatedAt
            self.hasRequestCount = hasRequestCount
            self.hasUsageData = hasUsageData
        }
    }

    public var records: [String: Record]
    public var updatedAt: Date

    public init(records: [String: Record] = [:], updatedAt: Date = Date()) {
        self.records = records
        self.updatedAt = updatedAt
    }
}

/// Keychain bridge used by both the app and the widget extension.
public enum SharedUsageStore {
    private static let service = "com.example.slopWidget.usage"
    private static let account = "latest"

    /// The free provisioning profile grants keychain access group `<TEAM>.*`.
    /// The app bundle ID is `XTL-<TEAM>.<bundle>` in xtool-signed builds.
    public static var accessGroup: String? {
        // Use the app's own keychain access group. The extension profile grants
        // the team wildcard, so the widget can read the app's item.
        "L25T52S232.XTL-L25T52S232.com.example.slopWidget"
    }

    public static func save(_ snapshot: UsageSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)

        #if canImport(Security)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            for (key, value) in attributes { addQuery[key] = value }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw UsageSnapshotError.keychain(Int32(addStatus))
            }
        default:
            throw UsageSnapshotError.keychain(Int32(updateStatus))
        }
        #else
        throw UsageSnapshotError.unsupported
        #endif
    }

    public static func load() -> UsageSnapshot? {
        #if canImport(Security)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(UsageSnapshot.self, from: data)
        #else
        return nil
        #endif
    }
}

public enum UsageSnapshotError: Error, Equatable {
    case unsupported
    case keychain(Int32)
}
