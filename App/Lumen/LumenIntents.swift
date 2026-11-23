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

/// Starts a focus session from Siri, Shortcuts or the Action button. A `LiveActivityIntent`, so
/// it runs in the app's process and may start the Live Activity while the app is in the
/// background.
struct StartFocusIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Start Focus"
    static let description = IntentDescription("Starts a focus session in Lumen, with a countdown on the Lock Screen.")

    @Parameter(title: "Minutes", default: 25)
    var minutes: Int

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = try await SharedServices.shared.services()
        let focus = services.focus
        do {
            let session = try await focus.service.start(FocusDraft(plannedMinutes: minutes))
            await focus.coordinator.reconcile()
            return .result(dialog: "Focusing for \(FocusIntegration.durationText(session.plannedDuration)).")
        } catch OrganizationError.focusSessionAlreadyActive {
            return .result(dialog: "A focus session is already running.")
        } catch let error as ValidationError {
            return .result(dialog: IntentDialog(stringLiteral: error.reason))
        }
    }
}

/// Finishes the running focus session, counting the time so far.
struct StopFocusIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Focus"
    static let description = IntentDescription("Finishes the running focus session in Lumen and counts the time so far.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = try await SharedServices.shared.services()
        let focus = services.focus
        guard let active = try await focus.service.activeSession() else {
            await focus.coordinator.reconcile()
            return .result(dialog: "No focus session is running.")
        }
        let ended = try await focus.service.finish(active.id).session
        await focus.coordinator.reconcile()
        let focused = FocusIntegration.durationText(ended.focusedDuration(at: ended.endedAt ?? ended.startedAt))
        return .result(dialog: "Done: \(focused) of focus.")
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
        AppShortcut(
            intent: StartFocusIntent(),
            phrases: ["Start focus in \(.applicationName)", "Start a focus session in \(.applicationName)"],
            shortTitle: "Start Focus",
            systemImageName: "timer"
        )
        AppShortcut(
            intent: StopFocusIntent(),
            phrases: ["Stop focus in \(.applicationName)", "End my focus session in \(.applicationName)"],
            shortTitle: "Stop Focus",
            systemImageName: "stop.circle"
        )
    }
}
