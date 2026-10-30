import Foundation
import SwiftUI
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The subset of Google Cloud Code's Antigravity quota response that the widget needs.
///
/// Endpoint: POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary
/// (consumer accounts use daily-cloudcode-pa.googleapis.com). Body: {"project": "<id>"}.
/// Anthropic/Google do not document this endpoint; every field is optional.
public struct AntigravityUsage: Decodable, Sendable, Equatable {
    public struct Bucket: Decodable, Sendable, Equatable {
        public var bucketId: String?
        public var displayName: String?
        public var window: String?
        public var remainingFraction: Double?
        public var remainingAmount: String?
        public var resetTime: String?
        public var disabled: Bool?

        enum CodingKeys: String, CodingKey {
            case bucketId = "bucketId"
            case displayName = "displayName"
            case window
            case remainingFraction = "remainingFraction"
            case remainingAmount = "remainingAmount"
            case resetTime = "resetTime"
            case disabled
        }

        /// Percent of this bucket used, 0...100. nil without a remaining fraction.
        public var usedPercent: Double? {
            guard let remainingFraction else { return nil }
            return min(100, max(0, ((1.0 - remainingFraction) * 100.0).rounded()))
        }

        /// Human-readable reset time for this bucket, if available.
        public var resetText: String? {
            guard let raw = resetTime else { return nil }
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
    }

    public struct Group: Decodable, Sendable, Equatable {
        public var buckets: [Bucket]?
    }

    public var description: String?
    public var groups: [Group]?

    enum CodingKeys: String, CodingKey {
        case description
        case groups
    }

    /// All buckets flattened across groups.
    public var allBuckets: [Bucket] {
        (groups ?? []).flatMap { $0.buckets ?? [] }
    }

    /// The most constrained bucket (lowest remaining fraction) that is enabled
    /// and carries a remainingFraction. Falls back to any bucket with data.
    private var displayBucket: Bucket? {
        let enabled = allBuckets.filter { !($0.disabled ?? false) && $0.remainingFraction != nil }
        if !enabled.isEmpty {
            return enabled.min { ($0.remainingFraction ?? 1) < ($1.remainingFraction ?? 1) }
        }
        return allBuckets.first { $0.remainingFraction != nil }
    }

    public var hasUsageData: Bool {
        displayBucket?.remainingFraction != nil
    }

    public var usedPercent: Int {
        guard let frac = displayBucket?.remainingFraction else { return 0 }
        let used = (1.0 - frac) * 100.0
        return min(100, max(0, Int(used.rounded())))
    }

    public var detail: String {
        displayBucket?.displayName ?? displayBucket?.window ?? "Antigravity"
    }

    public var statusText: String {
        guard hasUsageData else { return "No data" }
        if usedPercent >= 100 { return "Limit" }
        return usedPercent >= 85 ? "High" : "Active"
    }

    public var resetText: String? {
        displayBucket?.resetText
    }

    /// Every enabled bucket with data, in response order, for the widget's
    /// tap-to-cycle. Before the first tap the widget shows `displayBucket`
    /// (the most constrained), so that is the default.
    public var windowMeters: UsageSnapshot.WindowMeters? {
        let enabled = allBuckets.filter { !($0.disabled ?? false) && $0.remainingFraction != nil }
        let candidates = enabled.isEmpty ? allBuckets.filter { $0.remainingFraction != nil } : enabled
        guard !candidates.isEmpty else { return nil }

        let baseLabels = candidates.enumerated().map { index, bucket in
            bucket.displayName ?? bucket.window ?? bucket.bucketId ?? "Quota \(index + 1)"
        }
        var seenIDs = Set<String>()
        var windows: [UsageSnapshot.WindowMeters.Window] = []
        for (index, bucket) in candidates.enumerated() {
            var id = bucket.bucketId ?? "bucket-\(index)"
            if !seenIDs.insert(id).inserted {
                id = "\(id)#\(index)"
                seenIDs.insert(id)
            }
            var label = baseLabels[index]
            // Same name reported for several windows (e.g. 5-hour and weekly).
            if baseLabels.filter({ $0 == label }).count > 1, let window = bucket.window, window != label {
                label = "\(label) (\(window))"
            }
            windows.append(UsageSnapshot.WindowMeters.Window(
                id: id,
                label: label,
                percent: bucket.usedPercent ?? 0,
                resetText: bucket.resetText
            ))
        }
        let defaultID = displayBucket.flatMap { shown in
            candidates.firstIndex(of: shown).map { windows[$0].id }
        }
        return UsageSnapshot.WindowMeters(windows: windows, defaultID: defaultID)
    }

    public var providerUsageItem: ProviderUsageItem {
        ProviderUsageItem(
            id: "antigravity",
            name: "Antigravity",
            shortName: "AG",
            icon: "sparkles",
            color: Color(red: 0.65, green: 0.40, blue: 0.98),
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

public enum AntigravityUsageError: Error, LocalizedError, Sendable {
    case missingToken
    case http(Int, String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            return "No Antigravity token saved. Sign in with Google or add an API key."
        case let .http(status, body):
            return "Antigravity usage request failed (HTTP \(status)): \(body)"
        case let .invalidResponse(message):
            return "Antigravity usage response was invalid: \(message)"
        }
    }
}

public protocol AntigravityUsageFetching: Sendable {
    func fetchUsage(accessToken: String, projectID: String?) async throws -> AntigravityUsage
}

public struct URLSessionAntigravityUsageFetcher: AntigravityUsageFetching {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchUsage(accessToken: String, projectID: String?) async throws -> AntigravityUsage {
        guard !accessToken.isEmpty else { throw AntigravityUsageError.missingToken }

        let project = projectID ?? "aicode-consumers"
        let host = "daily-cloudcode-pa.googleapis.com"
        let url = URL(string: "https://\(host)/v1internal:retrieveUserQuotaSummary")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("antigravity/1.0", forHTTPHeaderField: "User-Agent")

        let body: [String: Any] = ["project": project]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AntigravityUsageError.invalidResponse(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AntigravityUsageError.invalidResponse("Non-HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AntigravityUsageError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }

        do {
            return try JSONDecoder().decode(AntigravityUsage.self, from: data)
        } catch {
            throw AntigravityUsageError.invalidResponse(error.localizedDescription)
        }
    }
}
