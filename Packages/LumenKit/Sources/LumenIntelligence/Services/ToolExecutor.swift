import Foundation
import Synchronization
import LumenFoundation

/// How a tool call ended.
public enum ToolOutcome: String, Sendable, Hashable, Codable {
    case succeeded
    /// The tool ran and reported an error (or threw).
    case failed
    /// Approval was required and not given.
    case denied
    case timedOut
    case invalidInput
    case unknownTool
    case cancelled
}

/// One executed (or refused) tool call and the result block returned to the model.
struct ToolExecution: Sendable, Hashable {
    let toolUseID: String
    let name: String
    let outcome: ToolOutcome
    let content: String
    let referencedEntities: [EntityReference]

    var isError: Bool { outcome != .succeeded }

    var resultBlock: ContentBlock {
        .toolResult(toolUseID: toolUseID, content: content, isError: isError)
    }
}

/// Runs tool calls: input validation, approval for mutating tools, a timeout, and conversion of
/// every failure into an error result the model can read. Nothing here throws.
struct ToolExecutor: Sendable {
    let timeout: TimeInterval
    let logger: Logger

    func execute(
        id: String,
        name: String,
        input: JSONValue,
        tool: (any AssistantTool)?,
        invalidRawInput: String?,
        requiresApproval: Bool,
        approval: (any ToolApprovalHandler)?,
        context: ToolContext
    ) async -> ToolExecution {
        func result(_ outcome: ToolOutcome, _ content: String, entities: [EntityReference] = []) -> ToolExecution {
            ToolExecution(toolUseID: id, name: name, outcome: outcome, content: content, referencedEntities: entities)
        }

        if let invalidRawInput {
            // The JSON library escapes the raw text, so quotes in it cannot break the wrapper.
            let wrapped = JSONValue.object(["INVALID_JSON": .string(invalidRawInput)]).compactText
            return result(.invalidInput, wrapped)
        }
        guard let tool else {
            return result(.unknownTool, "No tool named “\(name)” is available.")
        }
        let problems = ToolInputValidator.validate(input, against: tool.definition.inputSchema)
        guard problems.isEmpty else {
            return result(.invalidInput, "Invalid input: " + problems.joined(separator: " "))
        }
        if tool.isMutating && requiresApproval {
            let approved = await approval?.approve(tool: tool.definition, input: input) ?? false
            if Task.isCancelled {
                return result(.cancelled, "Cancelled before the tool ran.")
            }
            guard approved else {
                return result(.denied, "The user declined this action, so it was not performed. Don't retry it unless they ask.")
            }
        }
        do {
            let output = try await ToolTimeout.run(seconds: timeout) {
                try await tool.execute(input, context: context)
            }
            let text = output.text.nonBlank == nil ? "(no output)" : output.text
            return result(output.isError ? .failed : .succeeded, text, entities: output.referencedEntities)
        } catch is ToolTimeoutError {
            logger.warning("Tool timed out", metadata: ["tool": name, "timeout": String(timeout)])
            return result(.timedOut, "The tool did not finish within \(String(format: "%g", timeout)) seconds.")
        } catch is CancellationError {
            return result(.cancelled, "Cancelled before the tool finished.")
        } catch {
            logger.warning("Tool failed", metadata: ["tool": name, "error.type": String(describing: type(of: error))])
            let description = (error as? any PresentableError).map { "\($0.presentation.title): \($0.presentation.message)" }
                ?? String(describing: error)
            return result(.failed, "The tool failed: \(description)")
        }
    }
}

struct ToolTimeoutError: Error {}

/// Races an operation against a timer without waiting for an operation that ignores cancellation.
enum ToolTimeout {
    static func run<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let work = Task<T, any Error> { try await operation() }
        let nanoseconds = UInt64(min(max(0, seconds), 86_400) * 1_000_000_000)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                let once = ResumeOnce(continuation)
                let timer = Task {
                    do {
                        try await Task.sleep(nanoseconds: nanoseconds)
                    } catch {
                        // Cancelled because the work finished first: nothing to time out.
                        return
                    }
                    once.resume(with: .failure(ToolTimeoutError()))
                    work.cancel()
                }
                Task {
                    let outcome = await work.result
                    timer.cancel()
                    once.resume(with: outcome)
                }
            }
        } onCancel: {
            work.cancel()
        }
    }
}

/// Resumes a continuation at most once, from whichever side finishes first.
final class ResumeOnce<T: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<T, any Error>?>

    init(_ continuation: CheckedContinuation<T, any Error>) {
        self.continuation = Mutex(continuation)
    }

    func resume(with result: Result<T, any Error>) {
        let pending = continuation.withLock { value -> CheckedContinuation<T, any Error>? in
            let current = value
            value = nil
            return current
        }
        pending?.resume(with: result)
    }
}
