import Foundation
import LumenFoundation

/// Why a notification exists. Each category has its own delivery preferences.
public enum NotificationCategory: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    case reminder
    case automation
    case assistant
    case sync
    case insight
    case system

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .reminder: return "Reminders"
        case .automation: return "Automations"
        case .assistant: return "Assistant"
        case .sync: return "Sync"
        case .insight: return "Insights"
        case .system: return "System"
        }
    }

    public var summary: String {
        switch self {
        case .reminder: return "Task and event reminders you scheduled."
        case .automation: return "Messages sent by your automations."
        case .assistant: return "Replies that finish while you're away."
        case .sync: return "Conflicts that need your decision."
        case .insight: return "Weekly reports and productivity insights."
        case .system: return "Storage and account notices."
        }
    }
}

/// An entry in Lumen's in-app notification inbox.
public struct InboxNotification: Sendable, Hashable, Identifiable, Codable {
    public typealias ID = Identifier<InboxNotification>

    public let id: ID
    public var category: NotificationCategory
    public var title: String
    public var body: String
    /// The entity the notification is about; tapping opens it.
    public var entity: EntityReference?
    public var createdAt: Date
    /// When the notification becomes visible. Future values are scheduled reminders.
    public var deliverAt: Date
    public var readAt: Date?
    /// Identifier of the matching system notification request, when one was scheduled.
    public var systemRequestID: String?

    public init(
        id: ID = ID(),
        category: NotificationCategory,
        title: String,
        body: String,
        entity: EntityReference? = nil,
        createdAt: Date,
        deliverAt: Date,
        readAt: Date? = nil,
        systemRequestID: String? = nil
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.body = body
        self.entity = entity
        self.createdAt = createdAt
        self.deliverAt = deliverAt
        self.readAt = readAt
        self.systemRequestID = systemRequestID
    }

    public var isRead: Bool { readAt != nil }
}

/// What a caller asks to be notified about.
public struct NotificationDraft: Sendable, Hashable {
    public var category: NotificationCategory
    public var title: String
    public var body: String
    public var entity: EntityReference?
    /// `nil` delivers immediately.
    public var deliverAt: Date?
    /// Time-sensitive notifications ignore quiet hours (e.g. a reminder the user set for 23:00).
    public var bypassesQuietHours: Bool

    public init(
        category: NotificationCategory,
        title: String,
        body: String,
        entity: EntityReference? = nil,
        deliverAt: Date? = nil,
        bypassesQuietHours: Bool = false
    ) {
        self.category = category
        self.title = title
        self.body = body
        self.entity = entity
        self.deliverAt = deliverAt
        self.bypassesQuietHours = bypassesQuietHours
    }
}
