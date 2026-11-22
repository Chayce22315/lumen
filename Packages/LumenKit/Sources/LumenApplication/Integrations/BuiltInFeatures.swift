import Foundation
import LumenFoundation
import LumenPlugins
import LumenSearch
import LumenOrganization

/// Version of the built-in features; they ship with the app.
let builtInVersion = PluginVersion(major: 1, minor: 0, patch: 0)

/// App-wide navigation and creation commands.
struct CoreFeature: LumenPlugin {
    let manifest = PluginManifest(
        id: "app.lumen.core",
        name: "Lumen",
        summary: "Navigation and creation commands.",
        author: "Lumen",
        version: builtInVersion,
        capabilities: [.contributeCommands]
    )

    func activate(_ context: PluginContext) async throws {
        let commands: [(String, String, String, [String], String, AppDestination, Bool)] = [
            ("navigate.home", "Go to Home", "house", ["dashboard", "start"], "Navigate", .home, false),
            ("navigate.library", "Open Library", "books.vertical", ["notes", "documents", "knowledge"], "Navigate", .library, false),
            ("navigate.assistant", "Ask the assistant", "sparkles", ["ai", "chat", "help"], "Navigate", .assistant, true),
            ("navigate.automations", "Open Automations", "point.3.connected.trianglepath.dotted", ["workflows", "rules"], "Navigate", .automations, false),
            ("navigate.insights", "Open Insights", "chart.line.uptrend.xyaxis", ["analytics", "stats", "report"], "Navigate", .insights, false),
            ("navigate.notifications", "Open Notifications", "bell", ["inbox", "alerts"], "Navigate", .notifications, false),
            ("navigate.settings", "Open Settings", "gearshape", ["preferences", "options"], "Navigate", .settings(.general), false),
            ("settings.sync", "Sync settings", "arrow.triangle.2.circlepath", ["devices", "backup"], "Settings", .settings(.sync), false),
            ("settings.plugins", "Manage plugins", "puzzlepiece.extension", ["extensions", "permissions"], "Settings", .settings(.plugins), false),
            ("settings.diagnostics", "Diagnostics", "stethoscope", ["logs", "debug"], "Settings", .settings(.diagnostics), false),
            ("create.note", "New note", "square.and.pencil", ["write", "document"], "Create", .create(.note), true),
            ("create.workflow", "New automation", "plus.square.on.square", ["workflow", "rule"], "Create", .create(.workflow), false),
        ]
        for (id, title, symbol, keywords, category, destination, suggested) in commands {
            try context.contribute(
                LumenCommand(PaletteCommand(id: id, title: title, symbolName: symbol, keywords: keywords, category: category, isSuggested: suggested), action: .navigate(destination)),
                to: LumenExtensionPoints.commands
            )
        }
    }
}

/// Tasks, projects and calendar: search sources and commands.
struct OrganizationFeature: LumenPlugin {
    let tasks: TaskService
    let projects: ProjectService
    let calendars: CalendarService

    let manifest = PluginManifest(
        id: "app.lumen.organization",
        name: "Tasks & Calendar",
        summary: "Tasks, projects, calendars and reminders.",
        author: "Lumen",
        version: builtInVersion,
        capabilities: [.contributeCommands, .contributeSearchResults, .readTasks, .writeTasks, .readCalendar, .writeCalendar]
    )

    func activate(_ context: PluginContext) async throws {
        try context.contribute(TaskSearchSource(tasks: tasks, projects: projects), to: LumenExtensionPoints.searchSources)
        try context.contribute(ProjectSearchSource(projects: projects), to: LumenExtensionPoints.searchSources)
        try context.contribute(EventSearchSource(calendars: calendars), to: LumenExtensionPoints.searchSources)

        let navigation: [(String, String, String, [String], AppDestination, Bool)] = [
            ("create.task", "New task", "plus.circle", ["add", "todo", "capture"], .capture(text: nil), true),
            ("create.project", "New project", "folder.badge.plus", ["add"], .create(.project), false),
            ("create.event", "New event", "calendar.badge.plus", ["meeting", "appointment"], .create(.event), false),
            ("tasks.today", "Today", "sun.max", ["due", "focus"], .tasks(.today), true),
            ("tasks.upcoming", "Upcoming tasks", "calendar.day.timeline.left", ["week", "next"], .tasks(.upcoming), false),
            ("tasks.overdue", "Overdue tasks", "clock.badge.exclamationmark", ["late"], .tasks(.overdue), false),
            ("tasks.inbox", "Task inbox", "tray", ["unsorted"], .tasks(.inbox), false),
            ("tasks.projects", "Projects", "square.stack.3d.up", ["goals"], .tasks(.projects), false),
            ("navigate.calendar", "Calendar", "calendar", ["schedule", "agenda"], .calendar, false),
        ]
        for (id, title, symbol, keywords, destination, suggested) in navigation {
            try context.contribute(
                LumenCommand(PaletteCommand(id: id, title: title, symbolName: symbol, keywords: keywords, category: id.hasPrefix("create") ? "Create" : "Tasks", isSuggested: suggested), action: .navigate(destination)),
                to: LumenExtensionPoints.commands
            )
        }

        let tasks = self.tasks
        try context.contribute(
            LumenCommand(
                PaletteCommand(id: "tasks.completeOverdueReview", title: "Move overdue tasks to today", subtitle: "Reschedules every overdue task to today", symbolName: "arrow.uturn.forward", keywords: ["reschedule", "overdue"], category: "Tasks"),
                action: .perform {
                    let overdue = try await tasks.list(.overdue)
                    let today = tasks.today
                    for task in overdue {
                        _ = try await tasks.update(task.id, TaskChanges(dueDate: .some(today)))
                    }
                    let message = overdue.isEmpty ? "Nothing is overdue." : (overdue.count == 1 ? "Moved 1 task to today." : "Moved \(overdue.count) tasks to today.")
                    return CommandResult(message: message, destination: overdue.isEmpty ? nil : .tasks(.today))
                }
            ),
            to: LumenExtensionPoints.commands
        )
    }
}
