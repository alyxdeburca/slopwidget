import SwiftUI

@main
struct slopWidgetApp: App {
    init() {
        // A widget tap is delivered to the app by type name, so the AppIntent's
        // Swift metadata has to stay in the binary. Nothing else in the app
        // references it, and unreferenced types are dead-stripped at link time.
        _ = CycleOpenCodeMeterIntent.self
        _ = CycleClaudeMeterIntent.self
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
