import SwiftUI
import LumenCore
import LumenFoundation
import LumenDesignSystem
import LumenPresentation
import LumenApplication
import LumenAutomation

/// Workflows: status, last run, next run, run now; and the latest runs across all of them.
struct AutomationsView: View {
    let services: LumenServices
    let model: AppModel
    /// The automation or run shown beside the list on iPad; `nil` where rows push onto a stack.
    let selection: Binding<AppDestination?>?
    @State private var automations: AutomationsViewModel
    @State private var isCreating = false

    init(services: LumenServices, model: AppModel, selection: Binding<AppDestination?>? = nil) {
        self.services = services
        self.model = model
        self.selection = selection
        _automations = State(initialValue: AutomationsViewModel(services: services))
    }

    var body: some View {
        content
            .scrollContentBackground(.hidden)
            .lumenScreenBackground()
            .navigationTitle("Automations")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isCreating = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New automation")
                }
            }
            .sheet(isPresented: $isCreating) {
                NavigationStack { WorkflowEditorView(services: services, workflowID: nil) }
            }
            .task { await automations.start() }
    }

    @ViewBuilder
    private var content: some View {
        switch automations.state {
        case .idle, .loading:
            SkeletonRows().padding(LumenSpace.screen).frame(maxHeight: .infinity, alignment: .top)
        case .failed(let error):
            StateMessage(error.title, message: error.message, symbolName: "exclamationmark.triangle")
        case .loaded(let rows) where rows.isEmpty:
            StateMessage("No automations", message: "Automations run steps for you when something happens or on a schedule — like logging every finished task to a journal.", symbolName: "point.3.connected.trianglepath.dotted", actionTitle: "Create one") {
                isCreating = true
            }
        case .loaded(let rows):
            SelectableList(selection: selection) {
                Section {
                    ForEach(rows) { row in
                        let destination = AppDestination.entity(EntityReference(kind: .workflow, id: row.workflow.id))
                        NavigationLink(value: destination) {
                            WorkflowRow(row: row)
                        }
                        .selectableRow(destination, selection: selection, background: LumenColor.surface)
                        .swipeActions(edge: .leading) {
                            Button { Task { await automations.runNow(row.id) } } label: { Label("Run", systemImage: "play.fill") }
                                .tint(LumenColor.accentFill)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                // The detail beside the list would show a deleted automation.
                                if selection?.wrappedValue == destination { selection?.wrappedValue = nil }
                                Task { await automations.delete(row.id) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button { Task { await automations.duplicate(row.id) } } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                        }
                    }
                }
                if !automations.recentRuns.isEmpty {
                    Section("Recent runs") {
                        ForEach(automations.recentRuns) { run in
                            let destination = AppDestination.entity(run.reference)
                            NavigationLink(value: destination) {
                                RunSummaryRow(run: run, workflowName: rows.first { $0.workflow.id == run.workflowID }?.workflow.name)
                            }
                            .selectableRow(destination, selection: selection, background: LumenColor.surface)
                        }
                    }
                }
            }
        }
    }
}

private struct WorkflowRow: View {
    let row: AutomationsViewModel.Row

    var body: some View {
        HStack(spacing: LumenSpace.m) {
            IconBadge(symbol, tint: row.workflow.isEnabled ? LumenColor.accent : LumenColor.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.workflow.name).lumenText(.body)
                Text(detail).lumenText(.caption).foregroundStyle(LumenColor.textSecondary).lineLimit(1)
            }
            Spacer()
            if let status = row.lastRun?.status, status == .failed {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(LumenColor.danger).accessibilityLabel("Last run failed")
            }
        }
    }

    private var symbol: String {
        switch row.workflow.trigger {
        case .manual: return "hand.tap"
        case .event: return "bolt"
        case .schedule: return "clock"
        }
    }

    private var detail: String {
        if !row.workflow.isEnabled { return "Off" }
        if let next = row.nextFire {
            return "Next run " + next.formatted(date: .abbreviated, time: .shortened)
        }
        if let last = row.lastRun {
            return "Last run " + last.startedAt.formatted(.relative(presentation: .named))
        }
        return "Hasn't run yet"
    }
}
