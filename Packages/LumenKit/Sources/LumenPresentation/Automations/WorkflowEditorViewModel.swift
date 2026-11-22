import Foundation
import Observation
import LumenFoundation
import LumenCore
import LumenAutomation
import LumenApplication

/// Editing a workflow: its trigger and its graph of steps — actions, conditions with true/false
/// branches, delays and ends.
///
/// The graph is the single source of truth for both the step list and the canvas. Every change goes
/// through `WorkflowGraphEditing`, which refuses invalid structure (cycles, connections into the
/// trigger, a second trigger, a used or missing output) with a message in `rejection`; accepted
/// changes can be undone one by one. `issues` re-validates the whole workflow after every change.
@MainActor
@Observable
public final class WorkflowEditorViewModel {
    public enum TriggerChoice: Sendable, Hashable {
        case manual
        case event(EventName)
        case daily(TimeOfDay)
        /// A trigger the editor can't change in place (another schedule, an event with a condition).
        /// Kept as it is unless another choice replaces it.
        case custom(TriggerDefinition)
    }

    /// A kind of step to add.
    public enum NewStep: Sendable, Hashable {
        case action(AutomationActionID)
        case condition
        case delay
        case end
    }

    public static let undoLimit = 50

    public let workflowID: Workflow.ID?
    public var name = ""
    public var summary = ""
    public var trigger: TriggerChoice = .manual {
        didSet { revalidate() }
    }
    public private(set) var graph: WorkflowGraph
    /// Problems in the workflow as it stands; errors block saving.
    public private(set) var issues: [ValidationIssue] = []
    /// Why the last save failed.
    public private(set) var error: ErrorPresentation?
    /// Why the last edit was refused. Cleared by the next accepted edit or `dismissRejection()`.
    public private(set) var rejection: ErrorPresentation?
    public private(set) var isLoaded: Bool
    /// This workflow's latest runs (existing workflows only).
    public private(set) var recentRuns: [WorkflowRun] = []

    private let services: LumenServices
    private let labels: DateLabels
    private var undoStack: [WorkflowGraph] = []
    private var stored: Workflow?

    public init(services: LumenServices, workflowID: Workflow.ID? = nil, locale: Locale = .current) {
        self.services = services
        self.labels = DateLabels(calendar: services.calendar, locale: locale)
        self.workflowID = workflowID
        self.graph = .starter()
        self.isLoaded = workflowID == nil
        revalidate()
    }

    public var actions: [AutomationActionDescriptor] { services.automation.catalog.descriptors }
    public var triggers: [AutomationTriggerDescriptor] { services.automation.catalog.triggerDescriptors }
    public var canUndo: Bool { !undoStack.isEmpty }

    // MARK: - Loading and saving

    /// Loads the workflow being edited. Missing workflows and storage errors set `error`.
    public func load() async {
        guard let workflowID else { return }
        let engine = services.automation.engine
        do {
            guard let workflow = try await engine.workflow(workflowID) else {
                error = AutomationError.workflowNotFound(workflowID).presentation
                return
            }
            stored = workflow
            name = workflow.name
            summary = workflow.summary
            graph = workflow.graph
            undoStack = []
            trigger = Self.choice(for: workflow.trigger)
            recentRuns = try await engine.runs(workflowID: workflowID, limit: 10)
            isLoaded = true
            revalidate()
        } catch {
            self.error = ErrorPresentation.from(error)
        }
    }

    /// Validates and saves. Returns the workflow on success; `issues` and `error` explain failures.
    @discardableResult
    public func save() async -> Workflow? {
        error = nil
        let engine = services.automation.engine
        do {
            let workflow: Workflow
            if let workflowID {
                guard var existing = try await engine.workflow(workflowID) ?? stored else {
                    throw AutomationError.workflowNotFound(workflowID)
                }
                existing.name = name
                existing.summary = summary
                existing.trigger = triggerDefinition()
                existing.graph = graph
                workflow = try await engine.update(existing)
            } else {
                workflow = try await engine.create(WorkflowDraft(name: name, summary: summary, trigger: triggerDefinition(), graph: graph))
            }
            stored = workflow
            issues = engine.validate(workflow)
            return workflow
        } catch let failure as AutomationError {
            if case .invalidWorkflow(let found) = failure { issues = found }
            error = failure.presentation
            return nil
        } catch {
            self.error = ErrorPresentation.from(error)
            return nil
        }
    }

    public func triggerDefinition() -> TriggerDefinition {
        switch trigger {
        case .manual:
            return .manual
        case .event(let name):
            return .event(name: name, condition: nil)
        case .daily(let time):
            return .schedule(ScheduleTrigger(rule: .daily, anchor: services.today, time: time))
        case .custom(let definition):
            return definition
        }
    }

    static func choice(for definition: TriggerDefinition) -> TriggerChoice {
        switch definition {
        case .manual:
            return .manual
        case .event(let name, .none):
            return .event(name)
        case .schedule(let schedule) where schedule.rule == .daily:
            return .daily(schedule.time)
        case .event, .schedule:
            return .custom(definition)
        }
    }

    // MARK: - Reading the graph

    public func node(_ id: WorkflowNode.ID) -> WorkflowNode? {
        graph.node(id)
    }

    /// Steps in reading order, for the list form of the editor.
    public var outline: [WorkflowOutline.Item] {
        WorkflowOutline.items(for: graph)
    }

    public func issues(for id: WorkflowNode.ID) -> [ValidationIssue] {
        issues.issues(for: id)
    }

    /// What a step does, in a line.
    public func summary(of id: WorkflowNode.ID) -> String {
        guard let node = graph.node(id) else { return "" }
        switch node.kind {
        case .trigger:
            return triggerSummary
        case .action(let actionID, let parameters):
            let values = (services.automation.catalog.descriptor(actionID)?.parameters ?? [])
                .compactMap { spec in parameters[spec.name].map(ActionDraft.text(for:))?.nonBlank }
            return values.isEmpty ? (services.automation.catalog.descriptor(actionID)?.summary ?? actionID.rawValue) : values.joined(separator: " · ")
        case .condition(let condition):
            return condition.summary
        case .delay(let seconds):
            return DelayDraft(seconds: seconds).summary
        case .end:
            return "The run ends here"
        }
    }

    public var triggerSummary: String {
        switch trigger {
        case .manual: return "When I run it"
        case .event(let name): return triggers.first { $0.eventName == name }?.title ?? name.rawValue
        case .daily(let time): return "Every day at \(labels.timeLabel(time))"
        case .custom(let definition):
            switch definition {
            case .manual: return "When I run it"
            case .event(let name, _): return (triggers.first { $0.eventName == name }?.title ?? name.rawValue) + ", with a condition"
            case .schedule: return "On a custom schedule"
            }
        }
    }

    /// Output ports of `id` and where each leads (`nil` when free).
    public func outputs(of id: WorkflowNode.ID) -> [(port: EdgePort, target: WorkflowNode.ID?)] {
        guard let node = graph.node(id) else { return [] }
        return node.kind.outputPorts.map { port in (port, graph.successor(of: id, port: port)) }
    }

    /// Steps the free output `port` of `source` could connect to without breaking the graph's rules.
    public func connectionTargets(from source: WorkflowNode.ID, port: EdgePort) -> [WorkflowNode] {
        graph.nodes.filter { candidate in
            (try? WorkflowGraphEditing.connect(source, to: candidate.id, port: port, in: graph)) != nil // probing: a refusal just means "not a target"
        }
    }

    public static func title(for port: EdgePort) -> String {
        switch port {
        case .next: return "Then"
        case .whenTrue: return "If true"
        case .whenFalse: return "If false"
        }
    }

    // MARK: - Editing the graph

    /// Adds a step after `source` on `port`; when that output already led somewhere, the new step
    /// is spliced in between. Returns the new step's identifier, or `nil` with `rejection` set.
    @discardableResult
    public func add(_ step: NewStep, after source: WorkflowNode.ID, port: EdgePort = .next) -> WorkflowNode.ID? {
        let node = WorkflowNode(
            title: defaultTitle(for: step),
            position: WorkflowCanvasGeometry(graph: graph).placement(below: source, port: port),
            kind: kind(for: step)
        )
        let accepted = apply { graph in try WorkflowGraphEditing.insert(node, after: source, port: port, in: graph) }
        return accepted ? node.id : nil
    }

    /// Adds a step at the end of the main path (before a final end step).
    @discardableResult
    public func append(_ step: NewStep) -> WorkflowNode.ID? {
        guard let point = WorkflowOutline.appendPoint(in: graph) else {
            rejection = ErrorPresentation(title: "Can't change the workflow", message: "This workflow has no trigger to add steps after.")
            return nil
        }
        return add(step, after: point.node, port: point.port)
    }

    /// Appends an action step (the common case).
    @discardableResult
    public func addStep(_ actionID: AutomationActionID) -> WorkflowNode.ID? {
        append(.action(actionID))
    }

    @discardableResult
    public func remove(_ id: WorkflowNode.ID) -> Bool {
        apply { graph in try WorkflowGraphEditing.remove(id, from: graph) }
    }

    @discardableResult
    public func connect(_ source: WorkflowNode.ID, port: EdgePort, to target: WorkflowNode.ID) -> Bool {
        apply { graph in try WorkflowGraphEditing.connect(source, to: target, port: port, in: graph) }
    }

    /// Points a used output at another step in one undoable edit.
    @discardableResult
    public func reconnect(_ source: WorkflowNode.ID, port: EdgePort, to target: WorkflowNode.ID) -> Bool {
        apply { graph in
            try WorkflowGraphEditing.connect(source, to: target, port: port, in: WorkflowGraphEditing.disconnect(source, port: port, in: graph))
        }
    }

    @discardableResult
    public func disconnect(_ edge: WorkflowEdge) -> Bool {
        guard graph.edges.contains(edge) else { return false }
        return apply { graph in WorkflowGraphEditing.disconnect(edge, in: graph) }
    }

    @discardableResult
    public func disconnect(_ source: WorkflowNode.ID, port: EdgePort) -> Bool {
        guard graph.successor(of: source, port: port) != nil else { return false }
        return apply { graph in WorkflowGraphEditing.disconnect(source, port: port, in: graph) }
    }

    /// Moves a step on the canvas, snapped to the grid. Moving to where it already is changes nothing.
    @discardableResult
    public func move(_ id: WorkflowNode.ID, to position: CanvasPoint) -> Bool {
        let snapped = WorkflowCanvasGeometry.snap(position)
        guard let node = graph.node(id) else {
            rejection = WorkflowGraphEditError.nodeNotFound(id).presentation
            return false
        }
        guard node.position != snapped else { return false }
        return apply { graph in try WorkflowGraphEditing.move(id, to: snapped, in: graph) }
    }

    /// Lays every step out top to bottom, branches side by side.
    @discardableResult
    public func arrange() -> Bool {
        let positions = WorkflowAutoLayout.positions(for: graph)
        return apply { graph in
            var result = graph
            for index in result.nodes.indices {
                if let position = positions[result.nodes[index].id] {
                    result.nodes[index].position = position
                }
            }
            return result
        }
    }

    // MARK: - Editing steps

    public func actionDraft(for id: WorkflowNode.ID) -> ActionDraft? {
        guard case .action(let actionID, let parameters)? = graph.node(id)?.kind else { return nil }
        return ActionDraft(actionID: actionID, parameters: parameters)
    }

    public func conditionDraft(for id: WorkflowNode.ID) -> ConditionDraft? {
        guard case .condition(let condition)? = graph.node(id)?.kind else { return nil }
        return ConditionDraft(condition)
    }

    public func delayDraft(for id: WorkflowNode.ID) -> DelayDraft? {
        guard case .delay(let seconds)? = graph.node(id)?.kind else { return nil }
        return DelayDraft(seconds: seconds)
    }

    @discardableResult
    public func rename(_ id: WorkflowNode.ID, to title: String) -> Bool {
        guard let node = graph.node(id) else { return false }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != node.title else { return false }
        return apply { graph in try WorkflowGraphEditing.update(id, title: trimmed, kind: node.kind, in: graph) }
    }

    @discardableResult
    public func update(_ id: WorkflowNode.ID, title: String? = nil, action draft: ActionDraft) -> Bool {
        let specs = services.automation.catalog.descriptor(draft.actionID)?.parameters
        return updateKind(id, title: title, kind: .action(actionID: draft.actionID, parameters: draft.parameters(specs: specs)))
    }

    @discardableResult
    public func update(_ id: WorkflowNode.ID, title: String? = nil, condition draft: ConditionDraft) -> Bool {
        do {
            return updateKind(id, title: title, kind: .condition(try draft.condition()))
        } catch {
            rejection = ErrorPresentation.from(error)
            return false
        }
    }

    @discardableResult
    public func update(_ id: WorkflowNode.ID, title: String? = nil, delay draft: DelayDraft) -> Bool {
        do {
            return updateKind(id, title: title, kind: .delay(seconds: try draft.validatedSeconds()))
        } catch {
            rejection = ErrorPresentation.from(error)
            return false
        }
    }

    /// Fields a condition can test: the trigger's attributes, then the trigger's own facts.
    public var conditionFields: [ConditionField] {
        var fields: [ConditionField] = []
        if case .event(let name) = trigger, let descriptor = triggers.first(where: { $0.eventName == name }) {
            fields += descriptor.attributes.map { ConditionField(path: $0.path, title: $0.title, valueKind: ConditionDraft.ValueKind($0.valueType)) }
        }
        fields.append(ConditionField(path: "trigger.name", title: "Event name", valueKind: .text))
        fields.append(ConditionField(path: "trigger.actor", title: "Started by (user, assistant, automation, sync)", valueKind: .text))
        return fields
    }

    // MARK: - Undo

    public func undo() {
        guard let previous = undoStack.popLast() else { return }
        graph = previous
        rejection = nil
        revalidate()
    }

    public func dismissRejection() {
        rejection = nil
    }

    // MARK: - Helpers

    /// Applies an edit; on success records the previous graph for undo and re-validates.
    private func apply(_ change: (WorkflowGraph) throws -> WorkflowGraph) -> Bool {
        do {
            let updated = try change(graph)
            guard updated != graph else { return false }
            undoStack.append(graph)
            if undoStack.count > Self.undoLimit { undoStack.removeFirst(undoStack.count - Self.undoLimit) }
            graph = updated
            rejection = nil
            revalidate()
            return true
        } catch {
            rejection = ErrorPresentation.from(error)
            return false
        }
    }

    private func updateKind(_ id: WorkflowNode.ID, title: String?, kind: WorkflowNode.Kind) -> Bool {
        guard let node = graph.node(id) else {
            rejection = WorkflowGraphEditError.nodeNotFound(id).presentation
            return false
        }
        let newTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? node.title
        return apply { graph in try WorkflowGraphEditing.update(id, title: newTitle, kind: kind, in: graph) }
    }

    private func revalidate() {
        let candidate = Workflow(
            id: workflowID ?? Workflow.ID(),
            name: name.nonBlank ?? "Untitled",
            trigger: triggerDefinition(),
            graph: graph,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        issues = services.automation.engine.validate(candidate)
    }

    private func kind(for step: NewStep) -> WorkflowNode.Kind {
        switch step {
        case .action(let actionID): return .action(actionID: actionID, parameters: [:])
        case .condition: return .condition(.always)
        case .delay: return .delay(seconds: 300)
        case .end: return .end
        }
    }

    private func defaultTitle(for step: NewStep) -> String {
        switch step {
        case .action(let actionID): return services.automation.catalog.descriptor(actionID)?.title ?? actionID.rawValue
        case .condition: return "Check"
        case .delay: return "Wait"
        case .end: return "End"
        }
    }
}
