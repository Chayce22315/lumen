import Foundation
import LumenFoundation
import LumenCore
import LumenOrganization
import LumenKnowledge
import LumenSearch
import LumenIntelligence
import LumenAutomation

/// Builds a JSON schema object for tool inputs.
enum Schema {
    static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        [
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)),
            "additionalProperties": false,
        ]
    }

    static func string(_ description: String, enum values: [String]? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "string", "description": .string(description)]
        if let values { schema["enum"] = .array(values.map(JSONValue.string)) }
        return .object(schema)
    }

    static func integer(_ description: String, minimum: Int, maximum: Int) -> JSONValue {
        ["type": "integer", "description": .string(description), "minimum": .number(Double(minimum)), "maximum": .number(Double(maximum))]
    }

    static func stringArray(_ description: String) -> JSONValue {
        ["type": "array", "description": .string(description), "items": ["type": "string"]]
    }
}

extension JSONValue {
    func requiredString(_ key: String) throws -> String {
        guard let value = self[key]?.stringValue?.nonBlank else {
            throw ToolInputError(message: "Missing required field '\(key)'.")
        }
        return value
    }
}

struct ToolInputError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

// MARK: - Search

struct SearchLumenTool: AssistantTool {
    let search: SearchService

    let definition = ToolDefinition(
        name: "search_lumen",
        description: "Full-text search across the user's tasks, projects, events, notes, documents and workflows. Returns titles with their reference ids.",
        inputSchema: Schema.object([
            "query": Schema.string("Words to search for."),
            "kinds": Schema.stringArray("Optional filter: any of task, project, calendar-event, note, document, collection, workflow."),
        ], required: ["query"])
    )
    let isMutating = false

    func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let query = try input.requiredString("query")
        let kinds = input["kinds"]?.arrayValue.map { Set($0.compactMap(\.stringValue).map(EntityKind.init(rawValue:))) }
        let results = try await search.search(SearchQuery(text: query, kinds: kinds, limit: 10))
        guard !results.isEmpty else { return ToolOutput(text: "No results for “\(query)”.") }
        let lines = results.map { result -> String in
            var line = "- \(result.title) [\(result.reference.uri)]"
            if !result.subtitle.isEmpty { line += " — \(result.subtitle)" }
            if let snippet = result.snippet?.text { line += "\n  \(snippet)" }
            return line
        }
        return ToolOutput(text: lines.joined(separator: "\n"), referencedEntities: results.map(\.reference))
    }
}

// MARK: - Tasks

struct ListTasksTool: AssistantTool {
    let tasks: TaskService

    let definition = ToolDefinition(
        name: "list_tasks",
        description: "Lists the user's tasks in one of the built-in lists, with ids, due dates and priorities.",
        inputSchema: Schema.object([
            "list": Schema.string("Which list.", enum: ["today", "upcoming", "overdue", "inbox", "anytime", "completed"]),
        ], required: ["list"])
    )
    let isMutating = false

    func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        guard let list = SmartList(rawValue: try input.requiredString("list")) else {
            return .error("Unknown list. Use one of: today, upcoming, overdue, inbox, anytime, completed.")
        }
        let items = try await tasks.list(list, limit: 25)
        guard !items.isEmpty else { return ToolOutput(text: "The \(list.title) list is empty.") }
        let lines = items.map { task -> String in
            var parts = ["- \(task.title) [\(task.reference.uri)]"]
            if let due = task.dueDate { parts.append("due \(due)\(task.dueTime.map { " \($0)" } ?? "")") }
            if task.priority != .none { parts.append("priority \(task.priority.title.lowercased())") }
            if task.status.isClosed { parts.append(task.status.rawValue) }
            return parts.joined(separator: ", ")
        }
        return ToolOutput(text: lines.joined(separator: "\n"), referencedEntities: items.map(\.reference))
    }
}

struct CreateTaskTool: AssistantTool {
    let tasks: TaskService
    let projects: ProjectService

    let definition = ToolDefinition(
        name: "create_task",
        description: "Creates a task. Use ISO dates (YYYY-MM-DD) and 24-hour times (HH:MM) relative to the current date in the system prompt.",
        inputSchema: Schema.object([
            "title": Schema.string("Short, actionable title."),
            "notes": Schema.string("Optional details."),
            "due_date": Schema.string("Optional due day, YYYY-MM-DD."),
            "due_time": Schema.string("Optional due time, HH:MM (requires due_date)."),
            "priority": Schema.string("Optional priority.", enum: ["none", "low", "medium", "high", "urgent"]),
            "project": Schema.string("Optional name of an existing project."),
            "tags": Schema.stringArray("Optional tags without '#'."),
        ], required: ["title"])
    )
    let isMutating = true

    func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let title = try input.requiredString("title")
        var draft = TaskDraft(title: title, notes: input["notes"]?.stringValue ?? "")
        if let text = input["due_date"]?.stringValue {
            guard let day = CalendarDate(text) else { return .error("due_date must be YYYY-MM-DD.") }
            draft.dueDate = day
        }
        if let text = input["due_time"]?.stringValue {
            guard let time = TimeOfDay(text) else { return .error("due_time must be HH:MM.") }
            draft.dueTime = time
        }
        if let text = input["priority"]?.stringValue {
            guard let priority = ["none": TaskPriority.none, "low": .low, "medium": .medium, "high": .high, "urgent": .urgent][text] else {
                return .error("Unknown priority.")
            }
            draft.priority = priority
        }
        if let name = input["project"]?.stringValue?.foldedForMatching {
            let match = try await projects.projects().first { $0.status.isLive && $0.name.foldedForMatching == name }
            guard let match else { return .error("No active project named “\(input["project"]?.stringValue ?? "")”.") }
            draft.projectID = match.id
        }
        draft.tags = input["tags"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let task = try await tasks.create(draft, context: context.action)
        return ToolOutput(text: "Created task “\(task.title)” [\(task.reference.uri)].", referencedEntities: [task.reference])
    }
}

struct CompleteTaskTool: AssistantTool {
    let tasks: TaskService

    let definition = ToolDefinition(
        name: "complete_task",
        description: "Marks a task as done. Get the id from list_tasks or search_lumen.",
        inputSchema: Schema.object(["task_id": Schema.string("The task reference (task:UUID) or UUID.")], required: ["task_id"])
    )
    let isMutating = true

    func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let raw = try input.requiredString("task_id")
        guard let id = EntityReference(uri: raw).map(\.id) ?? UUID(uuidString: raw) else { return .error("Not a task id.") }
        let completion = try await tasks.complete(TaskItem.ID(id), context: context.action)
        var text = "Completed “\(completion.completed.title)”."
        if let next = completion.nextInstance, let due = next.dueDate { text += " It repeats; the next one is due \(due)." }
        if !completion.unblocked.isEmpty { text += " Unblocked: \(completion.unblocked.map(\.title).joined(separator: ", "))." }
        return ToolOutput(text: text, referencedEntities: [completion.completed.reference] + completion.unblocked.map(\.reference))
    }
}

struct AgendaTool: AssistantTool {
    let agenda: AgendaService

    let definition = ToolDefinition(
        name: "get_agenda",
        description: "The user's calendar events and due tasks for the coming days, starting today.",
        inputSchema: Schema.object(["days": Schema.integer("How many days, starting today.", minimum: 1, maximum: 14)], required: [])
    )
    let isMutating = false

    func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let days = min(max(input["days"]?.intValue ?? 3, 1), 14)
        let agenda = try await agenda.agenda(days: days)
        var lines: [String] = []
        for day in agenda {
            lines.append("\(day.day):")
            if day.isEmpty { lines.append("  nothing scheduled") }
            for entry in day.allDay + day.scheduled + day.anytime {
                switch entry {
                case .event(let occurrence):
                    lines.append("  event: \(occurrence.title)\(occurrence.isAllDay ? " (all day)" : "")")
                case .task(let task):
                    lines.append("  task: \(task.title)\(task.dueTime.map { " at \($0)" } ?? "") [\(task.reference.uri)]")
                }
            }
        }
        return ToolOutput(text: lines.joined(separator: "\n"))
    }
}

// MARK: - Notes

struct CreateNoteTool: AssistantTool {
    let notes: NoteService

    let definition = ToolDefinition(
        name: "create_note",
        description: "Creates a Markdown note. Link to other notes with [[Title]].",
        inputSchema: Schema.object([
            "title": Schema.string("Note title."),
            "body": Schema.string("Markdown body."),
        ], required: ["title"])
    )
    let isMutating = true

    func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let note = try await notes.create(title: try input.requiredString("title"), body: input["body"]?.stringValue ?? "", context: context.action)
        return ToolOutput(text: "Created note “\(note.title)” [\(note.reference.uri)].", referencedEntities: [note.reference])
    }
}

struct ReadNoteTool: AssistantTool {
    let notes: NoteService

    let definition = ToolDefinition(
        name: "read_note",
        description: "Returns the full Markdown of a note found with search_lumen.",
        inputSchema: Schema.object(["note_id": Schema.string("The note reference (note:UUID) or UUID.")], required: ["note_id"])
    )
    let isMutating = false

    func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let raw = try input.requiredString("note_id")
        guard let id = EntityReference(uri: raw).map(\.id) ?? UUID(uuidString: raw),
              let note = try await notes.note(Note.ID(id)) else { return .error("No note with that id.") }
        return ToolOutput(text: "# \(note.title)\n\n\(note.body.truncated(to: 12_000))", referencedEntities: [note.reference])
    }
}

// MARK: - Automations

struct ListWorkflowsTool: AssistantTool {
    let automation: AutomationEngine

    let definition = ToolDefinition(
        name: "list_workflows",
        description: "Lists the user's automations with their ids and whether they are enabled.",
        inputSchema: Schema.object([:])
    )
    let isMutating = false

    func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let workflows = try await automation.workflows()
        guard !workflows.isEmpty else { return ToolOutput(text: "There are no automations yet.") }
        let lines = workflows.map { "- \($0.name) [workflow:\($0.id.uuidString)]\($0.isEnabled ? "" : " (disabled)")" }
        return ToolOutput(text: lines.joined(separator: "\n"))
    }
}

struct RunWorkflowTool: AssistantTool {
    let automation: AutomationEngine

    let definition = ToolDefinition(
        name: "run_workflow",
        description: "Runs an automation now. Get the id from list_workflows.",
        inputSchema: Schema.object(["workflow_id": Schema.string("The workflow reference (workflow:UUID) or UUID.")], required: ["workflow_id"])
    )
    let isMutating = true

    func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let raw = try input.requiredString("workflow_id")
        guard let id = EntityReference(uri: raw).map(\.id) ?? UUID(uuidString: raw) else { return .error("Not a workflow id.") }
        let run = try await automation.run(Workflow.ID(id), input: .null, context: context.action)
        return ToolOutput(text: "The automation finished with status \(run.status.rawValue).")
    }
}
