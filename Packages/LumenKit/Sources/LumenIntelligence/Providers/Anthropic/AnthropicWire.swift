import Foundation
import LumenFoundation

/// Encodes `CompletionRequest`s as Anthropic Messages API bodies.
///
/// Wire shapes follow the Messages API (`POST /v1/messages`, `anthropic-version: 2026-10-21`):
/// content blocks `text`, `tool_use`, `tool_result`, `thinking` and `redacted_thinking`; tools as
/// `name`/`description`/`input_schema`. Sampling parameters are never sent because API version
/// 2026-10-21 rejects `temperature`, `top_p` and `top_k` on every model.
enum AnthropicWire {
    struct Options: Sendable, Hashable {
        /// Adds `eager_input_streaming: true` to each tool so large inputs stream as generated.
        var eagerInputStreaming: Bool
        /// Adds top-level `cache_control: {"type": "ephemeral"}` (automatic prompt caching).
        var promptCaching: Bool
    }

    static func body(for request: CompletionRequest, options: Options) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "max_tokens": .number(Double(request.maxTokens)),
            "stream": true,
            "messages": .array(request.messages.map(message)),
        ]
        if !request.system.isEmpty {
            body["system"] = .string(request.system)
        }
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { tool($0, eager: options.eagerInputStreaming) })
            if request.toolChoice == .none {
                body["tool_choice"] = ["type": "none"]
            }
        }
        if options.promptCaching {
            body["cache_control"] = ["type": "ephemeral"]
        }
        return .object(body)
    }

    static func message(_ message: WireMessage) -> JSONValue {
        [
            "role": .string(message.role.rawValue),
            "content": .array(message.blocks.map(content)),
        ]
    }

    static func content(_ block: ContentBlock) -> JSONValue {
        switch block {
        case .text(let text):
            return ["type": "text", "text": .string(text)]
        case .toolUse(let id, let name, let input):
            return ["type": "tool_use", "id": .string(id), "name": .string(name), "input": input]
        case .toolResult(let toolUseID, let content, let isError):
            var object: [String: JSONValue] = [
                "type": "tool_result",
                "tool_use_id": .string(toolUseID),
                "content": .string(content),
            ]
            if isError {
                object["is_error"] = true
            }
            return .object(object)
        case .thinking(let text, let signature):
            var object: [String: JSONValue] = ["type": "thinking", "thinking": .string(text)]
            if let signature {
                object["signature"] = .string(signature)
            }
            return .object(object)
        case .redactedThinking(let data):
            return ["type": "redacted_thinking", "data": .string(data)]
        }
    }

    static func tool(_ tool: ToolDefinition, eager: Bool) -> JSONValue {
        var object: [String: JSONValue] = [
            "name": .string(tool.name),
            "description": .string(tool.description),
            "input_schema": tool.inputSchema,
        ]
        if eager {
            object["eager_input_streaming"] = true
        }
        return .object(object)
    }

    /// Reads a `usage` object; absent fields stay `nil` so deltas can be merged.
    static func usageFields(_ value: JSONValue?) -> (input: Int?, output: Int?, cacheCreation: Int?, cacheRead: Int?) {
        (
            value?["input_tokens"]?.intValue,
            value?["output_tokens"]?.intValue,
            value?["cache_creation_input_tokens"]?.intValue,
            value?["cache_read_input_tokens"]?.intValue
        )
    }

    static func stopReason(_ raw: String) -> StopReason {
        switch raw {
        case "end_turn": return .endTurn
        case "tool_use": return .toolUse
        case "max_tokens", "model_context_window_exceeded": return .maxTokens
        case "stop_sequence": return .stopSequence
        case "refusal": return .refusal
        default: return .other(raw)
        }
    }
}
