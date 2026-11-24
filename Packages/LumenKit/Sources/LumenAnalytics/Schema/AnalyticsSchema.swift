import Foundation
import LumenPersistence

/// Tables owned by analytics. Analytics data is device-local and private: these tables are never
/// written to the change log, never synchronized and never exported by sync.
enum AnalyticsSchema {
    static let schema = DatabaseSchema(namespace: "analytics", migrations: [
        .sql("0001_events_and_daily_counts", """
            CREATE TABLE analytics_events (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                entity_kind TEXT,
                entity_id TEXT,
                actor TEXT NOT NULL,
                occurred_at REAL NOT NULL,
                day TEXT NOT NULL,
                hour INTEGER NOT NULL CHECK (hour BETWEEN 0 AND 23),
                attributes TEXT NOT NULL DEFAULT '{}'
            );
            CREATE INDEX analytics_events_day ON analytics_events (day);
            CREATE INDEX analytics_events_name ON analytics_events (name, day);
            CREATE INDEX analytics_events_occurred ON analytics_events (occurred_at DESC);

            CREATE TABLE analytics_daily_counts (
                day TEXT NOT NULL,
                name TEXT NOT NULL,
                actor TEXT NOT NULL,
                count INTEGER NOT NULL CHECK (count >= 0),
                PRIMARY KEY (day, name, actor)
            ) WITHOUT ROWID;
            CREATE INDEX analytics_daily_counts_name ON analytics_daily_counts (name, day);
            """),
        .sql("0002_daily_totals", """
            CREATE TABLE analytics_daily_totals (
                day TEXT NOT NULL,
                measure TEXT NOT NULL,
                actor TEXT NOT NULL,
                total REAL NOT NULL CHECK (total >= 0),
                PRIMARY KEY (day, measure, actor)
            ) WITHOUT ROWID;
            CREATE INDEX analytics_daily_totals_measure ON analytics_daily_totals (measure, day);
            """),
    ])
}
