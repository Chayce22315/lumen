import Foundation
import Synchronization
@testable import LumenIntelligence

/// Replays recorded responses. Never touches the network.
final class FakeTransport: HTTPStreamingTransport {
    struct Reply: Sendable {
        var status: Int = 200
        var headers: HTTPHeaders = [:]
        var chunks: [Data] = []
        /// Thrown after the chunks are delivered.
        var error: ProviderError?
        /// When true the body never finishes on its own (until cancelled).
        var hangs = false
    }

    private let replies = Mutex<[Reply]>([])
    private let recorded = Mutex<[HTTPRequest]>([])
    private let cancellations = Mutex(0)

    init(_ replies: [Reply] = []) {
        self.replies.withLock { $0 = replies }
    }

    func enqueue(_ reply: Reply) {
        replies.withLock { $0.append(reply) }
    }

    var requests: [HTTPRequest] { recorded.withLock { $0 } }
    var cancelledBodies: Int { cancellations.withLock { $0 } }

    func send(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
        recorded.withLock { $0.append(request) }
        guard let reply = replies.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) else {
            throw ProviderError.network("No recorded reply left.")
        }
        let (body, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        continuation.onTermination = { [self] termination in
            if case .cancelled = termination {
                cancellations.withLock { $0 += 1 }
            }
        }
        for chunk in reply.chunks {
            continuation.yield(chunk)
        }
        if let error = reply.error {
            continuation.finish(throwing: error)
        } else if !reply.hangs {
            continuation.finish()
        }
        return HTTPStreamResponse(status: reply.status, headers: reply.headers, body: body)
    }
}

enum Chunking {
    /// Splits `text`'s UTF-8 bytes into chunks of the given sizes (cycled), so boundaries land
    /// inside multi-byte characters, inside `\r\n` pairs and inside JSON tokens.
    static func split(_ text: String, sizes: [Int] = [1, 7, 3, 13, 2, 29, 5]) -> [Data] {
        let bytes = Array(text.utf8)
        var chunks: [Data] = []
        var offset = 0
        var turn = 0
        while offset < bytes.count {
            let size = max(1, sizes[turn % sizes.count])
            let end = min(bytes.count, offset + size)
            chunks.append(Data(bytes[offset..<end]))
            offset = end
            turn += 1
        }
        return chunks
    }

    /// An SSE stream from (event, JSON data) pairs.
    static func sse(_ events: [(String?, String)], lineEnding: String = "\n") -> String {
        events.map { event, data in
            var lines: [String] = []
            if let event { lines.append("event: \(event)") }
            lines.append("data: \(data)")
            return lines.joined(separator: lineEnding) + lineEnding + lineEnding
        }.joined()
    }
}
