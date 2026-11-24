import Foundation
import LumenFoundation

public enum MemorySource: String, Sendable, Codable, Hashable {
    /// Added by the user in settings.
    case user
    /// Saved by the assistant through the `remember` tool.
    case assistant
}

/// A fact the assistant remembers across conversations. Synchronized; the user can review, edit,
/// disable or delete each one.
public struct MemoryItem: Sendable, Hashable, Identifiable {
    public typealias ID = Identifier<MemoryItem>

    public let id: ID
    public var content: String
    public var source: MemorySource
    public var isEnabled: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: ID = ID(),
        content: String,
        source: MemorySource,
        isEnabled: Bool = true,
        createdAt: Date,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.content = content
        self.source = source
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    public var reference: EntityReference {
        EntityReference(kind: .memory, id: id)
    }
}

extension MemoryItem: Codable {
    enum CodingKeys: String, CodingKey {
        case id, content, source, isEnabled, createdAt, updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.init(
            id: try container.decode(ID.self, forKey: .id),
            content: try container.decode(String.self, forKey: .content),
            source: try container.decodeIfPresent(MemorySource.self, forKey: .source) ?? .user,
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
            createdAt: createdAt,
            updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(content, forKey: .content)
        try container.encode(source, forKey: .source)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}
