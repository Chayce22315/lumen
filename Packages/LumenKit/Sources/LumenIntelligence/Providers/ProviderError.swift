import Foundation
import LumenFoundation

/// Errors from a model provider, already classified for presentation and retry.
public enum ProviderError: PresentableError, Hashable {
    /// No API key is stored for the provider (associated value: the provider's display name).
    case missingAPIKey(provider: String)
    case unauthorized
    case permissionDenied(String)
    /// Unknown endpoint or a model the account cannot use.
    case notFound(String)
    /// A billing problem or spend cap; retrying does not help.
    case quotaExceeded(String)
    case rateLimited(retryAfter: TimeInterval?)
    case overloaded(retryAfter: TimeInterval?)
    case badRequest(String)
    case server(status: Int, message: String)
    case invalidResponse(String)
    case network(String)

    public var presentation: ErrorPresentation {
        switch self {
        case .missingAPIKey(let provider):
            return ErrorPresentation(
                title: "Add an API key",
                message: "The assistant needs your \(provider) API key to use this model.",
                recoverySuggestion: "Open Settings › Assistant › \(provider) and paste your key. It is stored only in this device's Keychain."
            )
        case .unauthorized:
            return ErrorPresentation(
                title: "API key not accepted",
                message: "The provider rejected the API key.",
                recoverySuggestion: "Check or replace the key in Settings › Assistant."
            )
        case .permissionDenied(let message):
            return ErrorPresentation(
                title: "Not allowed",
                message: message.nonBlank ?? "Your provider account is not allowed to make this request.",
                recoverySuggestion: "Check your account's permissions with the provider."
            )
        case .notFound(let message):
            return ErrorPresentation(
                title: "Model unavailable",
                message: message.nonBlank ?? "The selected model isn't available to your account.",
                recoverySuggestion: "Choose another model in Settings › Assistant."
            )
        case .quotaExceeded(let message):
            return ErrorPresentation(
                title: "Usage limit reached",
                message: message.nonBlank ?? "Your provider account has reached its usage or billing limit.",
                recoverySuggestion: "Check billing and limits in your provider's console."
            )
        case .rateLimited:
            return ErrorPresentation(
                title: "Too many requests",
                message: "The provider is limiting requests right now.",
                recoverySuggestion: "Wait a moment and try again.",
                isRetryable: true
            )
        case .overloaded:
            return ErrorPresentation(
                title: "Provider busy",
                message: "The model provider is temporarily overloaded.",
                recoverySuggestion: "Try again in a moment, or choose another model.",
                isRetryable: true
            )
        case .badRequest(let message):
            return ErrorPresentation(
                title: "Request not accepted",
                message: message.nonBlank ?? "The provider couldn't process this request.",
                recoverySuggestion: "Try rephrasing, starting a new conversation, or choosing another model."
            )
        case .server:
            return ErrorPresentation(
                title: "Provider error",
                message: "The model provider had a problem answering.",
                recoverySuggestion: "Try again.",
                isRetryable: true
            )
        case .invalidResponse:
            return ErrorPresentation(
                title: "Unexpected response",
                message: "The provider sent a response the assistant couldn't read.",
                recoverySuggestion: "Try again. If it keeps happening, check the provider's base URL in Settings.",
                isRetryable: true
            )
        case .network(let message):
            return ErrorPresentation(
                title: "Can't reach the provider",
                message: message.nonBlank ?? "The connection to the model provider failed.",
                recoverySuggestion: "Check your internet connection and try again.",
                isRetryable: true
            )
        }
    }

    /// A short, content-free label for logs and event attributes.
    public var kind: String {
        switch self {
        case .missingAPIKey: return "missingAPIKey"
        case .unauthorized: return "unauthorized"
        case .permissionDenied: return "permissionDenied"
        case .notFound: return "notFound"
        case .quotaExceeded: return "quotaExceeded"
        case .rateLimited: return "rateLimited"
        case .overloaded: return "overloaded"
        case .badRequest: return "badRequest"
        case .server(let status, _): return "server.\(status)"
        case .invalidResponse: return "invalidResponse"
        case .network: return "network"
        }
    }
}

// MARK: - Classification

extension ProviderError {
    /// Classifies a non-2xx HTTP response. Understands both the Anthropic and the OpenAI error
    /// documents (`{"error": {"type"|"code", "message"}}`).
    public static func fromHTTP(status: Int, headers: HTTPHeaders, body: Data, now: Date) -> ProviderError {
        // Error bodies are not always JSON (proxies, HTML error pages); such a body simply has no message.
        let document = try? JSONCoding.decoder.decode(JSONValue.self, from: body)
        let error = document?["error"]
        let message = error?["message"]?.stringValue ?? ""
        let detailCode = error?["details"]?["error_code"]?.stringValue
        let code = error?["code"]?.stringValue
        let retryAfter = RetryAfter.parse(headers, now: now)

        switch status {
        case 400, 413, 422:
            return .badRequest(message)
        case 401:
            return .unauthorized
        case 402:
            return .quotaExceeded(message)
        case 403:
            return .permissionDenied(message)
        case 404:
            return .notFound(message)
        case 408, 409:
            return .server(status: status, message: message)
        case 429:
            // A spend cap (Anthropic) or exhausted quota (OpenAI) is also a 429, but waiting won't help.
            if detailCode == "enforced_spend_limit_reached" || code == "insufficient_quota" {
                return .quotaExceeded(message)
            }
            return .rateLimited(retryAfter: retryAfter)
        case 503, 529:
            return .overloaded(retryAfter: retryAfter)
        case 500...599:
            return .server(status: status, message: message)
        case 400...499:
            return .badRequest(message)
        default:
            return .invalidResponse("Unexpected HTTP status \(status).")
        }
    }

    /// Classifies an error reported inside an event stream. Anthropic sends a `type` such as
    /// `overloaded_error`; OpenAI-compatible servers send a `code` (`rate_limit_exceeded`) that is
    /// more specific than their `type`, so a recognized `code` wins.
    public static func fromStreamError(type: String?, code: String? = nil, message: String?) -> ProviderError {
        let message = message ?? ""
        func classify(_ name: String?) -> ProviderError? {
            switch name {
            case "overloaded_error", "server_overloaded": return .overloaded(retryAfter: nil)
            case "rate_limit_error", "rate_limit_exceeded": return .rateLimited(retryAfter: nil)
            case "authentication_error", "invalid_api_key": return .unauthorized
            case "permission_error": return .permissionDenied(message)
            case "not_found_error", "model_not_found": return .notFound(message)
            case "billing_error", "insufficient_quota": return .quotaExceeded(message)
            case "invalid_request_error", "request_too_large", "context_length_exceeded": return .badRequest(message)
            case "timeout_error": return .server(status: 504, message: message)
            case "api_error", "server_error": return .server(status: 500, message: message)
            default: return nil
            }
        }
        return classify(code) ?? classify(type) ?? .server(status: 500, message: message)
    }

    /// Whether and how to retry `error`.
    ///
    /// 429, 529/503 (overloaded), 408/409, other 5xx and network failures are retryable;
    /// a server-provided `retry-after` is honoured unless it exceeds `maxRetryAfter`, in which case
    /// the error is surfaced instead of keeping the user waiting. Everything else (400, 401, 403,
    /// 404, quota, malformed responses, non-provider errors) fails immediately.
    public static func classifyForRetry(_ error: any Error, maxRetryAfter: TimeInterval = 60) -> RetryDecision {
        guard let error = error as? ProviderError else { return .fail }
        switch error {
        case .rateLimited(let retryAfter), .overloaded(let retryAfter):
            guard let retryAfter else { return .retry }
            return retryAfter <= maxRetryAfter ? .retryAfter(retryAfter) : .fail
        case .server(let status, _):
            return status >= 500 || status == 408 || status == 409 ? .retry : .fail
        case .network:
            return .retry
        case .missingAPIKey, .unauthorized, .permissionDenied, .notFound, .quotaExceeded, .badRequest, .invalidResponse:
            return .fail
        }
    }
}

/// Parses `retry-after-ms` (milliseconds, sent by OpenAI) and `retry-after` (seconds or an HTTP date).
public enum RetryAfter {
    public static func parse(_ headers: HTTPHeaders, now: Date) -> TimeInterval? {
        if let text = headers["retry-after-ms"]?.trimmingCharacters(in: .whitespaces),
           let milliseconds = Double(text), milliseconds.isFinite, milliseconds >= 0 {
            return milliseconds / 1_000
        }
        guard let text = headers["retry-after"]?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let seconds = Double(text), seconds.isFinite, seconds >= 0 {
            return seconds
        }
        guard let date = httpDate(text) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    /// RFC 9110 IMF-fixdate (`Sun, 06 Nov 1994 08:49:37 GMT`).
    static func httpDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.date(from: text)
    }
}
