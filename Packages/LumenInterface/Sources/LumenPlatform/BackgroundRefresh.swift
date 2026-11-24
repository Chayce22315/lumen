import Foundation
import LumenApplication
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif
#if canImport(os)
import os
#endif

/// Background app refresh: the task identifier (also listed under
/// `BGTaskSchedulerPermittedIdentifiers` in the app's Info.plist), scheduling, and the work.
public enum BackgroundRefresh {
    public static let taskIdentifier = "app.lumen.refresh"
    /// The earliest the next refresh may run. The system decides the actual time, often later.
    public static let minimumInterval: TimeInterval = 15 * 60

    #if canImport(os)
    private static var log: os.Logger { os.Logger(subsystem: "app.lumen", category: "background") }
    #endif

    /// Asks the system for the next refresh, replacing an earlier request.
    public static func schedule(after interval: TimeInterval = minimumInterval) {
        #if canImport(BackgroundTasks) && os(iOS)
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Expected in the simulator and when the user turned Background App Refresh off; the
            // app then catches up when it is opened.
            log.notice("Background refresh not scheduled: \(String(describing: error), privacy: .public)")
        }
        #endif
    }

    /// The system's refresh task: schedules the next one first, then runs the shared runtime's
    /// refresh. SwiftUI cancels the task when the system's time is up; the runtime stops between
    /// steps when that happens.
    public static func run() async {
        schedule()
        do {
            let runtime = try await SharedServices.shared.runtime()
            await runtime.performBackgroundRefresh()
        } catch {
            #if canImport(os)
            log.error("Background refresh could not open Lumen: \(String(describing: type(of: error)), privacy: .public)")
            #endif
        }
    }
}
