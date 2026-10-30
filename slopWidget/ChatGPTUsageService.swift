import Foundation
import SwiftUI
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The subset of ChatGPT's Codex usage response that the widget needs.
public struct ChatGPTUsage: Codable, Sendable, Equatable {
    public struct Window: Codable, Sendable, Equatable {
        public var usedPercent: Double?
        public var limitWindowSeconds: Int?
        public var resetAt: Int?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case limitWindowSeconds = "limit_window_seconds"
            case resetAt = "reset_at"
        }

        /// Human-readable reset time for this window, if available.
        public var resetText: String? {
            guard let resetAt else { return nil }
            let date = Date(timeIntervalSince1970: TimeInterval(resetAt))
            let interval = date.timeIntervalSince(Date())
            if interval > 0 && interval < 24 * 3600 {
                let hours = Int(interval) / 3600
                let minutes = (Int(interval) % 3600) / 60
                if hours > 0 {
                    return "Resets in \(hours)h \(minutes)m"
                }
                return "Resets in \(minutes)m"
            }
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            return "Resets \(formatter.string(from: date))"
        }
    }

    public var email: String?
    public var accountID: String?
    public var planType: String?
    public var allowed: Bool?
    public var limitReached: Bool?
    public var primaryWindow: Window?
    public var secondaryWindow: Window?

    enum CodingKeys: String, CodingKey {
        case email
        case accountID = "account_id"
        case planType = "plan_type"
        case allowed
        case limitReached = "limit_reached"
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }

    private struct Envelope: Decodable {
        var email: String?
        var accountID: String?
        var planType: String?
        var rateLimit: RateLimit?

        struct RateLimit: Decodable {
            var allowed: Bool?
            var limitReached: Bool?
            var primaryWindow: Window?
            var secondaryWindow: Window?

            enum CodingKeys: String, CodingKey {
                case allowed
                case limitReached = "limit_reached"
                case primaryWindow = "primary_window"
                case secondaryWindow = "secondary_window"
            }
        }

        enum CodingKeys: String, CodingKey {
            case email
            case accountID = "account_id"
            case planType = "plan_type"
            case rateLimit = "rate_limit"
        }
    }

    public static func decode(_ data: Data) throws -> ChatGPTUsage {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        return ChatGPTUsage(
            email: envelope.email,
            accountID: envelope.accountID,
            planType: envelope.planType,
            allowed: envelope.rateLimit?.allowed,
            limitReached: envelope.rateLimit?.limitReached,
            primaryWindow: envelope.rateLimit?.primaryWindow,
            secondaryWindow: envelope.rateLimit?.secondaryWindow
        )
    }

    /// Prefer the weekly window; otherwise use the primary window.
    public var displayWindow: Window? {
        if let secondaryWindow, secondaryWindow.limitWindowSeconds == 604_800 {
            return secondaryWindow
        }
        if let primaryWindow, primaryWindow.limitWindowSeconds == 604_800 {
            return primaryWindow
        }
        return secondaryWindow ?? primaryWindow
    }

    public var usedPercent: Int {
        guard let value = displayWindow?.usedPercent else { return 0 }
        return min(100, max(0, Int(value.rounded())))
    }

    public var statusText: String {
        if limitReached == true { return "Limit" }
        if allowed == false { return "Blocked" }
        return usedPercent >= 85 ? "High" : "Active"
    }

    public var planLabel: String {
        guard let planType, !planType.isEmpty else { return "ChatGPT" }
        return planType.uppercased()
    }

    /// Human-readable reset time for the displayed window, if available.
    public var resetText: String? {
        displayWindow?.resetText
    }

    /// Short label for a window length, e.g. 18000 -> "5-hour", 604800 -> "Weekly".
    public static func windowLabel(seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return "Window" }
        if seconds == 604_800 { return "Weekly" }
        if seconds == 86_400 { return "Daily" }
        if seconds % 86_400 == 0 { return "\(seconds / 86_400)-day" }
        if seconds % 3_600 == 0 { return "\(seconds / 3_600)-hour" }
        return "\(max(1, seconds / 60))-min"
    }

    /// Every reported window, shortest first, for the widget's tap-to-cycle.
    /// Before the first tap the widget shows `displayWindow` (weekly when
    /// reported), so that is the default.
    public var windowMeters: UsageSnapshot.WindowMeters? {
        var entries: [(id: String, window: Window)] = []
        if let primaryWindow, primaryWindow.usedPercent != nil { entries.append(("primary", primaryWindow)) }
        if let secondaryWindow, secondaryWindow.usedPercent != nil { entries.append(("secondary", secondaryWindow)) }
        guard !entries.isEmpty else { return nil }
        let ordered = entries.enumerated().sorted { lhs, rhs in
            let l = lhs.element.window.limitWindowSeconds ?? Int.max
            let r = rhs.element.window.limitWindowSeconds ?? Int.max
            return l == r ? lhs.offset < rhs.offset : l < r
        }.map(\.element)
        let windows = ordered.map { entry in
            UsageSnapshot.WindowMeters.Window(
                id: entry.id,
                label: Self.windowLabel(seconds: entry.window.limitWindowSeconds),
                percent: min(100, max(0, entry.window.usedPercent ?? 0)),
                resetText: entry.window.resetText
            )
        }
        let defaultID = displayWindow.flatMap { shown in ordered.first { $0.window == shown }?.id }
        return UsageSnapshot.WindowMeters(windows: windows, defaultID: defaultID)
    }

    public var providerUsageItem: ProviderUsageItem {
        ProviderUsageItem(
            id: "codex",
            name: "Codex",
            shortName: "CDX",
            icon: "terminal.fill",
            color: Color(red: 0.20, green: 0.80, blue: 0.58),
            requestsUsed: usedPercent,
            requestLimit: 100,
            tokensUsed: planLabel,
            status: statusText,
            resetText: resetText,
            hasRequestCount: false
        )
    }
}

public enum ChatGPTUsageError: Error, LocalizedError, Sendable {
    case missingAccountID
    case http(Int, String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingAccountID:
            return "The ChatGPT session is missing its account ID. Please sign in again."
        case let .http(status, body):
            return "ChatGPT usage request failed (HTTP \(status)): \(body)"
        case let .invalidResponse(message):
            return "ChatGPT usage response was invalid: \(message)"
        }
    }
}

public protocol ChatGPTUsageFetching: Sendable {
    func fetchUsage(tokens: ChatGPTTokens) async throws -> ChatGPTUsage
}

public struct URLSessionChatGPTUsageFetcher: ChatGPTUsageFetching {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchUsage(tokens: ChatGPTTokens) async throws -> ChatGPTUsage {
        guard let accountID = tokens.accountID, !accountID.isEmpty else {
            throw ChatGPTUsageError.missingAccountID
        }

        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        request.setValue("codex_cli_rs/0.164.0 (Linux; x86_64) slopWidget/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ChatGPTUsageError.invalidResponse(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ChatGPTUsageError.invalidResponse("The usage endpoint returned a non-HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ChatGPTUsageError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }

        do {
            return try ChatGPTUsage.decode(data)
        } catch {
            throw ChatGPTUsageError.invalidResponse(error.localizedDescription)
        }
    }
}
