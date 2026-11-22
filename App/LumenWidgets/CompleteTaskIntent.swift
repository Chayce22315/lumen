import AppIntents
import Foundation
import LumenWidgetData

/// Checks off a task from the Today widget. The extension never opens Lumen's database: the
/// completion is queued in the App Group for the app to apply, and the snapshot is updated at once
/// so the widget shows the task as done.
struct CompleteTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Complete Task"
    static let description = IntentDescription("Marks a task from the Today widget as done.")
    static let isDiscoverable = false

    @Parameter(title: "Task ID")
    var taskID: String

    init() {}

    init(taskID: UUID) {
        self.taskID = taskID.uuidString
    }

    func perform() async throws -> some IntentResult {
        guard let directory = SharedContainer.directory(), let id = UUID(uuidString: taskID) else {
            throw WidgetActionUnavailable()
        }
        try WidgetActionQueue(directory: directory).enqueue(WidgetAction(kind: .completeTask, taskID: id, requestedAt: Date()))
        let store = WidgetSnapshotStore(url: directory.appendingPathComponent(SharedContainer.snapshotFileName))
        if let snapshot = try store.read() {
            try store.write(snapshot.markingCompleted(id))
        }
        return .result()
    }
}

/// The App Group is not provisioned, so the widget can't hand work to the app.
struct WidgetActionUnavailable: Error, CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource {
        "Open Lumen to complete this task."
    }
}
