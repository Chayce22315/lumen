import Foundation
import LumenFoundation
import LumenPersistence

enum NotificationSchema {
    static let schema = DatabaseSchema(namespace: "notifications", migrations: [
        .sql("0001_inbox", """
            CREATE TABLE notifications_inbox (
                id TEXT PRIMARY KEY NOT NULL,
                category TEXT NOT NULL,
                title TEXT NOT NULL,
                body TEXT NOT NULL,
                entity_kind TEXT,
                entity_id TEXT,
                created_at REAL NOT NULL,
                deliver_at REAL NOT NULL,
                read_at REAL,
                system_request_id TEXT
            );
            CREATE INDEX notifications_inbox_deliver ON notifications_inbox (deliver_at DESC);
            CREATE INDEX notifications_inbox_entity ON notifications_inbox (entity_kind, entity_id);
            """),
    ])
}

extension InboxNotification {
    init(row: Row) throws {
        let categoryText: String = try row.get("category")
        guard let category = NotificationCategory(rawValue: categoryText) else {
            throw DatabaseError.typeMismatch(column: "category", expected: "NotificationCategory", actual: categoryText)
        }
        let kind: String? = try row.get("entity_kind")
        let entityID: UUID? = try row.get("entity_id")
        self.init(
            id: try row.get("id"),
            category: category,
            title: try row.get("title"),
            body: try row.get("body"),
            entity: zip(kind, entityID).map { EntityReference(kind: .init($0), id: $1) },
            createdAt: try row.get("created_at"),
            deliverAt: try row.get("deliver_at"),
            readAt: try row.get("read_at"),
            systemRequestID: try row.get("system_request_id")
        )
    }
}

/// `zip` for optionals.
func zip<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}
