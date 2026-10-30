import Foundation
import AppIntents
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Exposed by the app target so widget interactions can resolve its metadata.
/// Cycle order: 5-hour -> weekly -> 5-hour (shortest window first); before the first tap the weekly window is shown.
struct CycleCodexMeterIntent: AppIntent {
    static var title: LocalizedStringResource { "Cycle Codex Usage Window" }
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        WindowCycling.cycle(provider: "codex")
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        WidgetCenter.shared.reloadTimelines(ofKind: "slopWidget")
        #endif
        return .result()
    }
}
