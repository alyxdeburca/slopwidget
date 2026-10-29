import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The OpenCode Go allowance returned by the Console inference API.
public struct OpenCodeUsage: Decodable, Sendable, Equatable {
    public struct Meter: Decodable, Sendable, Equatable {
        public var status: String?
        public var percent: Double?
        public var resetsAt: String?

        public var isLimited: Bool {
            status == "rate-limited"
        }
    }

    public struct Meters: Decodable, Sendable, Equatable {
        public var rolling: Meter?
        public var weekly: Meter?
        public var monthly: Meter?
    }

    public var usage: Meters

    /// The most constrained meter is the one worth showing in a single tile.
    public var displayMeter: Meter? {
        let meters = [usage.weekly, usage.monthly, usage.rolling].compactMap { $0 }
        return meters.max { ($0.percent ?? 0) < ($1.percent ?? 0) }
    }

    public var displayPercent: Int {
        min(100, max(0, Int((displayMeter?.percent ?? 0).rounded())))
    }

    public var statusText: String {
        if displayMeter?.isLimited == true { return "Limit" }
        return displayPercent >= 85 ? "High" : "Active"
    }

    public var detail: String {
        if usage.weekly?.percent != nil { return "Weekly" }
        if usage.monthly?.percent != nil { return "Monthly" }
        return "Go"
    }
}

public enum OpenCodeUsageError: Error, LocalizedError, Sendable {
    case missingOrganization
    case http(Int, String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingOrganization:
            return "The OpenCode session is missing its organization ID. Sign in again."
        case let .http(status, body):
            return "OpenCode usage request failed (HTTP \(status)): \(body)"
        case let .invalidResponse(message):
            return "OpenCode usage response was invalid: \(message)"
        }
    }
}

public protocol OpenCodeUsageFetching: Sendable {
    func fetchUsage(tokens: OpenCodeTokens) async throws -> OpenCodeUsage
}

public struct URLSessionOpenCodeUsageFetcher: OpenCodeUsageFetching {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchUsage(tokens: OpenCodeTokens) async throws -> OpenCodeUsage {
        guard let orgID = tokens.orgID, !orgID.isEmpty else {
            throw OpenCodeUsageError.missingOrganization
        }

        var request = URLRequest(url: URL(string: "https://opencode.ai/zen/go/v1/usage")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(orgID, forHTTPHeaderField: "x-opencode-org-id")
        request.setValue("opencode/2.2.0", forHTTPHeaderField: "User-Agent")
        request.setValue("cli", forHTTPHeaderField: "x-opencode-client")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OpenCodeUsageError.invalidResponse(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OpenCodeUsageError.invalidResponse("The usage endpoint returned a non-HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenCodeUsageError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }

        do {
            return try JSONDecoder().decode(OpenCodeUsage.self, from: data)
        } catch {
            throw OpenCodeUsageError.invalidResponse(error.localizedDescription)
        }
    }
}
