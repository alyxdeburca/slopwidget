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
        public var fiveHourReset: String?
        public var sevenDayReset: String?

        public init(fiveHour: Double? = nil, sevenDay: Double? = nil, fiveHourReset: String? = nil, sevenDayReset: String? = nil) {
            self.fiveHour = fiveHour
            self.sevenDay = sevenDay
            self.fiveHourReset = fiveHourReset
            self.sevenDayReset = sevenDayReset
        }

        public func percent(for window: String) -> Double? {
            switch window {
            case "fiveHour": return fiveHour
            case "sevenDay": return sevenDay
            default: return nil
            }
        }

        public func resetText(for window: String) -> String? {
            switch window {
            case "fiveHour": return fiveHourReset
            case "sevenDay": return sevenDayReset
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

    /// A provider's usage windows (percent used, 0...100), retained so the
    /// widget can cycle through them. Used by providers without a bespoke
    /// meters type (Codex, Antigravity); keyed by provider ID in
    /// `UsageSnapshot.windowMeters`.
    ///
    /// Cycle order is the order of `windows`, wrapping at the end. Until the
    /// user first taps, nothing is selected and `defaultID` (or, without one, the
    /// most constrained window) is shown; after a tap the explicit selection is
    /// shown, falling back to that default if the selected window disappears.
    public struct WindowMeters: Codable, Sendable, Equatable {
        public struct Window: Codable, Sendable, Equatable {
            /// Stable key, so a selection survives refreshes.
            public var id: String
            /// Short text shown next to the percentage, e.g. "5-hour".
            public var label: String
            public var percent: Double
            public var resetText: String?

            public init(id: String, label: String, percent: Double, resetText: String? = nil) {
                self.id = id
                self.label = label
                self.percent = percent
                self.resetText = resetText
            }
        }

        public var windows: [Window]
        /// The window shown before the first tap.
        public var defaultID: String?

        public init(windows: [Window] = [], defaultID: String? = nil) {
            self.windows = windows
            self.defaultID = defaultID
        }

        /// The highest-utilization window (ties go to the earliest).
        public var mostConstrained: Window? {
            windows.reduce(nil) { best, window in
                guard let best else { return window }
                return window.percent > best.percent ? window : best
            }
        }

        /// The window to display for a stored selection. nil without any windows.
        public func displayed(selection: String?) -> Window? {
            if let selection, let match = windows.first(where: { $0.id == selection }) { return match }
            if let defaultID, let match = windows.first(where: { $0.id == defaultID }) { return match }
            return mostConstrained
        }

        /// The selection to store after a tap: the window after the one
        /// currently displayed. Stays put with fewer than two windows; nil
        /// when there are none.
        public func next(after selection: String?) -> String? {
            guard let current = displayed(selection: selection) else { return nil }
            guard windows.count > 1, let index = windows.firstIndex(where: { $0.id == current.id }) else {
                return current.id
            }
            return windows[(index + 1) % windows.count].id
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
        /// Optional "resets in/at …" text for providers that report it.
        public var resetText: String?

        public init(id: String, usedPercent: Double, detail: String, status: String, updatedAt: Date = Date(), hasRequestCount: Bool? = nil, hasUsageData: Bool? = nil, resetText: String? = nil) {
            self.id = id
            self.usedPercent = usedPercent
            self.detail = detail
            self.status = status
            self.updatedAt = updatedAt
            self.hasRequestCount = hasRequestCount
            self.hasUsageData = hasUsageData
            self.resetText = resetText
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
    /// Window lists for providers that cycle through generic windows, keyed by
    /// provider ID ("codex", "antigravity").
    public var windowMeters: [String: WindowMeters]?
    /// Per-provider selected window ID. A provider is missing until its first
    /// tap, which means "show the default window".
    public var windowSelections: [String: String]?
    /// Provider IDs in the order the user wants them shown. nil means default.
    public var providerOrder: [String]?
    /// How often, in minutes, the app refreshes usage and the widget reloads.
    /// nil means the default. Read through `refreshInterval`, which normalizes it.
    public var refreshMinutes: Int?

    public init(
        records: [String: Record] = [:],
        updatedAt: Date = Date(),
        openCodeMeters: OpenCodeMeters? = nil,
        openCodeMeterSelection: String? = nil,
        claudeMeters: ClaudeMeters? = nil,
        claudeMeterSelection: String? = nil,
        windowMeters: [String: WindowMeters]? = nil,
        windowSelections: [String: String]? = nil,
        providerOrder: [String]? = nil,
        refreshMinutes: Int? = nil
    ) {
        self.records = records
        self.updatedAt = updatedAt
        self.openCodeMeters = openCodeMeters
        self.openCodeMeterSelection = openCodeMeterSelection
        self.claudeMeters = claudeMeters
        self.claudeMeterSelection = claudeMeterSelection
        self.windowMeters = windowMeters
        self.windowSelections = windowSelections
        self.providerOrder = providerOrder
        self.refreshMinutes = refreshMinutes
    }

    /// The refresh interval in seconds, always one of `RefreshInterval.allowedMinutes`.
    public var refreshInterval: TimeInterval {
        TimeInterval(RefreshInterval.normalized(refreshMinutes) * 60)
    }

    /// Replaces `provider`'s windows (nil or empty removes them). The user's
    /// selection is kept; only the figures change.
    public mutating func setWindowMeters(_ meters: WindowMeters?, for provider: String) {
        var all = windowMeters ?? [:]
        if let meters, !meters.windows.isEmpty {
            all[provider] = meters
        } else {
            all[provider] = nil
        }
        windowMeters = all.isEmpty ? nil : all
    }

    /// The window currently shown for `provider`, given a selection that may
    /// come from the widget's own defaults (`stored`) or this snapshot.
    public func displayedWindow(for provider: String, stored: String? = nil) -> WindowMeters.Window? {
        windowMeters?[provider]?.displayed(selection: stored ?? windowSelections?[provider])
    }

    /// Advances `provider` to its next window. Returns the new selection, or
    /// nil (leaving the snapshot untouched) when the provider has no windows.
    @discardableResult
    public mutating func cycleWindow(for provider: String, stored: String? = nil) -> String? {
        guard let next = windowMeters?[provider]?.next(after: stored ?? windowSelections?[provider]) else {
            return nil
        }
        var selections = windowSelections ?? [:]
        selections[provider] = next
        windowSelections = selections
        return next
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

/// The refresh intervals the user can choose between. The app refreshes usage
/// on this schedule while it is open and asks iOS for background refreshes on
/// it; the widget reloads its timeline on it. iOS decides when background
/// refreshes and widget reloads actually run, so these are requests.
public enum RefreshInterval {
    public static let allowedMinutes = [5, 15, 30, 60]
    public static let defaultMinutes = 15

    /// `minutes` if it is an allowed value, the nearest allowed value (the
    /// shorter one on a tie) if not, and the default when nil.
    public static func normalized(_ minutes: Int?) -> Int {
        guard let minutes else { return defaultMinutes }
        if allowedMinutes.contains(minutes) { return minutes }
        return allowedMinutes.min { abs($0 - minutes) < abs($1 - minutes) } ?? defaultMinutes
    }

    /// Short label for a picker, e.g. "5 min", "1 hour".
    public static func label(forMinutes minutes: Int) -> String {
        minutes % 60 == 0 ? "\(minutes / 60) hour" : "\(minutes) min"
    }
}

/// Tap-to-cycle plumbing shared by the app and widget intents for providers
/// that use `UsageSnapshot.WindowMeters`.
///
/// The widget process keeps its own copy of the selection in `UserDefaults`
/// as well as the shared snapshot, so a tap still sticks if the Keychain write
/// from the extension is refused.
public enum WindowCycling {
    public static func defaultsKey(for provider: String) -> String {
        "windowSelection.\(provider)"
    }

    /// The selection stored by this process's last tap, if any.
    public static func storedSelection(for provider: String) -> String? {
        UserDefaults.standard.string(forKey: defaultsKey(for: provider))
    }

    /// Advances `provider` to its next window and persists the choice.
    /// Does nothing when the provider has no windows yet.
    public static func cycle(provider: String) {
        var snapshot = SharedUsageStore.load() ?? UsageSnapshot()
        guard let next = snapshot.cycleWindow(for: provider, stored: storedSelection(for: provider)) else { return }
        UserDefaults.standard.set(next, forKey: defaultsKey(for: provider))
        try? SharedUsageStore.save(snapshot)
    }
}

/// Keychain bridge used by both the app and the widget extension.
public enum SharedUsageStore {
    private static let service = "com.example.slopWidget.usage"
    private static let account = "latest"

    /// Keychain access group used by the author's xtool-signed builds. Only a
    /// fallback: re-signed builds (AltStore/SideStore OTA installs) run under a
    /// different team ID and bundle ID.
    static let fallbackAccessGroup = "L25T52S232.XTL-L25T52S232.com.example.slopWidget"

    /// Bundle ID suffix of the widget extension relative to the app.
    private static let extensionSuffix = ".slopWidgetExtension"

    /// The app's own keychain access group, which the widget extension also
    /// reads (the free provisioning profile grants the team wildcard). Resolved
    /// at runtime so the signing team and bundle ID can change on re-signing.
    public static let accessGroup: String? = {
        #if canImport(Security)
        guard let resolved = appAccessGroup(fromDefault: defaultAccessGroup()),
              !resolved.hasPrefix(fallbackAccessGroup.prefix { $0 != "." } + ".") else {
            // Probe failed, or this is the author's own team: keep the known value.
            return fallbackAccessGroup
        }
        return resolved
        #else
        return nil
        #endif
    }()

    /// Maps a process's default keychain group (`<TEAM>.<its bundle ID>`) to
    /// the app's group: the extension's default group is the app's plus
    /// `extensionSuffix`; the app's is already the right one.
    static func appAccessGroup(fromDefault group: String?) -> String? {
        guard let group, !group.isEmpty else { return nil }
        return group.hasSuffix(extensionSuffix) ? String(group.dropLast(extensionSuffix.count)) : group
    }

    #if canImport(Security)
    /// Adds a throwaway item without an explicit group and reads back which
    /// group the system put it in (the process's default group).
    private static func defaultAccessGroup() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "access-group-probe",
        ]
        var add = query
        add[kSecValueData as String] = Data([0])
        add[kSecReturnAttributes as String] = true
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        var result: CFTypeRef?
        var status = SecItemAdd(add as CFDictionary, &result)
        if status == errSecDuplicateItem {
            var lookup = query
            lookup[kSecReturnAttributes as String] = true
            status = SecItemCopyMatching(lookup as CFDictionary, &result)
        }
        guard status == errSecSuccess,
              let attributes = result as? [String: Any] else { return nil }
        return attributes[kSecAttrAccessGroup as String] as? String
    }
    #endif

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
