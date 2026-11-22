import SwiftUI
import LumenCore
import LumenDesignSystem
import LumenPresentation
import LumenApplication
import LumenFoundation
import LumenIntelligence

/// Modal content: capture, creation, settings and the command palette.
struct SheetView: View {
    let route: SheetRoute
    let services: LumenServices
    let model: AppModel

    var body: some View {
        switch route {
        case .capture(let text):
            QuickCaptureView(services: services, initialText: text)
                .presentationDetents([.height(260), .medium])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(LumenRadius.sheet)
        case .create(let kind):
            CreationSheet(kind: kind, services: services, model: model)
        case .settings(let section):
            SettingsView(services: services, model: model, initialSection: section)
                .presentationCornerRadius(LumenRadius.sheet)
        case .commandPalette:
            NavigationStack {
                SearchView(services: services, model: model)
            }
            .presentationDetents([.large])
        }
    }
}

/// "New …" flows. Each creates the item and opens it where the user continues editing.
struct CreationSheet: View {
    let kind: AppDestination.CreationKind
    let services: LumenServices
    let model: AppModel

    var body: some View {
        switch kind {
        case .task:
            QuickCaptureView(services: services, initialText: nil)
                .presentationDetents([.height(260), .medium])
        case .project:
            NavigationStack { ProjectCreationView(services: services, model: model) }
                .presentationDetents([.medium])
        case .event:
            NavigationStack { EventEditorView(services: services, eventID: nil) }
        case .note:
            NoteCreationLauncher(services: services, model: model)
        case .workflow:
            NavigationStack { WorkflowEditorView(services: services, workflowID: nil) }
        case .conversation:
            ConversationLauncher(services: services, model: model)
        }
    }
}

/// Creates an empty note and opens it in the Library.
struct NoteCreationLauncher: View {
    let services: LumenServices
    let model: AppModel

    var body: some View {
        ProgressView()
            .task {
                let library = LibraryViewModel(services: services)
                let note = await library.createNote()
                model.router.dismissSheet()
                if let note {
                    model.router.selectedTab = .library
                    model.router.libraryPath = [.entity(note.reference)]
                }
            }
    }
}

/// Starts a conversation and opens it in the Assistant tab.
struct ConversationLauncher: View {
    let services: LumenServices
    let model: AppModel

    var body: some View {
        ProgressView()
            .task {
                let conversations = ConversationsViewModel(services: services)
                let conversation = await conversations.create()
                model.router.dismissSheet()
                if let conversation {
                    model.router.selectedTab = .assistant
                    model.router.assistantPath = [.entity(EntityReference(kind: .conversation, id: conversation.id))]
                }
            }
    }
}
