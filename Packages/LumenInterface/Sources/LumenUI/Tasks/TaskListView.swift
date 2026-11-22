import SwiftUI
import LumenFoundation
import LumenDesignSystem
import LumenPresentation
import LumenApplication
import LumenOrganization

/// A list of tasks: a smart list, a project or a tag.
struct TaskListView: View {
    let services: LumenServices
    let model: AppModel
    @State private var list: TaskListViewModel

    init(source: TaskListSource, services: LumenServices, model: AppModel) {
        self.services = services
        self.model = model
        _list = State(initialValue: TaskListViewModel(source: source, services: services))
    }

    var body: some View {
        content
            .scrollContentBackground(.hidden)
            .lumenScreenBackground()
            .navigationTitle(list.title)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.router.open(.capture(text: nil)) } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New task")
                }
            }
            .task { await list.start() }
            .refreshable { await list.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch list.state {
        case .idle, .loading:
            SkeletonRows().padding(LumenSpace.screen).frame(maxHeight: .infinity, alignment: .top)
        case .failed(let error):
            StateMessage(error.title, message: error.message, symbolName: "exclamationmark.triangle", actionTitle: "Try again") {
                Task { await list.load() }
            }
        case .loaded(let rows) where rows.isEmpty:
            StateMessage(emptyTitle, message: emptyMessage, symbolName: "checkmark.circle", actionTitle: "Add a task") {
                model.router.open(.capture(text: nil))
            }
        case .loaded(let rows):
            List {
                ForEach(rows) { row in
                    NavigationLink(value: AppDestination.entity(row.task.reference)) {
                        TaskRowView(row: row) {
                            Task { await list.toggleCompletion(row.id) }
                        }
                    }
                    .listRowBackground(LumenColor.surface)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            Task { await list.toggleCompletion(row.id) }
                        } label: {
                            Label(row.isDone ? "Reopen" : "Done", systemImage: row.isDone ? "arrow.uturn.backward" : "checkmark")
                        }
                        .tint(LumenColor.success)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await list.delete(row.id) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            Task { await list.reschedule(row.id, to: services.today.adding(days: 1)) }
                        } label: {
                            Label("Tomorrow", systemImage: "arrow.right.circle")
                        }
                        .tint(LumenColor.accentFill)
                    }
                }
                .onMove(perform: supportsManualOrder ? { source, destination in
                    Task { await list.move(fromOffsets: source, toOffset: destination) }
                } : nil)
            }
            .animation(.lumenSmooth, value: rows.map(\.id))
        }
    }

    private var supportsManualOrder: Bool {
        switch list.source {
        case .project, .smart(.inbox), .smart(.anytime): return true
        default: return false
        }
    }

    private var emptyTitle: String {
        if case .smart(let smart) = list.source {
            switch smart {
            case .today: return "Today is clear"
            case .overdue: return "Nothing overdue"
            case .completed: return "Nothing completed yet"
            default: return "No tasks"
            }
        }
        return "No tasks"
    }

    private var emptyMessage: String {
        if case .smart(.today) = list.source {
            return "Tasks due today and anything you start today show up here."
        }
        return "Tasks you add here will appear in this list."
    }
}
