import Foundation
import Observation
import LumenFoundation
import LumenCore
import LumenKnowledge
import LumenSearch
import LumenApplication

/// A note or document that can be attached to an assistant message.
public struct AttachmentCandidate: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case note
        case document
    }

    public let reference: EntityReference
    public let title: String
    /// "Note" or the document's size, for the picker row.
    public let detail: String
    public let kind: Kind
    public let updatedAt: Date

    public init(reference: EntityReference, title: String, detail: String, kind: Kind, updatedAt: Date) {
        self.reference = reference
        self.title = title
        self.detail = detail
        self.kind = kind
        self.updatedAt = updatedAt
    }

    public var id: EntityReference { reference }

    public var symbolName: String {
        switch kind {
        case .note: return "note.text"
        case .document: return "doc.text"
        }
    }

    static func note(_ note: Note) -> AttachmentCandidate {
        AttachmentCandidate(
            reference: note.reference,
            title: note.title.collapsingWhitespace.nonBlank ?? "Untitled note",
            detail: "Note",
            kind: .note,
            updatedAt: note.updatedAt
        )
    }

    static func document(_ document: DocumentItem) -> AttachmentCandidate {
        AttachmentCandidate(
            reference: document.reference,
            title: document.title.collapsingWhitespace.nonBlank ?? document.originalFileName,
            detail: ByteCountFormatter.string(fromByteCount: document.byteCount, countStyle: .file),
            kind: .document,
            updatedAt: document.updatedAt
        )
    }
}

/// The sheet for attaching library items to a message: attachable notes and documents (those
/// with text the assistant can read), most recently changed first, filtered by a search that
/// covers titles and content.
@MainActor
@Observable
public final class AttachmentPickerViewModel {
    public var query = "" {
        didSet { scheduleSearch() }
    }
    public private(set) var state: LoadState<[AttachmentCandidate]> = .idle

    private let services: LumenServices
    private let debounce: TimeInterval
    private var attachable: [AttachmentCandidate] = []
    private let pending = ObservationHandle()

    public init(services: LumenServices, debounce: TimeInterval = 0.15) {
        self.services = services
        self.debounce = debounce
    }

    public func load() async {
        if state.value == nil { state = .loading }
        do {
            let notes = try await services.knowledge.notes.notes(query: NoteQuery(sort: .updated))
                .filter(KnowledgeAttachmentResolver.isAttachable)
            let documents = try await services.knowledge.documents.allDocuments()
                .filter(KnowledgeAttachmentResolver.isAttachable)
            attachable = (notes.map(AttachmentCandidate.note) + documents.map(AttachmentCandidate.document))
                .sorted { $0.updatedAt > $1.updatedAt }
            await search()
        } catch {
            state = .failed(ErrorPresentation.from(error))
        }
    }

    /// Filters by the current query: full-text matches from the search index first, then items
    /// whose title contains every term (the index can trail a just-written note briefly).
    public func search() async {
        let query = self.query
        let tokens = query.matchingTokens
        guard !tokens.isEmpty else {
            state = .loaded(attachable)
            return
        }
        let byReference = Dictionary(attachable.map { ($0.reference, $0) }, uniquingKeysWith: { first, _ in first })
        var matches: [AttachmentCandidate] = []
        do {
            let results = try await services.search.service.search(SearchQuery(text: query, kinds: [.note, .document], limit: 50))
            matches = results.compactMap { byReference[$0.reference] }
        } catch {
            services.errors.report(error, context: "Searching the library")
        }
        guard query == self.query else { return } // a newer query is on its way
        let found = Set(matches.map(\.reference))
        let titleMatches = attachable.filter { candidate in
            guard !found.contains(candidate.reference) else { return false }
            let title = candidate.title.foldedForMatching
            return tokens.allSatisfy { title.contains($0) }
        }
        state = .loaded(matches + titleMatches)
    }

    private func scheduleSearch() {
        let delay = UInt64(max(0, debounce) * 1_000_000_000)
        pending.replace(with: Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay) // cancellation (a newer keystroke) ends the wait early
            guard !Task.isCancelled else { return }
            await self?.search()
        })
    }
}
