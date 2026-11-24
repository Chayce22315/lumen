import Foundation

/// An action offered by the command palette ("New task", "Open Insights", "Run workflow …").
///
/// Commands carry no closure: the application layer dispatches on `id`, so they can be listed,
/// ranked and tested without the interface.
public struct PaletteCommand: Sendable, Hashable, Identifiable {
    public let id: String
    public var title: String
    public var subtitle: String
    /// SF Symbol name rendered by the interface.
    public var symbolName: String
    public var keywords: [String]
    public var category: String
    /// Shown first (in registration order) when the palette opens with an empty query.
    public var isSuggested: Bool

    public init(id: String, title: String, subtitle: String = "", symbolName: String, keywords: [String] = [], category: String, isSuggested: Bool = false) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        self.keywords = keywords
        self.category = category
        self.isSuggested = isSuggested
    }
}

public struct RankedCommand: Sendable, Hashable, Identifiable {
    public let command: PaletteCommand
    public let score: Double
    public let titleHighlights: [HighlightRange]

    public var id: String { command.id }
}
