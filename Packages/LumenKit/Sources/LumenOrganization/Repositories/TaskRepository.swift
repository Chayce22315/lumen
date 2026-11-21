import Foundation
import LumenFoundation
import LumenPersistence

/// SQL for tasks. Stateless; every function runs inside a `Database` closure.
public struct TaskRepository: Sendable {
    public init() {}

    static let columns = """
        id, title, notes, status, priority, due_date, due_time, start_date, project_id, parent_id, tags, recurrence,
        recurrence_anchor, series_id, blocked_by, estimated_minutes, reminder, sort_order, created_at, updated_at, completed_at
        """

    /// Writes the row and records the change for sync.
    public func save(_ task: TaskItem, in db: DatabaseConnection) throws {
        try upsertRow(task, in: db)
        try db.recordUpsert(task.reference, snapshot: task)
    }

    /// Writes the row only. Used by the sync engine when applying remote changes.
    public func upsertRow(_ task: TaskItem, in db: DatabaseConnection) throws {
        try db.execute(
            "INSERT OR REPLACE INTO organization_tasks (\(Self.columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            task.rowArguments
        )
    }

    public func delete(_ id: TaskItem.ID, in db: DatabaseConnection) throws {
        try deleteRow(id, in: db)
        try db.recordDeletion(EntityReference(kind: .task, id: id))
    }

    public func deleteRow(_ id: TaskItem.ID, in db: DatabaseConnection) throws {
        try db.execute("DELETE FROM organization_tasks WHERE id = ?", [id])
    }

    public func task(_ id: TaskItem.ID, in db: DatabaseConnection) throws -> TaskItem? {
        try db.queryFirst("SELECT * FROM organization_tasks WHERE id = ?", [id]).map(TaskItem.init(row:))
    }

    public func tasks(_ ids: [TaskItem.ID], in db: DatabaseConnection) throws -> [TaskItem] {
        try ids.compactMap { try task($0, in: db) }
    }

    public func tasks(matching query: TaskQuery, in db: DatabaseConnection) throws -> [TaskItem] {
        var clauses: [String] = []
        var arguments: [any DatabaseValueConvertible] = []
        if let statuses = query.statuses {
            guard !statuses.isEmpty else { return [] }
            clauses.append("status IN (\(Array(repeating: "?", count: statuses.count).joined(separator: ", ")))")
            let sortedStatuses: [String] = statuses.map(\.rawValue).sorted()
            arguments.append(contentsOf: sortedStatuses as [any DatabaseValueConvertible])
        }
        if let projectID = query.projectID {
            if let projectID {
                clauses.append("project_id = ?")
                arguments.append(projectID)
            } else {
                clauses.append("project_id IS NULL")
            }
        }
        if let parentID = query.parentID {
            if let parentID {
                clauses.append("parent_id = ?")
                arguments.append(parentID)
            } else {
                clauses.append("parent_id IS NULL")
            }
        }
        if let before = query.dueOnOrBefore {
            clauses.append("due_date IS NOT NULL AND due_date <= ?")
            arguments.append(before)
        }
        if let after = query.dueOnOrAfter {
            clauses.append("due_date IS NOT NULL AND due_date >= ?")
            arguments.append(after)
        }
        if let minimum = query.minimumPriority {
            clauses.append("priority >= ?")
            arguments.append(minimum.rawValue)
        }
        if let tag = query.tag {
            clauses.append("EXISTS (SELECT 1 FROM json_each(organization_tasks.tags) WHERE json_each.value = ?)")
            arguments.append(tag)
        }
        var sql = "SELECT * FROM organization_tasks"
        if !clauses.isEmpty {
            sql += " WHERE " + clauses.joined(separator: " AND ")
        }
        sql += " ORDER BY created_at, id"
        if let limit = query.limit {
            sql += " LIMIT ?"
            arguments.append(max(1, limit))
        }
        return try db.query(sql, arguments).map(TaskItem.init(row:))
    }

    public func all(in db: DatabaseConnection) throws -> [TaskItem] {
        try db.query("SELECT * FROM organization_tasks ORDER BY created_at, id").map(TaskItem.init(row:))
    }

    public func updated(since date: Date, in db: DatabaseConnection) throws -> [TaskItem] {
        try db.query("SELECT * FROM organization_tasks WHERE updated_at > ? ORDER BY updated_at", [date]).map(TaskItem.init(row:))
    }

    /// Open tasks that list `id` as a blocker.
    public func dependents(of id: TaskItem.ID, in db: DatabaseConnection) throws -> [TaskItem] {
        try db.query(
            "SELECT * FROM organization_tasks WHERE EXISTS (SELECT 1 FROM json_each(organization_tasks.blocked_by) WHERE json_each.value = ?)",
            [id.uuidString]
        ).map(TaskItem.init(row:))
    }

    public func completed(between start: Date, and end: Date, in db: DatabaseConnection) throws -> [TaskItem] {
        try db.query(
            "SELECT * FROM organization_tasks WHERE status = 'done' AND completed_at >= ? AND completed_at < ? ORDER BY completed_at DESC",
            [start, end]
        ).map(TaskItem.init(row:))
    }
}
