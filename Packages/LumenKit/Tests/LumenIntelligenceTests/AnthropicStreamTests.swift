import Foundation
import Testing
import LumenFoundation
@testable import LumenIntelligence

@Suite("Anthropic stream decoding")
struct AnthropicStreamTests {
    /// A recorded-shape stream: thinking (signature only), two text deltas, a tool call whose input
    /// arrives in fragments, a ping, and usage split between message_start and message_delta.
    static let toolStream = Chunking.sse([
        ("message_start", #"{"type":"message_start","message":{"id":"msg_01","type":"message","role":"assistant","model":"claude-opus-5-5","content":[],"stop_reason":null,"usage":{"input_tokens":412,"cache_creation_input_tokens":0,"cache_read_input_tokens":2048,"output_tokens":1}}}"#),
        ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"EqQBCgIYAhIM"}}"#),
        ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
        ("ping", #"{"type": "ping"}"#),
        ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Adding that "}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"— ✅ done."}}"#),
        ("content_block_stop", #"{"type":"content_block_stop","index":1}"#),
        ("content_block_start", #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_01","name":"create_task","input":{}}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":""}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"title\": \"Bu"}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"y milk\", \"due"}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"\": \"2026-11-22\"}"}}"#),
        ("content_block_stop", #"{"type":"content_block_stop","index":2}"#),
        ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":87}}"#),
        ("message_stop", #"{"type":"message_stop"}"#),
    ])

    static let expectedToolEvents: [CompletionEvent] = [
        .usage(TokenUsage(input: 412, output: 1, cacheCreation: 0, cacheRead: 2048)),
        .thinking(text: "", signature: "EqQBCgIYAhIM"),
        .textDelta("Adding that "),
        .textDelta("— ✅ done."),
        .toolUse(id: "toolu_01", name: "create_task", input: ["title": "Buy milk", "due": "2026-11-22"]),
        .usage(TokenUsage(input: 412, output: 87, cacheCreation: 0, cacheRead: 2048)),
        .stop(.toolUse),
    ]

    @Test("decodes text, reasoning, fragmented tool input and usage across awkward chunk boundaries", arguments: [[1], [3, 1, 4, 1, 5], [17, 2, 64], [100_000]])
    func toolStream(sizes: [Int]) async throws {
        let transport = FakeTransport([.init(chunks: Chunking.split(Self.toolStream, sizes: sizes))])
        let events = try await ProviderFixtures.collect(ProviderFixtures.anthropic(transport).stream(ProviderFixtures.simpleRequest))
        #expect(events == Self.expectedToolEvents)
    }

    @Test("CRLF-framed streams decode identically")
    func crlfFraming() async throws {
        let stream = Self.toolStream.replacingOccurrences(of: "\n", with: "\r\n")
        let transport = FakeTransport([.init(chunks: Chunking.split(stream))])
        let events = try await ProviderFixtures.collect(ProviderFixtures.anthropic(transport).stream(ProviderFixtures.simpleRequest))
        #expect(events == Self.expectedToolEvents)
    }

    func decode(_ events: [(String, String)]) throws -> [CompletionEvent] {
        var decoder = AnthropicStreamDecoder()
        var output: [CompletionEvent] = []
        for (type, data) in events {
            output += try decoder.decode(SSEEvent(event: type, data: data))
        }
        output += try decoder.finish()
        return output
    }

    @Test("maps every stop reason", arguments: [
        ("end_turn", StopReason.endTurn), ("tool_use", .toolUse), ("max_tokens", .maxTokens),
        ("stop_sequence", .stopSequence), ("refusal", .refusal), ("model_context_window_exceeded", .maxTokens),
        ("pause_turn", .other("pause_turn")),
    ])
    func stopReasons(raw: String, expected: StopReason) throws {
        let events = try decode([
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"\#(raw)"},"usage":{"output_tokens":3}}"#),
            ("message_stop", #"{"type":"message_stop"}"#),
        ])
        #expect(events.last == .stop(expected))
    }

    @Test("an error event mid-stream throws the classified error after the text already received")
    func errorEvent() async {
        let stream = Chunking.sse([
            ("message_start", #"{"type":"message_start","message":{"usage":{"input_tokens":5,"output_tokens":1}}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Partial"}}"#),
            ("error", #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#),
        ])
        let transport = FakeTransport([.init(chunks: Chunking.split(stream))])
        let (events, error) = await ProviderFixtures.collectUntilFailure(ProviderFixtures.anthropic(transport).stream(ProviderFixtures.simpleRequest))
        #expect(events.contains(.textDelta("Partial")))
        #expect(error as? ProviderError == .overloaded(retryAfter: nil))
    }

    @Test("full reasoning text and redacted reasoning blocks are emitted when their block stops")
    func reasoningBlocks() throws {
        let events = try decode([
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Consider "}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"the list."}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig-1"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"redacted_thinking","data":"opaque=="}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":1}"#),
            ("message_stop", #"{"type":"message_stop"}"#),
        ])
        #expect(events == [.thinking(text: "Consider the list.", signature: "sig-1"), .redactedThinking(data: "opaque=="), .stop(.endTurn)])
    }

    @Test("tool input that is not a JSON object becomes an invalid tool call")
    func invalidToolInput() throws {
        let events = try decode([
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_9","name":"create_task","input":{}}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"title\": \"Unfinish"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":9}}"#),
            ("message_stop", #"{"type":"message_stop"}"#),
        ])
        #expect(events.first == .invalidToolUse(id: "toolu_9", name: "create_task", rawInput: #"{"title": "Unfinish"#))
        #expect(events.last == .stop(.maxTokens))
    }

    @Test("a tool call without input fragments uses the input from its start event")
    func emptyToolInput() throws {
        let events = try decode([
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_2","name":"list_tasks","input":{}}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            ("message_stop", #"{"type":"message_stop"}"#),
        ])
        #expect(events.first == .toolUse(id: "toolu_2", name: "list_tasks", input: .object([:])))
    }

    @Test("unknown event, block and delta types are ignored")
    func forwardCompatibility() throws {
        let events = try decode([
            ("future_event", #"{"type":"future_event","x":1}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"srv_1"}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"citations_delta"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            ("message_stop", #"{"type":"message_stop"}"#),
        ])
        #expect(events == [.stop(.endTurn)])
    }

    @Test("a stream that ends before message_stop is reported as interrupted")
    func truncatedStream() async {
        let stream = Chunking.sse([
            ("message_start", #"{"type":"message_start","message":{"usage":{"input_tokens":5,"output_tokens":1}}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
        ])
        let transport = FakeTransport([.init(chunks: [Data(stream.utf8)])])
        let (_, error) = await ProviderFixtures.collectUntilFailure(ProviderFixtures.anthropic(transport).stream(ProviderFixtures.simpleRequest))
        #expect(error as? ProviderError == .network("The response ended before it was complete."))
    }

    @Test("malformed event data is an invalid response")
    func malformedData() {
        var decoder = AnthropicStreamDecoder()
        #expect(throws: ProviderError.invalidResponse("The provider sent a malformed stream event.")) {
            try decoder.decode(SSEEvent(event: "message_start", data: "{not json"))
        }
    }

    @Test("HTTP errors are classified from status, body and retry-after")
    func httpErrors() async {
        let body = Data(#"{"type":"error","error":{"type":"rate_limit_error","message":"Number of request tokens has exceeded your per-minute rate limit"},"request_id":"req_1"}"#.utf8)
        let transport = FakeTransport([
            .init(status: 429, headers: ["Retry-After": "12"], chunks: [body]),
            .init(status: 401, chunks: [Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8)]),
            .init(status: 529, chunks: [Data(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#.utf8)]),
        ])
        let provider = ProviderFixtures.anthropic(transport)
        let first = await ProviderFixtures.collectUntilFailure(provider.stream(ProviderFixtures.simpleRequest)).1
        let second = await ProviderFixtures.collectUntilFailure(provider.stream(ProviderFixtures.simpleRequest)).1
        let third = await ProviderFixtures.collectUntilFailure(provider.stream(ProviderFixtures.simpleRequest)).1
        #expect(first as? ProviderError == .rateLimited(retryAfter: 12))
        #expect(second as? ProviderError == .unauthorized)
        #expect(third as? ProviderError == .overloaded(retryAfter: nil))
    }

    @Test("a missing API key fails before any request is sent")
    func missingKey() async {
        let transport = FakeTransport()
        let provider = ProviderFixtures.anthropic(transport, secrets: ProviderFixtures.secrets([:]))
        let (_, error) = await ProviderFixtures.collectUntilFailure(provider.stream(ProviderFixtures.simpleRequest))
        #expect(error as? ProviderError == .missingAPIKey(provider: "Anthropic"))
        #expect(transport.requests.isEmpty)
    }

    static let hangingStart = Chunking.sse([
        ("message_start", #"{"type":"message_start","message":{"usage":{"input_tokens":5,"output_tokens":1}}}"#),
        ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}"#),
    ])

    func waitForCancellation(_ transport: FakeTransport) async throws {
        let deadline = Date().addingTimeInterval(2)
        while transport.cancelledBodies == 0 && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @Test("a consumer that stops iterating cancels the HTTP body stream")
    func stopIterating() async throws {
        let transport = FakeTransport([.init(chunks: [Data(Self.hangingStart.utf8)], hangs: true)])
        let provider = ProviderFixtures.anthropic(transport)
        for try await event in provider.stream(ProviderFixtures.simpleRequest) {
            if case .textDelta = event { break }
        }
        try await waitForCancellation(transport)
        #expect(transport.cancelledBodies == 1)
    }

    @Test("cancelling the consuming task cancels the HTTP body stream")
    func cancelConsumer() async throws {
        let transport = FakeTransport([.init(chunks: [Data(Self.hangingStart.utf8)], hangs: true)])
        let provider = ProviderFixtures.anthropic(transport)
        let consumer = Task {
            var received: [CompletionEvent] = []
            for try await event in provider.stream(ProviderFixtures.simpleRequest) {
                received.append(event)
            }
            return received
        }
        let deadline = Date().addingTimeInterval(2)
        while transport.requests.isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        consumer.cancel()
        try await waitForCancellation(transport)
        #expect(transport.cancelledBodies == 1)
        _ = await consumer.result
    }
}
