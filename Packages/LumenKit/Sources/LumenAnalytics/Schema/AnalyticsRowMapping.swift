import Foundation
import LumenFoundation
import LumenPersistence
import LumenCore

/// Row ⇄ model mapping for the analytics tables.
enum AnalyticsRowMapping {
    static func actor(_ row: Row, column: String = "actor") throws -> EventActor {
        let text: String = try row.get(column)
        guard let actor = EventActor(rawValue: text) else {
            throw DatabaseError.typeMismatch(column: column, expected: "EventActor", actual: text)
        }
        return actor
    }

    static func name(_ row: Row, column: String = "name") throws -> EventName {
        EventName(rawValue: try row.get(column, as: String.self))
    }
}

extension AnalyticsEventRecord {
    init(row: Row) throws {
        self.init(
            id: try row.get("id"),
            name: try AnalyticsRowMapping.name(row),
            entityKind: try row.get("entity_kind"),
            entityID: try row.get("entity_id"),
            actor: try AnalyticsRowMapping.actor(row),
            occurredAt: try row.get("occurred_at"),
            day: try row.get("day"),
            hour: try row.get("hour"),
            attributes: try row.json("attributes", as: [String: JSONValue].self)
        )
    }
}

extension DailyCount {
    init(row: Row) throws {
        self.init(
            day: try row.get("day"),
            name: try AnalyticsRowMapping.name(row),
            actor: try AnalyticsRowMapping.actor(row),
            count: try row.get("count")
        )
    }
}

extension HourlyCount {
    init(row: Row) throws {
        self.init(
            name: try AnalyticsRowMapping.name(row),
            hour: try row.get("hour"),
            count: try row.get("count")
        )
    }
}

/// Encodes an optional filter set as the JSON array text the repositories pass to `json_each`,
/// or `NULL` for "no filter". Elements are sorted so equal sets bind identical text.
enum FilterArgument {
    static func names(_ names: Set<EventName>?) throws -> String? {
        guard let names else { return nil }
        return try JSONCoding.encodeString(names.map(\.rawValue).sorted())
    }

    static func actors(_ actors: Set<EventActor>?) throws -> String? {
        guard let actors else { return nil }
        return try JSONCoding.encodeString(actors.map(\.rawValue).sorted())
    }
}
