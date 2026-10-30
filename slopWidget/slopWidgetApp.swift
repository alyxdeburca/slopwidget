import SwiftUI
import AppIntents

@main
struct slopWidgetApp: App {
    /// Every widget AppIntent. A widget tap is delivered to the app by type
    /// name, so each type's Swift metadata has to stay in the binary. Nothing
    /// else in the app references these types, and unreferenced types are
    /// dead-stripped at link time. (A bare `_ = Type.self` is discarded by the
    /// compiler, so the array is read for real in `init`.)
    private static let widgetIntents: [any AppIntent.Type] = [
        CycleOpenCodeMeterIntent.self,
        CycleClaudeMeterIntent.self,
        CycleCodexMeterIntent.self,
        CycleAntigravityMeterIntent.self,
    ]

    init() {
        precondition(!Self.widgetIntents.isEmpty)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
