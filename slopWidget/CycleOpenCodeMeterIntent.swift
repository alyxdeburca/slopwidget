import Foundation
import AppIntents
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Registered in the app target as well as the widget extension so the widget
/// interaction can be discovered reliably.
struct CycleOpenCodeMeterIntent: AppIntent {
    static let title: LocalizedStringResource = "Cycle OpenCode Usage Window"

    func perform() async throws -> some IntentResult {
        var snapshot = SharedUsageStore.load() ?? UsageSnapshot()
        let order = ["rolling", "weekly", "monthly"]
        let current = UserDefaults.standard.string(forKey: "opencodeMeterSelection")
            ?? snapshot.openCodeMeterSelection
            ?? "weekly"
        let index = order.firstIndex(of: current) ?? 1
        let next = order[(index + 1) % order.count]
        snapshot.openCodeMeterSelection = next
        UserDefaults.standard.set(next, forKey: "opencodeMeterSelection")
        try? SharedUsageStore.save(snapshot)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        WidgetCenter.shared.reloadTimelines(ofKind: "slopWidget")
        #endif
        return .result()
    }
}
