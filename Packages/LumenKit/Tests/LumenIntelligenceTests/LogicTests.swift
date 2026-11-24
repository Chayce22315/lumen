import Foundation
import Testing
import LumenFoundation
@testable import LumenIntelligence

@Suite("Wire transcript")
struct WireTranscriptTests {
    @Test("failed messages are skipped and consecutive user messages merge")
    func skipsFailedAndMerges() {
        var transcript = TranscriptBuilder()
        transcript.user("Hello")
        transcript.assistant([.text("Partial")], status: .failed)
        transcript.user("Are you there?")
        #expect(WireTranscript.messages(from: transcript.messages) == [
            WireMessage(role: .user, blocks: [.text("Hello"), .text("Are you there?")]),
        ])
    }

    @Test("cancelled messages keep the text they streamed; empty ones disappear")
    func cancelledMessages() {
        var transcript = TranscriptBuilder()
        transcript.user("Write a poem")
        transcript.assistant([.text("Roses are")], status: .cancelled)
        transcript.user("Shorter")
        transcript.assistant([], status: .cancelled)
        transcript.user("Never mind")
        let wire = WireTranscript.messages(from: transcript.messages)
        #expect(wire.map(\.role) == [.user, .assistant, .user])
        #expect(wire[1].blocks == [.text("Roses are")])
        #expect(wire[2].blocks == [.text("Shorter"), .text("Never mind")])
    }

    @Test("unanswered tool calls and orphaned results are removed")
    func orphans() {
        var transcript = TranscriptBuilder()
        transcript.user("Do things")
        transcript.assistant([.text("On it"), .toolUse(id: "a", name: "x", input: [:]), .toolUse(id: "b", name: "x", input: [:])])
        transcript.results([.toolResult(toolUseID: "a", content: "ok", isError: false), .toolResult(toolUseID: "zzz", content: "stray", isError: false)])
        let wire = WireTranscript.messages(from: transcript.messages)
        #expect(wire[1].blocks == [.text("On it"), .toolUse(id: "a", name: "x", input: [:])])
        #expect(wire[2].blocks == [.toolResult(toolUseID: "a", content: "ok", isError: false)])
    }

    @Test("an assistant message left with only reasoning is dropped, and the transcript starts with a user")
    func reasoningOnlyAndLeadingAssistant() {
        var transcript = TranscriptBuilder()
        transcript.assistant("Welcome!")
        transcript.user("Hi")
        transcript.assistant([.thinking(text: "", signature: "s"), .toolUse(id: "never", name: "x", input: [:])])
        transcript.user("Hello?")
        let wire = WireTranscript.messages(from: transcript.messages)
        #expect(wire == [WireMessage(role: .user, blocks: [.text("Hi"), .text("Hello?")])])
    }

    @Test("without tools, tool blocks are removed")
    func withoutTools() {
        var transcript = TranscriptBuilder()
        transcript.user("Remember I like tea")
        transcript.toolRound(id: "m1", name: "remember")
        transcript.assistant("Noted.")
        let wire = WireTranscript.messages(from: transcript.messages, includeToolBlocks: false)
        #expect(wire == [
            WireMessage(role: .user, blocks: [.text("Remember I like tea")]),
            WireMessage(role: .assistant, blocks: [.text("Noted.")]),
        ])
    }

    @Test("whitespace-only text is not sent and tool results lead merged user content")
    func whitespaceAndOrdering() {
        var transcript = TranscriptBuilder()
        transcript.user("Go")
        transcript.assistant([.text("  "), .toolUse(id: "a", name: "x", input: [:])])
        transcript.results([.toolResult(toolUseID: "a", content: "done", isError: false)])
        transcript.user("Next")
        let wire = WireTranscript.messages(from: transcript.messages)
        #expect(wire[1].blocks == [.toolUse(id: "a", name: "x", input: [:])])
        #expect(wire[2].blocks == [.toolResult(toolUseID: "a", content: "done", isError: false), .text("Next")])
    }
}

@Suite("Conversation titles")
struct ConversationTitleTests {
    @Test("short messages become the title with whitespace collapsed")
    func short() {
        #expect(ConversationTitle.make(from: "  Plan my\n\nweek  ") == "Plan my week")
    }

    @Test("long messages are cut at a word boundary within the limit, with an ellipsis")
    func long() {
        let title = ConversationTitle.make(from: "Could you help me plan a three-day trip to Kyoto in April, including temples and food?")
        #expect(title == "Could you help me plan a three-day trip to Kyoto in April…")
        #expect(title.count <= ConversationTitle.maximumLength)
    }

    @Test("a single very long word is cut hard")
    func longWord() {
        let title = ConversationTitle.make(from: String(repeating: "a", count: 100))
        #expect(title.count == 60)
        #expect(title.hasSuffix("…"))
    }
}

@Suite("Tool input validation")
struct ToolInputValidatorTests {
    static let schema: JSONValue = [
        "type": "object",
        "properties": [
            "title": ["type": "string", "minLength": 1],
            "priority": ["type": "string", "enum": ["low", "high"]],
            "estimate": ["type": "integer", "minimum": 0],
            "tags": ["type": "array", "items": ["type": "string"]],
        ],
        "required": ["title"],
        "additionalProperties": false,
    ]

    @Test("valid input passes")
    func valid() {
        #expect(ToolInputValidator.validate(["title": "Write report", "priority": "high", "estimate": 3, "tags": ["work"]], against: Self.schema).isEmpty)
    }

    @Test("reports missing, mistyped, unknown and out-of-range values")
    func problems() {
        let problems = ToolInputValidator.validate(["priority": "urgent", "estimate": 1.5, "tags": ["ok", 7], "colour": "red"], against: Self.schema)
        #expect(problems.contains("input.title is required."))
        #expect(problems.contains("input.colour is not an accepted property."))
        #expect(problems.contains(#"input.priority must be one of "low", "high"."#))
        #expect(problems.contains("input.estimate must be integer."))
        #expect(problems.contains("input.tags[1] must be string."))
    }

    @Test("a non-object input against an object schema is rejected")
    func notAnObject() {
        #expect(ToolInputValidator.validate("just text", against: Self.schema) == ["input must be object."])
    }

    @Test("schemas without constraints accept anything")
    func permissive() {
        #expect(ToolInputValidator.validate(["anything": [1, 2]], against: [:]).isEmpty)
    }
}

@Suite("Message accumulation")
struct MessageAccumulatorTests {
    @Test("text deltas merge; reasoning and tool calls keep their positions")
    func accumulation() {
        var accumulator = MessageAccumulator()
        #expect(!accumulator.hasOutput)
        accumulator.apply(.usage(TokenUsage(input: 10, output: 1)))
        accumulator.apply(.thinking(text: "", signature: "s"))
        #expect(!accumulator.hasOutput)
        accumulator.apply(.textDelta("Hel"))
        accumulator.apply(.textDelta("lo"))
        #expect(accumulator.hasOutput)
        accumulator.apply(.toolUse(id: "1", name: "x", input: ["a": 1]))
        accumulator.apply(.textDelta("after"))
        accumulator.apply(.usage(TokenUsage(input: 10, output: 20)))
        accumulator.apply(.stop(.toolUse))
        #expect(accumulator.blocks == [
            .thinking(text: "", signature: "s"), .text("Hello"), .toolUse(id: "1", name: "x", input: ["a": 1]), .text("after"),
        ])
        #expect(accumulator.usage == TokenUsage(input: 10, output: 20))
        #expect(accumulator.stopReason == .toolUse)
        #expect(accumulator.text == "Helloafter")
    }

    @Test("invalid tool input is echoed as an empty object and remembered for the error result")
    func invalidInput() {
        var accumulator = MessageAccumulator()
        accumulator.apply(.invalidToolUse(id: "9", name: "x", rawInput: "{oops"))
        #expect(accumulator.blocks == [.toolUse(id: "9", name: "x", input: .object([:]))])
        #expect(accumulator.invalidToolInputs == ["9": "{oops"])
        #expect(accumulator.hasOutput)
    }
}

@Suite("Model coding")
struct ModelCodingTests {
    @Test("content blocks round-trip through JSON")
    func blocksRoundTrip() throws {
        let blocks: [ContentBlock] = [
            .text("Hi"), .toolUse(id: "1", name: "x", input: ["a": [1, "b"]]),
            .toolResult(toolUseID: "1", content: "ok", isError: true),
            .thinking(text: "t", signature: nil), .redactedThinking(data: "d"),
        ]
        let text = try JSONCoding.encodeString(blocks)
        #expect(try JSONCoding.decode([ContentBlock].self, from: text) == blocks)
    }

    @Test("older snapshots without newer fields still decode")
    func lenientDecoding() throws {
        let conversationID = Conversation.ID()
        let conversation = try JSONCoding.decode(Conversation.self, from: #"{"id":"\#(conversationID.uuidString)","createdAt":100}"#)
        #expect(conversation.title == "" && !conversation.isPinned && conversation.updatedAt == conversation.createdAt)
        let message = try JSONCoding.decode(ChatMessage.self, from: #"{"id":"\#(UUID().uuidString)","conversationID":"\#(conversationID.uuidString)","role":"user","createdAt":5}"#)
        #expect(message.blocks.isEmpty && message.status == .complete)
        let memory = try JSONCoding.decode(MemoryItem.self, from: #"{"id":"\#(UUID().uuidString)","content":"x","createdAt":5}"#)
        #expect(memory.isEnabled && memory.source == .user)
    }

    @Test("token usage adds up and reports totals")
    func usageArithmetic() {
        let total = TokenUsage(input: 1, output: 2, cacheCreation: 3, cacheRead: 4) + TokenUsage(input: 10, output: 20)
        #expect(total == TokenUsage(input: 11, output: 22, cacheCreation: 3, cacheRead: 4))
        #expect(total.totalInput == 18 && total.total == 40)
        #expect(TokenUsage.zero.isEmpty)
    }

    @Test("API keys live under a per-provider secret key")
    func secretKeys() {
        #expect(ProviderID.anthropic.apiKeySecret.account == "intelligence.provider.anthropic.apiKey")
        #expect(ProviderID("ollama").apiKeySecret.account == "intelligence.provider.ollama.apiKey")
    }
}
