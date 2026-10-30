import SwiftUI
#if canImport(WidgetKit)
import WidgetKit
#endif

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
    /// Optional "resets in …" / "resets at …" text for providers that report it.
    public var resetText: String?
    /// False when the provider reports percentages but not request totals.
    public var hasRequestCount: Bool
    public var hasUsageData: Bool

    public init(id: String, name: String, shortName: String, icon: String, color: Color, requestsUsed: Int, requestLimit: Int, tokensUsed: String, status: String, resetText: String? = nil, hasRequestCount: Bool = true, hasUsageData: Bool = true) {
        self.id = id
        self.name = name
        self.shortName = shortName
        self.icon = icon
        self.color = color
        self.requestsUsed = requestsUsed
        self.requestLimit = requestLimit
        self.tokensUsed = tokensUsed
        self.status = status
        self.resetText = resetText
        self.hasRequestCount = hasRequestCount
        self.hasUsageData = hasUsageData
    }

    public var percentage: Double {
        guard requestLimit > 0 else { return 0 }
        return min(1.0, Double(requestsUsed) / Double(requestLimit))
    }

    public var percentageInt: Int {
        Int(percentage * 100)
    }

    public var percentageText: String {
        hasUsageData ? "\(percentageInt)%" : "—"
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
            requestsUsed: 0,
            requestLimit: 100,
            tokensUsed: "—",
            status: "Not synced",
            hasUsageData: false
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
            requestsUsed: 0,
            requestLimit: 50,
            tokensUsed: "—",
            status: "Not synced",
            hasUsageData: false
        ),
        ProviderUsageItem(
            id: "claude",
            name: "Claude",
            shortName: "CLD",
            icon: "text.bubble.fill",
            color: ServiceProviderType.claude.brandColor,
            requestsUsed: 0,
            requestLimit: 100,
            tokensUsed: "—",
            status: "Not synced",
            hasRequestCount: false,
            hasUsageData: false
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
                            Text(item.percentageText)
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

                        Text(item.percentageText)
                            .font(.system(size: 22, weight: .heavy, design: .rounded))
                            .foregroundColor(item.color)

                        ProgressView(value: item.percentage)
                            .tint(item.color)
                            .scaleEffect(x: 1, y: 0.7, anchor: .center)

                        HStack {
                            if item.hasRequestCount {
                                Text("\(item.requestsUsed)/\(item.requestLimit)")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(item.tokensUsed)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        if let reset = item.resetText {
                            Text(reset)
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
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
                ForEach(providers.prefix(3)) { item in
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
                            Text(item.percentageText)
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

                        if item.hasRequestCount {
                            Text("\(item.requestsUsed)/\(item.requestLimit) reqs")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                        }
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
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "cpu.fill")
                        .font(.title3)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI Operations")
                            .font(.headline)
                        Text(providers.map(\.name).joined(separator: " \u{2022} "))
                            .lineLimit(1)
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

            // Provider Detailed Rows
            VStack(spacing: 6) {
                ForEach(providers) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Image(systemName: item.icon)
                                .font(.footnote)
                                .foregroundColor(item.color)
                            Text(item.name)
                                .font(.footnote.bold())

                            Spacer()

                            Text(item.status)
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(item.color.opacity(0.18), in: Capsule())
                                .foregroundColor(item.color)

                            Text(item.percentageText)
                                .font(.footnote.bold())
                                .foregroundColor(item.color)
                        }

                        ProgressView(value: item.percentage)
                            .tint(item.color)
                            .scaleEffect(x: 1, y: 0.8, anchor: .center)

                        HStack {
                            if item.hasRequestCount {
                                Text("Requests: \(item.requestsUsed) of \(item.requestLimit)")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("Tokens: \(item.tokensUsed)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(7)
                    .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
            }

            Spacer(minLength: 0)

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
        .padding(14)
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
    @State private var isRefreshingUsage: Bool = false
    @State private var isRefreshingWidget: Bool = false
    @State private var widgetRefreshStatus: String?

    public init() {}

    private var orderedProviders: [ProviderUsageItem] {
        UsageSnapshot.ordered(providers, by: authManager.providerOrder, id: \.id)
    }

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
                            HStack(spacing: 8) {
                                Button {
                                    Task { await refreshUsage() }
                                } label: {
                                    if isRefreshingUsage {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Image(systemName: "arrow.clockwise")
                                    }
                                }
                                .disabled(isRefreshingUsage)
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
                        }

                        LazyVGrid(
                            columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                            alignment: .leading,
                            spacing: 8
                        ) {
                            ForEach(ServiceProviderType.allCases) { type in
                                servicePill(type: type)
                            }
                        }
                    }
                    .padding(16)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))

                    // Header
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("AI Usage Widget Gallery")
                                .font(.title.bold())
                            Spacer()
                            Button {
                                Task { await refreshWidget() }
                            } label: {
                                if isRefreshingWidget {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Label("Refresh Widget", systemImage: "arrow.triangle.2.circlepath")
                                        .font(.caption.bold())
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(isRefreshingWidget)
                        }
                        Text("Live preview of 1x1, 1x2, 1x3, and 2x2 widget formats.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if let widgetRefreshStatus {
                            Text(widgetRefreshStatus)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
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
                            Widget1x1View(providers: orderedProviders)
                        case 1:
                            Widget1x2View(providers: orderedProviders)
                        case 2:
                            Widget1x3View(providers: orderedProviders)
                        case 3:
                            Widget2x2View(providers: orderedProviders)
                        default:
                            Widget1x1View(providers: orderedProviders)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, minHeight: 380)
                    .padding(.vertical, 20)
                    .background(Color(.systemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))

                    refreshSection

                    providerOrderSection

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
                                    Text(providers[idx].hasUsageData
                                         ? (providers[idx].hasRequestCount
                                            ? "\(providers[idx].requestsUsed) / \(providers[idx].requestLimit) reqs (\(providers[idx].percentageInt)%)"
                                            : "\(providers[idx].percentageInt)% used")
                                         : "Usage not available")
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
            .onOpenURL { url in
                if url.scheme == "slopwidget", url.host == "cycle" {
                    authManager.cycleOpenCodeMeter()
                } else if url.scheme == "slopwidget", url.host == "cycle-claude" {
                    authManager.cycleClaudeMeter()
                } else if url.scheme == "slopwidget", url.host == "cycle-codex" {
                    authManager.cycleWindow(for: "codex")
                } else if url.scheme == "slopwidget", url.host == "cycle-antigravity" {
                    authManager.cycleWindow(for: "antigravity")
                }
            }
            .onAppear {
                if providers.isEmpty {
                    providers = SampleUsageData.providers
                }
            }
            .task {
                authManager.publishRefreshSetting()
                await refreshUsage()
            }
            // While the app is open, refresh on the chosen interval. The task
            // restarts (and its sleep restarts) whenever the interval changes.
            .task(id: authManager.refreshMinutes) {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(Double(authManager.refreshMinutes) * 60))
                    if Task.isCancelled { break }
                    await refreshUsage()
                }
            }
            .onChange(of: authManager.chatGPTUsage) { _, usage in
                guard let usage else { return }
                replaceCodexProvider(with: usage.providerUsageItem)
            }
            .onChange(of: authManager.openCodeUsage) { _, usage in
                guard let usage else { return }
                replaceOpenCodeProvider(with: usage)
            }
            .onChange(of: authManager.claudeUsage) { _, usage in
                guard let usage else { return }
                replaceProvider(with: usage.providerUsageItem)
            }
            .onChange(of: authManager.antigravityUsage) { _, usage in
                guard let usage else { return }
                replaceProvider(with: usage.providerUsageItem)
            }
        }
    }

    @MainActor
    private func refreshWidget() async {
        guard !isRefreshingWidget else { return }
        isRefreshingWidget = true
        defer { isRefreshingWidget = false }
        await authManager.refreshChatGPTUsage()
        await authManager.refreshOpenCodeUsage()
        if authManager.claudeCreds.isLoggedIn {
            await authManager.refreshClaudeUsage()
        }
        if authManager.antigravityCreds.isLoggedIn || authManager.antigravityAuthMethod == .google {
            await authManager.refreshAntigravityUsage()
        }
        if let usage = authManager.claudeUsage {
            replaceProvider(with: usage.providerUsageItem)
        }
        if let usage = authManager.antigravityUsage {
            replaceProvider(with: usage.providerUsageItem)
        }
        if let usage = authManager.chatGPTUsage {
            replaceCodexProvider(with: usage.providerUsageItem)
        }
        if let usage = authManager.openCodeUsage {
            replaceOpenCodeProvider(with: usage)
        }
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        WidgetCenter.shared.reloadTimelines(ofKind: "slopWidget")
        #endif
        widgetRefreshStatus = "Widget refreshed at \(Date().formatted(date: .omitted, time: .shortened))."
    }

    @MainActor
    private func refreshUsage() async {
        isRefreshingUsage = true
        defer { isRefreshingUsage = false }
        if authManager.codexAuthMethod == .chatGPT {
            await authManager.refreshChatGPTUsage()
            if let usage = authManager.chatGPTUsage {
                replaceCodexProvider(with: usage.providerUsageItem)
            }
        }
        if authManager.openCodeAuthMethod == .oauth {
            await authManager.refreshOpenCodeUsage()
            if let usage = authManager.openCodeUsage {
                replaceOpenCodeProvider(with: usage)
            }
        }
        if authManager.claudeCreds.isLoggedIn {
            await authManager.refreshClaudeUsage()
            if let usage = authManager.claudeUsage {
                replaceProvider(with: usage.providerUsageItem)
            }
        }
        if authManager.antigravityAuthMethod == .google || authManager.antigravityCreds.isLoggedIn {
            await authManager.refreshAntigravityUsage()
            if let usage = authManager.antigravityUsage {
                replaceProvider(with: usage.providerUsageItem)
            }
        }
    }

    // MARK: Refresh interval

    private var refreshSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Refresh")
                .font(.headline)
            Picker("Refresh every", selection: Binding(
                get: { authManager.refreshMinutes },
                set: { minutes in
                    authManager.setRefreshMinutes(minutes)
                    BackgroundRefresh.schedule(after: TimeInterval(authManager.refreshMinutes * 60))
                }
            )) {
                ForEach(RefreshInterval.allowedMinutes, id: \.self) { minutes in
                    Text(RefreshInterval.label(forMinutes: minutes)).tag(minutes)
                }
            }
            .pickerStyle(.segmented)
            Text("How often usage refreshes while the app is open, and how often the widget reloads. When the app is closed iOS decides when background refreshes run (it may be less often than this), so open the app or tap Refresh Widget for fresh numbers right now.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Widget order

    private var providerOrderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Widget Order")
                    .font(.headline)
                Spacer()
                Button("Reset") {
                    authManager.resetProviderOrder()
                }
                .font(.caption.bold())
                .disabled(authManager.providerOrder == AuthManager.defaultProviderOrder)
            }
            Text("Widgets list providers top to bottom, left to right. The 1x2 widget shows the first two and the 1x3 and medium widgets the first three.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(orderedProviders) { item in
                let position = authManager.providerOrder.firstIndex(of: item.id) ?? 0
                HStack(spacing: 10) {
                    Image(systemName: item.icon)
                        .foregroundColor(item.color)
                        .frame(width: 20)
                    Text(item.name)
                        .font(.subheadline.bold())
                    Spacer()
                    Button {
                        authManager.moveProvider(item.id, by: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(position == 0)
                    .accessibilityLabel("Move \(item.name) up")
                    Button {
                        authManager.moveProvider(item.id, by: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(position >= authManager.providerOrder.count - 1)
                    .accessibilityLabel("Move \(item.name) down")
                }
                .buttonStyle(.borderless)
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func replaceCodexProvider(with item: ProviderUsageItem) {
        replaceProvider(with: item)
    }

    private func replaceProvider(with item: ProviderUsageItem) {
        if let index = providers.firstIndex(where: { $0.id == item.id }) {
            providers[index] = item
        } else {
            providers.append(item)
        }
    }

    private func replaceOpenCodeProvider(with usage: OpenCodeUsage) {
        let item = ProviderUsageItem(
            id: "opencode-go",
            name: "OpenCode Go",
            shortName: "OCG",
            icon: "bolt.fill",
            color: Color(red: 0.25, green: 0.65, blue: 0.98),
            requestsUsed: usage.displayPercent,
            requestLimit: 100,
            tokensUsed: usage.detail,
            status: usage.statusText,
            hasRequestCount: false,
            hasUsageData: true
        )
        if let index = providers.firstIndex(where: { $0.id == "opencode-go" }) {
            providers[index] = item
        } else {
            providers.append(item)
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
                .lineLimit(1)
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

#Preview("MainDashboard") {
    ContentView()
}
