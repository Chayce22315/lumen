import Foundation
import LumenFoundation
import LumenPersistence
import LumenCore

extension AutomationEngine {
    /// What one `tick` did.
    public struct TickReport: Sendable, Hashable {
        /// Runs started by due schedules, in their final (or waiting) state.
        public var firedRuns: [WorkflowRun] = []
        /// Waiting runs whose delay elapsed, in their final (or waiting) state.
        public var resumedRuns: [WorkflowRun] = []
        /// Occurrences each fired workflow's single run stood for (1 when on time).
        public var coalescedOccurrences: [Workflow.ID: Int] = [:]
        public var failures: [Failure] = []
        /// The earliest pending schedule or delay; when the next tick has work.
        public var nextWakeDate: Date?

        public init() {}
    }

    /// What `recoverInterruptedRuns` did.
    public struct RecoveryReport: Sendable, Hashable {
        /// Runs found executing at launch, marked interrupted.
        public var interruptedRuns: [WorkflowRun] = []
        /// The interrupted runs whose workflows allow resuming, in their state after resuming.
        public var resumedRuns: [WorkflowRun] = []
        public var failures: [Failure] = []

        public init() {}
    }

    @discardableResult
    public func tick() async throws -> TickReport {
        try await tick(now: timeSource.now())
    }

    /// Fires due schedule triggers (once, however many occurrences were missed) and resumes
    /// waiting runs whose `resumeAt` is at or before `now`.
    @discardableResult
    public func tick(now: Date) async throws -> TickReport {
        var report = TickReport()
        let (workflows, states) = try await database.read { db in
            (try WorkflowRepository.fetchEnabledScheduled(in: db), try ScheduleStateRepository.fetchAll(in: db))
        }

        for workflow in workflows where !inFlightSchedules.contains(workflow.id) {
            guard let schedule = workflow.trigger.schedule else { continue }
            guard let state = states[workflow.id], state.schedule == schedule else {
                // New, re-enabled or edited (possibly through sync): schedule from now without firing.
                let previous = states[workflow.id]
                try await saveScheduleState(ScheduleState(
                    workflowID: workflow.id,
                    schedule: schedule,
                    nextFireAt: ScheduleCalculator.nextFireDate(for: schedule, after: now, calendar: calendar),
                    lastFiredAt: previous?.lastFiredAt,
                    updatedAt: now
                ))
                continue
            }
            let decision = ScheduleCalculator.decision(for: schedule, scheduledFireDate: state.nextFireAt, now: now, calendar: calendar)
            guard decision.isDue, let scheduledFor = state.nextFireAt else { continue }

            inFlightSchedules.insert(workflow.id)
            defer { inFlightSchedules.remove(workflow.id) }
            // Claim the occurrence before running: a crash mid-run must not replay it.
            try await saveScheduleState(ScheduleState(
                workflowID: workflow.id,
                schedule: schedule,
                nextFireAt: decision.nextFireDate,
                lastFiredAt: now,
                updatedAt: now
            ))
            let trigger = TriggerPayload.schedule(scheduledFor: scheduledFor, firedAt: now, coalescedOccurrences: decision.coalescedOccurrences)
            do {
                report.firedRuns.append(try await executor.start(workflow, trigger: trigger))
                report.coalescedOccurrences[workflow.id] = decision.coalescedOccurrences
            } catch {
                logger.error("Scheduled workflow run could not be executed", error: error, metadata: ["workflow": workflow.id.uuidString])
                report.failures.append(Failure(workflowID: workflow.id, runID: nil, message: String(describing: error)))
            }
        }

        let due = try await database.read { db in try RunRepository.waitingRuns(dueBy: now, in: db) }
        for run in due where !inFlightResumes.contains(run.id) {
            inFlightResumes.insert(run.id)
            defer { inFlightResumes.remove(run.id) }
            do {
                guard let workflow = try await self.workflow(run.workflowID) else { continue }
                report.resumedRuns.append(try await executor.resume(run, workflow: workflow))
            } catch {
                logger.error("Waiting workflow run could not be resumed", error: error, metadata: ["workflow": run.workflowID.uuidString, "run": run.id.uuidString])
                report.failures.append(Failure(workflowID: run.workflowID, runID: run.id, message: String(describing: error)))
            }
        }

        report.nextWakeDate = try await nextWakeDate()
        return report
    }

    /// The earliest pending schedule occurrence or delay end.
    public func nextWakeDate() async throws -> Date? {
        let (fire, resume) = try await database.read { db in
            (try ScheduleStateRepository.earliestFireDate(in: db), try RunRepository.earliestResumeDate(in: db))
        }
        return [fire, resume].compactMap { $0 }.min()
    }

    /// Call once at launch, before `tick`. Runs left `.running` by a previous process become
    /// `.interrupted`; those whose workflow allows it are re-executed from the step that was in
    /// progress, the others are reported through `automation.run.failed`.
    @discardableResult
    public func recoverInterruptedRuns() async throws -> RecoveryReport {
        let executing = await executor.activeRunIDs
        let now = timeSource.now()
        let interrupted: [WorkflowRun] = try await database.write { db in
            var marked: [WorkflowRun] = []
            for var run in try RunRepository.runs(withStatus: .running, in: db) where !executing.contains(run.id) {
                run.status = .interrupted
                run.finishedAt = now
                run.errorMessage = "Lumen stopped while this run was in progress."
                try RunRepository.closeOpenSteps(of: run.id, as: .interrupted, at: now, in: db)
                try RunRepository.update(run, in: db)
                marked.append(run)
            }
            return marked
        }

        var report = RecoveryReport()
        report.interruptedRuns = interrupted
        for run in interrupted {
            do {
                guard let workflow = try await self.workflow(run.workflowID) else { continue }
                if workflow.failurePolicy.resumeInterruptedRuns {
                    report.resumedRuns.append(try await executor.resume(run, workflow: workflow))
                } else {
                    let steps = try await database.read { db in try RunRepository.steps(of: run.id, in: db) }
                    events.publish(RunEvents.event(
                        AutomationEvents.runFailed,
                        for: run,
                        stepCount: steps.count,
                        failedSteps: steps.filter { $0.status == .failed }.count,
                        at: now
                    ))
                }
            } catch {
                logger.error("Interrupted workflow run could not be recovered", error: error, metadata: ["workflow": run.workflowID.uuidString, "run": run.id.uuidString])
                report.failures.append(Failure(workflowID: run.workflowID, runID: run.id, message: String(describing: error)))
            }
        }
        if !interrupted.isEmpty {
            logger.notice("Recovered interrupted workflow runs", metadata: [
                "interrupted": String(interrupted.count),
                "resumed": String(report.resumedRuns.count),
            ])
        }
        return report
    }

    private func saveScheduleState(_ state: ScheduleState) async throws {
        try await database.write { db in
            try ScheduleStateRepository.upsert(state, in: db)
        }
    }
}
