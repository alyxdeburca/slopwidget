import Foundation
import AppIntents
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Exposed by the app target so widget interactions can resolve its metadata.
struct CycleOpenCodeMeterIntent: AppIntent {
    static var title: LocalizedStringResource { "Cycle OpenCode Usage Window" }
    static var openAppWhenRun: Bool { false }

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
