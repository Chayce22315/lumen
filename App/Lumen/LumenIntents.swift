import AppIntents
import LumenFoundation
import LumenCore
import LumenOrganization
import LumenKnowledge
import LumenApplication
import LumenPlatform

/// "Add a task" from Siri, Shortcuts, Spotlight or the Action button.
struct AddTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Task"
    static let description = IntentDescription("Adds a task to Lumen. Dates, times, priorities (!high) and #tags in the text are understood.")

    @Parameter(title: "Task", requestValueDialog: "What should I add?")
    var text: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = try await SharedServices.shared.services()
        let (task, _) = try await services.organization.tasks.capture(text)
        var detail = ""
        if let due = task.dueDate { detail = " for \(due)" }
        return .result(dialog: "Added “\(task.title)”\(detail).")
    }
}

/// A spoken summary of today.
struct TodaySummaryIntent: AppIntent {
    static let title: LocalizedStringResource = "Today in Lumen"
    static let description = IntentDescription("Tells you what's due today and what's next.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = try await SharedServices.shared.services()
        let overview = try await services.organization.agenda.todayOverview(focusLimit: 3)
        var parts: [String] = []
        let due = overview.summary.dueToday
        parts.append(due == 0 ? "Nothing is due today." : (due == 1 ? "1 task is due today." : "\(due) tasks are due today."))
        if overview.summary.overdue > 0 {
            parts.append("\(overview.summary.overdue) overdue.")
        }
        if let first = overview.focusTasks.first {
            parts.append("Up first: \(first.title).")
        }
        if let next = overview.nextEvent {
            parts.append("Next event: \(next.title) at \(next.start.formatted(date: .omitted, time: .shortened)).")
        }
        return .result(dialog: IntentDialog(stringLiteral: parts.joined(separator: " ")))
    }
}

/// Saves a quick note.
struct AddNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Note"
    static let description = IntentDescription("Saves a note to your Lumen library.")

    @Parameter(title: "Note", requestValueDialog: "What should the note say?")
    var text: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = try await SharedServices.shared.services()
        let firstLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
        let note = try await services.knowledge.notes.create(title: firstLine.truncated(to: 80), body: text)
        return .result(dialog: "Saved “\(note.title)”.")
    }
}

struct LumenShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddTaskIntent(),
            phrases: ["Add a task in \(.applicationName)", "Capture a task in \(.applicationName)"],
            shortTitle: "Add Task",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: TodaySummaryIntent(),
            phrases: ["What's on today in \(.applicationName)", "My day in \(.applicationName)"],
            shortTitle: "Today",
            systemImageName: "sun.max"
        )
        AppShortcut(
            intent: AddNoteIntent(),
            phrases: ["Add a note in \(.applicationName)"],
            shortTitle: "Add Note",
            systemImageName: "square.and.pencil"
        )
    }
}
