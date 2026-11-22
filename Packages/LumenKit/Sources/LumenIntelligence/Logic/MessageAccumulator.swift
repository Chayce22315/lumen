import Foundation
import LumenFoundation

/// Folds a completion's events into message content.
///
/// Consecutive text deltas extend one text block; reasoning and tool blocks keep their position
/// in the stream so the message can be replayed to the provider unchanged.
public struct MessageAccumulator: Sendable, Hashable {
    public private(set) var blocks: [ContentBlock] = []
    /// The last cumulative usage reported.
    public private(set) var usage: TokenUsage?
    public private(set) var stopReason: StopReason?
    /// Tool calls whose input was not a valid JSON object, keyed by call id, with the raw input.
    public private(set) var invalidToolInputs: [String: String] = [:]
    /// Whether anything visible (text or a tool call) has arrived. A failed attempt is retried
    /// only before this becomes true, so the user never sees a reply restart.
    public private(set) var hasOutput = false

    public init() {}

    public mutating func apply(_ event: CompletionEvent) {
        switch event {
        case .textDelta(let delta):
            hasOutput = true
            if case .text(let existing)? = blocks.last {
                blocks[blocks.count - 1] = .text(existing + delta)
            } else {
                blocks.append(.text(delta))
            }
        case .thinking(let text, let signature):
            blocks.append(.thinking(text: text, signature: signature))
        case .redactedThinking(let data):
            blocks.append(.redactedThinking(data: data))
        case .toolUse(let id, let name, let input):
            hasOutput = true
            blocks.append(.toolUse(id: id, name: name, input: input))
        case .invalidToolUse(let id, let name, let rawInput):
            hasOutput = true
            // The call is echoed with an empty object (the format requires an object) and answered
            // with an error result carrying the raw input.
            invalidToolInputs[id] = rawInput
            blocks.append(.toolUse(id: id, name: name, input: .object([:])))
        case .usage(let usage):
            self.usage = usage
        case .stop(let reason):
            stopReason = reason
        }
    }

    public var text: String {
        blocks.compactMap(\.textValue).joined()
    }

    public var toolUses: [(id: String, name: String, input: JSONValue)] {
        blocks.compactMap { block in
            if case .toolUse(let id, let name, let input) = block { return (id, name, input) }
            return nil
        }
    }
}
