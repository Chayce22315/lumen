import Foundation
import Testing
import LumenFoundation
import LumenTestSupport
@testable import LumenIntelligence

@Suite("Provider errors and retry classification")
struct ProviderErrorTests {
    let now = ManualTimeSource.referenceDate

    func classify(_ status: Int, headers: HTTPHeaders = [:], body: String = "") -> ProviderError {
        ProviderError.fromHTTP(status: status, headers: headers, body: Data(body.utf8), now: now)
    }

    @Test("classifies HTTP statuses", arguments: [
        (400, ProviderError.badRequest("bad")), (401, .unauthorized), (402, .quotaExceeded("bad")),
        (403, .permissionDenied("bad")), (404, .notFound("bad")), (408, .server(status: 408, message: "bad")),
        (413, .badRequest("bad")), (429, .rateLimited(retryAfter: nil)), (500, .server(status: 500, message: "bad")),
        (502, .server(status: 502, message: "bad")), (503, .overloaded(retryAfter: nil)), (529, .overloaded(retryAfter: nil)),
        (418, .badRequest("bad")), (302, .invalidResponse("Unexpected HTTP status 302.")),
    ])
    func statuses(status: Int, expected: ProviderError) {
        #expect(classify(status, body: #"{"type":"error","error":{"type":"x","message":"bad"}}"#) == expected)
    }

    @Test("a non-JSON error body still classifies, with an empty message")
    func nonJSONBody() {
        #expect(classify(400, body: "<html>Bad Request</html>") == .badRequest(""))
    }

    @Test("an Anthropic spend-limit 429 is a quota error, not a rate limit")
    func spendLimit() {
        let body = #"{"type":"error","error":{"type":"rate_limit_error","message":"Spend limit reached","details":{"error_code":"enforced_spend_limit_reached"}}}"#
        #expect(classify(429, body: body) == .quotaExceeded("Spend limit reached"))
    }

    @Test("retry-after accepts seconds, milliseconds and HTTP dates")
    func retryAfterParsing() {
        #expect(RetryAfter.parse(["retry-after": "7"], now: now) == 7)
        #expect(RetryAfter.parse(["Retry-After": "2.5"], now: now) == 2.5)
        #expect(RetryAfter.parse(["retry-after-ms": "250", "retry-after": "9"], now: now) == 0.25)
        let date = "Sat, 21 Nov 2026 09:00:30 GMT"
        #expect(RetryAfter.parse(["retry-after": date], now: now) == 30)
        #expect(RetryAfter.parse(["retry-after": "Sat, 21 Nov 2026 08:00:00 GMT"], now: now) == 0)
        #expect(RetryAfter.parse(["retry-after": "soon"], now: now) == nil)
        #expect(RetryAfter.parse([:], now: now) == nil)
    }

    @Test("rate limits carry retry-after into the error")
    func rateLimitRetryAfter() {
        #expect(classify(429, headers: ["retry-after": "20"]) == .rateLimited(retryAfter: 20))
        #expect(classify(529, headers: ["retry-after": "3"]) == .overloaded(retryAfter: 3))
    }

    @Test("retry decisions: transient errors retry, client errors fail", arguments: [
        (ProviderError.rateLimited(retryAfter: nil), RetryDecision.retry),
        (.rateLimited(retryAfter: 4), .retryAfter(4)),
        (.rateLimited(retryAfter: 600), .fail),
        (.overloaded(retryAfter: nil), .retry),
        (.overloaded(retryAfter: 2), .retryAfter(2)),
        (.server(status: 500, message: ""), .retry),
        (.server(status: 504, message: ""), .retry),
        (.server(status: 408, message: ""), .retry),
        (.network("offline"), .retry),
        (.badRequest("x"), .fail),
        (.unauthorized, .fail),
        (.permissionDenied("x"), .fail),
        (.notFound("x"), .fail),
        (.quotaExceeded("x"), .fail),
        (.missingAPIKey(provider: "Anthropic"), .fail),
        (.invalidResponse("x"), .fail),
    ])
    func retryDecisions(error: ProviderError, expected: RetryDecision) {
        #expect(ProviderError.classifyForRetry(error) == expected)
    }

    @Test("non-provider errors and cancellation never retry")
    func otherErrors() {
        #expect(ProviderError.classifyForRetry(CancellationError()) == .fail)
        #expect(ProviderError.classifyForRetry(AssistantError.noModelSelected) == .fail)
    }

    @Test("stream error types map like their HTTP counterparts")
    func streamErrors() {
        #expect(ProviderError.fromStreamError(type: "overloaded_error", message: "Overloaded") == .overloaded(retryAfter: nil))
        #expect(ProviderError.fromStreamError(type: "api_error", message: "Internal") == .server(status: 500, message: "Internal"))
        #expect(ProviderError.fromStreamError(type: "invalid_request_error", message: "prompt is too long") == .badRequest("prompt is too long"))
        #expect(ProviderError.fromStreamError(type: "requests", code: "rate_limit_exceeded", message: nil) == .rateLimited(retryAfter: nil))
        #expect(ProviderError.fromStreamError(type: "mystery", message: nil) == .server(status: 500, message: ""))
    }

    @Test("every error has a presentation; transient ones are retryable and the key error says where to fix it")
    func presentations() {
        let missing = ProviderError.missingAPIKey(provider: "Anthropic").presentation
        #expect(missing.title == "Add an API key")
        #expect(missing.recoverySuggestion?.contains("Settings › Assistant › Anthropic") == true)
        #expect(!missing.isRetryable)
        #expect(ProviderError.rateLimited(retryAfter: nil).presentation.isRetryable)
        #expect(ProviderError.network("The device is offline.").presentation.message == "The device is offline.")
        #expect(ProviderError.badRequest("prompt is too long").presentation.message == "prompt is too long")
        #expect(!ProviderError.unauthorized.presentation.isRetryable)
    }

    @Test("URL loading errors map to network errors and cancellation")
    func urlErrors() {
        #expect(URLSessionStreamingTransport.mapError(URLError(.cancelled)) is CancellationError)
        #expect(URLSessionStreamingTransport.mapError(URLError(.timedOut)) as? ProviderError == .network("The request timed out."))
        #expect(URLSessionStreamingTransport.mapError(URLError(.notConnectedToInternet)) as? ProviderError == .network("The device is offline."))
    }
}
