import Foundation
import LumenFoundation
import LumenPersistence
import LumenSync

/// Adapts a repository's row functions to the sync engine for any `Codable` model whose
/// encoded form is its change-log snapshot.
struct CodableSyncHandler<Model: Codable & Sendable>: SyncEntityHandler {
    let kind: EntityKind
    let fetch: @Sendable (UUID, DatabaseConnection) throws -> Model?
    let upsert: @Sendable (Model, DatabaseConnection) throws -> Void
    let delete: @Sendable (UUID, DatabaseConnection) throws -> Void

    func snapshot(id: UUID, in db: DatabaseConnection) throws -> JSONValue? {
        try fetch(id, db).map { try JSONValue(encoding: $0) }
    }

    func apply(_ snapshot: JSONValue, id: UUID, in db: DatabaseConnection) throws {
        try upsert(try snapshot.decode(as: Model.self), db)
    }

    func remove(id: UUID, in db: DatabaseConnection) throws {
        try delete(id, db)
    }
}
