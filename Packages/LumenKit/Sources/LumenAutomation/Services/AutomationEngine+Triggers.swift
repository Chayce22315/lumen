import Foundation
import LumenFoundation
import LumenCore

extension AutomationEngine {
    /// Starts every enabled workflow the event triggers, with loop protection:
    /// - events at `maxCausationDepth` or deeper are ignored;
    /// - an event published by a run of a workflow (same correlation) never triggers that workflow;
    /// - events applied by sync are ignored (when `ignoresSyncedEvents`).
    func handle(_ event: DomainEvent) async {
        statistics.eventsReceived += 1
        if configuration.ignoresSyncedEvents, event.actor == .sync {
            statistics.eventsIgnoredFromSync += 1
            return
        }

        let candidates: [Workflow]
        do {
            candidates = try await database.read { db in
                try WorkflowRepository.fetchEnabled(triggeredBy: event.name, in: db)
            }
        } catch {
            logger.error("Event-triggered workflows could not be loaded", error: error, metadata: ["event": event.name.rawValue])
            return
        }
        guard !candidates.isEmpty else { return }

        var stoppedByDepth = false
        for workflow in candidates {
            switch TriggerMatcher.decide(workflow.trigger, for: event, maxCausationDepth: configuration.maxCausationDepth) {
            case .matches:
                break
            case .causationLimit:
                stoppedByDepth = true
                continue
            case .notAnEventTrigger, .differentEvent, .conditionFailed:
                continue
            }
            if let correlationID = event.correlationID {
                do {
                    let causedByThisWorkflow = try await database.read { db in
                        try RunRepository.hasRun(of: workflow.id, correlationID: correlationID, in: db)
                    }
                    if causedByThisWorkflow {
                        statistics.eventsIgnoredForCorrelation += 1
                        logger.debug("Event ignored: published by a run of the same workflow", metadata: ["workflow": workflow.id.uuidString])
                        continue
                    }
                } catch {
                    logger.error("Run history could not be checked for loop protection", error: error, metadata: ["workflow": workflow.id.uuidString])
                    continue
                }
            }
            launchRun(of: workflow, trigger: TriggerPayload.event(event), causationDepth: event.causationDepth)
        }
        if stoppedByDepth {
            statistics.eventsIgnoredForDepth += 1
            logger.notice("Event ignored: automation causation limit reached", metadata: [
                "event": event.name.rawValue,
                "depth": String(event.causationDepth),
            ])
        }
    }

    /// Executes a run in the background so a slow workflow never delays event delivery.
    func launchRun(of workflow: Workflow, trigger: JSONValue, causationDepth: Int) {
        statistics.runsStartedByEvents += 1
        let token = UUID()
        eventRuns[token] = Task {
            await self.executeEventRun(of: workflow, trigger: trigger, causationDepth: causationDepth, token: token)
        }
    }

    private func executeEventRun(of workflow: Workflow, trigger: JSONValue, causationDepth: Int, token: UUID) async {
        do {
            try await executor.start(workflow, trigger: trigger, causationDepth: causationDepth)
        } catch {
            logger.error("Event-triggered workflow run could not be executed", error: error, metadata: ["workflow": workflow.id.uuidString])
        }
        eventRuns[token] = nil
    }
}
