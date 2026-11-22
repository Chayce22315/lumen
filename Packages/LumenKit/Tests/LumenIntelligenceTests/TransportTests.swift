import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import LumenIntelligence

@Suite("HTTP transport")
struct TransportTests {
    @Test("header names are case-insensitive")
    func caseInsensitiveHeaders() {
        var headers: HTTPHeaders = ["Content-Type": "application/json"]
        #expect(headers["content-type"] == "application/json")
        #expect(headers["CONTENT-TYPE"] == "application/json")
        headers["X-Api-Key"] = "secret"
        #expect(headers.fields["x-api-key"] == "secret")
    }

    @Test("credential headers are redacted from descriptions")
    func redaction() {
        let headers: HTTPHeaders = ["Authorization": "Bearer abc", "x-api-key": "k", "accept": "text/event-stream"]
        let description = String(describing: headers)
        #expect(!description.contains("abc"))
        #expect(!description.contains(": k"))
        #expect(description.contains("accept: text/event-stream"))
    }

    @Test("requests map to URLRequests with method, headers, body and idle timeout")
    func urlRequestMapping() {
        let request = HTTPRequest(
            method: "POST",
            url: ProviderFixtures.url("https://api.anthropic.com/v1/messages"),
            headers: ["anthropic-version": "2026-10-21", "content-type": "application/json"],
            body: Data("{}".utf8),
            timeout: 90
        )
        let urlRequest = URLSessionStreamingTransport.makeURLRequest(request)
        #expect(urlRequest.httpMethod == "POST")
        #expect(urlRequest.url == request.url)
        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        #expect(urlRequest.httpBody == Data("{}".utf8))
        #expect(urlRequest.timeoutInterval == 90)
    }

    @Test("collectBody enforces its size limit")
    func bodyLimit() async {
        let transport = FakeTransport([.init(chunks: [Data(repeating: 65, count: 10), Data(repeating: 66, count: 10)])])
        await #expect(throws: ProviderError.invalidResponse("The response body exceeded 15 bytes.")) {
            _ = try await transport.fetch(HTTPRequest(url: ProviderFixtures.url("https://example.com")), limit: 15)
        }
    }

    @Test("fetchJSON decodes success bodies and classifies failures")
    func fetchJSON() async throws {
        let transport = FakeTransport([
            .init(chunks: Chunking.split(#"{"ok":true}"#)),
            .init(status: 404, chunks: [Data(#"{"error":{"type":"not_found_error","message":"model: nope"}}"#.utf8)]),
            .init(chunks: [Data("not json".utf8)]),
        ])
        let request = HTTPRequest(url: ProviderFixtures.url("https://example.com/x"))
        #expect(try await transport.fetchJSON(request, now: Date())["ok"] == true)
        await #expect(throws: ProviderError.notFound("model: nope")) {
            _ = try await transport.fetchJSON(request, now: Date())
        }
        await #expect(throws: ProviderError.invalidResponse("The provider returned a response that is not valid JSON.")) {
            _ = try await transport.fetchJSON(request, now: Date())
        }
    }
}
