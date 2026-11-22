import Foundation
import LumenFoundation
import LumenCore
import LumenSync

/// What a background refresh got done.
public struct BackgroundRefreshReport: Sendable, Hashable {
    public enum Step: String, Sendable, Hashable, CaseIterable {
        case automations
        case widgetActions
        case sync
        case widgets
        case documentFiles
    }

    /// Steps that ran, in order.
    public var completed: [Step] = []
    /// Steps not started because the task was cancelled or ran out of time.
    public var skipped: [Step] = []
    /// The sync run's outcome; `nil` when sync waited for a pending retry or didn't run.
    public var syncOutcome: SyncRun.Outcome?

    public init() {}

    public var isComplete: Bool { skipped.isEmpty }
}

extension LumenRuntime {
    /// The work of a background app refresh: due automations, tasks checked on the widget, a sync
    /// pass, the widget snapshot and document uploads, cheapest and most visible first. Starts the runtime if the system launched
    /// the app in the background. Stops between steps when the task is cancelled (the system's
    /// time is up) or `deadline` has passed.
    @discardableResult
    public func performBackgroundRefresh(deadline: Date? = nil) async -> BackgroundRefreshReport {
        await start()
        let services = self.services
        var report = BackgroundRefreshReport()

        let mayContinue: @Sendable () -> Bool = {
            let outOfTime = deadline.map { services.timeSource.now() >= $0 } ?? false
            return !Task.isCancelled && !outOfTime
        }

        if mayContinue() {
            await tickAutomations()
            report.completed.append(.automations)
        } else {
            report.skipped.append(.automations)
        }
        // Tasks checked on the widget while the app was closed are completed before syncing, so
        // the sync pass carries them. (A cold start already applied them in `start()`.)
        if mayContinue() {
            await applyWidgetActions()
            report.completed.append(.widgetActions)
        } else {
            report.skipped.append(.widgetActions)
        }
        if mayContinue() {
            report.syncOutcome = await services.sync.synchronizeIfDue()?.outcome
            report.completed.append(.sync)
        } else {
            report.skipped.append(.sync)
        }
        if mayContinue() {
            await services.widgets.refresh()
            report.completed.append(.widgets)
        } else {
            report.skipped.append(.widgets)
        }
        if mayContinue() {
            await services.documentFiles.uploadPending()
            report.completed.append(.documentFiles)
        } else {
            report.skipped.append(.documentFiles)
        }

        services.logging.logger("runtime").info("Background refresh finished", metadata: [
            "completed": report.completed.map(\.rawValue).joined(separator: ","),
            "skipped": report.skipped.map(\.rawValue).joined(separator: ","),
        ])
        return report
    }
}
