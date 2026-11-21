import Foundation
import LumenFoundation
import LumenPersistence

/// Tables owned by the organization engine.
public enum OrganizationSchema {
    public static let schema = DatabaseSchema(namespace: "organization", migrations: [
        .sql("0001_projects_tasks_calendars", """
            CREATE TABLE organization_projects (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                summary TEXT NOT NULL DEFAULT '',
                status TEXT NOT NULL,
                color TEXT NOT NULL,
                start_date TEXT,
                target_date TEXT,
                sort_order REAL NOT NULL DEFAULT 0,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                completed_at REAL
            );

            CREATE TABLE organization_tasks (
                id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL,
                notes TEXT NOT NULL DEFAULT '',
                status TEXT NOT NULL,
                priority INTEGER NOT NULL DEFAULT 0,
                due_date TEXT,
                due_time TEXT,
                start_date TEXT,
                project_id TEXT,
                parent_id TEXT,
                tags TEXT NOT NULL DEFAULT '[]',
                recurrence TEXT,
                recurrence_anchor TEXT,
                series_id TEXT,
                blocked_by TEXT NOT NULL DEFAULT '[]',
                estimated_minutes INTEGER,
                reminder TEXT,
                sort_order REAL NOT NULL DEFAULT 0,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                completed_at REAL
            );
            CREATE INDEX organization_tasks_status_due ON organization_tasks (status, due_date);
            CREATE INDEX organization_tasks_project ON organization_tasks (project_id);
            CREATE INDEX organization_tasks_parent ON organization_tasks (parent_id);
            CREATE INDEX organization_tasks_updated ON organization_tasks (updated_at);

            CREATE TABLE organization_calendars (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                color TEXT NOT NULL,
                is_visible INTEGER NOT NULL DEFAULT 1,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );

            CREATE TABLE organization_events (
                id TEXT PRIMARY KEY NOT NULL,
                calendar_id TEXT NOT NULL,
                title TEXT NOT NULL,
                notes TEXT NOT NULL DEFAULT '',
                location TEXT NOT NULL DEFAULT '',
                timing TEXT NOT NULL,
                range_start REAL NOT NULL,
                range_end REAL,
                recurrence TEXT,
                reminder_offsets TEXT NOT NULL DEFAULT '[]',
                project_id TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE INDEX organization_events_range ON organization_events (range_start, range_end);
            CREATE INDEX organization_events_calendar ON organization_events (calendar_id);
            """),
    ])
}

enum RowDecoding {
    static func enumValue<T: RawRepresentable>(_ row: Row, _ column: String, as _: T.Type = T.self) throws -> T where T.RawValue == String {
        let raw: String = try row.get(column)
        guard let value = T(rawValue: raw) else {
            throw DatabaseError.typeMismatch(column: column, expected: String(describing: T.self), actual: raw)
        }
        return value
    }
}

extension TaskItem {
    init(row: Row) throws {
        let priorityRaw: Int = try row.get("priority")
        self.init(
            id: try row.get("id"),
            title: try row.get("title"),
            notes: try row.get("notes"),
            status: try RowDecoding.enumValue(row, "status"),
            priority: TaskPriority(rawValue: priorityRaw) ?? TaskPriority.none,
            dueDate: try row.get("due_date"),
            dueTime: try row.get("due_time"),
            startDate: try row.get("start_date"),
            projectID: try row.get("project_id"),
            parentID: try row.get("parent_id"),
            tags: try row.json("tags"),
            recurrence: try row.optionalJSON("recurrence"),
            recurrenceAnchor: try row.get("recurrence_anchor"),
            seriesID: try row.get("series_id"),
            blockedBy: try row.json("blocked_by"),
            estimatedMinutes: try row.get("estimated_minutes"),
            reminder: try row.optionalJSON("reminder"),
            sortOrder: try row.get("sort_order"),
            createdAt: try row.get("created_at"),
            updatedAt: try row.get("updated_at"),
            completedAt: try row.get("completed_at")
        )
    }

    var rowArguments: [any DatabaseValueConvertible] {
        [
            id, title, notes, status.rawValue, priority.rawValue, dueDate, dueTime, startDate, projectID, parentID,
            JSONColumn(tags), recurrence.map(JSONColumn.init), recurrenceAnchor, seriesID, JSONColumn(blockedBy),
            estimatedMinutes, reminder.map(JSONColumn.init), sortOrder, createdAt, updatedAt, completedAt,
        ]
    }
}

extension Project {
    init(row: Row) throws {
        self.init(
            id: try row.get("id"),
            name: try row.get("name"),
            summary: try row.get("summary"),
            status: try RowDecoding.enumValue(row, "status"),
            color: try RowDecoding.enumValue(row, "color"),
            startDate: try row.get("start_date"),
            targetDate: try row.get("target_date"),
            sortOrder: try row.get("sort_order"),
            createdAt: try row.get("created_at"),
            updatedAt: try row.get("updated_at"),
            completedAt: try row.get("completed_at")
        )
    }

    var rowArguments: [any DatabaseValueConvertible] {
        [id, name, summary, status.rawValue, color.rawValue, startDate, targetDate, sortOrder, createdAt, updatedAt, completedAt]
    }
}

extension LumenCalendar {
    init(row: Row) throws {
        self.init(
            id: try row.get("id"),
            name: try row.get("name"),
            color: try RowDecoding.enumValue(row, "color"),
            isVisible: try row.get("is_visible"),
            createdAt: try row.get("created_at"),
            updatedAt: try row.get("updated_at")
        )
    }

    var rowArguments: [any DatabaseValueConvertible] {
        [id, name, color.rawValue, isVisible, createdAt, updatedAt]
    }
}

extension CalendarEvent {
    init(row: Row) throws {
        self.init(
            id: try row.get("id"),
            calendarID: try row.get("calendar_id"),
            title: try row.get("title"),
            notes: try row.get("notes"),
            location: try row.get("location"),
            timing: try row.json("timing"),
            recurrence: try row.optionalJSON("recurrence"),
            reminderOffsets: try row.json("reminder_offsets"),
            projectID: try row.get("project_id"),
            createdAt: try row.get("created_at"),
            updatedAt: try row.get("updated_at")
        )
    }

    /// Earliest instant the event can touch, used for range queries. Uses UTC day bounds for
    /// all-day events, widened by a day on each side to cover every time zone.
    var rangeStart: Date {
        switch timing {
        case .timed(let start, _, _): return start
        case .allDay(let start, _): return start.adding(days: -1).startDate(in: Self.utc)
        }
    }

    /// Latest instant the event can touch; `nil` for open-ended recurring events.
    var rangeEnd: Date? {
        if let recurrence {
            switch recurrence.end {
            case .never, .afterOccurrences: return nil
            case .onDate(let until): return until.adding(days: 2).startDate(in: Self.utc).addingTimeInterval(singleDuration)
            }
        }
        switch timing {
        case .timed(_, let end, _): return end
        case .allDay(_, let end): return end.adding(days: 2).startDate(in: Self.utc)
        }
    }

    private var singleDuration: TimeInterval {
        switch timing {
        case .timed(let start, let end, _): return max(0, end.timeIntervalSince(start))
        case .allDay(let start, let end): return TimeInterval(end.days(since: start) + 1) * 86_400
        }
    }

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        return calendar
    }

    var rowArguments: [any DatabaseValueConvertible] {
        [
            id, calendarID, title, notes, location, JSONColumn(timing), rangeStart, rangeEnd,
            recurrence.map(JSONColumn.init), JSONColumn(reminderOffsets), projectID, createdAt, updatedAt,
        ]
    }
}
