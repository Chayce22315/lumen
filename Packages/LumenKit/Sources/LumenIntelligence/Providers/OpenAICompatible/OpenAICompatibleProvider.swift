import Foundation
import LumenFoundation
import LumenCore

/// Any server speaking the Chat Completions API: OpenAI itself, or local servers such as Ollama
/// (`http://localhost:11434/v1`) and LM Studio (`http://localhost:1234/v1`).
///
/// Streams `POST {baseURL}/chat/completions` with `stream: true`; lists models with
/// `GET {baseURL}/models`. The API key (read from the `SecretStore` per request) is sent as
/// `Authorization: Bearer` when present and required only when `requiresAPIKey` is set.
public struct OpenAICompatibleProvider: ModelProvider {
    /// Which body field carries the output limit. OpenAI's current models take
    /// `max_completion_tokens`; most local servers take the older `max_tokens`.
    public enum MaxTokensField: String, Sendable, Hashable {
        case maxTokens = "max_tokens"
        case maxCompletionTokens = "max_completion_tokens"
    }

    public struct Configuration: Sendable, Hashable {
        public var id: ProviderID
        public var displayName: String
        /// The API root including its version path, e.g. `https://api.openai.com/v1`.
        public var baseURL: URL
        public var requiresAPIKey: Bool
        public var maxTokensField: MaxTokensField
        /// Sends `stream_options.include_usage` so the stream ends with token counts.
        public var includeUsageInStream: Bool
        /// Applied to listed models, which this API lists without limits.
        public var defaultContextWindow: Int?
        public var defaultMaxOutputTokens: Int?
        /// Whether listed models are offered tools.
        public var assumesToolSupport: Bool
        /// Listed model ids containing any of these (case-insensitive) are hidden — e.g. embedding
        /// or speech models that cannot chat.
        public var excludedModelSubstrings: [String]
        public var requestTimeout: TimeInterval

        public init(
            id: ProviderID,
            displayName: String,
            baseURL: URL,
            requiresAPIKey: Bool,
            maxTokensField: MaxTokensField = .maxTokens,
            includeUsageInStream: Bool = true,
            defaultContextWindow: Int? = nil,
            defaultMaxOutputTokens: Int? = nil,
            assumesToolSupport: Bool = true,
            excludedModelSubstrings: [String] = [],
            requestTimeout: TimeInterval = 300
        ) {
            self.id = id
            self.displayName = displayName
            self.baseURL = baseURL
            self.requiresAPIKey = requiresAPIKey
            self.maxTokensField = maxTokensField
            self.includeUsageInStream = includeUsageInStream
            self.defaultContextWindow = defaultContextWindow
            self.defaultMaxOutputTokens = defaultMaxOutputTokens
            self.assumesToolSupport = assumesToolSupport
            self.excludedModelSubstrings = excludedModelSubstrings
            self.requestTimeout = requestTimeout
        }

        /// The literal is a valid URL; the file-URL fallback only keeps this total without a force unwrap.
        public static let openAIBaseURL = URL(string: "https://api.openai.com/v1") ?? URL(fileURLWithPath: "/")

        /// OpenAI's hosted API. Non-chat model families are hidden from the list.
        public static let openAI = Configuration(
            id: .openAI,
            displayName: "OpenAI",
            baseURL: openAIBaseURL,
            requiresAPIKey: true,
            maxTokensField: .maxCompletionTokens,
            defaultContextWindow: 128_000,
            defaultMaxOutputTokens: 16_384,
            excludedModelSubstrings: ["embedding", "tts", "whisper", "dall-e", "moderation", "transcribe", "realtime", "audio", "image", "search", "davinci", "babbage"]
        )

        /// A local server that needs no key. Context limits are conservative because local models
        /// are often loaded with small windows; raise them for models known to be larger.
        public static func local(
            id: ProviderID,
            displayName: String,
            baseURL: URL,
            contextWindow: Int = 8_192,
            maxOutputTokens: Int = 2_048
        ) -> Configuration {
            Configuration(
                id: id,
                displayName: displayName,
                baseURL: baseURL,
                requiresAPIKey: false,
                maxTokensField: .maxTokens,
                defaultContextWindow: contextWindow,
                defaultMaxOutputTokens: maxOutputTokens
            )
        }
    }

    public let configuration: Configuration
    private let transport: any HTTPStreamingTransport
    private let secrets: any SecretStore
    private let timeSource: any TimeSource
    private let logger: Logger

    public init(
        configuration: Configuration,
        transport: any HTTPStreamingTransport,
        secrets: any SecretStore,
        timeSource: any TimeSource,
        logger: Logger = .disabled()
    ) {
        self.configuration = configuration
        self.transport = transport
        self.secrets = secrets
        self.timeSource = timeSource
        self.logger = logger
    }

    public var id: ProviderID { configuration.id }
    public var displayName: String { configuration.displayName }
    public var requiresAPIKey: Bool { configuration.requiresAPIKey }

    public func stream(_ request: CompletionRequest) -> AsyncThrowingStream<CompletionEvent, any Error> {
        let provider = self
        return CompletionStreaming.stream(transport: transport, timeSource: timeSource, decoder: OpenAICompatibleStreamDecoder()) {
            try provider.completionRequest(for: request)
        }
    }

    /// The HTTP request for a completion. Internal for request-encoding tests.
    func completionRequest(for request: CompletionRequest) throws -> HTTPRequest {
        let body = OpenAICompatibleWire.body(for: request, options: .init(
            maxTokensField: configuration.maxTokensField,
            includeUsage: configuration.includeUsageInStream
        ))
        var headers = try authorizationHeaders()
        headers["content-type"] = "application/json"
        headers["accept"] = "text/event-stream"
        return HTTPRequest(
            method: "POST",
            url: CompletionStreaming.endpoint(configuration.baseURL, "chat/completions"),
            headers: headers,
            body: try JSONCoding.encoder.encode(body),
            timeout: configuration.requestTimeout
        )
    }

    public func availableModels() async throws -> [ModelDescriptor] {
        var headers = try authorizationHeaders()
        headers["accept"] = "application/json"
        let request = HTTPRequest(url: CompletionStreaming.endpoint(configuration.baseURL, "models"), headers: headers, timeout: 30)
        let list = try await transport.fetchJSON(request, now: timeSource.now())
        guard let entries = list["data"]?.arrayValue else {
            throw ProviderError.invalidResponse("The model list was not in the expected format.")
        }
        let excluded = configuration.excludedModelSubstrings.map { $0.lowercased() }
        let models = entries.compactMap { entry -> ModelDescriptor? in
            guard let modelID = entry["id"]?.stringValue else { return nil }
            let lowered = modelID.lowercased()
            guard !excluded.contains(where: { lowered.contains($0) }) else { return nil }
            return ModelDescriptor(
                id: modelID,
                displayName: modelID,
                providerID: id,
                contextWindow: configuration.defaultContextWindow,
                maxOutputTokens: configuration.defaultMaxOutputTokens,
                supportsTools: configuration.assumesToolSupport
            )
        }
        logger.debug("Listed models", metadata: ["provider": id.rawValue, "count": String(models.count)])
        return models.sorted { $0.id < $1.id }
    }

    private func authorizationHeaders() throws -> HTTPHeaders {
        let key = try secrets.secret(for: id.apiKeySecret)?.nonBlank
        if configuration.requiresAPIKey && key == nil {
            throw ProviderError.missingAPIKey(provider: displayName)
        }
        var headers: HTTPHeaders = [:]
        if let key {
            headers["authorization"] = "Bearer \(key)"
        }
        return headers
    }
}
