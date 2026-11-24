import Foundation
import LumenFoundation
import LumenKnowledge
import LumenIntelligence

/// Lets assistant messages carry notes and documents: reads their current text through the
/// knowledge services. Documents without extracted text (images, scanned PDFs) and empty notes
/// are not attachable.
public struct KnowledgeAttachmentResolver: AttachmentResolver {
    private let notes: NoteService
    private let documents: DocumentService

    public init(notes: NoteService, documents: DocumentService) {
        self.notes = notes
        self.documents = documents
    }

    public func content(of reference: EntityReference) async throws -> AttachmentContent? {
        switch reference.kind {
        case .note:
            guard let note = try await notes.note(Note.ID(reference.id)), note.body.nonBlank != nil else { return nil }
            return AttachmentContent(title: Self.title(note.title, fallback: "Untitled note"), kind: "note", text: note.body)
        case .document:
            guard let document = try await documents.document(DocumentItem.ID(reference.id)),
                  let text = document.extractedText, text.nonBlank != nil else { return nil }
            return AttachmentContent(title: Self.title(document.title, fallback: document.originalFileName), kind: "document", text: text)
        default:
            return nil
        }
    }

    /// Whether `document` can be attached (it has text the assistant can read).
    public static func isAttachable(_ document: DocumentItem) -> Bool {
        document.extractedText?.nonBlank != nil
    }

    /// Whether `note` can be attached (it has a body).
    public static func isAttachable(_ note: Note) -> Bool {
        note.body.nonBlank != nil
    }

    private static func title(_ title: String, fallback: String) -> String {
        title.collapsingWhitespace.nonBlank ?? fallback
    }
}
