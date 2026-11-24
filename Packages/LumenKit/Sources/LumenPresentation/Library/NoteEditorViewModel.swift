import Foundation
import Observation
import LumenFoundation
import LumenKnowledge
import LumenApplication

/// Editing a note with autosave, live structure (outline, word count), backlinks and history.
@MainActor
@Observable
public final class NoteEditorViewModel {
    public let noteID: Note.ID
    public var title = "" {
        didSet { if isLoaded { scheduleSave() } }
    }
    public var body = "" {
        didSet {
            if isLoaded { scheduleSave() }
            structure = MarkdownStructure(parsing: body)
        }
    }
    public private(set) var structure = MarkdownStructure(parsing: "")
    public private(set) var note: Note?
    public private(set) var backlinks: [Note] = []
    public private(set) var versions: [NoteVersion] = []
    public private(set) var isSaving = false
    public private(set) var lastSaved: Date?
    public private(set) var error: ErrorPresentation?

    private var isLoaded = false
    private let services: LumenServices
    private let autosave = ObservationHandle()
    private let autosaveDelay: TimeInterval

    public init(noteID: Note.ID, services: LumenServices, autosaveDelay: TimeInterval = 0.8) {
        self.noteID = noteID
        self.services = services
        self.autosaveDelay = autosaveDelay
    }

    public func load() async {
        do {
            guard let note = try await services.knowledge.notes.note(noteID) else {
                error = KnowledgeLookupError.missing.presentation
                return
            }
            self.note = note
            title = note.title
            body = note.body
            isLoaded = true
            await loadRelations()
        } catch {
            self.error = ErrorPresentation.from(error)
        }
    }

    private func loadRelations() async {
        do {
            backlinks = try await services.knowledge.notes.backlinkingNotes(to: EntityReference(kind: .note, id: noteID))
            versions = try await services.knowledge.notes.versions(of: noteID)
        } catch {
            services.errors.report(error, context: "Loading note links")
        }
    }

    /// Saves pending edits now (on dismiss and backgrounding).
    public func saveNow() async {
        autosave.cancel()
        guard let note, title != note.title || body != note.body else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            self.note = try await services.knowledge.notes.update(noteID, title: title, body: body)
            lastSaved = services.timeSource.now()
            error = nil
            await loadRelations()
        } catch {
            self.error = ErrorPresentation.from(error)
        }
    }

    /// Ticks the `index`-th checkbox of the body (tapping a rendered task item).
    public func toggleCheckbox(at index: Int) {
        if let updated = MarkdownStructure.togglingCheckbox(at: index, in: body) {
            body = updated
        }
    }

    public func restore(_ version: NoteVersion) async {
        do {
            let restored = try await services.knowledge.notes.restore(version.id)
            isLoaded = false
            note = restored
            title = restored.title
            body = restored.body
            isLoaded = true
            await loadRelations()
        } catch {
            self.error = ErrorPresentation.from(error)
        }
    }

    public func diff(to version: NoteVersion) async -> NoteVersionDiff? {
        do {
            return try await services.knowledge.notes.diff(from: version.id, to: nil)
        } catch {
            self.error = ErrorPresentation.from(error)
            return nil
        }
    }

    private func scheduleSave() {
        let delay = UInt64(autosaveDelay * 1_000_000_000)
        autosave.replace(with: Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await self?.saveNow()
        })
    }
}

enum KnowledgeLookupError: PresentableError {
    case missing

    var presentation: ErrorPresentation {
        ErrorPresentation(title: "Note not found", message: "This note no longer exists. It may have been deleted on another device.")
    }
}
