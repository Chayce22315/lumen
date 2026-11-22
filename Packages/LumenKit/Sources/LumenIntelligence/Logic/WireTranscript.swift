import Foundation

/// Derives the provider-neutral wire transcript from stored messages, guaranteeing the shape
/// every provider accepts:
///
/// - failed messages are left out (a cancelled message keeps the text it streamed);
///   whitespace-only text blocks and empty messages are dropped;
/// - consecutive messages of the same role are merged, and tool results lead a user message;
/// - a tool call is kept only when the next message answers it, and a tool result only when it
///   answers a call in the previous message;
/// - an assistant message left with nothing but reasoning is dropped;
/// - the transcript starts with a user message.
///
/// Without tools in the request (`includeToolBlocks == false`) tool blocks are removed: providers
/// reject tool blocks in a request that declares no tools.
public enum WireTranscript {
    public static func messages(from history: [ChatMessage], includeToolBlocks: Bool = true) -> [WireMessage] {
        var messages: [WireMessage] = history.compactMap { message in
            guard message.status != .failed else { return nil }
            let blocks = message.blocks.filter { block in
                switch block {
                case .text(let text):
                    return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                case .toolUse, .toolResult:
                    return includeToolBlocks
                case .thinking, .redactedThinking:
                    return message.role == .assistant
                }
            }
            return WireMessage(role: message.role, blocks: blocks)
        }
        // Each pass can only remove blocks, so this settles in a few passes.
        var previous: [WireMessage] = []
        while previous != messages {
            previous = messages
            messages = pairToolBlocks(merge(dropEmpty(messages)))
        }
        while let first = messages.first, first.role != .user {
            messages.removeFirst()
        }
        return messages
    }

    private static func dropEmpty(_ messages: [WireMessage]) -> [WireMessage] {
        messages.filter { message in
            switch message.role {
            case .user:
                return !message.blocks.isEmpty
            case .assistant:
                return message.blocks.contains { !$0.isReasoning }
            }
        }
    }

    private static func merge(_ messages: [WireMessage]) -> [WireMessage] {
        var merged: [WireMessage] = []
        for message in messages {
            if let last = merged.last, last.role == message.role {
                merged[merged.count - 1].blocks.append(contentsOf: message.blocks)
            } else {
                merged.append(message)
            }
        }
        return merged.map { message in
            guard message.role == .user else { return message }
            // Tool results must come first in a user message; the sort is stable otherwise.
            let results = message.blocks.filter(\.isToolResult)
            let others = message.blocks.filter { !$0.isToolResult }
            return WireMessage(role: .user, blocks: results + others)
        }
    }

    private static func pairToolBlocks(_ messages: [WireMessage]) -> [WireMessage] {
        var paired = messages
        for index in paired.indices {
            switch paired[index].role {
            case .assistant:
                let answered = index + 1 < paired.count && paired[index + 1].role == .user
                    ? Set(paired[index + 1].blocks.compactMap(toolResultID))
                    : []
                paired[index].blocks.removeAll { block in
                    guard case .toolUse(let id, _, _) = block else { return false }
                    return !answered.contains(id)
                }
            case .user:
                let requested = index > 0 && messages[index - 1].role == .assistant
                    ? Set(messages[index - 1].blocks.compactMap(toolUseID))
                    : []
                paired[index].blocks.removeAll { block in
                    guard case .toolResult(let id, _, _) = block else { return false }
                    return !requested.contains(id)
                }
            }
        }
        return paired
    }

    private static func toolUseID(_ block: ContentBlock) -> String? {
        if case .toolUse(let id, _, _) = block { return id }
        return nil
    }

    private static func toolResultID(_ block: ContentBlock) -> String? {
        if case .toolResult(let id, _, _) = block { return id }
        return nil
    }
}
