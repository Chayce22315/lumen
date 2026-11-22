import Foundation
import LumenFoundation
import LumenPersistence

/// The executor's persistence: each write keeps a step and its run's position consistent in one
/// transaction, so after a crash `currentNodeID` is always the first node not yet completed.
struct RunJournal: Sendable {
    let database: Database

    func insert(_ run: WorkflowRun) async throws {
        try await database.write { db in
            try RunRepository.insert(run, in: db)
        }
    }

    /// Saves a step (new or updated) together with the run's status and position.
    func record(_ step: RunStep, run: WorkflowRun) async throws {
        try await database.write { db in
            try RunRepository.upsertStep(step, in: db)
            try RunRepository.update(run, in: db)
        }
    }

    func update(_ run: WorkflowRun) async throws {
        try await database.write { db in
            try RunRepository.update(run, in: db)
        }
    }

    /// Saves the final state of a run, closing steps left running or waiting.
    func finish(_ run: WorkflowRun, openStepsAs status: RunStep.Status, at date: Date) async throws {
        try await database.write { db in
            try RunRepository.closeOpenSteps(of: run.id, as: status, at: date, in: db)
            try RunRepository.update(run, in: db)
        }
    }

    func run(_ id: WorkflowRun.ID) async throws -> WorkflowRun? {
        try await database.read { db in try RunRepository.fetch(id, in: db) }
    }

    func runExists(_ id: WorkflowRun.ID) async throws -> Bool {
        try await database.read { db in try RunRepository.exists(id, in: db) }
    }

    func steps(of id: WorkflowRun.ID) async throws -> [RunStep] {
        try await database.read { db in try RunRepository.steps(of: id, in: db) }
    }
}
