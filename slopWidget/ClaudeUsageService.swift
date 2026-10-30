import Foundation
import SwiftUI
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The subset of Claude's OAuth usage response that the widget needs.
///
/// Anthropic does not document this endpoint (it backs Claude Code's `/status`),
/// so every field is optional and unknown keys are ignored.
public struct ClaudeUsage: Decodable, Sendable, Equatable {
    public struct Window: Decodable, Sendable, Equatable {
        /// Percentage used, 0...100.
        public var utilization: Double?
        public var resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }

        public init(utilization: Double? = nil, resetsAt: String? = nil) {
            self.utilization = utilization
            self.resetsAt = resetsAt
        }
    }

    public var fiveHour: Window?
    public var sevenDay: Window?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }

    public init(fiveHour: Window? = nil, sevenDay: Window? = nil) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }

    /// The most constrained window is the one worth showing in a single tile.
    private var displayEntry: (label: String, window: Window)? {
        let candidates: [(String, Window)] = [
            ("5-hour", fiveHour),
            ("Weekly", sevenDay),
        ].compactMap { label, window in
            guard let window, window.utilization != nil else { return nil }
            return (label, window)
        }
        return candidates.max { ($0.1.utilization ?? 0) < ($1.1.utilization ?? 0) }
    }

    /// False when the response carried no utilization figure at all.
    public var hasUsageData: Bool {
        displayEntry != nil
    }

    public var usedPercent: Int {
        min(100, max(0, Int((displayEntry?.window.utilization ?? 0).rounded())))
    }

    public var detail: String {
        displayEntry?.label ?? "Claude"
    }

    public var statusText: String {
        guard hasUsageData else { return "No data" }
        if usedPercent >= 100 { return "Limit" }
        return usedPercent >= 85 ? "High" : "Active"
    }

    /// Human-readable reset time for a specific window label ("fiveHour"/"sevenDay").
    public func resetText(for window: String) -> String? {
        let raw: String?
        switch window {
        case "fiveHour": raw = fiveHour?.resetsAt
        case "sevenDay": raw = sevenDay?.resetsAt
        default: raw = nil
        }
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: raw)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: raw)
        }
        guard let date else { return "Resets \(raw)" }
        let interval = date.timeIntervalSince(Date())
        if interval > 0 && interval < 24 * 3600 {
            let hours = Int(interval) / 3600
            let minutes = (Int(interval) % 3600) / 60
            if hours > 0 {
                return "Resets in \(hours)h \(minutes)m"
            }
            return "Resets in \(minutes)m"
        }
        let out = DateFormatter()
        out.dateStyle = .short
        out.timeStyle = .short
        return "Resets \(out.string(from: date))"
    }

    /// Human-readable reset time for the displayed (most constrained) window.
    public var resetText: String? {
        guard let raw = displayEntry?.window.resetsAt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: raw)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: raw)
        }
        guard let date else { return "Resets \(raw)" }
        let interval = date.timeIntervalSince(Date())
        if interval > 0 && interval < 24 * 3600 {
            let hours = Int(interval) / 3600
            let minutes = (Int(interval) % 3600) / 60
            if hours > 0 {
                return "Resets in \(hours)h \(minutes)m"
            }
            return "Resets in \(minutes)m"
        }
        let out = DateFormatter()
        out.dateStyle = .short
        out.timeStyle = .short
        return "Resets \(out.string(from: date))"
    }

    public var providerUsageItem: ProviderUsageItem {
        ProviderUsageItem(
            id: "claude",
            name: "Claude",
            shortName: "CLD",
            icon: "text.bubble.fill",
            color: ServiceProviderType.claude.brandColor,
            requestsUsed: usedPercent,
            requestLimit: 100,
            tokensUsed: detail,
            status: statusText,
            resetText: resetText,
            hasRequestCount: false,
            hasUsageData: hasUsageData
        )
    }
}

public enum ClaudeUsageError: Error, LocalizedError, Sendable {
    case missingToken
    case http(Int, String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            return "No Claude token saved. Add one in Service Accounts."
        case let .http(status, body):
            if status == 401 || status == 403 {
                return "Claude rejected the token (HTTP \(status)). It needs the user:profile scope and may have expired."
            }
            return "Claude usage request failed (HTTP \(status)): \(body)"
        case let .invalidResponse(message):
            return "Claude usage response was invalid: \(message)"
        }
    }
}

public protocol ClaudeUsageFetching: Sendable {
    func fetchUsage(accessToken: String) async throws -> ClaudeUsage
}

public struct URLSessionClaudeUsageFetcher: ClaudeUsageFetching {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchUsage(accessToken: String) async throws -> ClaudeUsage {
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ClaudeUsageError.missingToken }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("slopWidget/1.0", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClaudeUsageError.invalidResponse(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClaudeUsageError.invalidResponse("The usage endpoint returned a non-HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClaudeUsageError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }

        do {
            return try JSONDecoder().decode(ClaudeUsage.self, from: data)
        } catch {
            throw ClaudeUsageError.invalidResponse(error.localizedDescription)
        }
    }
}
