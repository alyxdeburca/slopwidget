import Foundation

#if os(iOS) && canImport(BackgroundTasks)
import BackgroundTasks

/// Asks iOS to wake the app periodically so usage (and therefore the widget)
/// stays fresh without opening it.
///
/// iOS treats `earliestBeginDate` as a lower bound and decides when the task
/// really runs, based on how often the app is used, battery and network, so the
/// chosen interval is a request, not a guarantee. The task identifier must be
/// listed in Info.plist (`BGTaskSchedulerPermittedIdentifiers`) and the app
/// needs the `fetch` background mode.
enum BackgroundRefresh {
    static let taskIdentifier = "com.example.slopWidget.refresh"

    /// Must run before the app finishes launching (from `App.init`).
    @MainActor
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            let box = TaskBox(task)
            Task { @MainActor in
                handle(box)
            }
        }
    }

    /// Requests the next refresh `interval` seconds from now, replacing any
    /// pending request.
    static func schedule(after interval: TimeInterval) {
        let scheduler = BGTaskScheduler.shared
        scheduler.cancel(taskRequestWithIdentifier: taskIdentifier)
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: max(60, interval))
        try? scheduler.submit(request)
    }

    @MainActor
    private static func handle(_ box: TaskBox) {
        let auth = AuthManager.shared
        // Queue the next one first so a failure or expiry does not end the chain.
        schedule(after: TimeInterval(auth.refreshMinutes * 60))
        let work = Task { @MainActor in
            let success = await auth.refreshAllUsage()
            box.task.setTaskCompleted(success: success)
        }
        box.task.expirationHandler = {
            work.cancel()
        }
    }

    /// BGTask is not Sendable; it is only touched from the main actor and its
    /// own expiration handler, which BackgroundTasks makes safe to call.
    private final class TaskBox: @unchecked Sendable {
        let task: BGTask
        init(_ task: BGTask) { self.task = task }
    }
}
#else
/// No-op where BackgroundTasks is unavailable (plain Linux builds).
enum BackgroundRefresh {
    @MainActor static func register() {}
    static func schedule(after interval: TimeInterval) {}
}
#endif
