import Foundation
import Testing
import LumenFoundation
@testable import LumenIntelligence

@Suite("OpenAI-compatible provider")
struct OpenAICompatibleTests {
    /// Two parallel tool calls whose fragments interleave by index, then a usage-only chunk and [DONE].
    static let toolStream = Chunking.sse([
        (nil, #"{"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":"Checking "},"finish_reason":null}]}"#),
        (nil, #"{"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"both…"},"finish_reason":null}]}"#),
        (nil, #"{"id":"c1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"search_notes","arguments":""}}]},"finish_reason":null}]}"#),
        (nil, #"{"id":"c1","choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"call_b","type":"function","function":{"name":"list_tasks","arguments":"{\"du"}}]},"finish_reason":null}]}"#),
        (nil, #"{"id":"c1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"query\":"}}]},"finish_reason":null}]}"#),
        (nil, #"{"id":"c1","choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"function":{"arguments":"e\":\"today\"}"}}]},"finish_reason":null}]}"#),
        (nil, #"{"id":"c1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"trip\"}"}}]},"finish_reason":null}]}"#),
        (nil, #"{"id":"c1","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#),
        (nil, #"{"id":"c1","choices":[],"usage":{"prompt_tokens":120,"completion_tokens":33,"total_tokens":153,"prompt_tokens_details":{"cached_tokens":100}}}"#),
        (nil, "[DONE]"),
    ])

    @Test("accumulates tool calls by index and reports usage and the stop reason", arguments: [[1], [4, 9, 2], [1_000_000]])
    func toolCalls(sizes: [Int]) async throws {
        let transport = FakeTransport([.init(chunks: Chunking.split(Self.toolStream, sizes: sizes))])
        let events = try await ProviderFixtures.collect(ProviderFixtures.openAI(transport).stream(ProviderFixtures.simpleRequest))
        #expect(events == [
            .textDelta("Checking "),
            .textDelta("both…"),
            .toolUse(id: "call_a", name: "search_notes", input: ["query": "trip"]),
            .toolUse(id: "call_b", name: "list_tasks", input: ["due": "today"]),
            .usage(TokenUsage(input: 20, output: 33, cacheRead: 100)),
            .stop(.toolUse),
        ])
    }

    func decode(_ chunks: [String], finish: Bool = true) throws -> [CompletionEvent] {
        var decoder = OpenAICompatibleStreamDecoder()
        var events: [CompletionEvent] = []
        for chunk in chunks {
            events += try decoder.decode(SSEEvent(data: chunk))
        }
        if finish {
            events += try decoder.finish()
        }
        return events
    }

    @Test("maps finish reasons", arguments: [
        ("stop", StopReason.endTurn), ("length", .maxTokens), ("tool_calls", .toolUse),
        ("content_filter", .refusal), ("eos", .other("eos")),
    ])
    func finishReasons(raw: String, expected: StopReason) throws {
        let events = try decode([#"{"choices":[{"index":0,"delta":{},"finish_reason":"\#(raw)"}]}"#, "[DONE]"])
        #expect(events == [.stop(expected)])
    }

    @Test("a stream that ends after its finish reason without [DONE] is accepted")
    func missingDone() throws {
        let events = try decode([#"{"choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":"stop"}]}"#])
        #expect(events == [.textDelta("Hi"), .stop(.endTurn)])
    }

    @Test("a stream that ends without a finish reason is interrupted")
    func truncated() {
        #expect(throws: ProviderError.network("The response ended before it was complete.")) {
            try decode([#"{"choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}"#])
        }
    }

    @Test("an error chunk throws the classified error")
    func errorChunk() {
        #expect(throws: ProviderError.rateLimited(retryAfter: nil)) {
            try decode([#"{"error":{"message":"Rate limit reached","type":"requests","code":"rate_limit_exceeded"}}"#], finish: false)
        }
    }

    @Test("malformed tool arguments become an invalid tool call; missing ids are synthesized")
    func malformedArguments() throws {
        let events = try decode([
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"name":"create_task","arguments":"{\"title\": "}}]},"finish_reason":"tool_calls"}]}"#,
            "[DONE]",
        ])
        #expect(events == [.invalidToolUse(id: "call_0", name: "create_task", rawInput: #"{"title": "#), .stop(.toolUse)])
    }

    static let transcriptRequest = CompletionRequest(
        model: "gpt-5",
        system: "Be brief.",
        messages: [
            WireMessage(role: .user, blocks: [.text("Find my trip notes")]),
            WireMessage(role: .assistant, blocks: [
                .thinking(text: "", signature: "anthropic-only"),
                .toolUse(id: "call_a", name: "search_notes", input: ["query": "trip"]),
            ]),
            WireMessage(role: .user, blocks: [
                .toolResult(toolUseID: "call_a", content: "Index unavailable", isError: true),
                .text("Also check tasks"),
            ]),
        ],
        tools: [ToolDefinition(name: "search_notes", description: "Search notes", inputSchema: ["type": "object", "properties": ["query": ["type": "string"]]])],
        maxTokens: 2048,
        temperature: 0.5
    )

    @Test("encodes the exact Chat Completions body: system message, tool calls, tool messages, usage option")
    func exactBody() throws {
        let request = try ProviderFixtures.openAI(FakeTransport()).completionRequest(for: Self.transcriptRequest)
        let expected = #"{"max_completion_tokens":2048,"messages":[{"content":"Be brief.","role":"system"},{"content":"Find my trip notes","role":"user"},{"content":null,"role":"assistant","tool_calls":[{"function":{"arguments":"{\"query\":\"trip\"}","name":"search_notes"},"id":"call_a","type":"function"}]},{"content":"Error: Index unavailable","role":"tool","tool_call_id":"call_a"},{"content":"Also check tasks","role":"user"}],"model":"gpt-5","stream":true,"stream_options":{"include_usage":true},"temperature":0.5,"tools":[{"function":{"description":"Search notes","name":"search_notes","parameters":{"properties":{"query":{"type":"string"}},"type":"object"}},"type":"function"}]}"#
        #expect(request.bodyText == expected)
        #expect(request.url.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(request.headers["authorization"] == "Bearer \(ProviderFixtures.openAIKey)")
        #expect(request.headers["content-type"] == "application/json")
    }

    @Test("a local server needs no key, uses max_tokens and its own base URL")
    func localServer() throws {
        let configuration = OpenAICompatibleProvider.Configuration.local(id: "ollama", displayName: "Ollama", baseURL: ProviderFixtures.url("http://localhost:11434/v1"))
        let provider = ProviderFixtures.openAI(FakeTransport(), configuration: configuration, secrets: ProviderFixtures.secrets([:]))
        #expect(!provider.requiresAPIKey)
        let request = try provider.completionRequest(for: ProviderFixtures.simpleRequest)
        #expect(request.url.absoluteString == "http://localhost:11434/v1/chat/completions")
        #expect(request.headers["authorization"] == nil)
        let body = try JSONValue(parsing: try #require(request.bodyText))
        #expect(body["max_tokens"] == 256)
        #expect(body["max_completion_tokens"] == nil)
    }

    @Test("OpenAI requires a key")
    func missingKey() {
        let provider = ProviderFixtures.openAI(FakeTransport(), secrets: ProviderFixtures.secrets([:]))
        #expect(throws: ProviderError.missingAPIKey(provider: "OpenAI")) {
            try provider.completionRequest(for: ProviderFixtures.simpleRequest)
        }
    }

    @Test("lists chat models from /models with configured limits, hiding non-chat models")
    func listModels() async throws {
        let list = #"{"object":"list","data":[{"id":"gpt-5","object":"model","owned_by":"openai"},{"id":"text-embedding-3-large","object":"model"},{"id":"gpt-5-mini","object":"model"},{"id":"whisper-1","object":"model"}]}"#
        let transport = FakeTransport([.init(chunks: Chunking.split(list))])
        let models = try await ProviderFixtures.openAI(transport).availableModels()
        #expect(models.map(\.id) == ["gpt-5", "gpt-5-mini"])
        #expect(models.allSatisfy { $0.contextWindow == 128_000 && $0.maxOutputTokens == 16_384 && $0.providerID == .openAI })
        #expect(transport.requests.first?.url.absoluteString == "https://api.openai.com/v1/models")
    }

    @Test("HTTP errors use the OpenAI error document, including exhausted quota on 429")
    func httpErrors() async {
        let quota = Data(#"{"error":{"message":"You exceeded your current quota","type":"insufficient_quota","code":"insufficient_quota"}}"#.utf8)
        let transport = FakeTransport([
            .init(status: 429, headers: ["retry-after-ms": "1500"], chunks: [Data(#"{"error":{"message":"slow down","code":"rate_limit_exceeded"}}"#.utf8)]),
            .init(status: 429, chunks: [quota]),
        ])
        let provider = ProviderFixtures.openAI(transport)
        let first = await ProviderFixtures.collectUntilFailure(provider.stream(ProviderFixtures.simpleRequest)).1
        let second = await ProviderFixtures.collectUntilFailure(provider.stream(ProviderFixtures.simpleRequest)).1
        #expect(first as? ProviderError == .rateLimited(retryAfter: 1.5))
        #expect(second as? ProviderError == .quotaExceeded("You exceeded your current quota"))
    }
}
