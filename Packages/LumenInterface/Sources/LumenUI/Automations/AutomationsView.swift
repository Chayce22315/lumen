import SwiftUI
import LumenCore
import LumenFoundation
import LumenDesignSystem
import LumenPresentation
import LumenApplication
import LumenAutomation

/// Workflows: status, last run, next run, run now.
struct AutomationsView: View {
    let services: LumenServices
    let model: AppModel
    @State private var automations: AutomationsViewModel
    @State private var isCreating = false

    init(services: LumenServices, model: AppModel) {
        self.services = services
        self.model = model
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
            List(rows) { row in
                NavigationLink(value: AppDestination.entity(EntityReference(kind: .workflow, id: row.workflow.id))) {
                    WorkflowRow(row: row)
                }
                .listRowBackground(LumenColor.surface)
                .swipeActions(edge: .leading) {
                    Button { Task { await automations.runNow(row.id) } } label: { Label("Run", systemImage: "play.fill") }
                        .tint(LumenColor.accentFill)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { Task { await automations.delete(row.id) } } label: { Label("Delete", systemImage: "trash") }
                    Button { Task { await automations.duplicate(row.id) } } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
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

/// Builds a workflow: trigger, then steps; shows the graph it produces.
struct WorkflowEditorView: View {
    let services: LumenServices
    @State private var editor: WorkflowEditorViewModel
    @State private var showsCanvas = false
    @Environment(\.dismiss) private var dismiss

    init(services: LumenServices, workflowID: Workflow.ID?) {
        self.services = services
        _editor = State(initialValue: WorkflowEditorViewModel(services: services, workflowID: workflowID))
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $editor.name)
                TextField("What it does", text: $editor.summary, axis: .vertical)
            }
            Section("When") { TriggerPicker(editor: editor) }
            Section("Then") {
                ForEach($editor.steps) { $step in
                    StepEditor(step: $step, descriptor: editor.actions.first { $0.id == step.actionID })
                }
                .onDelete { offsets in
                    for index in offsets { editor.removeStep(editor.steps[index].id) }
                }
                .onMove { editor.moveSteps(fromOffsets: $0, toOffset: $1) }
                Menu {
                    ForEach(editor.actions) { action in
                        Button(action.title, systemImage: action.symbolName) { editor.addStep(action.id) }
                    }
                } label: {
                    Label("Add step", systemImage: "plus.circle")
                }
            }
            Section {
                Button("Show as diagram", systemImage: "point.3.connected.trianglepath.dotted") { showsCanvas = true }
            } footer: {
                Text("Fields accept placeholders such as {{trigger.entity.id}} or {{steps.<step id>.output.title}}.")
            }
            if !editor.issues.isEmpty || editor.error != nil {
                Section("Needs attention") {
                    ForEach(editor.issues, id: \.self) { issue in
                        Text(issue.message).foregroundStyle(LumenColor.danger)
                    }
                    if editor.issues.isEmpty, let error = editor.error {
                        Text(error.message).foregroundStyle(LumenColor.danger)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .lumenScreenBackground()
        .navigationTitle(editor.workflowID == nil ? "New automation" : "Automation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { if await editor.save() != nil { dismiss() } } }
                    .disabled(editor.name.isEmpty)
            }
        }
        .sheet(isPresented: $showsCanvas) {
            NavigationStack {
                WorkflowCanvasView(graph: editor.graph())
                    .navigationTitle("Diagram")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task { await loadExisting() }
    }

    private func loadExisting() async {
        guard let id = editor.workflowID, editor.name.isEmpty,
              let workflow = try? await services.automation.engine.workflow(id) else { return }
        editor.name = workflow.name
        editor.summary = workflow.summary
        switch workflow.trigger {
        case .manual: editor.trigger = .manual
        case .event(let name, _): editor.trigger = .event(name)
        case .schedule(let schedule): editor.trigger = .daily(schedule.time)
        }
        editor.steps = WorkflowStepReader.steps(from: workflow.graph)
    }
}

/// Reads a linear graph back into editable steps.
enum WorkflowStepReader {
    static func steps(from graph: WorkflowGraph) -> [WorkflowEditorViewModel.Step] {
        guard var current = graph.nodes.first(where: { $0.kind == .trigger })?.id else { return [] }
        var steps: [WorkflowEditorViewModel.Step] = []
        var visited = Set<WorkflowNode.ID>()
        while let edge = graph.edges.first(where: { $0.from == current }), visited.insert(edge.to).inserted,
              let node = graph.nodes.first(where: { $0.id == edge.to }) {
            if case .action(let actionID, let parameters) = node.kind {
                let values = parameters.compactMapValues { value -> String? in
                    switch value {
                    case .literal(let json): return json.displayString
                    case .template(let text): return text
                    case .reference(let path): return "{{\(path)}}"
                    }
                }
                steps.append(WorkflowEditorViewModel.Step(id: node.id, actionID: actionID, parameters: values))
            }
            current = node.id
        }
        return steps
    }
}

private struct TriggerPicker: View {
    @Bindable var editor: WorkflowEditorViewModel

    var body: some View {
        Picker("Trigger", selection: Binding(
            get: { kind },
            set: { newKind in
                switch newKind {
                case "manual": editor.trigger = .manual
                case "daily": editor.trigger = .daily(TimeOfDay.nine)
                default: editor.trigger = .event(EventName(newKind))
                }
            }
        )) {
            Text("When I run it").tag("manual")
            Text("Every day").tag("daily")
            ForEach(editor.triggers) { trigger in
                Text(trigger.title).tag(trigger.eventName.rawValue)
            }
        }
        if case .daily(let time) = editor.trigger {
            DatePicker("At", selection: Binding(
                get: { time.date(on: CalendarDate(Date(), calendar: .current), calendar: .current) },
                set: { editor.trigger = .daily(TimeOfDay($0, calendar: .current)) }
            ), displayedComponents: .hourAndMinute)
        }
    }

    private var kind: String {
        switch editor.trigger {
        case .manual: return "manual"
        case .daily: return "daily"
        case .event(let name): return name.rawValue
        }
    }
}

private struct StepEditor: View {
    @Binding var step: WorkflowEditorViewModel.Step
    let descriptor: AutomationActionDescriptor?

    var body: some View {
        VStack(alignment: .leading, spacing: LumenSpace.s) {
            Label(descriptor?.title ?? step.actionID.rawValue, systemImage: descriptor?.symbolName ?? "gearshape")
                .lumenText(.headline)
            ForEach(descriptor?.parameters ?? [], id: \.name) { parameter in
                TextField(parameter.title + (parameter.isRequired ? "" : " (optional)"), text: Binding(
                    get: { step.parameters[parameter.name] ?? "" },
                    set: { step.parameters[parameter.name] = $0 }
                ), axis: .vertical)
                .lumenText(.body)
                .textInputAutocapitalization(.sentences)
            }
        }
        .padding(.vertical, LumenSpace.xs)
    }
}
