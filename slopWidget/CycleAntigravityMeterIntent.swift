import Foundation
import AppIntents
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Exposed by the app target so widget interactions can resolve its metadata.
/// Cycle order: each quota bucket in the order the service reports them; before the first tap the most constrained bucket is shown.
struct CycleAntigravityMeterIntent: AppIntent {
    static var title: LocalizedStringResource { "Cycle Antigravity Usage Window" }
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        WindowCycling.cycle(provider: "antigravity")
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        WidgetCenter.shared.reloadTimelines(ofKind: "slopWidget")
        #endif
        return .result()
    }
}
