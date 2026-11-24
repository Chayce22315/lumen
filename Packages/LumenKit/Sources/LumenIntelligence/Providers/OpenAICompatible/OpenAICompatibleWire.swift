import Foundation
import LumenFoundation

/// Encodes `CompletionRequest`s as Chat Completions bodies (`POST {base}/chat/completions`).
///
/// Mapping: the system prompt is the first `system` message; assistant tool calls become
/// `tool_calls` with JSON-string `arguments`; each tool result becomes a `tool` message (placed
/// before any user text of the same turn, as the format requires). Reasoning blocks belong to
/// another provider's format and are omitted. The format has no error flag for tool results, so
/// failed results are prefixed with `Error: `.
enum OpenAICompatibleWire {
    struct Options: Sendable, Hashable {
        var maxTokensField: OpenAICompatibleProvider.MaxTokensField
        var includeUsage: Bool
    }

    static func body(for request: CompletionRequest, options: Options) -> JSONValue {
        var messages: [JSONValue] = []
        if !request.system.isEmpty {
            messages.append(["role": "system", "content": .string(request.system)])
        }
        for message in request.messages {
            messages.append(contentsOf: encode(message))
        }
        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "messages": .array(messages),
            "stream": true,
            options.maxTokensField.rawValue: .number(Double(request.maxTokens)),
        ]
        if options.includeUsage {
            body["stream_options"] = ["include_usage": true]
        }
        if let temperature = request.temperature {
            body["temperature"] = .number(temperature)
        }
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map(tool))
            if request.toolChoice == .none {
                body["tool_choice"] = "none"
            }
        }
        return .object(body)
    }

    static func encode(_ message: WireMessage) -> [JSONValue] {
        switch message.role {
        case .assistant:
            let text = message.blocks.compactMap(\.textValue).joined()
            let calls: [JSONValue] = message.blocks.compactMap { block in
                guard case .toolUse(let id, let name, let input) = block else { return nil }
                return [
                    "id": .string(id),
                    "type": "function",
                    "function": ["name": .string(name), "arguments": .string(input.compactText)],
                ]
            }
            var object: [String: JSONValue] = ["role": "assistant"]
            object["content"] = text.isEmpty && !calls.isEmpty ? .null : .string(text)
            if !calls.isEmpty {
                object["tool_calls"] = .array(calls)
            }
            return [.object(object)]
        case .user:
            var encoded: [JSONValue] = []
            for block in message.blocks {
                if case .toolResult(let toolUseID, let content, let isError) = block {
                    encoded.append([
                        "role": "tool",
                        "tool_call_id": .string(toolUseID),
                        "content": .string(isError ? "Error: \(content)" : content),
                    ])
                }
            }
            let text = message.blocks.compactMap(\.textValue).joined(separator: "\n\n")
            if !text.isEmpty {
                encoded.append(["role": "user", "content": .string(text)])
            }
            return encoded
        }
    }

    static func tool(_ tool: ToolDefinition) -> JSONValue {
        [
            "type": "function",
            "function": [
                "name": .string(tool.name),
                "description": .string(tool.description),
                "parameters": tool.inputSchema,
            ],
        ]
    }

    static func stopReason(_ raw: String) -> StopReason {
        switch raw {
        case "stop": return .endTurn
        case "length": return .maxTokens
        case "tool_calls", "function_call": return .toolUse
        case "content_filter": return .refusal
        default: return .other(raw)
        }
    }
}
