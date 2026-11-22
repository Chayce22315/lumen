import Foundation
import LumenFoundation
@testable import LumenIntelligence

/// Builds message histories for logic tests with strictly increasing timestamps.
struct TranscriptBuilder {
    let conversationID = Conversation.ID()
    private(set) var messages: [ChatMessage] = []
    private var clock = Date(timeIntervalSince1970: 1_795_251_600)

    private mutating func stamp() -> Date {
        clock = clock.addingTimeInterval(1)
        return clock
    }

    @discardableResult
    mutating func user(_ text: String) -> ChatMessage {
        append(ChatMessage(conversationID: conversationID, role: .user, blocks: [.text(text)], createdAt: stamp()))
    }

    @discardableResult
    mutating func assistant(_ blocks: [ContentBlock], status: MessageStatus = .complete) -> ChatMessage {
        append(ChatMessage(conversationID: conversationID, role: .assistant, blocks: blocks, status: status, createdAt: stamp()))
    }

    @discardableResult
    mutating func assistant(_ text: String) -> ChatMessage {
        assistant([.text(text)])
    }

    @discardableResult
    mutating func results(_ blocks: [ContentBlock]) -> ChatMessage {
        append(ChatMessage(conversationID: conversationID, role: .user, blocks: blocks, createdAt: stamp()))
    }

    /// An assistant tool call plus its result message.
    mutating func toolRound(id: String, name: String = "search_notes", payload: String = "result", reasoning: Bool = false) {
        var blocks: [ContentBlock] = reasoning ? [.thinking(text: "", signature: "sig-\(id)")] : []
        blocks.append(.toolUse(id: id, name: name, input: ["query": .string(id)]))
        assistant(blocks)
        results([.toolResult(toolUseID: id, content: payload, isError: false)])
    }

    private mutating func append(_ message: ChatMessage) -> ChatMessage {
        messages.append(message)
        return message
    }
}

/// Deterministic pseudo-random numbers (a 64-bit LCG) for generated histories.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
