import Foundation
import LumenFoundation
import LumenCore

/// Claude models through the Anthropic Messages API, streamed over server-sent events.
///
/// Requests go to `{baseURL}/v1/messages` with `x-api-key` (read from the `SecretStore` on every
/// request, so a newly saved key applies immediately) and `anthropic-version`. Model lists come
/// from `GET {baseURL}/v1/models`; when listing fails for a transient reason the documented
/// `fallbackModels` are returned instead.
public struct AnthropicProvider: ModelProvider {
    public struct Configuration: Sendable, Hashable {
        public var id: ProviderID
        public var displayName: String
        public var baseURL: URL
        /// The `anthropic-version` header.
        public var apiVersion: String
        /// Stream tool inputs as generated. Defaults to on only for the official endpoint: a proxy
        /// in front of the API may reject the field.
        public var eagerInputStreaming: Bool
        /// Automatic prompt caching (top-level `cache_control`).
        public var promptCaching: Bool
        /// Idle timeout for requests, in seconds.
        public var requestTimeout: TimeInterval
        /// Returned by `availableModels()` when the listing endpoint is unavailable.
        public var fallbackModels: [ModelDescriptor]

        public init(
            id: ProviderID = .anthropic,
            displayName: String = "Anthropic",
            baseURL: URL = AnthropicProvider.defaultBaseURL,
            apiVersion: String = AnthropicProvider.defaultAPIVersion,
            eagerInputStreaming: Bool? = nil,
            promptCaching: Bool = true,
            requestTimeout: TimeInterval = 300,
            fallbackModels: [ModelDescriptor]? = nil
        ) {
            self.id = id
            self.displayName = displayName
            self.baseURL = baseURL
            self.apiVersion = apiVersion
            self.eagerInputStreaming = eagerInputStreaming ?? (baseURL == AnthropicProvider.defaultBaseURL)
            self.promptCaching = promptCaching
            self.requestTimeout = requestTimeout
            self.fallbackModels = fallbackModels ?? AnthropicProvider.fallbackModels(providerID: id)
        }
    }

    /// The literal is a valid URL; the file-URL fallback only keeps this total without a force unwrap.
    public static let defaultBaseURL = URL(string: "https://api.anthropic.com") ?? URL(fileURLWithPath: "/")

    /// The current Messages API version (it removed sampling parameters; see `AnthropicWire`).
    public static let defaultAPIVersion = "2026-10-21"

    /// Models offered when `/v1/models` cannot be reached: the current Opus, Sonnet and Haiku
    /// (1M-token context, 128K output each), per Anthropic's model catalog as of November 2026.
    public static func fallbackModels(providerID: ProviderID = .anthropic) -> [ModelDescriptor] {
        [
            ModelDescriptor(id: "claude-opus-5-5", displayName: "Claude Opus 5.5", providerID: providerID, contextWindow: 1_000_000, maxOutputTokens: 128_000),
            ModelDescriptor(id: "claude-sonnet-5-5", displayName: "Claude Sonnet 5.5", providerID: providerID, contextWindow: 1_000_000, maxOutputTokens: 128_000),
            ModelDescriptor(id: "claude-haiku-5-5", displayName: "Claude Haiku 5.5", providerID: providerID, contextWindow: 1_000_000, maxOutputTokens: 128_000),
        ]
    }

    public let configuration: Configuration
    private let transport: any HTTPStreamingTransport
    private let secrets: any SecretStore
    private let timeSource: any TimeSource
    private let logger: Logger

    public init(
        configuration: Configuration = Configuration(),
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
    public var requiresAPIKey: Bool { true }

    // MARK: - Completion

    public func stream(_ request: CompletionRequest) -> AsyncThrowingStream<CompletionEvent, any Error> {
        let provider = self
        return CompletionStreaming.stream(transport: transport, timeSource: timeSource, decoder: AnthropicStreamDecoder()) {
            try provider.completionRequest(for: request)
        }
    }

    /// The HTTP request for a completion. Internal for request-encoding tests.
    func completionRequest(for request: CompletionRequest) throws -> HTTPRequest {
        let key = try apiKey()
        let body = AnthropicWire.body(for: request, options: .init(
            eagerInputStreaming: configuration.eagerInputStreaming,
            promptCaching: configuration.promptCaching
        ))
        var headers = baseHeaders(key: key)
        headers["content-type"] = "application/json"
        headers["accept"] = "text/event-stream"
        return HTTPRequest(
            method: "POST",
            url: CompletionStreaming.endpoint(configuration.baseURL, "v1/messages"),
            headers: headers,
            body: try JSONCoding.encoder.encode(body),
            timeout: configuration.requestTimeout
        )
    }

    // MARK: - Models

    public func availableModels() async throws -> [ModelDescriptor] {
        let key = try apiKey()
        do {
            return try await listModels(key: key)
        } catch let error as ProviderError {
            switch error {
            case .network, .server, .overloaded, .rateLimited, .invalidResponse:
                logger.warning("Model listing failed; using the built-in model list", metadata: ["provider": id.rawValue, "error": error.kind])
                return configuration.fallbackModels
            default:
                throw error
            }
        }
    }

    private func listModels(key: String) async throws -> [ModelDescriptor] {
        var models: [ModelDescriptor] = []
        var afterID: String?
        // The catalog is small; the page cap only guards against a misbehaving `has_more`.
        for _ in 0..<20 {
            let base = CompletionStreaming.endpoint(configuration.baseURL, "v1/models")
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
            var query = [URLQueryItem(name: "limit", value: "100")]
            if let afterID {
                query.append(URLQueryItem(name: "after_id", value: afterID))
            }
            components?.queryItems = query
            let url = components?.url ?? base
            var headers = baseHeaders(key: key)
            headers["accept"] = "application/json"
            let page = try await transport.fetchJSON(HTTPRequest(url: url, headers: headers, timeout: 30), now: timeSource.now())
            guard let entries = page["data"]?.arrayValue else {
                throw ProviderError.invalidResponse("The model list was not in the expected format.")
            }
            for entry in entries {
                guard let modelID = entry["id"]?.stringValue else { continue }
                models.append(ModelDescriptor(
                    id: modelID,
                    displayName: entry["display_name"]?.stringValue ?? modelID,
                    providerID: id,
                    contextWindow: entry["max_input_tokens"]?.intValue,
                    maxOutputTokens: entry["max_tokens"]?.intValue,
                    supportsTools: true
                ))
            }
            guard page["has_more"]?.boolValue == true, let last = page["last_id"]?.stringValue else { break }
            afterID = last
        }
        return models
    }

    // MARK: - Helpers

    private func baseHeaders(key: String) -> HTTPHeaders {
        [
            "x-api-key": key,
            "anthropic-version": configuration.apiVersion,
        ]
    }

    private func apiKey() throws -> String {
        guard let key = try secrets.secret(for: id.apiKeySecret)?.nonBlank else {
            throw ProviderError.missingAPIKey(provider: displayName)
        }
        return key
    }
}
