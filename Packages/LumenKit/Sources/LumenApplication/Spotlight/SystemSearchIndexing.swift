import Foundation
import LumenFoundation
import LumenOrganization
import LumenKnowledge

/// One entity as the system search (Spotlight on Apple platforms) shows it: a title and a short
/// snippet, never a full note body.
public struct SystemSearchItem: Sendable, Hashable {
    /// Longest snippet handed to the system index.
    public static let maximumSnippetLength = 160

    public let reference: EntityReference
    public var title: String
    public var snippet: String
    public var keywords: [String]
    public var updatedAt: Date

    public init(reference: EntityReference, title: String, snippet: String, keywords: [String] = [], updatedAt: Date) {
        self.reference = reference
        self.title = title
        self.snippet = snippet.truncated(to: Self.maximumSnippetLength)
        self.keywords = keywords
        self.updatedAt = updatedAt
    }

    /// The item's identifier in the system index: `kind:UUID`, which the system hands back when
    /// the user opens the result.
    public var identifier: String { reference.uri }

    /// Groups items by kind (`app.lumen.task`), so a kind can be cleared at once.
    public var domain: String { "app.lumen.\(reference.kind.rawValue)" }

    /// The entity behind an identifier the system handed back, when it is one Lumen indexes.
    public static func reference(fromIdentifier identifier: String) -> EntityReference? {
        guard let reference = EntityReference(uri: identifier), SystemSearchIndexer.indexedKinds.contains(reference.kind) else { return nil }
        return reference
    }
}

/// The device's system search index (CoreSpotlight in the app). Every call may be slow; the
/// indexer batches them.
public protocol SystemSearchIndexing: Sendable {
    /// Adds or replaces items, matched by `identifier`.
    func index(_ items: [SystemSearchItem]) async throws
    func remove(identifiers: [String]) async throws
    /// Removes every item Lumen added.
    func removeAll() async throws
}

/// What each kind of entity looks like in system search, and which entities belong there: open
/// tasks and notes that are not archived. Pure.
public enum SystemSearchItems {
    public static func item(for task: TaskItem, calendar: Calendar) -> SystemSearchItem? {
        guard task.isOpen else { return nil }
        var parts: [String] = []
        if let due = task.dueDate {
            parts.append("Due \(dueFormatter(calendar).string(from: due.startDate(in: calendar)))")
        }
        let notes = task.notes.collapsingWhitespace
        if !notes.isEmpty { parts.append(notes) }
        return SystemSearchItem(
            reference: task.reference,
            title: task.title,
            snippet: parts.isEmpty ? "Task" : parts.joined(separator: " · "),
            keywords: task.tags,
            updatedAt: task.updatedAt
        )
    }

    public static func item(for note: Note) -> SystemSearchItem? {
        guard !note.isArchived else { return nil }
        return SystemSearchItem(
            reference: note.reference,
            title: note.title.nonBlank ?? "Untitled note",
            snippet: note.excerpt(maximumLength: SystemSearchItem.maximumSnippetLength),
            keywords: note.tags,
            updatedAt: note.updatedAt
        )
    }

    private static func dueFormatter(_ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }
}
