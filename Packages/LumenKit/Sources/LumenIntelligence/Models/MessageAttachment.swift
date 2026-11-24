import Foundation
import LumenFoundation

/// A library item (a note or a document) attached to a user message.
///
/// The message stores the reference, not the item's text: the text is read again each time the
/// message is sent to a model, so a conversation never accumulates copies of the user's notes.
/// `title` is kept only to label the attachment, including after the item is renamed or deleted.
public struct MessageAttachment: Sendable, Hashable, Codable {
    public var reference: EntityReference
    public var title: String
    /// Characters of the item's text sent with the message (after budgeting).
    public var includedCharacters: Int
    /// Characters the item's text had when it was attached.
    public var totalCharacters: Int

    public init(reference: EntityReference, title: String, includedCharacters: Int, totalCharacters: Int) {
        self.reference = reference
        self.title = title
        self.includedCharacters = max(0, includedCharacters)
        self.totalCharacters = max(0, totalCharacters)
    }

    /// Only the beginning of the item fitted the context budget.
    public var isTruncated: Bool { includedCharacters < totalCharacters }
}

/// The current text of an attachable item, as read by an `AttachmentResolver`.
public struct AttachmentContent: Sendable, Hashable {
    public var title: String
    /// A short lowercase noun for the prompt: "note", "document".
    public var kind: String
    public var text: String

    public init(title: String, kind: String, text: String) {
        self.title = title
        self.kind = kind
        self.text = text
    }
}

/// Reads attachable library items for the assistant.
///
/// The application layer implements this over the knowledge engine, so the intelligence engine
/// never reads another module's tables.
public protocol AttachmentResolver: Sendable {
    /// The item's current content; `nil` when it no longer exists or has no text to send.
    func content(of reference: EntityReference) async throws -> AttachmentContent?
}
