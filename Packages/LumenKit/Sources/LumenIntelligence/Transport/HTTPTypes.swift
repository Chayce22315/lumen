import Foundation

/// HTTP header fields with case-insensitive names. Names are stored lowercased.
///
/// `description` redacts credential headers so a request can never leak a key into a log line or
/// a test failure message by accident.
public struct HTTPHeaders: Sendable, Hashable {
    public private(set) var fields: [String: String]

    public init(_ fields: [String: String] = [:]) {
        var normalized: [String: String] = [:]
        for (name, value) in fields {
            normalized[name.lowercased()] = value
        }
        self.fields = normalized
    }

    public subscript(name: String) -> String? {
        get { fields[name.lowercased()] }
        set { fields[name.lowercased()] = newValue }
    }

    public var isEmpty: Bool { fields.isEmpty }

    static let redactedNames: Set<String> = ["authorization", "x-api-key", "api-key", "proxy-authorization"]
}

extension HTTPHeaders: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, String)...) {
        self.init(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

extension HTTPHeaders: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        let pairs = fields.sorted { $0.key < $1.key }.map { name, value in
            "\(name): \(Self.redactedNames.contains(name) ? "<redacted>" : value)"
        }
        return "[" + pairs.joined(separator: ", ") + "]"
    }

    public var debugDescription: String { description }
}

/// A request handed to an `HTTPStreamingTransport`.
public struct HTTPRequest: Sendable, Hashable {
    public var method: String
    public var url: URL
    public var headers: HTTPHeaders
    public var body: Data?
    /// Maximum idle time between received bytes, in seconds.
    public var timeout: TimeInterval

    public init(method: String = "GET", url: URL, headers: HTTPHeaders = [:], body: Data? = nil, timeout: TimeInterval = 60) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }

    /// The body as UTF-8 text (for tests and diagnostics of non-secret payloads).
    public var bodyText: String? {
        body.map { String(decoding: $0, as: UTF8.self) }
    }
}

extension HTTPRequest: CustomStringConvertible {
    public var description: String {
        "\(method) \(url.absoluteString) \(headers)"
    }
}

/// A response whose body arrives incrementally.
public struct HTTPStreamResponse: Sendable {
    public var status: Int
    public var headers: HTTPHeaders
    /// Body bytes as they arrive. Ending iteration early (or cancelling the consuming task)
    /// cancels the underlying request.
    public var body: AsyncThrowingStream<Data, any Error>

    public init(status: Int, headers: HTTPHeaders, body: AsyncThrowingStream<Data, any Error>) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public var isSuccess: Bool { (200..<300).contains(status) }

    /// Reads the whole body, failing with `ProviderError.invalidResponse` beyond `limit` bytes.
    public func collectBody(limit: Int = 8 * 1024 * 1024) async throws -> Data {
        var data = Data()
        for try await chunk in body {
            data.append(chunk)
            if data.count > limit {
                throw ProviderError.invalidResponse("The response body exceeded \(limit) bytes.")
            }
        }
        try Task.checkCancellation()
        return data
    }
}

/// Sends HTTP requests and streams their responses.
///
/// `send` returns once the status line and headers are known. Production uses
/// `URLSessionStreamingTransport`; tests replay recorded byte chunks through a fake.
public protocol HTTPStreamingTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPStreamResponse
}
