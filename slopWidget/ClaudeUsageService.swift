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
            hasRequestCount: false,
            hasUsageData: hasUsageData
        )
    }
}

public enum ClaudeUsageError: Error, LocalizedError, Sendable {
    case missingToken
    case http(Int, String)
    case invalidResponse(String)
    case relayURLInvalid
    case relayUnreachable
    case relayUnauthorized
    case relay(status: String, message: String)

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
        case .relayURLInvalid:
            return "The relay URL is invalid. Use something like http://100.x.y.z:8787."
        case .relayUnreachable:
            return "Can't reach the usage relay. Is Tailscale on, and is the relay running on your desktop?"
        case .relayUnauthorized:
            return "The usage relay rejected the secret. Re-enter it in Service Accounts."
        case let .relay(status, message):
            if status == "token_expired" {
                return "The desktop's Claude login has expired. Run `claude` on the desktop to refresh it."
            }
            return "The usage relay reported a problem: \(message)"
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

/// Reads usage from the desktop relay (`scripts/claude-usage-relay.py`) instead
/// of Anthropic. The relay serves the same `five_hour` / `seven_day` shape plus
/// a `status` field, so no Claude credential ever reaches the phone.
///
/// `fetchUsage(accessToken:)` takes the relay's shared secret.
public struct RelayClaudeUsageFetcher: ClaudeUsageFetching {
    public let baseURL: URL
    public let session: URLSession

    public init(baseURL: URL, session: URLSession = RelayClaudeUsageFetcher.defaultSession) {
        self.baseURL = baseURL
        self.session = session
    }

    /// Short timeouts: a phone that is off Tailscale should fail fast rather
    /// than hang the refresh.
    public static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration)
    }()

    /// Accepts `100.x.y.z:8787` or a full URL; returns nil unless the result is
    /// an http(s) URL with a host.
    public static func normalizedURL(from text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = "http://" + trimmed }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    private struct Envelope: Decodable {
        var status: String?
        var message: String?
    }

    public func fetchUsage(accessToken: String) async throws -> ClaudeUsage {
        let secret = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { throw ClaudeUsageError.missingToken }

        var request = URLRequest(url: baseURL.appendingPathComponent("usage"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where Self.isUnreachable(error.code) {
            throw ClaudeUsageError.relayUnreachable
        } catch {
            throw ClaudeUsageError.invalidResponse(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClaudeUsageError.invalidResponse("The relay returned a non-HTTP response.")
        }
        if http.statusCode == 401 { throw ClaudeUsageError.relayUnauthorized }

        let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        guard (200..<300).contains(http.statusCode), envelope?.status == "ok" else {
            if let status = envelope?.status {
                throw ClaudeUsageError.relay(status: status, message: envelope?.message ?? "HTTP \(http.statusCode)")
            }
            throw ClaudeUsageError.http(http.statusCode, String(decoding: data.prefix(200), as: UTF8.self))
        }

        do {
            return try JSONDecoder().decode(ClaudeUsage.self, from: data)
        } catch {
            throw ClaudeUsageError.invalidResponse(error.localizedDescription)
        }
    }

    private static func isUnreachable(_ code: URLError.Code) -> Bool {
        switch code {
        case .cannotConnectToHost, .cannotFindHost, .timedOut, .notConnectedToInternet,
             .networkConnectionLost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed:
            return true
        default:
            return false
        }
    }
}
