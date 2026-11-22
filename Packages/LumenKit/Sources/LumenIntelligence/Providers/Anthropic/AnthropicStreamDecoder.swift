import Foundation
import LumenFoundation

/// Turns Anthropic Messages API stream events into `CompletionEvent`s.
///
/// Event flow: `message_start` (input usage) → per block `content_block_start` /
/// `content_block_delta`* / `content_block_stop` → `message_delta` (stop reason, cumulative
/// usage) → `message_stop`. `ping` is ignored; `error` throws the classified `ProviderError`.
/// Text deltas are forwarded immediately; tool inputs (`input_json_delta` fragments) and
/// reasoning blocks (`thinking_delta` / `signature_delta`) are accumulated and emitted when
/// their block stops. Unknown event, block and delta types are ignored for forward compatibility.
struct AnthropicStreamDecoder: CompletionStreamDecoder {
    private enum OpenBlock: Sendable {
        case text
        case toolUse(id: String, name: String, json: String, initialInput: JSONValue?)
        case thinking(text: String, signature: String?)
        case redactedThinking(data: String)
        case ignored
    }

    private var blocks: [Int: OpenBlock] = [:]
    private var usage = TokenUsage()
    private var stopReason: StopReason?
    private(set) var isComplete = false

    mutating func decode(_ event: SSEEvent) throws -> [CompletionEvent] {
        guard !isComplete else { return [] }
        let payload: JSONValue
        do {
            payload = try JSONValue(parsing: event.data)
        } catch {
            throw ProviderError.invalidResponse("The provider sent a malformed stream event.")
        }
        let type = payload["type"]?.stringValue ?? event.event
        switch type {
        case "message_start":
            mergeUsage(payload["message"]?["usage"])
            return [.usage(usage)]
        case "content_block_start":
            return try startBlock(payload)
        case "content_block_delta":
            return try applyDelta(payload)
        case "content_block_stop":
            return try stopBlock(payload)
        case "message_delta":
            if let raw = payload["delta"]?["stop_reason"]?.stringValue {
                stopReason = AnthropicWire.stopReason(raw)
            }
            mergeUsage(payload["usage"])
            return [.usage(usage)]
        case "message_stop":
            isComplete = true
            return [.stop(stopReason ?? .endTurn)]
        case "error":
            let error = payload["error"]
            throw ProviderError.fromStreamError(type: error?["type"]?.stringValue, message: error?["message"]?.stringValue)
        default:
            // `ping` and event types this version does not know.
            return []
        }
    }

    /// Called when the byte stream ends; a stream that ends before `message_stop` was interrupted.
    mutating func finish() throws -> [CompletionEvent] {
        guard isComplete else {
            throw ProviderError.network("The response ended before it was complete.")
        }
        return []
    }

    private mutating func startBlock(_ payload: JSONValue) throws -> [CompletionEvent] {
        let index = try blockIndex(payload)
        let block = payload["content_block"]
        switch block?["type"]?.stringValue {
        case "text":
            blocks[index] = .text
            if let text = block?["text"]?.stringValue, !text.isEmpty {
                return [.textDelta(text)]
            }
        case "tool_use":
            guard let id = block?["id"]?.stringValue, let name = block?["name"]?.stringValue else {
                throw ProviderError.invalidResponse("A tool call arrived without an id or name.")
            }
            blocks[index] = .toolUse(id: id, name: name, json: "", initialInput: block?["input"])
        case "thinking":
            blocks[index] = .thinking(text: block?["thinking"]?.stringValue ?? "", signature: block?["signature"]?.stringValue)
        case "redacted_thinking":
            blocks[index] = .redactedThinking(data: block?["data"]?.stringValue ?? "")
        default:
            blocks[index] = .ignored
        }
        return []
    }

    private mutating func applyDelta(_ payload: JSONValue) throws -> [CompletionEvent] {
        let index = try blockIndex(payload)
        let delta = payload["delta"]
        switch (blocks[index], delta?["type"]?.stringValue) {
        case (.text?, "text_delta"):
            if let text = delta?["text"]?.stringValue, !text.isEmpty {
                return [.textDelta(text)]
            }
        case (.toolUse(let id, let name, let json, let initial)?, "input_json_delta"):
            blocks[index] = .toolUse(id: id, name: name, json: json + (delta?["partial_json"]?.stringValue ?? ""), initialInput: initial)
        case (.thinking(let text, let signature)?, "thinking_delta"):
            blocks[index] = .thinking(text: text + (delta?["thinking"]?.stringValue ?? ""), signature: signature)
        case (.thinking(let text, _)?, "signature_delta"):
            blocks[index] = .thinking(text: text, signature: delta?["signature"]?.stringValue)
        default:
            // Citations and other delta kinds this engine does not use.
            break
        }
        return []
    }

    private mutating func stopBlock(_ payload: JSONValue) throws -> [CompletionEvent] {
        let index = try blockIndex(payload)
        guard let block = blocks.removeValue(forKey: index) else { return [] }
        switch block {
        case .text, .ignored:
            return []
        case .toolUse(let id, let name, let json, let initialInput):
            let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                // No fragments: the input arrived whole in `content_block_start` (usually `{}`).
                if let initialInput, case .object = initialInput {
                    return [.toolUse(id: id, name: name, input: initialInput)]
                }
                return [.toolUse(id: id, name: name, input: .object([:]))]
            }
            guard let input = try? JSONValue(parsing: trimmed), case .object = input else {
                // Truncated (max_tokens) or malformed input; the engine answers it with an error result.
                return [.invalidToolUse(id: id, name: name, rawInput: json)]
            }
            return [.toolUse(id: id, name: name, input: input)]
        case .thinking(let text, let signature):
            return [.thinking(text: text, signature: signature)]
        case .redactedThinking(let data):
            return [.redactedThinking(data: data)]
        }
    }

    private func blockIndex(_ payload: JSONValue) throws -> Int {
        guard let index = payload["index"]?.intValue else {
            throw ProviderError.invalidResponse("A content block event arrived without an index.")
        }
        return index
    }

    private mutating func mergeUsage(_ value: JSONValue?) {
        let fields = AnthropicWire.usageFields(value)
        if let input = fields.input { usage.input = input }
        if let output = fields.output { usage.output = output }
        if let cacheCreation = fields.cacheCreation { usage.cacheCreation = cacheCreation }
        if let cacheRead = fields.cacheRead { usage.cacheRead = cacheRead }
    }
}
