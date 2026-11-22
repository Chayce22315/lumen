import Foundation
import Observation
import LumenFoundation
import LumenCore
import LumenKnowledge
import LumenApplication

/// One imported document: its details, extracted text, sharing and the QuickLook preview.
@MainActor
@Observable
public final class DocumentDetailViewModel {
    public let documentID: DocumentItem.ID
    public private(set) var state: LoadState<DocumentItem> = .idle
    /// The document's file on this device; `nil` when its bytes aren't here.
    public private(set) var fileURL: URL?
    /// Set to present the QuickLook preview; the preview clears it when it closes.
    public var previewURL: URL?

    private let services: LumenServices
    private let observation = ObservationHandle()

    public init(documentID: DocumentItem.ID, services: LumenServices) {
        self.documentID = documentID
        self.services = services
    }

    /// Previewing and sharing need the file on this device.
    public var canOpenFile: Bool { fileURL != nil }

    public func start() async {
        await load()
        services.events.observe(EventFilter(modules: ["knowledge", "sync"], entityKinds: [.document]), into: observation) { [weak self] in
            await self?.load()
        }
    }

    public func load() async {
        if state.value == nil { state = .loading }
        do {
            guard let document = try await services.knowledge.documents.document(documentID) else {
                state = .failed(ErrorPresentation(
                    title: "Document not found",
                    message: "This document no longer exists. It may have been deleted on another device."
                ))
                fileURL = nil
                return
            }
            state = .loaded(document)
            fileURL = try await services.knowledge.documents.availableFileURL(for: documentID)
        } catch {
            state = .failed(ErrorPresentation.from(error))
        }
    }

    public func preview() {
        previewURL = fileURL
    }
}
