import Foundation
import Testing
import LumenFoundation
import LumenPersistence
import LumenTestSupport

@Suite("Database")
struct DatabaseTests {
    static let schema = DatabaseSchema(namespace: "test", migrations: [
        .sql("0001_items", """
            CREATE TABLE items (
                id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL,
                due TEXT,
                weight REAL,
                done INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL,
                tags TEXT NOT NULL DEFAULT '[]',
                data BLOB
            );
            """),
    ])

    func makeDatabase() async throws -> Database {
        let database = try Database.inMemory(timeSource: ManualTimeSource())
        try await database.migrate([Self.schema])
        return database
    }

    @Test("values round-trip with their Swift types")
    func roundTrip() async throws {
        let database = try await makeDatabase()
        let id = UUID()
        let due = try #require(CalendarDate(year: 2026, month: 12, day: 1))
        let created = Date(timeIntervalSince1970: 1_800_000_000.25)
        try await database.write { db in
            try db.execute(
                "INSERT INTO items (id, title, due, weight, done, created_at, tags, data) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                [id, "Write \"docs\" — ünïcode ✓", due, 0.5, true, created, JSONColumn(["a", "b"]), Data([0, 1, 2])]
            )
        }
        let row = try #require(try await database.read { db in try db.queryFirst("SELECT * FROM items") })
        #expect(try row.get("id", as: UUID.self) == id)
        #expect(try row.get("title", as: String.self) == "Write \"docs\" — ünïcode ✓")
        #expect(try row.get("due", as: CalendarDate.self) == due)
        #expect(try row.get("weight", as: Double.self) == 0.5)
        #expect(try row.get("done", as: Bool.self) == true)
        #expect(try row.get("created_at", as: Date.self) == created)
        #expect(try row.json("tags", as: [String].self) == ["a", "b"])
        #expect(try row.get("data", as: Data.self) == Data([0, 1, 2]))
    }

    @Test("NULL is only accepted when an optional is requested")
    func nullHandling() async throws {
        let database = try await makeDatabase()
        try await database.write { db in
            try db.execute("INSERT INTO items (id, title, created_at) VALUES (?, ?, ?)", [UUID(), "x", Date()])
        }
        let row = try #require(try await database.read { db in try db.queryFirst("SELECT * FROM items") })
        #expect(try row.get("due", as: CalendarDate?.self) == nil)
        #expect(throws: DatabaseError.self) { try row.get("due", as: CalendarDate.self) }
        #expect(throws: DatabaseError.missingColumn("nope")) { try row.value("nope") }
    }

    @Test("a failing write rolls back everything it did")
    func rollback() async throws {
        let database = try await makeDatabase()
        struct Abort: Error {}
        await #expect(throws: Abort.self) {
            try await database.write { db in
                try db.execute("INSERT INTO items (id, title, created_at) VALUES (?, ?, ?)", [UUID(), "x", Date()])
                throw Abort()
            }
        }
        let count: Int? = try await database.read { db in try db.scalar("SELECT count(*) FROM items") }
        #expect(count == 0)
    }

    @Test("nested transactions roll back only the inner savepoint")
    func savepoints() async throws {
        let database = try await makeDatabase()
        struct Inner: Error {}
        try await database.write { db in
            try db.execute("INSERT INTO items (id, title, created_at) VALUES (?, ?, ?)", [UUID(), "outer", Date()])
            do {
                try db.transaction {
                    try db.execute("INSERT INTO items (id, title, created_at) VALUES (?, ?, ?)", [UUID(), "inner", Date()])
                    throw Inner()
                }
            } catch is Inner {}
        }
        let titles: [String] = try await database.read { db in
            try db.query("SELECT title FROM items").map { try $0.get("title") }
        }
        #expect(titles == ["outer"])
    }

    @Test("argument count mismatches are reported, not silently bound")
    func argumentMismatch() async throws {
        let database = try await makeDatabase()
        await #expect(throws: DatabaseError.self) {
            try await database.write { db in
                try db.execute("INSERT INTO items (id, title, created_at) VALUES (?, ?, ?)", [UUID()])
            }
        }
    }

    @Test("constraint violations are recognisable")
    func constraints() async throws {
        let database = try await makeDatabase()
        let id = UUID()
        try await database.write { db in
            try db.execute("INSERT INTO items (id, title, created_at) VALUES (?, ?, ?)", [id, "a", Date()])
        }
        do {
            try await database.write { db in
                try db.execute("INSERT INTO items (id, title, created_at) VALUES (?, ?, ?)", [id, "b", Date()])
            }
            Issue.record("Expected a constraint violation")
        } catch let error as DatabaseError {
            #expect(error.isConstraintViolation)
        }
    }

    @Test("FTS5 is available in this SQLite build")
    func fts5() async throws {
        let database = try await makeDatabase()
        let supported = try await database.read { db in try db.supportsFTS5() }
        #expect(supported)
    }

    @Test("file databases persist the replica identity across opens")
    func fileReplica() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nested/lumen.sqlite")
        let first = try Database(location: .file(url))
        let replica = first.replicaID
        try await first.migrate([Self.schema])
        try await first.write { db in
            try db.execute("INSERT INTO items (id, title, created_at) VALUES (?, ?, ?)", [UUID(), "kept", Date()])
        }
        let second = try Database(location: .file(url))
        #expect(second.replicaID == replica)
        let count: Int? = try await second.read { db in try db.scalar("SELECT count(*) FROM items") }
        #expect(count == 1)
        #expect(try await second.integrityCheck().isEmpty)
    }
}
