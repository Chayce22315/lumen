import SwiftUI
import LumenCore
import LumenFoundation
import LumenDesignSystem
import LumenPresentation
import LumenAutomation

/// Settings for one step. Edits are local until Done, which applies them as one undoable change;
/// if the editor refuses them (a number that isn't one, a delay over 30 days) the sheet stays open
/// and says why.
struct WorkflowNodeInspector: View {
    let editor: WorkflowEditorViewModel
    let nodeID: WorkflowNode.ID
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var action: ActionDraft?
    @State private var condition: ConditionDraft?
    @State private var delay: DelayDraft?
    @State private var hasLoaded = false

    var body: some View {
        Form {
            if let node = editor.node(nodeID) {
                Section("Name") {
                    TextField(WorkflowStyle.kindName(node.kind), text: $title)
                }
                if let binding = Binding($action) {
                    ActionFields(draft: binding, descriptor: editor.actions.first { $0.id == binding.wrappedValue.actionID })
                }
                if let binding = Binding($condition) {
                    ConditionFields(draft: binding, fields: editor.conditionFields)
                }
                if let binding = Binding($delay) {
                    DelayFields(draft: binding)
                }
                if case .end = node.kind {
                    Section {
                        Text("The run ends successfully when it reaches this step.")
                            .foregroundStyle(LumenColor.textSecondary)
                    }
                }
                if let rejection = editor.rejection {
                    Section {
                        Label(rejection.message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(LumenColor.danger)
                    }
                }
                let issues = editor.issues(for: nodeID)
                if !issues.isEmpty {
                    Section("Needs attention") {
                        ForEach(issues) { issue in
                            Text(issue.message).foregroundStyle(issue.severity == .error ? LumenColor.danger : LumenColor.warning)
                        }
                    }
                }
            } else {
                Text("This step was removed.").foregroundStyle(LumenColor.textSecondary)
            }
        }
        .scrollContentBackground(.hidden)
        .lumenScreenBackground()
        .navigationTitle(editor.node(nodeID).map { WorkflowStyle.kindName($0.kind) } ?? "Step")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    editor.dismissRejection()
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { apply() }
                    .disabled(editor.node(nodeID) == nil)
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard !hasLoaded, let node = editor.node(nodeID) else { return }
        hasLoaded = true
        editor.dismissRejection()
        title = node.title
        action = editor.actionDraft(for: nodeID)
        condition = editor.conditionDraft(for: nodeID)
        delay = editor.delayDraft(for: nodeID)
    }

    private func apply() {
        editor.dismissRejection()
        if let action {
            editor.update(nodeID, title: title, action: action)
        } else if let condition {
            editor.update(nodeID, title: title, condition: condition)
        } else if let delay {
            editor.update(nodeID, title: title, delay: delay)
        } else {
            editor.rename(nodeID, to: title)
        }
        if editor.rejection == nil { dismiss() }
    }
}

private struct ActionFields: View {
    @Binding var draft: ActionDraft
    let descriptor: AutomationActionDescriptor?

    var body: some View {
        Section {
            if let descriptor {
                ForEach(descriptor.parameters, id: \.name) { parameter in
                    VStack(alignment: .leading, spacing: LumenSpace.xs) {
                        Text(parameter.title + (parameter.isRequired ? "" : " (optional)"))
                            .lumenText(.caption)
                            .foregroundStyle(LumenColor.textSecondary)
                        TextField(placeholder(for: parameter), text: Binding(
                            get: { draft.texts[parameter.name] ?? "" },
                            set: { draft.texts[parameter.name] = $0 }
                        ), axis: .vertical)
                        .lumenText(.body)
                        .textInputAutocapitalization(.sentences)
                    }
                }
            } else {
                Text("This action isn't available on this device, so its settings can't be edited here.")
                    .foregroundStyle(LumenColor.textSecondary)
            }
        } header: {
            Label(descriptor?.title ?? draft.actionID.rawValue, systemImage: descriptor?.symbolName ?? "gearshape")
        } footer: {
            Text("Fields accept placeholders such as {{trigger.entity.id}} or {{steps.<step id>.output.title}}.")
        }
    }

    private func placeholder(for parameter: ActionParameterSpec) -> String {
        switch parameter.kind {
        case .number: return "A number"
        case .boolean: return "Yes or no"
        case .choice(let options): return options.joined(separator: ", ")
        case .date: return "YYYY-MM-DD"
        case .entity: return "An item, e.g. {{trigger.entity.id}}"
        case .text, .multilineText: return parameter.title
        }
    }
}

private struct ConditionFields: View {
    @Binding var draft: ConditionDraft
    let fields: [ConditionField]

    var body: some View {
        if let advanced = draft.advanced {
            Section("Condition") {
                Text(advanced.summary)
                Text("This condition was made elsewhere and can't be shown as rules.")
                    .lumenText(.footnote)
                    .foregroundStyle(LumenColor.textSecondary)
                Button("Replace with rules", systemImage: "arrow.triangle.2.circlepath") {
                    draft.replaceAdvanced(with: fields.first)
                }
            }
        } else {
            Section {
                if draft.rules.count > 1 {
                    Picker("Match", selection: $draft.match) {
                        ForEach(ConditionDraft.Match.allCases, id: \.self) { match in
                            Text(match.title).tag(match)
                        }
                    }
                }
                ForEach($draft.rules) { $rule in
                    RuleEditor(rule: $rule, fields: fields)
                }
                .onDelete { draft.rules.remove(atOffsets: $0) }
                Button("Add rule", systemImage: "plus.circle") {
                    draft.rules.append(ConditionDraft.Rule(path: fields.first?.path ?? "", valueKind: fields.first?.valueKind ?? .text))
                }
            } header: {
                Text("Continue on “If true” when")
            } footer: {
                if let problem = draft.problem {
                    Text(problem).foregroundStyle(LumenColor.danger)
                } else if draft.rules.isEmpty {
                    Text("With no rules the condition is always true.")
                } else {
                    Text("Otherwise the run continues on “If false”. Numbers, text and yes/no compare only with the same kind.")
                }
            }
        }
    }
}

private struct RuleEditor: View {
    @Binding var rule: ConditionDraft.Rule
    let fields: [ConditionField]
    private let customTag = "__custom__"

    var body: some View {
        VStack(alignment: .leading, spacing: LumenSpace.s) {
            Picker("Field", selection: fieldSelection) {
                ForEach(fields) { field in
                    Text(field.title).tag(field.path)
                }
                Text("Other field…").tag(customTag)
            }
            if isCustom {
                TextField("Path, e.g. input.priority", text: $rule.path)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lumenText(.monospaced)
                Picker("Value is", selection: $rule.valueKind) {
                    ForEach(ConditionDraft.ValueKind.allCases, id: \.self) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
            }
            Picker("Comparison", selection: $rule.comparison) {
                ForEach(ConditionDraft.comparisons(for: rule.valueKind), id: \.self) { comparison in
                    Text(comparison.title).tag(comparison)
                }
            }
            if !rule.comparison.isUnary {
                switch rule.valueKind {
                case .boolean:
                    Picker("Value", selection: $rule.value) {
                        Text("Yes").tag("true")
                        Text("No").tag("false")
                    }
                    .pickerStyle(.segmented)
                case .number:
                    TextField("Number", text: $rule.value)
                        .keyboardType(.numbersAndPunctuation)
                case .text:
                    TextField("Text", text: $rule.value)
                }
            }
        }
        .padding(.vertical, LumenSpace.xs)
        .onChange(of: rule.valueKind) { _, kind in
            if !ConditionDraft.comparisons(for: kind).contains(rule.comparison) { rule.comparison = .equals }
            if kind == .boolean, rule.value != "true", rule.value != "false" { rule.value = "true" }
        }
    }

    private var isCustom: Bool {
        !fields.contains { $0.path == rule.path }
    }

    private var fieldSelection: Binding<String> {
        Binding(
            get: { isCustom ? customTag : rule.path },
            set: { tag in
                if tag == customTag {
                    if !isCustom { rule.path = "" }
                } else if let field = fields.first(where: { $0.path == tag }) {
                    rule.path = field.path
                    rule.valueKind = field.valueKind
                }
            }
        )
    }
}

private struct DelayFields: View {
    @Binding var draft: DelayDraft

    var body: some View {
        Section {
            Stepper(value: $draft.amount, in: 0...max(0, draft.maximumAmount)) {
                Text("\(draft.amount) \(draft.unit.title(for: draft.amount))")
                    .monospacedDigit()
            }
            Picker("Unit", selection: $draft.unit) {
                ForEach(DelayDraft.Unit.allCases, id: \.self) { unit in
                    Text(unit.title(for: 2).capitalized).tag(unit)
                }
            }
        } header: {
            Text("Wait for")
        } footer: {
            if let problem = draft.problem {
                Text(problem).foregroundStyle(LumenColor.danger)
            } else {
                Text("Up to 30 days. Waits longer than a minute continue the next time Lumen is open after the time has passed.")
            }
        }
        .onChange(of: draft.unit) { _, _ in
            draft.amount = min(draft.amount, draft.maximumAmount)
        }
    }
}
