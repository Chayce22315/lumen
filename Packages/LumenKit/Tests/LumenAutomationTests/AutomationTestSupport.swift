import Foundation
import Synchronization
import Testing
import LumenFoundation
import LumenPersistence
import LumenCore
import LumenAutomation
import LumenTestSupport

// MARK: - Test actions

/// Records every invocation and returns its parameters as output.
final class RecordingAction: AutomationAction {
    let descriptor: AutomationActionDescriptor
    private let invocations = Mutex<[ActionInvocation]>([])

    init(_ id: AutomationActionID = "test.record", parameters: [ActionParameterSpec] = [], title: String = "Record", category: String = "Test") {
        self.descriptor = AutomationActionDescriptor(
            id: id, title: title, summary: "Records invocations.", symbolName: "list.bullet",
            category: category, parameters: parameters, isMutating: false
        )
    }

    func perform(_ invocation: ActionInvocation) async throws -> ActionOutcome {
        invocations.withLock { $0.append(invocation) }
        return ActionOutcome(output: .object(invocation.parameters), message: "Recorded")
    }

    var recorded: [ActionInvocation] { invocations.withLock { $0 } }
    var count: Int { invocations.withLock { $0.count } }
}

/// Throws `error` for the first `failures` attempts, then succeeds.
final class FlakyAction: AutomationAction {
    let descriptor: AutomationActionDescriptor
    let failures: Int
    let error: any Error
    private let attempts = Mutex(0)

    init(_ id: AutomationActionID = "test.flaky", failures: Int, error: any Error) {
        self.descriptor = AutomationActionDescriptor(
            id: id, title: "Flaky", summary: "Fails, then succeeds.", symbolName: "bolt",
            category: "Test", isMutating: true
        )
        self.failures = failures
        self.error = error
    }

    func perform(_ invocation: ActionInvocation) async throws -> ActionOutcome {
        let attempt = attempts.withLock { value -> Int in
            value += 1
            return value
        }
        if attempt <= failures { throw error }
        return ActionOutcome(output: ["attempt": .number(Double(attempt))])
    }

    var attemptCount: Int { attempts.withLock { $0 } }
}

/// Blocks until its task is cancelled.
final class BlockingAction: AutomationAction {
    let descriptor = AutomationActionDescriptor(
        id: "test.block", title: "Block", summary: "Waits until cancelled.", symbolName: "hourglass",
        category: "Test", isMutating: false
    )
    private let started = Mutex(false)

    func perform(_ invocation: ActionInvocation) async throws -> ActionOutcome {
        started.withLock { $0 = true }
        // Ends with CancellationError as soon as the run is cancelled; the hour is never reached.
        try await Task.sleep(nanoseconds: 3_600 * 1_000_000_000)
        return ActionOutcome()
    }

    var hasStarted: Bool { started.withLock { $0 } }
}

/// Publishes a domain event with the invocation's context, like a real service would.
final class PublishingAction: AutomationAction {
    let descriptor: AutomationActionDescriptor
    let bus: EventBus
    let eventName: EventName
    let clock: ManualTimeSource

    init(_ id: AutomationActionID, publishing eventName: EventName, on bus: EventBus, clock: ManualTimeSource) {
        self.descriptor = AutomationActionDescriptor(
            id: id, title: "Publish \(eventName.rawValue)", summary: "Publishes an event.", symbolName: "megaphone",
            category: "Test", isMutating: true
        )
        self.bus = bus
        self.eventName = eventName
        self.clock = clock
    }

    func perform(_ invocation: ActionInvocation) async throws -> ActionOutcome {
        bus.publish(invocation.context.event(eventName, attributes: ["workflowID": .string(invocation.workflowID.uuidString)], at: clock.now()))
        return ActionOutcome()
    }
}

struct Glitch: Error {}

// MARK: - Sleeper

/// Records requested sleeps and returns immediately.
final class RecordingSleeper: Sendable {
    private let sleeps = Mutex<[TimeInterval]>([])

    var recorded: [TimeInterval] { sleeps.withLock { $0 } }

    var sleeper: AutomationSleeper {
        { [self] seconds in self.sleeps.withLock { $0.append(seconds) } }
    }
}

// MARK: - Harness

struct AutomationHarness {
    let environment: CoreTestEnvironment
    let catalog: AutomationCatalog
    let engine: AutomationEngine
    let sleeper: RecordingSleeper

    var clock: ManualTimeSource { environment.clock }
    var database: Database { environment.database }
    var events: EventBus { environment.events }

    static func make(
        actions: [any AutomationAction] = [],
        configuration: AutomationEngine.Configuration = AutomationEngine.Configuration(),
        sleeper customSleeper: AutomationSleeper? = nil
    ) async throws -> AutomationHarness {
        let environment = try await CoreTestEnvironment.make(schemas: [AutomationEngine.schema])
        let catalog = AutomationCatalog()
        for action in actions {
            try catalog.register(action)
        }
        let sleeper = RecordingSleeper()
        let engine = AutomationEngine(
            database: environment.database,
            events: environment.events,
            catalog: catalog,
            timeSource: environment.clock,
            calendar: environment.calendar,
            logger: environment.logger("automation"),
            sleeper: customSleeper ?? sleeper.sleeper,
            configuration: configuration,
            randomUnit: { 0 }
        )
        return AutomationHarness(environment: environment, catalog: catalog, engine: engine, sleeper: sleeper)
    }

    /// Creates an enabled workflow from a graph.
    @discardableResult
    func create(
        _ graph: WorkflowGraph,
        name: String = "Workflow",
        trigger: TriggerDefinition = .manual,
        isEnabled: Bool = true,
        policy: FailurePolicy = FailurePolicy(retry: .never)
    ) async throws -> Workflow {
        try await engine.create(WorkflowDraft(name: name, isEnabled: isEnabled, trigger: trigger, graph: graph, failurePolicy: policy))
    }

    func steps(of run: WorkflowRun) async throws -> [RunStep] {
        try #require(try await engine.runDetail(run.id)).steps
    }

    func changes() async throws -> [ChangeRecord] {
        try await database.read { db in try db.changes(after: 0) }
    }
}

// MARK: - Graphs

/// Builds graphs rooted at a trigger node.
struct GraphBuilder {
    private(set) var graph: WorkflowGraph
    let trigger: WorkflowNode.ID

    init() {
        let trigger = WorkflowNode.ID()
        self.trigger = trigger
        self.graph = WorkflowGraph(nodes: [WorkflowNode(id: trigger, title: "Trigger", kind: .trigger)])
    }

    @discardableResult
    mutating func add(_ kind: WorkflowNode.Kind, title: String = "Step", after source: WorkflowNode.ID, port: EdgePort = .next) -> WorkflowNode.ID {
        let node = WorkflowNode(title: title, kind: kind)
        graph.nodes.append(node)
        graph.edges.append(WorkflowEdge(from: source, to: node.id, port: port))
        return node.id
    }

    /// Appends a chain after the trigger and returns the node ids in order.
    @discardableResult
    mutating func chain(_ kinds: [WorkflowNode.Kind]) -> [WorkflowNode.ID] {
        var previous = trigger
        var ids: [WorkflowNode.ID] = []
        for (index, kind) in kinds.enumerated() {
            previous = add(kind, title: "Step \(index + 1)", after: previous)
            ids.append(previous)
        }
        return ids
    }
}

func action(_ id: AutomationActionID, _ parameters: [String: ParameterValue] = [:]) -> WorkflowNode.Kind {
    .action(actionID: id, parameters: parameters)
}

/// `{{ steps.<id>.output<suffix> }}` path text.
func stepPath(_ id: WorkflowNode.ID, _ suffix: String = "") -> String {
    "steps.\(id.uuidString).output\(suffix)"
}

// MARK: - Time

func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) throws -> Date {
    try #require(Calendar.testUTC.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)))
}

func day(_ year: Int, _ month: Int, _ day: Int) throws -> CalendarDate {
    try #require(CalendarDate(year: year, month: month, day: day))
}

func time(_ hour: Int, _ minute: Int) throws -> TimeOfDay {
    try #require(TimeOfDay(hour: hour, minute: minute))
}

/// Polls `condition` until it holds or `timeout` seconds pass (for work on background tasks).
func eventually(timeout: TimeInterval = 5, _ condition: @Sendable () async throws -> Bool) async rethrows -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return try await condition()
}
