import Foundation
import LumenFoundation
import LumenPersistence

public struct ProjectRepository: Sendable {
    public init() {}

    public func save(_ project: Project, in db: DatabaseConnection) throws {
        try upsertRow(project, in: db)
        try db.recordUpsert(project.reference, snapshot: project)
    }

    public func upsertRow(_ project: Project, in db: DatabaseConnection) throws {
        try db.execute(
            """
            INSERT OR REPLACE INTO organization_projects
                (id, name, summary, status, color, start_date, target_date, sort_order, created_at, updated_at, completed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            project.rowArguments
        )
    }

    public func delete(_ id: Project.ID, in db: DatabaseConnection) throws {
        try deleteRow(id, in: db)
        try db.recordDeletion(EntityReference(kind: .project, id: id))
    }

    public func deleteRow(_ id: Project.ID, in db: DatabaseConnection) throws {
        try db.execute("DELETE FROM organization_projects WHERE id = ?", [id])
    }

    public func project(_ id: Project.ID, in db: DatabaseConnection) throws -> Project? {
        try db.queryFirst("SELECT * FROM organization_projects WHERE id = ?", [id]).map(Project.init(row:))
    }

    public func projects(statuses: Set<ProjectStatus>? = nil, in db: DatabaseConnection) throws -> [Project] {
        let all = try db.query("SELECT * FROM organization_projects ORDER BY sort_order, name COLLATE NOCASE").map(Project.init(row:))
        guard let statuses else { return all }
        return all.filter { statuses.contains($0.status) }
    }
}
