import Foundation
import LumenFoundation
import LumenCore
import LumenOrganization
import LumenWidgetData

extension LumenRuntime {
    /// How long a widget action that keeps failing is retried before it is dropped.
    public static let widgetActionLifetime: TimeInterval = 7 * 86_400

    /// Carries out what the user did on widgets while Lumen was not running (checking off
    /// tasks), through the same services as the interface, then rewrites the snapshot. Actions for
    /// tasks that no longer exist are dropped; others that fail stay queued for the next attempt
    /// until `widgetActionLifetime` has passed. Returns how many actions changed something.
    @discardableResult
    public func applyWidgetActions() async -> Int {
        let queue = services.widgets.actionQueue
        let pending: [WidgetAction]
        do {
            pending = try queue.pending()
        } catch {
            services.errors.report(error, context: "Reading widget actions")
            return 0
        }
        guard !pending.isEmpty else { return 0 }

        let now = services.timeSource.now()
        var finished: Set<UUID> = []
        var applied = 0
        for action in pending {
            switch action.kind {
            case .completeTask:
                let tasks = services.organization.tasks
                let id = TaskItem.ID(action.taskID)
                do {
                    // Deleted or already closed since the widget showed it: nothing left to do.
                    if let task = try await tasks.task(id), task.isOpen {
                        _ = try await tasks.complete(id, context: .user)
                        applied += 1
                    }
                    finished.insert(action.id)
                } catch OrganizationError.taskNotFound(_) {
                    finished.insert(action.id)
                } catch {
                    services.errors.report(error, context: "Completing a task from the widget")
                    if now.timeIntervalSince(action.requestedAt) > Self.widgetActionLifetime {
                        finished.insert(action.id)
                    }
                }
            }
        }
        do {
            try queue.remove(finished)
        } catch {
            services.errors.report(error, context: "Clearing widget actions")
        }
        await services.widgets.refresh()
        return applied
    }
}
