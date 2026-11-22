import Foundation
import LumenFoundation
import LumenPersistence
import LumenCore

/// The automation engine: workflow definitions, triggers, execution, scheduling and history.
///
/// Lifecycle: call `recoverInterruptedRuns()` once at launch, `start()` to react to domain events,
/// and `tick()` whenever the app is active or woken in the background (`TickReport.nextWakeDate`
/// says when the next tick is useful). `stop()` unsubscribes from events.
public actor AutomationEngine {
    public static let schema = AutomationSchema.schema

    public struct Configuration: Sendable, Hashable {
        /// Events at or beyond this automation depth never start workflows (loop protection).
        public var maxCausationDepth: Int
        /// Events applied by sync already ran their automations on the device where they happened.
        public var ignoresSyncedEvents: Bool
        public var execution: WorkflowExecutor.Configuration

        public init(maxCausationDepth: Int = 3, ignoresSyncedEvents: Bool = true, execution: WorkflowExecutor.Configuration = WorkflowExecutor.Configuration()) {
            self.maxCausationDepth = max(1, maxCausationDepth)
            self.ignoresSyncedEvents = ignoresSyncedEvents
            self.execution = execution
        }
    }

    /// Counters for the diagnostics screen.
    public struct Statistics: Sendable, Hashable {
        public var eventsReceived = 0
        public var eventsIgnoredForDepth = 0
        public var eventsIgnoredForCorrelation = 0
        public var eventsIgnoredFromSync = 0
        public var runsStartedByEvents = 0

        public init() {}
    }

    /// A workflow that could not be fired or resumed during `tick` or recovery.
    public struct Failure: Sendable, Hashable {
        public var workflowID: Workflow.ID
        public var runID: WorkflowRun.ID?
        public var message: String
    }

    public nonisolated let catalog: AutomationCatalog
    public nonisolated let configuration: Configuration
    public nonisolated let executor: WorkflowExecutor
    let database: Database
    let events: EventBus
    let timeSource: any TimeSource
    let calendar: Calendar
    let logger: Logger

    var listener: Task<Void, Never>?
    var eventRuns: [UUID: Task<Void, Never>] = [:]
    var inFlightSchedules: Set<Workflow.ID> = []
    var inFlightResumes: Set<WorkflowRun.ID> = []
    public internal(set) var statistics = Statistics()

    public init(
        database: Database,
        events: EventBus,
        catalog: AutomationCatalog,
        timeSource: any TimeSource,
        calendar: Calendar,
        logger: Logger,
        sleeper: @escaping AutomationSleeper = AutomationSleepers.system,
        configuration: Configuration = Configuration(),
        randomUnit: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
    ) {
        self.database = database
        self.events = events
        self.catalog = catalog
        self.timeSource = timeSource
        self.calendar = calendar
        self.logger = logger
        self.configuration = configuration
        self.executor = WorkflowExecutor(
            database: database,
            catalog: catalog,
            events: events,
            timeSource: timeSource,
            logger: logger,
            sleeper: sleeper,
            configuration: configuration.execution,
            randomUnit: randomUnit
        )
    }

    // MARK: - Lifecycle

    public var isStarted: Bool {
        listener != nil
    }

    /// Subscribes to the event bus; enabled event-triggered workflows start reacting.
    public func start() {
        guard listener == nil else { return }
        let stream = events.events(matching: .all)
        listener = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
        logger.info("Automation engine started")
    }

    /// Unsubscribes from the event bus. Runs already executing continue.
    public func stop() {
        listener?.cancel()
        listener = nil
        logger.info("Automation engine stopped")
    }

    /// Waits until every run started by an event so far has finished or parked.
    public func waitUntilIdle() async {
        while let entry = eventRuns.first {
            await entry.value.value
            eventRuns[entry.key] = nil
        }
    }

    // MARK: - Definitions

    /// Validation against the actions and trigger sources registered right now.
    public nonisolated func validate(_ workflow: Workflow) -> [ValidationIssue] {
        WorkflowValidator.validate(workflow, actions: catalog.descriptorsByID, knownEvents: catalog.knownEventNames)
    }

    @discardableResult
    public func create(_ draft: WorkflowDraft, context: ActionContext = .user) async throws -> Workflow {
        let now = timeSource.now()
        let workflow = Workflow(
            name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: draft.summary,
            isEnabled: draft.isEnabled,
            trigger: draft.trigger,
            graph: draft.graph,
            failurePolicy: draft.failurePolicy,
            createdAt: now,
            updatedAt: now
        )
        try requireValid(workflow)
        let calendar = self.calendar
        try await database.write { db in
            try WorkflowRepository.save(workflow, in: db)
            try Self.reconcileSchedule(for: workflow, now: now, calendar: calendar, in: db)
        }
        publish(AutomationEvents.workflowCreated, for: workflow, context: context, at: now)
        logger.info("Workflow created", metadata: ["workflow": workflow.id.uuidString])
        return workflow
    }

    /// Saves an edited workflow. `createdAt` is preserved and `updatedAt` set to now. An unchanged
    /// schedule keeps its pending fire date; a changed one is recomputed from now.
    @discardableResult
    public func update(_ workflow: Workflow, context: ActionContext = .user) async throws -> Workflow {
        let now = timeSource.now()
        var edited = workflow
        edited.name = workflow.name.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.updatedAt = now
        try requireValid(edited)
        let candidate = edited
        let calendar = self.calendar
        let (previous, stored) = try await database.write { db -> (Workflow, Workflow) in
            guard let existing = try WorkflowRepository.fetch(candidate.id, in: db) else {
                throw AutomationError.workflowNotFound(candidate.id)
            }
            var stored = candidate
            stored.createdAt = existing.createdAt
            try WorkflowRepository.save(stored, in: db)
            try Self.reconcileSchedule(for: stored, now: now, calendar: calendar, in: db)
            return (existing, stored)
        }
        publish(AutomationEvents.workflowUpdated, for: stored, context: context, at: now)
        if previous.isEnabled != stored.isEnabled {
            publish(stored.isEnabled ? AutomationEvents.workflowEnabled : AutomationEvents.workflowDisabled, for: stored, context: context, at: now)
        }
        logger.info("Workflow updated", metadata: ["workflow": stored.id.uuidString])
        return stored
    }

    /// Deletes a workflow with its history. Executing runs are cancelled first.
    public func delete(_ id: Workflow.ID, context: ActionContext = .user) async throws {
        await executor.cancelRuns(of: id)
        let deleted = try await database.write { db in
            try WorkflowRepository.delete(id, in: db)
        }
        guard deleted else { throw AutomationError.workflowNotFound(id) }
        let now = timeSource.now()
        events.publish(context.event(
            AutomationEvents.workflowDeleted,
            entity: EntityReference(kind: .workflow, id: id),
            attributes: ["workflowID": .string(id.uuidString)],
            at: now
        ))
        logger.info("Workflow deleted", metadata: ["workflow": id.uuidString])
    }

    /// Enables or disables triggers. Enabling validates the workflow (it may have arrived through
    /// sync with actions this device lacks) and schedules from now, so occurrences missed while
    /// disabled are not caught up.
    @discardableResult
    public func setEnabled(_ id: Workflow.ID, _ isEnabled: Bool, context: ActionContext = .user) async throws -> Workflow {
        guard var workflow = try await self.workflow(id) else { throw AutomationError.workflowNotFound(id) }
        guard workflow.isEnabled != isEnabled else { return workflow }
        let now = timeSource.now()
        workflow.isEnabled = isEnabled
        workflow.updatedAt = now
        if isEnabled {
            try requireValid(workflow)
        }
        let stored = workflow
        let calendar = self.calendar
        try await database.write { db in
            try WorkflowRepository.save(stored, in: db)
            try Self.reconcileSchedule(for: stored, now: now, calendar: calendar, in: db)
        }
        publish(isEnabled ? AutomationEvents.workflowEnabled : AutomationEvents.workflowDisabled, for: stored, context: context, at: now)
        return stored
    }

    /// Copies a workflow under a new identity. The copy starts disabled so it never doubles the
    /// original's triggers; node identifiers are kept so references between steps stay valid.
    @discardableResult
    public func duplicate(_ id: Workflow.ID, context: ActionContext = .user) async throws -> Workflow {
        guard let original = try await self.workflow(id) else { throw AutomationError.workflowNotFound(id) }
        let now = timeSource.now()
        let copy = Workflow(
            name: "\(original.name) copy",
            summary: original.summary,
            isEnabled: false,
            trigger: original.trigger,
            graph: original.graph,
            failurePolicy: original.failurePolicy,
            createdAt: now,
            updatedAt: now
        )
        try await database.write { db in
            try WorkflowRepository.save(copy, in: db)
        }
        publish(AutomationEvents.workflowCreated, for: copy, context: context, at: now)
        return copy
    }

    public func workflow(_ id: Workflow.ID) async throws -> Workflow? {
        try await database.read { db in try WorkflowRepository.fetch(id, in: db) }
    }

    /// Every workflow, by name.
    public func workflows() async throws -> [Workflow] {
        try await database.read { db in try WorkflowRepository.fetchAll(in: db) }
    }

    /// When a schedule-triggered workflow fires next (`nil` when not scheduled or ended).
    public func nextFireDate(for id: Workflow.ID) async throws -> Date? {
        try await database.read { db in try ScheduleStateRepository.fetch(id, in: db)?.nextFireAt }
    }

    // MARK: - Running

    /// Runs a workflow now, whatever its trigger and even when disabled. Waits until the run
    /// finishes or parks on a long delay.
    @discardableResult
    public func run(_ workflowID: Workflow.ID, input: JSONValue = .null, context: ActionContext = .user) async throws -> WorkflowRun {
        guard context.causationDepth < configuration.maxCausationDepth else {
            throw AutomationError.causationLimitReached(depth: context.causationDepth)
        }
        guard let workflow = try await self.workflow(workflowID) else { throw AutomationError.workflowNotFound(workflowID) }
        try requireValid(workflow)
        let trigger = TriggerPayload.manual(at: timeSource.now(), actor: context.actor)
        return try await executor.start(workflow, trigger: trigger, input: input, causationDepth: context.causationDepth)
    }

    /// Runs a workflow again with the trigger payload and input of an earlier run, using the
    /// workflow's current definition. The payload gains `rerunOf` (the earlier run's identifier) so
    /// steps can tell a replay apart. Like `run`, it works on disabled workflows and waits until the
    /// new run finishes or parks on a long delay.
    @discardableResult
    public func rerun(_ runID: WorkflowRun.ID, context: ActionContext = .user) async throws -> WorkflowRun {
        guard context.causationDepth < configuration.maxCausationDepth else {
            throw AutomationError.causationLimitReached(depth: context.causationDepth)
        }
        let stored = try await database.read { db in try RunRepository.fetch(runID, in: db) }
        guard let original = stored else { throw AutomationError.runNotFound(runID) }
        guard let workflow = try await self.workflow(original.workflowID) else {
            throw AutomationError.workflowNotFound(original.workflowID)
        }
        try requireValid(workflow)
        var trigger = original.triggerPayload
        if case .object(var payload) = trigger {
            payload["rerunOf"] = .string(runID.uuidString)
            trigger = .object(payload)
        }
        return try await executor.start(workflow, trigger: trigger, input: original.input, causationDepth: context.causationDepth)
    }

    @discardableResult
    public func cancel(_ runID: WorkflowRun.ID) async throws -> Bool {
        try await executor.cancel(runID)
    }

    // MARK: - History

    /// Runs of one workflow, newest first.
    public func runs(workflowID: Workflow.ID, limit: Int = 50) async throws -> [WorkflowRun] {
        try await database.read { db in try RunRepository.runs(of: workflowID, limit: limit, in: db) }
    }

    /// Runs of every workflow, newest first.
    public func recentRuns(limit: Int = 50) async throws -> [WorkflowRun] {
        try await database.read { db in try RunRepository.recentRuns(limit: limit, in: db) }
    }

    /// A run with its steps in execution order.
    public func runDetail(_ id: WorkflowRun.ID) async throws -> RunDetail? {
        try await database.read { db in
            guard let run = try RunRepository.fetch(id, in: db) else { return nil }
            return RunDetail(run: run, steps: try RunRepository.steps(of: id, in: db))
        }
    }

    /// Deletes finished runs that ended more than `age` seconds ago. Returns how many.
    @discardableResult
    public func purgeHistory(olderThan age: TimeInterval) async throws -> Int {
        let cutoff = timeSource.now().addingTimeInterval(-abs(age))
        let purged = try await database.write { db in
            try RunRepository.purge(finishedBefore: cutoff, in: db)
        }
        if purged > 0 {
            logger.info("Purged workflow run history", metadata: ["runs": String(purged)])
        }
        return purged
    }

    // MARK: - Helpers

    func requireValid(_ workflow: Workflow) throws {
        let issues = validate(workflow)
        if issues.hasErrors {
            throw AutomationError.invalidWorkflow(issues)
        }
    }

    func publish(_ name: EventName, for workflow: Workflow, context: ActionContext, at date: Date) {
        events.publish(context.event(
            name,
            entity: workflow.reference,
            attributes: [
                "workflowID": .string(workflow.id.uuidString),
                "triggerType": .string(workflow.trigger.kind.rawValue),
                "isEnabled": .bool(workflow.isEnabled),
            ],
            at: date
        ))
    }

    /// Keeps the schedule state in step with the workflow: removed unless enabled and
    /// schedule-triggered; recomputed from `now` when missing or when the schedule changed.
    static func reconcileSchedule(for workflow: Workflow, now: Date, calendar: Calendar, in db: DatabaseConnection) throws {
        guard workflow.isEnabled, let schedule = workflow.trigger.schedule else {
            try ScheduleStateRepository.delete(workflow.id, in: db)
            return
        }
        let existing = try ScheduleStateRepository.fetch(workflow.id, in: db)
        if let existing, existing.schedule == schedule { return }
        try ScheduleStateRepository.upsert(ScheduleState(
            workflowID: workflow.id,
            schedule: schedule,
            nextFireAt: ScheduleCalculator.nextFireDate(for: schedule, after: now, calendar: calendar),
            lastFiredAt: existing?.lastFiredAt,
            updatedAt: now
        ), in: db)
    }
}
