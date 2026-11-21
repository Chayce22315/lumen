import Foundation
import Testing
import LumenPersistence
import LumenTestSupport

@Suite("Migrations")
struct MigrationTests {
    @Test("migrations run once, in order, and are recorded")
    func idempotent() async throws {
        let database = try Database.inMemory()
        let schema = DatabaseSchema(namespace: "m", migrations: [
            .sql("0001", "CREATE TABLE a (x INTEGER);"),
            .sql("0002", "ALTER TABLE a ADD COLUMN y TEXT;"),
        ])
        let first = try await database.migrate([schema])
        #expect(first.applied == ["m/0001", "m/0002"])
        let second = try await database.migrate([schema])
        #expect(second.applied.isEmpty)
        #expect(second.alreadyApplied == 2)
    }

    @Test("a failing migration leaves no partial schema behind")
    func failureIsAtomic() async throws {
        let database = try Database.inMemory()
        let schema = DatabaseSchema(namespace: "m", migrations: [
            .sql("0001", "CREATE TABLE ok (x INTEGER); CREATE TABLE broken (;"),
        ])
        await #expect(throws: DatabaseError.self) {
            try await database.migrate([schema])
        }
        let exists = try await database.read { db in try db.tableExists("ok") }
        #expect(exists == false)
    }

    @Test("duplicate identifiers are rejected before anything runs")
    func duplicates() async throws {
        let database = try Database.inMemory()
        let schema = DatabaseSchema(namespace: "m", migrations: [
            .sql("0001", "CREATE TABLE a (x INTEGER);"),
            .sql("0001", "CREATE TABLE b (x INTEGER);"),
        ])
        await #expect(throws: DatabaseError.duplicateMigration("m/0001")) {
            try await database.migrate([schema])
        }
        let exists = try await database.read { db in try db.tableExists("a") }
        #expect(exists == false)
    }
}
