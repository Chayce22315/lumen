import Foundation
import LumenFoundation
import LumenPersistence

/// SQL for the link index (`knowledge_links`).
///
/// Links are derived from note bodies and are not synchronized; every write of a note refreshes
/// them. A `[[Title]]` link is resolved when it is written: it keeps the note it resolved to before
/// (as long as that note exists, even if renamed), otherwise it takes the most recently updated
/// note with a matching title, otherwise it stays unresolved.
public struct LinkRepository {
    private let db: DatabaseConnection

    public init(_ db: DatabaseConnection) {
        self.db = db
    }

    // MARK: - Reads

    /// Links written in `source`, in source order.
    public func outgoingLinks(from source: EntityReference) throws -> [EntityLink] {
        try db.query(
            "SELECT * FROM knowledge_links WHERE source_kind = ? AND source_id = ? ORDER BY position",
            [source.kind, source.id]
        ).map(EntityLink.init(row:))
    }

    /// Links resolved to `target`, plus — when `titleKey` is given — unresolved `[[Title]]` links
    /// with that title key. Most recently updated source first.
    public func backlinks(to target: EntityReference, unresolvedTitleKey titleKey: String?) throws -> [EntityLink] {
        try db.query(
            """
            SELECT l.* FROM knowledge_links l
            LEFT JOIN knowledge_notes n ON l.source_kind = 'note' AND n.id = l.source_id
            WHERE (l.target_kind = ? AND l.target_id = ?)
               OR (? = 1 AND l.target_kind IS NULL AND l.kind = 'wikiLink' AND l.target_title_key = ?)
            ORDER BY n.updated_at DESC, l.source_id, l.position
            """,
            [target.kind, target.id, titleKey != nil, titleKey ?? ""]
        ).map(EntityLink.init(row:))
    }

    // MARK: - Writes

    /// Replaces every link of `source` with `links` (their `source` and `position` are rewritten
    /// to match).
    public func replaceOutgoingLinks(from source: EntityReference, with links: [EntityLink]) throws {
        try deleteOutgoingLinks(from: source)
        for (position, link) in links.enumerated() {
            try db.execute(
                """
                INSERT INTO knowledge_links
                    (source_kind, source_id, position, target_kind, target_id, target_title, target_title_key, label, kind)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    source.kind, source.id, position, link.target?.kind, link.target?.id, link.targetTitle,
                    LinkTitle.matchingKey(link.targetTitle), link.label, link.kind.rawValue,
                ]
            )
        }
    }

    /// Re-parses `note.body` and stores its links, resolving `[[Title]]` links (see type docs).
    public func refreshLinks(for note: Note) throws {
        let source = note.reference
        let matches = WikiLinkParser.links(in: note.body)
        guard !matches.isEmpty else {
            try deleteOutgoingLinks(from: source)
            return
        }

        var previousTargets: [String: EntityReference] = [:]
        for link in try outgoingLinks(from: source) where link.kind == .wikiLink {
            guard let target = link.target else { continue }
            let key = LinkTitle.matchingKey(link.targetTitle)
            if previousTargets[key] == nil {
                previousTargets[key] = target
            }
        }

        let notes = NoteRepository(db)
        var resolved: [String: EntityReference?] = [:]
        func resolve(_ title: String) throws -> EntityReference? {
            let key = LinkTitle.matchingKey(title)
            if let cached = resolved[key] { return cached }
            var target: EntityReference?
            if let previous = previousTargets[key], previous.kind == .note, try notes.exists(previous.identifier(as: Note.self)) {
                target = previous
            } else {
                target = try notes.mostRecentNote(withTitleKey: key)?.reference
            }
            resolved[key] = .some(target)
            return target
        }

        var links: [EntityLink] = []
        for (position, match) in matches.enumerated() {
            switch match.target {
            case .entity(let reference):
                links.append(EntityLink(source: source, position: position, target: reference, targetTitle: reference.uri, label: match.alias, kind: .entityMention))
            case .title(let title):
                links.append(EntityLink(source: source, position: position, target: try resolve(title), targetTitle: title, label: match.alias, kind: .wikiLink))
            }
        }
        try replaceOutgoingLinks(from: source, with: links)
    }

    public func deleteOutgoingLinks(from source: EntityReference) throws {
        try db.execute("DELETE FROM knowledge_links WHERE source_kind = ? AND source_id = ?", [source.kind, source.id])
    }

    /// Turns `[[Title]]` links resolved to `target` back into unresolved title links. Entity
    /// mentions keep their explicit reference.
    public func unresolveLinks(targeting target: EntityReference) throws {
        try db.execute(
            "UPDATE knowledge_links SET target_kind = NULL, target_id = NULL WHERE target_kind = ? AND target_id = ? AND kind = 'wikiLink'",
            [target.kind, target.id]
        )
    }
}
