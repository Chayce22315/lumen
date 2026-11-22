import SwiftUI
import LumenCore
import LumenFoundation
import LumenDesignSystem
import LumenPresentation
import LumenApplication
import LumenAutomation

/// A step to open in the inspector.
struct InspectedStep: Identifiable, Hashable {
    let id: WorkflowNode.ID
}

/// Builds a workflow: the trigger, then steps in reading order. Each step's menu adds, connects,
/// disconnects and deletes steps, so everything the diagram does by dragging is also possible here
/// (and with VoiceOver).
struct WorkflowEditorView: View {
    let services: LumenServices
    @State private var editor: WorkflowEditorViewModel
    @State private var inspecting: InspectedStep?
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
            Section {
                ForEach(editor.outline) { item in
                    StepListRow(item: item, editor: editor) { inspecting = InspectedStep(id: $0) }
                }
                Menu {
                    NewStepButtons(actions: editor.actions) { step in
                        if let id = editor.append(step), step != .end { inspecting = InspectedStep(id: id) }
                    }
                } label: {
                    Label("Add step", systemImage: "plus.circle")
                }
            } header: {
                Text("Steps")
            } footer: {
                Text("A step's menu adds steps after it, connects its outputs and removes it. Conditions continue on “If true” or “If false”.")
            }
            Section {
                Button("Edit as diagram", systemImage: "point.3.connected.trianglepath.dotted") { showsCanvas = true }
            } footer: {
                Text("Drag steps to arrange them and drag from a step's output dot to another step to connect them.")
            }
            if !editor.recentRuns.isEmpty {
                Section("Recent runs") {
                    ForEach(editor.recentRuns) { run in
                        NavigationLink(value: AppDestination.entity(run.reference)) {
                            RunSummaryRow(run: run)
                        }
                    }
                }
            }
            if !workflowIssues.isEmpty || editor.error != nil {
                Section("Needs attention") {
                    ForEach(workflowIssues) { issue in
                        Text(issue.message).foregroundStyle(issue.severity == .error ? LumenColor.danger : LumenColor.warning)
                    }
                    if let error = editor.error {
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
            ToolbarItem(placement: .topBarTrailing) {
                Button { editor.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!editor.canUndo)
                    .accessibilityLabel("Undo")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { if await editor.save() != nil { dismiss() } } }
                    .disabled(editor.name.trimmingCharacters(in: .whitespaces).isEmpty || (editor.workflowID != nil && !editor.isLoaded))
            }
        }
        .sheet(item: $inspecting) { step in
            NavigationStack { WorkflowNodeInspector(editor: editor, nodeID: step.id) }
        }
        .fullScreenCover(isPresented: $showsCanvas) {
            NavigationStack { WorkflowCanvasEditor(editor: editor) }
        }
        .alert(
            editor.rejection?.title ?? "",
            isPresented: Binding(
                get: { editor.rejection != nil && inspecting == nil && !showsCanvas },
                set: { if !$0 { editor.dismissRejection() } }
            ),
            actions: { Button("OK", role: .cancel) { editor.dismissRejection() } },
            message: { Text(editor.rejection?.message ?? "") }
        )
        .task { await editor.load() }
    }

    /// Issues not tied to a step (step issues show on their rows).
    private var workflowIssues: [ValidationIssue] {
        editor.issues.filter { $0.nodeID == nil || editor.node($0.nodeID ?? WorkflowNode.ID()) == nil }
    }
}

/// One step in the list, indented by branch, with its menu.
private struct StepListRow: View {
    let item: WorkflowOutline.Item
    let editor: WorkflowEditorViewModel
    let inspect: (WorkflowNode.ID) -> Void

    var body: some View {
        if let node = editor.node(item.nodeID) {
            HStack(alignment: .top, spacing: LumenSpace.s) {
                Button {
                    if !node.kind.isTrigger { inspect(node.id) }
                } label: {
                    HStack(alignment: .top, spacing: LumenSpace.m) {
                        IconBadge(WorkflowStyle.symbol(for: node.kind), tint: WorkflowStyle.tint(for: node.kind))
                        VStack(alignment: .leading, spacing: 2) {
                            if let via = item.via, via.port != .next {
                                Text(WorkflowEditorViewModel.title(for: via.port))
                                    .lumenText(.caption)
                                    .foregroundStyle(WorkflowStyle.tint(for: via.port))
                            }
                            Text(node.title.isEmpty ? WorkflowStyle.kindName(node.kind) : node.title)
                                .lumenText(.body)
                                .foregroundStyle(LumenColor.textPrimary)
                            Text(editor.summary(of: node.id))
                                .lumenText(.caption)
                                .foregroundStyle(LumenColor.textSecondary)
                                .lineLimit(2)
                            if !item.isConnected {
                                Label("Not connected to the trigger", systemImage: "exclamationmark.triangle")
                                    .lumenText(.caption)
                                    .foregroundStyle(LumenColor.warning)
                            }
                            ForEach(editor.issues(for: node.id)) { issue in
                                Text(issue.message)
                                    .lumenText(.caption)
                                    .foregroundStyle(issue.severity == .error ? LumenColor.danger : LumenColor.warning)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(node.kind.isTrigger ? "Change the trigger under When." : "Opens the step's settings.")
                StepMenu(node: node, editor: editor, inspect: inspect)
            }
            .padding(.leading, CGFloat(item.depth) * LumenSpace.l)
        }
    }
}

/// Everything you can do to a step: edit, add after each output, connect or disconnect each
/// output, delete.
struct StepMenu: View {
    let node: WorkflowNode
    let editor: WorkflowEditorViewModel
    let inspect: (WorkflowNode.ID) -> Void

    var body: some View {
        Menu {
            StepMenuItems(node: node, editor: editor, inspect: inspect)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body)
                .foregroundStyle(LumenColor.textSecondary)
                .frame(width: LumenLayout.tapTarget, height: LumenLayout.tapTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Actions for \(node.title)")
    }
}

/// The items of a step's menu, also used for the canvas context menu.
struct StepMenuItems: View {
    let node: WorkflowNode
    let editor: WorkflowEditorViewModel
    let inspect: (WorkflowNode.ID) -> Void

    var body: some View {
        if !node.kind.isTrigger {
            Button("Edit step", systemImage: "slider.horizontal.3") { inspect(node.id) }
        }
        ForEach(node.kind.outputPorts, id: \.self) { port in
            Section(WorkflowEditorViewModel.title(for: port)) {
                Menu("Add step", systemImage: "plus") {
                    NewStepButtons(actions: editor.actions) { step in
                        if let id = editor.add(step, after: node.id, port: port), step != .end { inspect(id) }
                    }
                }
                if let target = editor.graph.successor(of: node.id, port: port) {
                    let targetTitle = editor.node(target)?.title ?? "step"
                    Button("Disconnect from “\(targetTitle)”", systemImage: "scissors") {
                        editor.disconnect(node.id, port: port)
                    }
                } else {
                    let targets = editor.connectionTargets(from: node.id, port: port)
                    if !targets.isEmpty {
                        Menu("Connect to", systemImage: "arrow.turn.down.right") {
                            ForEach(targets) { target in
                                Button(target.title.isEmpty ? WorkflowStyle.kindName(target.kind) : target.title) {
                                    editor.connect(node.id, port: port, to: target.id)
                                }
                            }
                        }
                    }
                }
            }
        }
        if !node.kind.isTrigger {
            Button("Delete step", systemImage: "trash", role: .destructive) { editor.remove(node.id) }
        }
    }
}

/// The kinds of step that can be added.
struct NewStepButtons: View {
    let actions: [AutomationActionDescriptor]
    let add: (WorkflowEditorViewModel.NewStep) -> Void

    var body: some View {
        ForEach(actions) { action in
            Button(action.title, systemImage: action.symbolName) { add(.action(action.id)) }
        }
        Divider()
        Button("Condition", systemImage: "arrow.triangle.branch") { add(.condition) }
        Button("Wait", systemImage: "hourglass") { add(.delay) }
        Button("End", systemImage: "flag.checkered") { add(.end) }
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
                case "custom": break
                default: editor.trigger = .event(EventName(newKind))
                }
            }
        )) {
            Text("When I run it").tag("manual")
            Text("Every day").tag("daily")
            ForEach(editor.triggers) { trigger in
                Text(trigger.title).tag(trigger.eventName.rawValue)
            }
            if case .custom = editor.trigger {
                Text(editor.triggerSummary).tag("custom")
            }
        }
        if case .daily(let time) = editor.trigger {
            DatePicker("At", selection: Binding(
                get: { time.date(on: CalendarDate(Date(), calendar: .current), calendar: .current) },
                set: { editor.trigger = .daily(TimeOfDay($0, calendar: .current)) }
            ), displayedComponents: .hourAndMinute)
        }
        if case .custom = editor.trigger {
            Text("This trigger was set up elsewhere. It stays as it is unless you choose another one.")
                .lumenText(.footnote)
                .foregroundStyle(LumenColor.textSecondary)
        }
    }

    private var kind: String {
        switch editor.trigger {
        case .manual: return "manual"
        case .daily: return "daily"
        case .event(let name): return name.rawValue
        case .custom: return "custom"
        }
    }
}
