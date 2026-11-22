import Foundation
import LumenFoundation

/// A fully read, non-streaming response.
public struct HTTPDataResponse: Sendable, Hashable {
    public var status: Int
    public var headers: HTTPHeaders
    public var body: Data

    public init(status: Int, headers: HTTPHeaders, body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public var isSuccess: Bool { (200..<300).contains(status) }
}

extension HTTPStreamingTransport {
    /// Sends `request` and reads the whole body (bounded by `limit` bytes).
    public func fetch(_ request: HTTPRequest, limit: Int = 8 * 1024 * 1024) async throws -> HTTPDataResponse {
        let response = try await send(request)
        let body = try await response.collectBody(limit: limit)
        return HTTPDataResponse(status: response.status, headers: response.headers, body: body)
    }

    /// Sends `request` and decodes a JSON body. Non-2xx responses throw the classified
    /// `ProviderError`; `now` resolves HTTP-date `retry-after` values.
    public func fetchJSON(_ request: HTTPRequest, now: Date, limit: Int = 8 * 1024 * 1024) async throws -> JSONValue {
        let response = try await fetch(request, limit: limit)
        guard response.isSuccess else {
            throw ProviderError.fromHTTP(status: response.status, headers: response.headers, body: response.body, now: now)
        }
        do {
            return try JSONCoding.decoder.decode(JSONValue.self, from: response.body)
        } catch {
            throw ProviderError.invalidResponse("The provider returned a response that is not valid JSON.")
        }
    }
}
