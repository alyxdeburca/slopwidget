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
    public struct OpenCodeMeters: Codable, Sendable, Equatable {
        public var rolling: Double
        public var weekly: Double
        public var monthly: Double

        public init(rolling: Double, weekly: Double, monthly: Double) {
            self.rolling = rolling
            self.weekly = weekly
            self.monthly = monthly
        }

        public func percent(for window: String) -> Double? {
            switch window {
            case "rolling": return rolling
            case "monthly": return monthly
            default: return weekly
            }
        }
    }

    /// The Claude usage windows (percent used, 0...100), retained so the widget
    /// can cycle them. A nil value means the API reported no figure for it.
    ///
    /// Cycle order: "fiveHour" -> "sevenDay" -> "fiveHour". Only windows that
    /// have data take part. Until the user first taps, nothing is selected and
    /// the most constrained (highest) window is shown; after a tap the explicit
    /// selection is shown, falling back to the most constrained window if the
    /// selected one later loses its data.
    public struct ClaudeMeters: Codable, Sendable, Equatable {
        public static let cycleOrder = ["fiveHour", "sevenDay"]

        public var fiveHour: Double?
        public var sevenDay: Double?

        public init(fiveHour: Double? = nil, sevenDay: Double? = nil) {
            self.fiveHour = fiveHour
            self.sevenDay = sevenDay
        }

        public func percent(for window: String) -> Double? {
            switch window {
            case "fiveHour": return fiveHour
            case "sevenDay": return sevenDay
            default: return nil
            }
        }

        public static func label(for window: String) -> String {
            window == "sevenDay" ? "Weekly" : "5-hour"
        }

        /// Windows in cycle order that actually have data.
        public var availableWindows: [String] {
            Self.cycleOrder.filter { percent(for: $0) != nil }
        }

        /// The window with the highest utilization (ties go to the first in cycle order).
        public var mostConstrainedWindow: String? {
            availableWindows.reduce(nil) { best, window in
                guard let best else { return window }
                return (percent(for: window) ?? 0) > (percent(for: best) ?? 0) ? window : best
            }
        }

        /// The window to display for a stored selection: the selection when it
        /// has data, otherwise the most constrained window. nil without any data.
        public func displayedWindow(selection: String?) -> String? {
            if let selection, percent(for: selection) != nil { return selection }
            return mostConstrainedWindow
        }

        /// The selection to store after a tap: the next window with data after
        /// the one currently displayed. Stays put when fewer than two windows
        /// have data; nil when none do.
        public func nextWindow(after selection: String?) -> String? {
            guard let current = displayedWindow(selection: selection) else { return nil }
            let available = availableWindows
            guard available.count > 1, let index = available.firstIndex(of: current) else { return current }
            return available[(index + 1) % available.count]
        }
    }

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
    /// All three OpenCode Go windows, retained so the widget can cycle them.
    public var openCodeMeters: OpenCodeMeters?
    /// "rolling", "weekly", or "monthly".
    public var openCodeMeterSelection: String?
    /// Both Claude usage windows, retained so the widget can cycle them.
    public var claudeMeters: ClaudeMeters?
    /// "fiveHour" or "sevenDay". nil until the user first taps, which means
    /// "show the most constrained window".
    public var claudeMeterSelection: String?
    /// Provider IDs in the order the user wants them shown. nil means default.
    public var providerOrder: [String]?

    public init(
        records: [String: Record] = [:],
        updatedAt: Date = Date(),
        openCodeMeters: OpenCodeMeters? = nil,
        openCodeMeterSelection: String? = nil,
        claudeMeters: ClaudeMeters? = nil,
        claudeMeterSelection: String? = nil,
        providerOrder: [String]? = nil
    ) {
        self.records = records
        self.updatedAt = updatedAt
        self.openCodeMeters = openCodeMeters
        self.openCodeMeterSelection = openCodeMeterSelection
        self.claudeMeters = claudeMeters
        self.claudeMeterSelection = claudeMeterSelection
        self.providerOrder = providerOrder
    }

    /// Stable sort of `items` by their position in `order`. Items missing from
    /// `order` keep their relative position after the ones that are listed.
    public static func ordered<T>(_ items: [T], by order: [String]?, id: (T) -> String) -> [T] {
        guard let order, !order.isEmpty else { return items }
        let rank = Dictionary(
            order.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        return items.enumerated()
            .sorted { lhs, rhs in
                let l = rank[id(lhs.element)] ?? Int.max
                let r = rank[id(rhs.element)] ?? Int.max
                return l == r ? lhs.offset < rhs.offset : l < r
            }
            .map(\.element)
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
