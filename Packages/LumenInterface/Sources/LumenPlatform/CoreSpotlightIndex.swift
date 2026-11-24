import Foundation
import LumenApplication
#if canImport(CoreSpotlight)
@preconcurrency import CoreSpotlight
import UniformTypeIdentifiers
#endif

/// Tasks and notes in Spotlight, through the device's on-device CoreSpotlight index (no
/// entitlement). Each item carries a title and a short snippet only. Opening a result continues a
/// `CSSearchableItemActionType` user activity whose identifier is the item's `kind:UUID`; the root
/// view hands it to `AppModel.openSearchableItem(identifier:)`.
public struct CoreSpotlightIndex: SystemSearchIndexing {
    public init() {}

    /// Whether this device indexes for Spotlight at all.
    public static var isSupported: Bool {
        #if canImport(CoreSpotlight)
        CSSearchableIndex.isIndexingAvailable()
        #else
        false
        #endif
    }

    public func index(_ items: [SystemSearchItem]) async throws {
        #if canImport(CoreSpotlight)
        guard !items.isEmpty else { return }
        try await CSSearchableIndex.default().indexSearchableItems(items.map(Self.searchableItem(for:)))
        #endif
    }

    public func remove(identifiers: [String]) async throws {
        #if canImport(CoreSpotlight)
        guard !identifiers.isEmpty else { return }
        try await CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: identifiers)
        #endif
    }

    public func removeAll() async throws {
        #if canImport(CoreSpotlight)
        try await CSSearchableIndex.default().deleteAllSearchableItems()
        #endif
    }

    #if canImport(CoreSpotlight)
    static func searchableItem(for item: SystemSearchItem) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: UTType.text)
        attributes.title = item.title
        attributes.contentDescription = item.snippet
        attributes.keywords = item.keywords
        attributes.contentModificationDate = item.updatedAt // privacy-audit: sets the item's own date on Spotlight metadata; reads no file timestamp
        let searchable = CSSearchableItem(uniqueIdentifier: item.identifier, domainIdentifier: item.domain, attributeSet: attributes)
        // Items otherwise expire after a month; Lumen removes them itself when they go.
        searchable.expirationDate = .distantFuture
        return searchable
    }
    #endif
}
