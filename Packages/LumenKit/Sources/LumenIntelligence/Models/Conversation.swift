import Foundation
import LumenFoundation

/// One assistant conversation. Synchronized across devices through the change log.
public struct Conversation: Sendable, Hashable, Identifiable {
    public typealias ID = Identifier<Conversation>

    public let id: ID
    /// User-facing title. Empty means "untitled"; the first user message fills it automatically.
    public var title: String
    /// The model for this conversation; `nil` follows `AssistantSettings.defaultModel`.
    public var selection: ModelSelection?
    public var createdAt: Date
    /// Bumped whenever a message is added, which orders the conversation list.
    public var updatedAt: Date
    public var isArchived: Bool
    public var isPinned: Bool

    public init(
        id: ID = ID(),
        title: String = "",
        selection: ModelSelection? = nil,
        createdAt: Date,
        updatedAt: Date? = nil,
        isArchived: Bool = false,
        isPinned: Bool = false
    ) {
        self.id = id
        self.title = title
        self.selection = selection
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.isArchived = isArchived
        self.isPinned = isPinned
    }

    /// The title to show, with a placeholder for untitled conversations.
    public var displayTitle: String {
        title.nonBlank ?? "New conversation"
    }

    public var reference: EntityReference {
        EntityReference(kind: .conversation, id: id)
    }
}

extension Conversation: Codable {
    enum CodingKeys: String, CodingKey {
        case id, title, selection, createdAt, updatedAt, isArchived, isPinned
    }

    /// Decodes with defaults for every field after `id`/`createdAt` so older change-log snapshots stay readable.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.init(
            id: try container.decode(ID.self, forKey: .id),
            title: try container.decodeIfPresent(String.self, forKey: .title) ?? "",
            selection: try container.decodeIfPresent(ModelSelection.self, forKey: .selection),
            createdAt: createdAt,
            updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt,
            isArchived: try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false,
            isPinned: try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(selection, forKey: .selection)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(isArchived, forKey: .isArchived)
        try container.encode(isPinned, forKey: .isPinned)
    }
}
