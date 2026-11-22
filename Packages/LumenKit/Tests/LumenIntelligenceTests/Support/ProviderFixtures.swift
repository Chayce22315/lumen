import Foundation
import LumenCore
import LumenTestSupport
@testable import LumenIntelligence

enum ProviderFixtures {
    static let anthropicKey = "sk-ant-test-key"
    static let openAIKey = "sk-openai-test-key"

    static func secrets(_ entries: [ProviderID: String] = [.anthropic: anthropicKey, .openAI: openAIKey]) -> InMemorySecretStore {
        InMemorySecretStore(Dictionary(uniqueKeysWithValues: entries.map { ($0.key.apiKeySecret, $0.value) }))
    }

    static func anthropic(
        _ transport: FakeTransport,
        configuration: AnthropicProvider.Configuration = .init(),
        secrets: InMemorySecretStore = ProviderFixtures.secrets()
    ) -> AnthropicProvider {
        AnthropicProvider(configuration: configuration, transport: transport, secrets: secrets, timeSource: ManualTimeSource())
    }

    static func openAI(
        _ transport: FakeTransport,
        configuration: OpenAICompatibleProvider.Configuration = .openAI,
        secrets: InMemorySecretStore = ProviderFixtures.secrets()
    ) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(configuration: configuration, transport: transport, secrets: secrets, timeSource: ManualTimeSource())
    }

    static func collect(_ stream: AsyncThrowingStream<CompletionEvent, any Error>) async throws -> [CompletionEvent] {
        var events: [CompletionEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    /// Events received before the stream failed, and the failure.
    static func collectUntilFailure(_ stream: AsyncThrowingStream<CompletionEvent, any Error>) async -> ([CompletionEvent], (any Error)?) {
        var events: [CompletionEvent] = []
        do {
            for try await event in stream {
                events.append(event)
            }
            return (events, nil)
        } catch {
            return (events, error)
        }
    }

    static func url(_ text: String) -> URL {
        URL(string: text) ?? URL(fileURLWithPath: "/invalid")
    }

    static let simpleRequest = CompletionRequest(
        model: "claude-opus-5-5",
        system: "Be brief.",
        messages: [WireMessage(role: .user, blocks: [.text("Hi")])],
        maxTokens: 256
    )
}
