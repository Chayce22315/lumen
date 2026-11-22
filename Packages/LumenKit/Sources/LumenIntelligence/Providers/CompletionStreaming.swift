import Foundation
import LumenFoundation

/// Converts a provider's server-sent events into `CompletionEvent`s.
protocol CompletionStreamDecoder: Sendable {
    mutating func decode(_ event: SSEEvent) throws -> [CompletionEvent]
    /// Called once the byte stream ends; throws when the stream was cut short.
    mutating func finish() throws -> [CompletionEvent]
}

/// The request → SSE → events pipeline shared by the streaming providers.
enum CompletionStreaming {
    /// Error bodies larger than this are not read further.
    static let errorBodyLimit = 1024 * 1024

    static func stream<Decoder: CompletionStreamDecoder>(
        transport: any HTTPStreamingTransport,
        timeSource: any TimeSource,
        decoder: Decoder,
        makeRequest: @escaping @Sendable () throws -> HTTPRequest
    ) -> AsyncThrowingStream<CompletionEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest()
                    let response = try await transport.send(request)
                    guard response.isSuccess else {
                        let body = try await response.collectBody(limit: errorBodyLimit)
                        throw ProviderError.fromHTTP(status: response.status, headers: response.headers, body: body, now: timeSource.now())
                    }
                    var parser = SSEParser()
                    var decoder = decoder
                    for try await chunk in response.body {
                        for event in parser.feed(chunk) {
                            for output in try decoder.decode(event) {
                                continuation.yield(output)
                            }
                        }
                    }
                    // A cancelled body stream ends early; report cancellation, not truncation.
                    try Task.checkCancellation()
                    for event in parser.finish() {
                        for output in try decoder.decode(event) {
                            continuation.yield(output)
                        }
                    }
                    for output in try decoder.finish() {
                        continuation.yield(output)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// `base` with `path` appended (`https://host/prefix` + `v1/messages`).
    static func endpoint(_ base: URL, _ path: String) -> URL {
        path.split(separator: "/").reduce(base) { url, component in
            url.appendingPathComponent(String(component))
        }
    }
}
