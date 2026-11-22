import SwiftUI
import LumenCore
import LumenFoundation
import LumenDesignSystem
import LumenPresentation
import LumenApplication
import LumenOrganization
import LumenKnowledge
import LumenIntelligence
import LumenAutomation

/// Maps a destination to its screen.
struct DestinationView: View {
    let destination: AppDestination
    let services: LumenServices
    let model: AppModel

    var body: some View {
        switch destination {
        case .tasks(let kind):
            if kind == .projects {
                ProjectsView(services: services, model: model)
            } else {
                TaskListView(source: .smart(SmartList(kind)), services: services, model: model)
            }
        case .calendar:
            CalendarView(services: services, model: model)
        case .automations:
            AutomationsView(services: services, model: model)
        case .insights:
            InsightsView(services: services)
        case .notifications:
            NotificationsView(services: services, model: model)
        case .entity(let reference):
            EntityView(reference: reference, services: services, model: model)
        case .home, .library, .assistant, .settings, .search, .capture, .create:
            // Tab roots and sheets are handled by the router, never pushed.
            EmptyView()
        }
    }
}

/// Opens any entity by kind.
struct EntityView: View {
    let reference: EntityReference
    let services: LumenServices
    let model: AppModel

    var body: some View {
        switch reference.kind {
        case .task:
            TaskEditorView(taskID: TaskItem.ID(reference.id), services: services, model: model)
        case .project:
            ProjectDetailView(projectID: Project.ID(reference.id), services: services, model: model)
        case .calendarEvent:
            EventEditorView(services: services, eventID: CalendarEvent.ID(reference.id))
        case .note:
            NoteEditorView(noteID: Note.ID(reference.id), services: services, model: model)
        case .document:
            DocumentDetailView(documentID: DocumentItem.ID(reference.id), services: services)
        case .collection:
            LibraryView(services: services, model: model, initialFilter: .collection(NoteCollection.ID(reference.id)))
        case .conversation:
            ChatView(conversationID: Conversation.ID(reference.id), services: services, model: model)
        case .workflow:
            WorkflowEditorView(services: services, workflowID: Workflow.ID(reference.id))
        default:
            StateMessage("Can't open this", message: "Lumen doesn't know how to show this kind of item yet.", symbolName: "questionmark.square.dashed")
        }
    }
}

extension SmartList {
    init(_ kind: AppDestination.TaskListKind) {
        switch kind {
        case .today: self = .today
        case .upcoming: self = .upcoming
        case .overdue: self = .overdue
        case .inbox: self = .inbox
        case .anytime: self = .anytime
        case .completed: self = .completed
        case .projects: self = .anytime
        }
    }
}
