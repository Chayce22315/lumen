import Foundation
import LumenFoundation
import LumenPersistence
import LumenCore

/// Lumen's notification manager: the in-app inbox, per-category preferences, quiet hours and
/// system delivery, behind one API every engine uses.
public final class NotificationService: Sendable {
    public static let schema = NotificationSchema.schema
    public static let postedEvent: EventName = "notifications.inbox.posted"

    private let database: Database
    private let settings: SettingsStore
    private let scheduler: any SystemNotificationScheduling
    private let events: EventBus
    private let timeSource: any TimeSource
    private let calendar: Calendar
    private let logger: Logger

    public init(
        database: Database,
        settings: SettingsStore,
        scheduler: any SystemNotificationScheduling,
        events: EventBus,
        timeSource: any TimeSource,
        calendar: Calendar,
        logger: Logger
    ) {
        self.database = database
        self.settings = settings
        self.scheduler = scheduler
        self.events = events
        self.timeSource = timeSource
        self.calendar = calendar
        self.logger = logger
    }

    // MARK: - Preferences

    public func preferences() async -> NotificationPreferences {
        await settings.value(NotificationPreferences.key)
    }

    public func updatePreferences(_ preferences: NotificationPreferences) async throws {
        try await settings.set(preferences, for: NotificationPreferences.key)
    }

    public func authorization() async -> NotificationAuthorization {
        await scheduler.authorization()
    }

    public func requestAuthorization() async throws -> Bool {
        try await scheduler.requestAuthorization()
    }

    // MARK: - Posting

    /// Posts or schedules a notification according to the user's preferences.
    ///
    /// Returns the inbox entry, or `nil` when the category is fully disabled.
    @discardableResult
    public func post(_ draft: NotificationDraft) async throws -> InboxNotification? {
        let preferences = await preferences()
        let preference = preferences.preference(for: draft.category)
        guard preference.showsInInbox || preference.deliversAlert else {
            logger.debug("Notification suppressed by preferences", metadata: ["category": draft.category.rawValue])
            return nil
        }

        let now = timeSource.now()
        let requested = max(draft.deliverAt ?? now, now)
        var alertDate = requested
        if let quietHours = preferences.quietHours, !draft.bypassesQuietHours {
            alertDate = quietHours.nextAllowedDate(onOrAfter: requested, calendar: calendar)
        }

        var notification = InboxNotification(
            category: draft.category,
            title: draft.title,
            body: draft.body,
            entity: draft.entity,
            createdAt: now,
            deliverAt: requested
        )

        if preference.deliversAlert, await scheduler.authorization() != .denied {
            let identifier = "lumen.\(notification.id.uuidString)"
            let request = SystemNotificationRequest(
                identifier: identifier,
                title: draft.title,
                body: draft.body,
                categoryIdentifier: draft.category.rawValue,
                fireDate: alertDate > now ? alertDate : nil,
                deepLink: draft.entity.map { "lumen://entity/\($0.uri)" }
            )
            do {
                try await scheduler.schedule(request)
                notification.systemRequestID = identifier
            } catch {
                // The inbox entry is still created; the failure is logged so it is visible in diagnostics.
                logger.error("System notification could not be scheduled", error: error)
            }
        }

        if preference.showsInInbox {
            let stored = notification
            try await database.write { db in
                try Self.insert(stored, in: db)
            }
        }
        events.publish(DomainEvent(
            name: Self.postedEvent,
            entity: draft.entity,
            attributes: ["category": .string(draft.category.rawValue)],
            actor: .system,
            occurredAt: now
        ))
        return notification
    }

    /// Cancels pending reminders about `entity` (for example when a task is completed or deleted).
    public func cancelPending(for entity: EntityReference) async throws {
        let now = timeSource.now()
        let requestIDs: [String] = try await database.write { db in
            let rows = try db.query(
                "SELECT system_request_id FROM notifications_inbox WHERE entity_kind = ? AND entity_id = ? AND deliver_at > ? AND system_request_id IS NOT NULL",
                [entity.kind, entity.id, now]
            )
            let ids = try rows.map { try $0.get("system_request_id", as: String.self) }
            try db.execute(
                "DELETE FROM notifications_inbox WHERE entity_kind = ? AND entity_id = ? AND deliver_at > ?",
                [entity.kind, entity.id, now]
            )
            return ids
        }
        if !requestIDs.isEmpty {
            await scheduler.cancel(identifiers: requestIDs)
        }
    }

    // MARK: - Inbox

    /// Delivered notifications, newest first.
    public func inbox(limit: Int = 100) async throws -> [InboxNotification] {
        let now = timeSource.now()
        return try await database.read { db in
            try db.query(
                "SELECT * FROM notifications_inbox WHERE deliver_at <= ? ORDER BY deliver_at DESC LIMIT ?",
                [now, max(1, limit)]
            ).map(InboxNotification.init(row:))
        }
    }

    /// Scheduled notifications that have not been delivered yet, soonest first.
    public func upcoming(limit: Int = 100) async throws -> [InboxNotification] {
        let now = timeSource.now()
        return try await database.read { db in
            try db.query(
                "SELECT * FROM notifications_inbox WHERE deliver_at > ? ORDER BY deliver_at ASC LIMIT ?",
                [now, max(1, limit)]
            ).map(InboxNotification.init(row:))
        }
    }

    public func unreadCount() async throws -> Int {
        let now = timeSource.now()
        return try await database.read { db in
            try db.scalar("SELECT count(*) FROM notifications_inbox WHERE read_at IS NULL AND deliver_at <= ?", [now]) ?? 0
        }
    }

    public func markRead(_ id: InboxNotification.ID) async throws {
        let now = timeSource.now()
        try await database.write { db in
            try db.execute("UPDATE notifications_inbox SET read_at = ? WHERE id = ? AND read_at IS NULL", [now, id])
        }
    }

    public func markAllRead() async throws {
        let now = timeSource.now()
        try await database.write { db in
            try db.execute("UPDATE notifications_inbox SET read_at = ? WHERE read_at IS NULL AND deliver_at <= ?", [now, now])
        }
    }

    public func delete(_ id: InboxNotification.ID) async throws {
        let requestID: String? = try await database.write { db in
            let requestID: String? = try db.scalar("SELECT system_request_id FROM notifications_inbox WHERE id = ?", [id])
            try db.execute("DELETE FROM notifications_inbox WHERE id = ?", [id])
            return requestID
        }
        if let requestID {
            await scheduler.cancel(identifiers: [requestID])
        }
    }

    /// Deletes read notifications older than `age` seconds.
    public func purgeRead(olderThan age: TimeInterval) async throws {
        let cutoff = timeSource.now().addingTimeInterval(-abs(age))
        try await database.write { db in
            try db.execute("DELETE FROM notifications_inbox WHERE read_at IS NOT NULL AND deliver_at < ?", [cutoff])
        }
    }

    private static func insert(_ notification: InboxNotification, in db: DatabaseConnection) throws {
        try db.execute(
            """
            INSERT INTO notifications_inbox
                (id, category, title, body, entity_kind, entity_id, created_at, deliver_at, read_at, system_request_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                notification.id, notification.category.rawValue, notification.title, notification.body,
                notification.entity?.kind, notification.entity?.id, notification.createdAt, notification.deliverAt,
                notification.readAt, notification.systemRequestID,
            ]
        )
    }
}
