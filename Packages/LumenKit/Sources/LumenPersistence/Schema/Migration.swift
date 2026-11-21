import Foundation

/// One forward-only schema step. Identifiers are persisted: never rename or reorder a shipped migration.
public struct Migration: Sendable {
    public let identifier: String
    let apply: @Sendable (DatabaseConnection) throws -> Void

    public init(_ identifier: String, apply: @escaping @Sendable (DatabaseConnection) throws -> Void) {
        self.identifier = identifier
        self.apply = apply
    }

    /// A migration made of plain SQL statements.
    public static func sql(_ identifier: String, _ script: String) -> Migration {
        Migration(identifier) { connection in
            try connection.executeScript(script)
        }
    }
}

/// The ordered migrations owned by one module. Each module owns its tables and nothing else.
public struct DatabaseSchema: Sendable {
    public let namespace: String
    public let migrations: [Migration]

    public init(namespace: String, migrations: [Migration]) {
        self.namespace = namespace
        self.migrations = migrations
    }
}

public struct MigrationReport: Sendable, Equatable {
    /// Fully qualified identifiers (`namespace/identifier`) applied by this run, in order.
    public let applied: [String]
    public let alreadyApplied: Int
}

enum Migrator {
    static func migrate(_ connection: DatabaseConnection, schemas: [DatabaseSchema], now: Date) throws -> MigrationReport {
        try connection.executeScript("""
            CREATE TABLE IF NOT EXISTS lumen_migrations (
                identifier TEXT PRIMARY KEY NOT NULL,
                applied_at REAL NOT NULL
            );
            """)

        var seen = Set<String>()
        for schema in schemas {
            for migration in schema.migrations {
                let qualified = "\(schema.namespace)/\(migration.identifier)"
                guard seen.insert(qualified).inserted else { throw DatabaseError.duplicateMigration(qualified) }
            }
        }

        let appliedRows = try connection.query("SELECT identifier FROM lumen_migrations")
        let alreadyApplied = Set(try appliedRows.map { try $0.get("identifier", as: String.self) })

        var applied: [String] = []
        var skipped = 0
        for schema in schemas {
            for migration in schema.migrations {
                let qualified = "\(schema.namespace)/\(migration.identifier)"
                if alreadyApplied.contains(qualified) {
                    skipped += 1
                    continue
                }
                do {
                    try connection.transaction {
                        try migration.apply(connection)
                        try connection.execute(
                            "INSERT INTO lumen_migrations (identifier, applied_at) VALUES (?, ?)",
                            [qualified, now]
                        )
                    }
                } catch {
                    throw DatabaseError.migrationFailed(identifier: qualified, message: String(describing: error))
                }
                applied.append(qualified)
            }
        }
        return MigrationReport(applied: applied, alreadyApplied: skipped)
    }
}
