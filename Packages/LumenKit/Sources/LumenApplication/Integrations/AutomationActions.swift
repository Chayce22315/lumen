import Foundation
import LumenFoundation
import LumenCore
import LumenNotifications
import LumenOrganization
import LumenKnowledge
import LumenAutomation

/// Resolves an entity parameter given as `kind:UUID` or a bare UUID.
private func entityID(_ value: String?) -> UUID? {
    guard let value = value?.nonBlank else { return nil }
    return EntityReference(uri: value)?.id ?? UUID(uuidString: value)
}

struct CreateTaskAction: AutomationAction {
    let tasks: TaskService
    let projects: ProjectService

    let descriptor = AutomationActionDescriptor(
        id: "organization.createTask",
        title: "Create task",
        summary: "Adds a task. Fields accept {{placeholders}} from the trigger and earlier steps.",
        symbolName: "plus.circle",
        category: "Tasks",
        parameters: [
            ActionParameterSpec(name: "title", title: "Title", kind: .text, isRequired: true),
            ActionParameterSpec(name: "notes", title: "Notes", kind: .multilineText),
            ActionParameterSpec(name: "dueDate", title: "Due date", kind: .date),
            ActionParameterSpec(name: "priority", title: "Priority", kind: .choice(["none", "low", "medium", "high", "urgent"]), defaultValue: "none"),
            ActionParameterSpec(name: "project", title: "Project name", kind: .text),
        ],
        isMutating: true
    )

    func perform(_ invocation: ActionInvocation) async throws -> ActionOutcome {
        guard let title = invocation.string("title")?.nonBlank else {
            throw AutomationActionError.permanent("A title is required.")
        }
        var draft = TaskDraft(title: title, notes: invocation.string("notes") ?? "")
        if let text = invocation.string("dueDate")?.nonBlank {
            guard let day = CalendarDate(String(text.prefix(10))) else { throw AutomationActionError.permanent("The due date must be YYYY-MM-DD.") }
            draft.dueDate = day
        }
        if let text = invocation.string("priority"), let priority = ["none": TaskPriority.none, "low": .low, "medium": .medium, "high": .high, "urgent": .urgent][text] {
            draft.priority = priority
        }
        if let name = invocation.string("project")?.nonBlank?.foldedForMatching {
            draft.projectID = try await projects.projects().first { $0.status.isLive && $0.name.foldedForMatching == name }?.id
        }
        let task = try await tasks.create(draft, context: invocation.context)
        return ActionOutcome(output: ["id": .string(task.id.uuidString), "reference": .string(task.reference.uri), "title": .string(task.title)], message: "Created “\(task.title)”")
    }
}

struct CompleteTaskAction: AutomationAction {
    let tasks: TaskService

    let descriptor = AutomationActionDescriptor(
        id: "organization.completeTask",
        title: "Complete task",
        summary: "Marks a task as done.",
        symbolName: "checkmark.circle",
        category: "Tasks",
        parameters: [ActionParameterSpec(name: "task", title: "Task", kind: .entity(.task), isRequired: true)],
        isMutating: true
    )

    func perform(_ invocation: ActionInvocation) async throws -> ActionOutcome {
        guard let id = entityID(invocation.string("task")) else { throw AutomationActionError.permanent("Choose a task.") }
        let completion = try await tasks.complete(TaskItem.ID(id), context: invocation.context)
        return ActionOutcome(output: ["title": .string(completion.completed.title)], message: "Completed “\(completion.completed.title)”")
    }
}

struct CreateNoteAction: AutomationAction {
    let notes: NoteService

    let descriptor = AutomationActionDescriptor(
        id: "knowledge.createNote",
        title: "Create note",
        summary: "Writes a new Markdown note.",
        symbolName: "square.and.pencil",
        category: "Notes",
        parameters: [
            ActionParameterSpec(name: "title", title: "Title", kind: .text, isRequired: true),
            ActionParameterSpec(name: "body", title: "Body", kind: .multilineText),
        ],
        isMutating: true
    )

    func perform(_ invocation: ActionInvocation) async throws -> ActionOutcome {
        guard let title = invocation.string("title")?.nonBlank else { throw AutomationActionError.permanent("A title is required.") }
        let note = try await notes.create(title: title, body: invocation.string("body") ?? "", context: invocation.context)
        return ActionOutcome(output: ["id": .string(note.id.uuidString), "reference": .string(note.reference.uri)], message: "Created “\(note.title)”")
    }
}

struct AppendToNoteAction: AutomationAction {
    let notes: NoteService

    let descriptor = AutomationActionDescriptor(
        id: "knowledge.appendToNote",
        title: "Append to note",
        summary: "Adds a line or paragraph to the end of a note (a journal, a log).",
        symbolName: "text.append",
        category: "Notes",
        parameters: [
            ActionParameterSpec(name: "note", title: "Note", kind: .entity(.note), isRequired: true),
            ActionParameterSpec(name: "text", title: "Text", kind: .multilineText, isRequired: true),
        ],
        isMutating: true
    )

    func perform(_ invocation: ActionInvocation) async throws -> ActionOutcome {
        guard let id = entityID(invocation.string("note")) else { throw AutomationActionError.permanent("Choose a note.") }
        guard let text = invocation.string("text")?.nonBlank else { return ActionOutcome(message: "Nothing to append") }
        guard let note = try await notes.note(Note.ID(id)) else { throw AutomationActionError.permanent("That note no longer exists.") }
        let separator = note.body.isEmpty || note.body.hasSuffix("\n") ? "" : "\n"
        _ = try await notes.update(note.id, title: nil, body: note.body + separator + text, context: invocation.context)
        return ActionOutcome(message: "Appended to “\(note.title)”")
    }
}

struct SendNotificationAction: AutomationAction {
    let notifications: NotificationService

    let descriptor = AutomationActionDescriptor(
        id: "notifications.send",
        title: "Send notification",
        summary: "Shows a notification and adds it to the inbox.",
        symbolName: "bell",
        category: "Notifications",
        parameters: [
            ActionParameterSpec(name: "title", title: "Title", kind: .text, isRequired: true),
            ActionParameterSpec(name: "body", title: "Message", kind: .multilineText),
        ],
        isMutating: false
    )

    func perform(_ invocation: ActionInvocation) async throws -> ActionOutcome {
        guard let title = invocation.string("title")?.nonBlank else { throw AutomationActionError.permanent("A title is required.") }
        try await notifications.post(NotificationDraft(category: .automation, title: title, body: invocation.string("body") ?? ""))
        return ActionOutcome(message: "Notified")
    }
}

/// Events from built-in features that workflows can start on.
struct BuiltInTriggerSource: AutomationTriggerSource {
    var triggers: [AutomationTriggerDescriptor] {
        let taskAttributes = [
            TriggerAttributeSpec(name: "status", title: "Status", valueType: .string),
            TriggerAttributeSpec(name: "priority", title: "Priority (0–4)", valueType: .number),
            TriggerAttributeSpec(name: "projectID", title: "Project", valueType: .string),
            TriggerAttributeSpec(name: "dueDate", title: "Due date", valueType: .string),
        ]
        return [
            AutomationTriggerDescriptor(eventName: OrganizationEvent.taskCreated, title: "Task added", summary: "When a task is created.", symbolName: "plus.circle", category: "Tasks", attributes: taskAttributes),
            AutomationTriggerDescriptor(eventName: OrganizationEvent.taskCompleted, title: "Task completed", summary: "When a task is marked done.", symbolName: "checkmark.circle", category: "Tasks", attributes: taskAttributes),
            AutomationTriggerDescriptor(eventName: OrganizationEvent.projectCompleted, title: "Project completed", summary: "When a project is marked completed.", symbolName: "flag.checkered", category: "Projects"),
            AutomationTriggerDescriptor(eventName: OrganizationEvent.eventCreated, title: "Event scheduled", summary: "When a calendar event is created.", symbolName: "calendar.badge.plus", category: "Calendar"),
            AutomationTriggerDescriptor(eventName: KnowledgeEvents.noteCreated, title: "Note created", summary: "When a note is written.", symbolName: "square.and.pencil", category: "Notes"),
            AutomationTriggerDescriptor(eventName: KnowledgeEvents.documentImported, title: "Document imported", summary: "When a file is added to the library.", symbolName: "doc.badge.plus", category: "Notes"),
        ]
    }
}
