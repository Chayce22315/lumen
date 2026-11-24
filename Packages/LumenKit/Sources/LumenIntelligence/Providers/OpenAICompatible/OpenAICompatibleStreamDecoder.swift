import Foundation
import LumenFoundation

/// Turns Chat Completions stream chunks into `CompletionEvent`s.
///
/// Text arrives in `choices[0].delta.content`. Tool calls arrive as `delta.tool_calls` fragments
/// keyed by `index` (id and name in the first fragment, `arguments` spread over many) and are
/// emitted, in index order, when `finish_reason` arrives. With `stream_options.include_usage`
/// a final chunk with empty `choices` carries `usage`. `data: [DONE]` ends the stream.
struct OpenAICompatibleStreamDecoder: CompletionStreamDecoder {
    private struct PendingCall: Sendable {
        var id: String?
        var name = ""
        var arguments = ""
    }

    private var calls: [Int: PendingCall] = [:]
    private var finishReason: String?
    private var isDone = false

    mutating func decode(_ event: SSEEvent) throws -> [CompletionEvent] {
        guard !isDone else { return [] }
        let data = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
        if data == "[DONE]" {
            isDone = true
            return flushCalls() + [.stop(OpenAICompatibleWire.stopReason(finishReason ?? "stop"))]
        }
        if data.isEmpty { return [] }
        let chunk: JSONValue
        do {
            chunk = try JSONValue(parsing: data)
        } catch {
            throw ProviderError.invalidResponse("The provider sent a malformed stream chunk.")
        }
        if let error = chunk["error"], case .object = error {
            throw ProviderError.fromStreamError(
                type: error["type"]?.stringValue,
                code: error["code"]?.stringValue,
                message: error["message"]?.stringValue
            )
        }
        var events: [CompletionEvent] = []
        for choice in chunk["choices"]?.arrayValue ?? [] {
            let delta = choice["delta"]
            if let text = delta?["content"]?.stringValue, !text.isEmpty {
                events.append(.textDelta(text))
            }
            for fragment in delta?["tool_calls"]?.arrayValue ?? [] {
                let index = fragment["index"]?.intValue ?? 0
                var call = calls[index] ?? PendingCall()
                if let id = fragment["id"]?.stringValue, !id.isEmpty {
                    call.id = id
                }
                // The name arrives whole in the call's first fragment; later fragments carry arguments.
                if call.name.isEmpty, let name = fragment["function"]?["name"]?.stringValue {
                    call.name = name
                }
                if let arguments = fragment["function"]?["arguments"]?.stringValue {
                    call.arguments += arguments
                }
                calls[index] = call
            }
            if let reason = choice["finish_reason"]?.stringValue {
                finishReason = reason
                events.append(contentsOf: flushCalls())
            }
        }
        if let usage = chunk["usage"], case .object = usage {
            let prompt = usage["prompt_tokens"]?.intValue ?? 0
            let cached = usage["prompt_tokens_details"]?["cached_tokens"]?.intValue ?? 0
            events.append(.usage(TokenUsage(
                input: max(0, prompt - cached),
                output: usage["completion_tokens"]?.intValue ?? 0,
                cacheRead: cached
            )))
        }
        return events
    }

    /// Accepts a stream that ended after its `finish_reason` without `[DONE]` (some local servers do).
    mutating func finish() throws -> [CompletionEvent] {
        if isDone { return [] }
        guard let finishReason else {
            throw ProviderError.network("The response ended before it was complete.")
        }
        isDone = true
        return flushCalls() + [.stop(OpenAICompatibleWire.stopReason(finishReason))]
    }

    private mutating func flushCalls() -> [CompletionEvent] {
        defer { calls.removeAll() }
        return calls.keys.sorted().compactMap { index in
            guard let call = calls[index], !call.name.isEmpty else { return nil }
            // Some local servers omit ids; one is needed to pair the result with the call.
            let id = call.id ?? "call_\(index)"
            let trimmed = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return .toolUse(id: id, name: call.name, input: .object([:]))
            }
            guard let input = try? JSONValue(parsing: trimmed), case .object = input else {
                // Malformed arguments are answered with an error result, not executed.
                return .invalidToolUse(id: id, name: call.name, rawInput: call.arguments)
            }
            return .toolUse(id: id, name: call.name, input: input)
        }
    }
}
