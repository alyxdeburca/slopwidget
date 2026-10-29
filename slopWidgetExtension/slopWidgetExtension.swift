import WidgetKit
import SwiftUI
import Foundation

// MARK: - Usage Model

struct ProviderUsage: Identifiable {
    let id: String
    let name: String
    let icon: String
    let color: Color
    var requestsUsed: Int
    var requestLimit: Int
    var tokensUsed: String
    var status: String
    var hasRequestCount: Bool = true
    var hasUsageData: Bool = true

    var percentage: Double {
        guard requestLimit > 0 else { return 0 }
        return min(1.0, Double(requestsUsed) / Double(requestLimit))
    }

    var percentageInt: Int {
        Int(percentage * 100)
    }

    var percentageText: String {
        hasUsageData ? "\(percentageInt)%" : "—"
    }
}

enum UsageData {
    static let defaultProviders: [ProviderUsage] = [
        ProviderUsage(
            id: "antigravity",
            name: "Antigravity",
            icon: "sparkles",
            color: Color(red: 0.65, green: 0.40, blue: 0.98),
            requestsUsed: 0,
            requestLimit: 100,
            tokensUsed: "—",
            status: "Not synced",
            hasUsageData: false
        ),
        ProviderUsage(
            id: "codex",
            name: "Codex",
            icon: "terminal.fill",
            color: Color(red: 0.20, green: 0.80, blue: 0.58),
            requestsUsed: 88,
            requestLimit: 100,
            tokensUsed: "1.8M",
            status: "High"
        ),
        ProviderUsage(
            id: "opencode-go",
            name: "OpenCode Go",
            icon: "bolt.fill",
            color: Color(red: 0.25, green: 0.65, blue: 0.98),
            requestsUsed: 0,
            requestLimit: 50,
            tokensUsed: "—",
            status: "Not synced",
            hasUsageData: false
        )
    ]
}

// MARK: - Timeline Entry & Provider

struct UsageWidgetEntry: TimelineEntry {
    let date: Date
    let providers: [ProviderUsage]

    var averagePercentageInt: Int {
        guard !providers.isEmpty else { return 0 }
        let total = providers.map(\.percentage).reduce(0, +)
        return Int((total / Double(providers.count)) * 100)
    }
}

struct UsageWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageWidgetEntry {
        UsageWidgetEntry(date: Date(), providers: UsageData.defaultProviders)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageWidgetEntry) -> Void) {
        completion(UsageWidgetEntry(date: Date(), providers: currentProviders()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageWidgetEntry>) -> Void) {
        let currentDate = Date()
        let entry = UsageWidgetEntry(date: currentDate, providers: currentProviders())
        completion(Timeline(entries: [entry], policy: .after(currentDate.addingTimeInterval(15 * 60))))
    }

    /// Read the snapshot the app writes to the shared keychain. Fall back to
    /// the sample values when no live fetch has happened yet.
    private func currentProviders() -> [ProviderUsage] {
        guard let snapshot = SharedUsageStore.load() else {
            return UsageData.defaultProviders
        }
        return UsageData.defaultProviders.map { base in
            guard let record = snapshot.records[base.id] else { return base }
            return ProviderUsage(
                id: base.id,
                name: base.name,
                icon: base.icon,
                color: base.color,
                requestsUsed: min(100, max(0, Int(record.usedPercent.rounded()))),
                requestLimit: 100,
                tokensUsed: record.detail,
                status: record.status,
                hasRequestCount: record.hasRequestCount ?? true
            )
        }
    }
}

// MARK: - Widget Views

struct UsageWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    var entry: UsageWidgetProvider.Entry

    var body: some View {
        switch family {
        case .systemSmall:
            smallWidgetView
        case .systemMedium:
            mediumWidgetView
        case .accessoryCircular:
            accessoryCircularView
        case .accessoryRectangular:
            accessoryRectangularView
        default:
            mediumWidgetView
        }
    }

    // Small Widget (2x2 grid)
    private var smallWidgetView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("AI Usage", systemImage: "cpu.fill")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(entry.averagePercentageInt)%")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.18), in: Capsule())
            }

            Spacer()

            VStack(spacing: 6) {
                ForEach(entry.providers) { provider in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Image(systemName: provider.icon)
                                .font(.system(size: 9))
                                .foregroundColor(provider.color)
                            Text(provider.name)
                                .font(.system(size: 10, weight: .semibold))
                                .lineLimit(1)
                            Spacer()
                            Text(provider.percentageText)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(provider.color)
                        }
                        ProgressView(value: provider.percentage)
                            .tint(provider.color)
                            .scaleEffect(x: 1, y: 0.6, anchor: .center)
                    }
                }
            }
        }
    }

    // Medium Widget (4x2 card)
    private var mediumWidgetView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "cpu.fill")
                        .font(.footnote)
                        .foregroundStyle(.tint)
                    Text("AI Usage Stats")
                        .font(.footnote.bold())
                }
                Spacer()
                Text("Avg \(entry.averagePercentageInt)%")
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
            }

            HStack(spacing: 8) {
                ForEach(entry.providers) { provider in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: provider.icon)
                                .font(.caption2)
                                .foregroundColor(provider.color)
                            Text(provider.name)
                                .font(.system(size: 11, weight: .bold))
                                .lineLimit(1)
                        }

                        Spacer()

                        Text(provider.percentageText)
                            .font(.system(size: 20, weight: .heavy, design: .rounded))
                            .foregroundColor(provider.color)

                        ProgressView(value: provider.percentage)
                            .tint(provider.color)
                            .scaleEffect(x: 1, y: 0.7, anchor: .center)

                        HStack {
                            if provider.hasRequestCount {
                                Text("\(provider.requestsUsed)/\(provider.requestLimit)")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(provider.tokensUsed)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    // Lock Screen Circular
    private var accessoryCircularView: some View {
        Gauge(value: Double(entry.averagePercentageInt), in: 0...100) {
            Image(systemName: "cpu.fill")
        } currentValueLabel: {
            Text("\(entry.averagePercentageInt)")
                .font(.system(size: 11, weight: .bold))
        }
        .gaugeStyle(.accessoryCircular)
    }

    // Lock Screen Rectangular
    private var accessoryRectangularView: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "cpu.fill")
                Text("AI Usage").font(.caption.bold())
                Spacer()
                Text("\(entry.averagePercentageInt)%").font(.caption.bold())
            }
            Text("AG: 42% \u{2022} Codex: 88% \u{2022} OC: 30%")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Widget Declaration

@main
struct slopWidgetBundle: WidgetBundle {
    var body: some Widget {
        slopWidget()
    }
}

struct slopWidget: Widget {
    let kind: String = "slopWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageWidgetProvider()) { entry in
            UsageWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("AI Usage Stats")
        .description("Track requests and token usage for Antigravity, Codex, and OpenCode Go.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryCircular,
            .accessoryRectangular,
        ])
    }
}
