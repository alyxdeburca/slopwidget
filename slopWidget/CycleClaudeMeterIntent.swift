import Foundation
import AppIntents
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Exposed by the app target so widget interactions can resolve its metadata.
/// Cycle order: 5-hour -> weekly -> 5-hour, skipping windows without data;
/// before the first tap the most constrained window is shown.
struct CycleClaudeMeterIntent: AppIntent {
    static var title: LocalizedStringResource { "Cycle Claude Usage Window" }
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        var snapshot = SharedUsageStore.load() ?? UsageSnapshot()
        if let meters = snapshot.claudeMeters {
            let current = UserDefaults.standard.string(forKey: "claudeMeterSelection")
                ?? snapshot.claudeMeterSelection
            if let next = meters.nextWindow(after: current) {
                snapshot.claudeMeterSelection = next
                UserDefaults.standard.set(next, forKey: "claudeMeterSelection")
                try? SharedUsageStore.save(snapshot)
            }
        }
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        WidgetCenter.shared.reloadTimelines(ofKind: "slopWidget")
        #endif
        return .result()
    }
}
