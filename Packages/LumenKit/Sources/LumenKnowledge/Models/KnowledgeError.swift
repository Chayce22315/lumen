import Foundation
import LumenFoundation

/// Failures specific to the knowledge engine. Missing entities are reported as
/// `DatabaseError.notFound`, invalid input as `ValidationError`.
public enum KnowledgeError: Error, Sendable, Hashable, CustomStringConvertible {
    /// A storage key that is not a plain file name (empty, contains a path separator, starts with a dot).
    case invalidStorageKey(String)
    /// The document's file is not in storage.
    case documentFileMissing(storageKey: String)
    /// No saved version has this identifier (it may have been pruned).
    case versionNotFound(NoteVersion.ID)
    /// The file's bytes are not a readable document of its type (a damaged PDF, for example).
    case unreadableDocument

    public var description: String {
        switch self {
        case .unreadableDocument:
            return "The document's data could not be read"
        case .invalidStorageKey(let key):
            return "Invalid document storage key '\(key)'"
        case .documentFileMissing(let key):
            return "Document file '\(key)' is missing from storage"
        case .versionNotFound(let id):
            return "No note version \(id)"
        }
    }
}

extension KnowledgeError: PresentableError {
    public var presentation: ErrorPresentation {
        switch self {
        case .invalidStorageKey:
            return ErrorPresentation(
                title: "Storage problem",
                message: "Lumen couldn't store this document.",
                recoverySuggestion: "Try importing the file again."
            )
        case .documentFileMissing:
            return ErrorPresentation(
                title: "File missing",
                message: "The file for this document is no longer on this device.",
                recoverySuggestion: "Import the original file again to restore it."
            )
        case .versionNotFound:
            return ErrorPresentation(title: "Version not found", message: "This version is no longer in the note's history.")
        case .unreadableDocument:
            return ErrorPresentation(
                title: "Unreadable document",
                message: "Lumen couldn't read this file's contents. It may be damaged.",
                recoverySuggestion: "Open it in another app to check it, then import it again."
            )
        }
    }
}
