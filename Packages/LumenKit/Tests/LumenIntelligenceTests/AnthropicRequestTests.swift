import Foundation
import Testing
import LumenFoundation
@testable import LumenIntelligence

@Suite("Anthropic requests and models")
struct AnthropicRequestTests {
    static let createTask = ToolDefinition(
        name: "create_task",
        description: "Create a task",
        inputSchema: ["type": "object", "properties": ["title": ["type": "string"]], "required": ["title"]]
    )

    static let transcriptRequest = CompletionRequest(
        model: "claude-opus-5-5",
        system: "Be brief.",
        messages: [
            WireMessage(role: .user, blocks: [.text("Add milk to my list")]),
            WireMessage(role: .assistant, blocks: [
                .thinking(text: "", signature: "sig"),
                .text("Adding it."),
                .toolUse(id: "toolu_1", name: "create_task", input: ["title": "Buy milk"]),
            ]),
            WireMessage(role: .user, blocks: [.toolResult(toolUseID: "toolu_1", content: "List is read-only", isError: true)]),
        ],
        tools: [createTask],
        maxTokens: 1024,
        temperature: 0.3
    )

    @Test("encodes the exact Messages API body: blocks, tools, caching, and no sampling parameters")
    func exactBody() throws {
        let request = try ProviderFixtures.anthropic(FakeTransport()).completionRequest(for: Self.transcriptRequest)
        let expected = #"{"cache_control":{"type":"ephemeral"},"max_tokens":1024,"messages":[{"content":[{"text":"Add milk to my list","type":"text"}],"role":"user"},{"content":[{"signature":"sig","thinking":"","type":"thinking"},{"text":"Adding it.","type":"text"},{"id":"toolu_1","input":{"title":"Buy milk"},"name":"create_task","type":"tool_use"}],"role":"assistant"},{"content":[{"content":"List is read-only","is_error":true,"tool_use_id":"toolu_1","type":"tool_result"}],"role":"user"}],"model":"claude-opus-5-5","stream":true,"system":"Be brief.","tools":[{"description":"Create a task","eager_input_streaming":true,"input_schema":{"properties":{"title":{"type":"string"}},"required":["title"],"type":"object"},"name":"create_task"}]}"#
        #expect(request.bodyText == expected)
    }

    @Test("sends the API key, version header and streaming headers to /v1/messages")
    func headers() throws {
        let request = try ProviderFixtures.anthropic(FakeTransport()).completionRequest(for: ProviderFixtures.simpleRequest)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.headers["x-api-key"] == ProviderFixtures.anthropicKey)
        #expect(request.headers["anthropic-version"] == "2026-10-21")
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.headers["accept"] == "text/event-stream")
        #expect(request.headers["authorization"] == nil)
    }

    @Test("tool_choice none keeps the tools declared; successful results omit is_error")
    func toolChoiceNone() throws {
        var completion = Self.transcriptRequest
        completion.toolChoice = .none
        completion.messages[2] = WireMessage(role: .user, blocks: [.toolResult(toolUseID: "toolu_1", content: "Created", isError: false)])
        let body = try JSONValue(parsing: try #require(try ProviderFixtures.anthropic(FakeTransport()).completionRequest(for: completion).bodyText))
        #expect(body["tool_choice"] == ["type": "none"])
        #expect(body["tools"]?[0]?["name"] == "create_task")
        #expect(body["messages"]?[2]?["content"]?[0] == ["type": "tool_result", "tool_use_id": "toolu_1", "content": "Created"])
        #expect(body["temperature"] == nil)
    }

    @Test("a custom base URL keeps its path and turns eager input streaming off by default")
    func customBaseURL() throws {
        let configuration = AnthropicProvider.Configuration(baseURL: ProviderFixtures.url("https://gateway.example.com/anthropic"), promptCaching: false)
        let request = try ProviderFixtures.anthropic(FakeTransport(), configuration: configuration).completionRequest(for: Self.transcriptRequest)
        #expect(request.url.absoluteString == "https://gateway.example.com/anthropic/v1/messages")
        let body = try JSONValue(parsing: try #require(request.bodyText))
        #expect(body["tools"]?[0]?["eager_input_streaming"] == nil)
        #expect(body["cache_control"] == nil)
    }

    @Test("the request description never contains the API key")
    func redaction() throws {
        let request = try ProviderFixtures.anthropic(FakeTransport()).completionRequest(for: ProviderFixtures.simpleRequest)
        #expect(!String(describing: request).contains(ProviderFixtures.anthropicKey))
        #expect(String(describing: request.headers).contains("x-api-key: <redacted>"))
    }

    @Test("lists models across pages from /v1/models")
    func listModels() async throws {
        let page1 = #"{"data":[{"type":"model","id":"claude-opus-5-5","display_name":"Claude Opus 5.5","created_at":"2026-09-01T00:00:00Z","max_input_tokens":1000000,"max_tokens":128000}],"has_more":true,"first_id":"claude-opus-5-5","last_id":"claude-opus-5-5"}"#
        let page2 = #"{"data":[{"type":"model","id":"claude-haiku-5-5","display_name":"Claude Haiku 5.5","max_input_tokens":1000000,"max_tokens":128000}],"has_more":false,"first_id":"claude-haiku-5-5","last_id":"claude-haiku-5-5"}"#
        let transport = FakeTransport([.init(chunks: Chunking.split(page1)), .init(chunks: [Data(page2.utf8)])])
        let models = try await ProviderFixtures.anthropic(transport).availableModels()
        #expect(models == [
            ModelDescriptor(id: "claude-opus-5-5", displayName: "Claude Opus 5.5", providerID: .anthropic, contextWindow: 1_000_000, maxOutputTokens: 128_000),
            ModelDescriptor(id: "claude-haiku-5-5", displayName: "Claude Haiku 5.5", providerID: .anthropic, contextWindow: 1_000_000, maxOutputTokens: 128_000),
        ])
        let urls = transport.requests.map(\.url.absoluteString)
        #expect(urls == [
            "https://api.anthropic.com/v1/models?limit=100",
            "https://api.anthropic.com/v1/models?limit=100&after_id=claude-opus-5-5",
        ])
        #expect(transport.requests.allSatisfy { $0.headers["x-api-key"] == ProviderFixtures.anthropicKey && $0.headers["anthropic-version"] == "2026-10-21" })
    }

    @Test("falls back to the documented model list when listing fails transiently")
    func listingFallback() async throws {
        let transport = FakeTransport([.init(status: 503, chunks: [Data("Service Unavailable".utf8)])])
        let models = try await ProviderFixtures.anthropic(transport).availableModels()
        #expect(models.map(\.id) == ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"])
        #expect(models.allSatisfy { $0.contextWindow == 1_000_000 && $0.maxOutputTokens == 128_000 && $0.supportsTools })
    }

    @Test("a rejected key is reported instead of falling back")
    func listingUnauthorized() async {
        let transport = FakeTransport([.init(status: 401, chunks: [Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8)])])
        await #expect(throws: ProviderError.unauthorized) {
            try await ProviderFixtures.anthropic(transport).availableModels()
        }
    }
}
