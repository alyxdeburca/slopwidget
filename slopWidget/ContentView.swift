import SwiftUI

// MARK: - Data Models

public struct ProviderUsageItem: Identifiable, Sendable {
    public let id: String
    public var name: String
    public var shortName: String
    public var icon: String
    public var color: Color
    public var requestsUsed: Int
    public var requestLimit: Int
    public var tokensUsed: String
    public var status: String

    public init(id: String, name: String, shortName: String, icon: String, color: Color, requestsUsed: Int, requestLimit: Int, tokensUsed: String, status: String) {
        self.id = id
        self.name = name
        self.shortName = shortName
        self.icon = icon
        self.color = color
        self.requestsUsed = requestsUsed
        self.requestLimit = requestLimit
        self.tokensUsed = tokensUsed
        self.status = status
    }

    public var percentage: Double {
        guard requestLimit > 0 else { return 0 }
        return min(1.0, Double(requestsUsed) / Double(requestLimit))
    }

    public var percentageInt: Int {
        Int(percentage * 100)
    }
}

@MainActor
public enum SampleUsageData {
    public static let providers: [ProviderUsageItem] = [
        ProviderUsageItem(
            id: "antigravity",
            name: "Antigravity",
            shortName: "AG",
            icon: "sparkles",
            color: Color(red: 0.65, green: 0.40, blue: 0.98),
            requestsUsed: 42,
            requestLimit: 100,
            tokensUsed: "740k",
            status: "Active"
        ),
        ProviderUsageItem(
            id: "codex",
            name: "Codex",
            shortName: "CDX",
            icon: "terminal.fill",
            color: Color(red: 0.20, green: 0.80, blue: 0.58),
            requestsUsed: 88,
            requestLimit: 100,
            tokensUsed: "1.8M",
            status: "High"
        ),
        ProviderUsageItem(
            id: "opencode-go",
            name: "OpenCode Go",
            shortName: "OCG",
            icon: "bolt.fill",
            color: Color(red: 0.25, green: 0.65, blue: 0.98),
            requestsUsed: 15,
            requestLimit: 50,
            tokensUsed: "310k",
            status: "Normal"
        )
    ]

    public static var averagePercentage: Int {
        let total = providers.map(\.percentage).reduce(0, +)
        return Int((total / Double(providers.count)) * 100)
    }
}

// MARK: - 1x1 Widget (Compact Square)
public struct Widget1x1View: View {
    public var providers: [ProviderUsageItem]

    @MainActor
    public init(providers: [ProviderUsageItem] = SampleUsageData.providers) {
        self.providers = providers
    }

    private var averagePercentage: Int {
        guard !providers.isEmpty else { return 0 }
        let total = providers.map(\.percentage).reduce(0, +)
        return Int((total / Double(providers.count)) * 100)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("AI Stats", systemImage: "cpu.fill")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(averagePercentage)%")
                    .font(.caption.bold())
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.18), in: Capsule())
            }

            Spacer()

            VStack(spacing: 6) {
                ForEach(providers) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Image(systemName: item.icon)
                                .font(.system(size: 8))
                                .foregroundColor(item.color)
                            Text(item.name)
                                .font(.system(size: 9, weight: .bold))
                                .lineLimit(1)
                            Spacer()
                            Text("\(item.percentageInt)%")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(item.color)
                        }
                        ProgressView(value: item.percentage)
                            .tint(item.color)
                            .scaleEffect(x: 1, y: 0.6, anchor: .center)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 158, height: 158)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 5)
    }
}

// MARK: - 1x2 Widget (Horizontal 2-Card)
public struct Widget1x2View: View {
    public var providers: [ProviderUsageItem]

    @MainActor
    public init(providers: [ProviderUsageItem] = SampleUsageData.providers) {
        self.providers = providers
    }

    private var displayProviders: [ProviderUsageItem] {
        Array(providers.prefix(2))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "cpu.fill")
                        .foregroundStyle(.tint)
                    Text("AI Dual Monitor")
                        .font(.caption.bold())
                }
                Spacer()
                Text("1x2 View")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                ForEach(displayProviders) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: item.icon)
                                .font(.caption2)
                                .foregroundColor(item.color)
                            Text(item.name)
                                .font(.system(size: 11, weight: .bold))
                                .lineLimit(1)
                            Spacer()
                            Text(item.status)
                                .font(.system(size: 8, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(item.color.opacity(0.18), in: Capsule())
                                .foregroundColor(item.color)
                        }

                        Spacer()

                        Text("\(item.percentageInt)%")
                            .font(.system(size: 22, weight: .heavy, design: .rounded))
                            .foregroundColor(item.color)

                        ProgressView(value: item.percentage)
                            .tint(item.color)
                            .scaleEffect(x: 1, y: 0.7, anchor: .center)

                        HStack {
                            Text("\(item.requestsUsed)/\(item.requestLimit)")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(item.tokensUsed)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
        .padding(14)
        .frame(width: 338, height: 158)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 5)
    }
}

// MARK: - 1x3 Widget (Panoramic 3-Column Strip)
public struct Widget1x3View: View {
    public var providers: [ProviderUsageItem]

    @MainActor
    public init(providers: [ProviderUsageItem] = SampleUsageData.providers) {
        self.providers = providers
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundColor(.purple)
                    Text("AI Providers (1x3 Panoramic)")
                        .font(.caption.bold())
                }
                Spacer()
                Text("Live Quota")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                ForEach(providers) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Image(systemName: item.icon)
                                .font(.system(size: 10))
                                .foregroundColor(item.color)
                            Text(item.name)
                                .font(.system(size: 10, weight: .bold))
                                .lineLimit(1)
                        }

                        HStack(alignment: .firstTextBaseline) {
                            Text("\(item.percentageInt)%")
                                .font(.system(size: 16, weight: .heavy, design: .rounded))
                                .foregroundColor(item.color)
                            Spacer()
                            Text(item.tokensUsed)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                        }

                        ProgressView(value: item.percentage)
                            .tint(item.color)
                            .scaleEffect(x: 1, y: 0.65, anchor: .center)

                        Text("\(item.requestsUsed)/\(item.requestLimit) reqs")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding(12)
        .frame(width: 350, height: 120)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 5)
    }
}

// MARK: - 2x2 Widget (Large Square Dashboard)
public struct Widget2x2View: View {
    public var providers: [ProviderUsageItem]

    @MainActor
    public init(providers: [ProviderUsageItem] = SampleUsageData.providers) {
        self.providers = providers
    }

    private var averagePercentage: Int {
        guard !providers.isEmpty else { return 0 }
        let total = providers.map(\.percentage).reduce(0, +)
        return Int((total / Double(providers.count)) * 100)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "cpu.fill")
                        .font(.title3)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI Operations")
                            .font(.headline)
                        Text("Antigravity \u{2022} Codex \u{2022} OpenCode")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(averagePercentage)%")
                        .font(.title2.bold())
                        .foregroundColor(.accentColor)
                    Text("Overall Load")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // 3 Provider Detailed Rows
            VStack(spacing: 12) {
                ForEach(providers) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: item.icon)
                                .font(.footnote)
                                .foregroundColor(item.color)
                            Text(item.name)
                                .font(.subheadline.bold())

                            Spacer()

                            Text(item.status)
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(item.color.opacity(0.18), in: Capsule())
                                .foregroundColor(item.color)

                            Text("\(item.percentageInt)%")
                                .font(.subheadline.bold())
                                .foregroundColor(item.color)
                        }

                        ProgressView(value: item.percentage)
                            .tint(item.color)
                            .scaleEffect(x: 1, y: 0.8, anchor: .center)

                        HStack {
                            Text("Requests: \(item.requestsUsed) of \(item.requestLimit)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("Tokens: \(item.tokensUsed)")
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
            }

            Spacer()

            // Footer
            HStack {
                Label("Synced just now", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("2x2 Full View")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(width: 338, height: 338)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 28))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
    }
}

// MARK: - Main Application View
public struct ContentView: View {
    @ObservedObject private var authManager = AuthManager.shared
    @State private var providers: [ProviderUsageItem] = []
    @State private var selectedTab: Int = 0
    @State private var showingLoginSheet: Bool = false

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Connected Accounts Quick Banner
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Connected Services", systemImage: "key.fill")
                                .font(.headline)
                            Spacer()
                            Button {
                                showingLoginSheet = true
                            } label: {
                                Text("Manage")
                                    .font(.caption.bold())
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                            }
                        }

                        HStack(spacing: 8) {
                            servicePill(type: .antigravity)
                            servicePill(type: .codex)
                            servicePill(type: .opencodeGo)
                        }
                    }
                    .padding(16)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))

                    // Header
                    VStack(alignment: .leading, spacing: 6) {
                        Text("AI Usage Widget Gallery")
                            .font(.title.bold())
                        Text("Live preview of 1x1, 1x2, 1x3, and 2x2 widget formats.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    // Widget Selector Tabs
                    Picker("Widget Size", selection: $selectedTab) {
                        Text("1x1").tag(0)
                        Text("1x2").tag(1)
                        Text("1x3").tag(2)
                        Text("2x2").tag(3)
                    }
                    .pickerStyle(.segmented)

                    // Widget Display Canvas
                    VStack {
                        Spacer()
                        switch selectedTab {
                        case 0:
                            Widget1x1View(providers: providers)
                        case 1:
                            Widget1x2View(providers: providers)
                        case 2:
                            Widget1x3View(providers: providers)
                        case 3:
                            Widget2x2View(providers: providers)
                        default:
                            Widget1x1View(providers: providers)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, minHeight: 380)
                    .padding(.vertical, 20)
                    .background(Color(.systemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))

                    // Adjust Values
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Tweak Placeholder Metrics")
                            .font(.headline)

                        ForEach(providers.indices, id: \.self) { idx in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Image(systemName: providers[idx].icon)
                                        .foregroundColor(providers[idx].color)
                                    Text(providers[idx].name)
                                        .font(.subheadline.bold())
                                    Spacer()
                                    Text("\(providers[idx].requestsUsed) / \(providers[idx].requestLimit) reqs (\(providers[idx].percentageInt)%)")
                                        .font(.caption.bold())
                                        .foregroundColor(providers[idx].color)
                                }

                                Slider(
                                    value: Binding(
                                        get: { Double(providers[idx].requestsUsed) },
                                        set: { providers[idx].requestsUsed = Int($0) }
                                    ),
                                    in: 0...Double(providers[idx].requestLimit),
                                    step: 1
                                )
                                .tint(providers[idx].color)
                            }
                            .padding(12)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Widgets")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingLoginSheet = true
                    } label: {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                    }
                }
            }
            .sheet(isPresented: $showingLoginSheet) {
                LoginSheetView()
            }
            .onAppear {
                if providers.isEmpty {
                    providers = SampleUsageData.providers
                }
            }
        }
    }

    @ViewBuilder
    private func servicePill(type: ServiceProviderType) -> some View {
        let creds = authManager.credentials(for: type)
        HStack(spacing: 4) {
            Image(systemName: type.icon)
                .font(.system(size: 10))
                .foregroundColor(type.brandColor)
            Text(type.displayName)
                .font(.system(size: 10, weight: .semibold))
            Circle()
                .fill(creds.isLoggedIn ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(.tertiarySystemBackground), in: Capsule())
    }
}

// MARK: - Individual Previews for isim Snapshotting

#Preview("Widget1x1") {
    ZStack {
        Color(.systemGroupedBackground).ignoresSafeArea()
        Widget1x1View()
    }
}

#Preview("Widget1x2") {
    ZStack {
        Color(.systemGroupedBackground).ignoresSafeArea()
        Widget1x2View()
    }
}

#Preview("Widget1x3") {
    ZStack {
        Color(.systemGroupedBackground).ignoresSafeArea()
        Widget1x3View()
    }
}

#Preview("Widget2x2") {
    ZStack {
        Color(.systemGroupedBackground).ignoresSafeArea()
        Widget2x2View()
    }
}
