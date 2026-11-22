import Foundation
import LumenFoundation
import LumenCore

extension EntityKind {
    /// A Markdown note (`Note`).
    public static let note: EntityKind = "note"
    /// An imported file (`DocumentItem`).
    public static let document: EntityKind = "document"
    /// A folder of notes and documents (`NoteCollection`).
    public static let collection: EntityKind = "collection"
}

/// Domain events published by the knowledge engine, always after the transaction committed.
///
/// Attributes are limited to identifiers, content types and counts; titles and bodies never
/// appear in events.
public enum KnowledgeEvents {
    public static let noteCreated: EventName = "knowledge.note.created"
    public static let noteUpdated: EventName = "knowledge.note.updated"
    public static let noteDeleted: EventName = "knowledge.note.deleted"
    public static let noteArchived: EventName = "knowledge.note.archived"
    /// Published when an archived note is brought back (unarchived). Restoring an older version
    /// is a content change and publishes `noteUpdated` with a `restoredVersionID` attribute.
    public static let noteRestored: EventName = "knowledge.note.restored"

    public static let documentImported: EventName = "knowledge.document.imported"
    public static let documentUpdated: EventName = "knowledge.document.updated"
    public static let documentDeleted: EventName = "knowledge.document.deleted"

    public static let collectionCreated: EventName = "knowledge.collection.created"
    public static let collectionUpdated: EventName = "knowledge.collection.updated"
    public static let collectionDeleted: EventName = "knowledge.collection.deleted"

    /// Every event name this module publishes.
    public static let all: Set<EventName> = [
        noteCreated, noteUpdated, noteDeleted, noteArchived, noteRestored,
        documentImported, documentUpdated, documentDeleted,
        collectionCreated, collectionUpdated, collectionDeleted,
    ]
}
