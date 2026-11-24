import Foundation
import Synchronization
import LumenFoundation

/// Commands available in the palette, contributed by features and plugins.
public final class CommandRegistry: Sendable {
    private let commands = Mutex<[PaletteCommand]>([])

    public init(_ initial: [PaletteCommand] = []) {
        for command in initial {
            register(command)
        }
    }

    /// Registers or replaces a command (by `id`). Registration order is preserved.
    public func register(_ command: PaletteCommand) {
        commands.withLock { commands in
            if let index = commands.firstIndex(where: { $0.id == command.id }) {
                commands[index] = command
            } else {
                commands.append(command)
            }
        }
    }

    public func unregister(id: String) {
        commands.withLock { $0.removeAll { $0.id == id } }
    }

    /// Removes every command whose id starts with `prefix` (a plugin's namespace).
    public func unregister(prefix: String) {
        commands.withLock { $0.removeAll { $0.id.hasPrefix(prefix) } }
    }

    public var all: [PaletteCommand] {
        commands.withLock { $0 }
    }

    public func command(id: String) -> PaletteCommand? {
        commands.withLock { $0.first { $0.id == id } }
    }

    /// Ranked commands for `text`. An empty query returns suggested commands first, then the rest.
    public func search(_ text: String, limit: Int = 8) -> [RankedCommand] {
        let all = self.all
        let query = text.collapsingWhitespace
        guard !query.isEmpty else {
            let ordered = all.filter(\.isSuggested) + all.filter { !$0.isSuggested }
            return ordered.prefix(limit).map { RankedCommand(command: $0, score: 0, titleHighlights: []) }
        }
        var ranked: [RankedCommand] = []
        for command in all {
            if let match = FuzzyMatcher.match(query, in: command.title) {
                ranked.append(RankedCommand(command: command, score: match.score + 1, titleHighlights: FuzzyMatcher.highlights(for: match.indices)))
            } else if let keywordScore = command.keywords.compactMap({ FuzzyMatcher.match(query, in: $0)?.score }).max() {
                // Keyword matches rank below title matches of similar quality.
                ranked.append(RankedCommand(command: command, score: keywordScore * 0.6, titleHighlights: []))
            }
        }
        return Array(ranked.sorted { ($0.score, $1.command.title) > ($1.score, $0.command.title) }.prefix(limit))
    }
}
