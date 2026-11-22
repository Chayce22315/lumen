import Foundation
import LumenFoundation

/// A saved snapshot of a note's title and body. Versions are device-local history: they are not
/// part of the change log.
public struct NoteVersion: Sendable, Hashable, Codable, Identifiable {
    public typealias ID = Identifier<NoteVersion>

    public let id: ID
    public var noteID: Note.ID
    public var title: String
    public var body: String
    public var savedAt: Date

    public init(id: ID = ID(), noteID: Note.ID, title: String, body: String, savedAt: Date) {
        self.id = id
        self.noteID = noteID
        self.title = title
        self.body = body
        self.savedAt = savedAt
    }

    /// Whether this version holds exactly `title` and `body`.
    public func matches(title: String, body: String) -> Bool {
        self.title == title && self.body == body
    }
}

extension NoteVersion {
    enum CodingKeys: String, CodingKey {
        case id, noteID, title, body, savedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(ID.self, forKey: .id),
            noteID: try container.decode(Note.ID.self, forKey: .noteID),
            title: try container.decodeIfPresent(String.self, forKey: .title) ?? "",
            body: try container.decodeIfPresent(String.self, forKey: .body) ?? "",
            savedAt: try container.decode(Date.self, forKey: .savedAt)
        )
    }
}

/// The difference between two states of a note: a version and either a later version or the
/// note as it is now.
public struct NoteVersionDiff: Sendable, Hashable {
    public var noteID: Note.ID
    public var fromVersionID: NoteVersion.ID
    /// `nil` when the comparison is against the note's current state.
    public var toVersionID: NoteVersion.ID?
    public var oldTitle: String
    public var newTitle: String
    public var body: LineDiff

    public init(
        noteID: Note.ID,
        fromVersionID: NoteVersion.ID,
        toVersionID: NoteVersion.ID?,
        oldTitle: String,
        newTitle: String,
        body: LineDiff
    ) {
        self.noteID = noteID
        self.fromVersionID = fromVersionID
        self.toVersionID = toVersionID
        self.oldTitle = oldTitle
        self.newTitle = newTitle
        self.body = body
    }

    public var titleChanged: Bool { oldTitle != newTitle }
}
