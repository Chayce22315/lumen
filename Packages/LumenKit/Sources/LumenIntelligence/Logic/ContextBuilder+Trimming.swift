import Foundation

/// The result of fitting a history into a token budget.
public struct FittedHistory: Sendable, Hashable {
    public var messages: [ChatMessage]
    /// Messages removed to fit the budget.
    public var droppedMessageCount: Int
    /// Whether reasoning blocks of the latest turn had to be removed too (see `ContextBuilder.fit`).
    public var strippedCurrentTurnReasoning: Bool
    public var estimatedTokens: Int
}

extension ContextBuilder {
    /// Fits `history` into `budget` estimated tokens.
    ///
    /// - A *turn* starts at a user message that is not only tool results and runs until the next
    ///   one. The last turn is the current one.
    /// - Oldest whole turns are dropped first. If the current turn alone is still too large, its
    ///   oldest tool rounds (an assistant message plus the tool results answering it) are dropped,
    ///   keeping the opening user message and the newest round. Because whole turns and whole
    ///   rounds are the only units removed, a tool call is never separated from its result, and
    ///   the latest user message is always kept even when it alone exceeds the budget.
    /// - Reasoning blocks are kept only in the current turn. Providers bind them to the exact
    ///   request prefix that produced them, and earlier turns were produced under a different
    ///   system prompt. Removing every block is always valid, so once anything is dropped (which
    ///   changes the prefix) the current turn's reasoning is removed as well.
    public func fit(_ history: [ChatMessage], budget: Int) -> FittedHistory {
        let turns = Self.splitIntoTurns(history)
        guard var current = turns.last else {
            return FittedHistory(messages: [], droppedMessageCount: 0, strippedCurrentTurnReasoning: false, estimatedTokens: 0)
        }
        var prior = turns.dropLast().map { turn in turn.map { $0.removingReasoning() } }
        var priorTokens = prior.reduce(0) { $0 + Self.estimatedTokens(for: $1) }
        var currentTokens = Self.estimatedTokens(for: current)
        var dropped = 0

        while priorTokens + currentTokens > budget, !prior.isEmpty {
            let turn = prior.removeFirst()
            dropped += turn.count
            priorTokens -= Self.estimatedTokens(for: turn)
        }

        if priorTokens + currentTokens > budget {
            let opener = current.first.map { $0.startsTurn ? [$0] : [] } ?? []
            var rounds = Self.splitIntoRounds(Array(current.dropFirst(opener.count)))
            while priorTokens + currentTokens > budget, rounds.count > 1 {
                let round = rounds.removeFirst()
                dropped += round.count
                currentTokens -= Self.estimatedTokens(for: round)
            }
            current = opener + rounds.flatMap { $0 }
        }

        var stripped = false
        if dropped > 0, current.contains(where: { $0.blocks.contains(where: \.isReasoning) }) {
            current = current.map { $0.removingReasoning() }
            stripped = true
            currentTokens = Self.estimatedTokens(for: current)
        }

        return FittedHistory(
            messages: prior.flatMap { $0 } + current,
            droppedMessageCount: dropped,
            strippedCurrentTurnReasoning: stripped,
            estimatedTokens: priorTokens + currentTokens
        )
    }

    /// Splits a history into turns (see `fit`). A history that begins mid-turn yields a first
    /// turn without an opening user message.
    static func splitIntoTurns(_ history: [ChatMessage]) -> [[ChatMessage]] {
        var turns: [[ChatMessage]] = []
        for message in history {
            if message.startsTurn || turns.isEmpty {
                turns.append([message])
            } else {
                turns[turns.count - 1].append(message)
            }
        }
        return turns
    }

    /// Splits the messages after a turn's opener into rounds, each starting at an assistant message.
    static func splitIntoRounds(_ messages: [ChatMessage]) -> [[ChatMessage]] {
        var rounds: [[ChatMessage]] = []
        for message in messages {
            if message.role == .assistant || rounds.isEmpty {
                rounds.append([message])
            } else {
                rounds[rounds.count - 1].append(message)
            }
        }
        return rounds
    }
}
