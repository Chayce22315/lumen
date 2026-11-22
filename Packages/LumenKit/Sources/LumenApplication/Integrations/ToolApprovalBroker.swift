import Foundation
import LumenFoundation
import LumenIntelligence

/// A pending request for the user to allow an assistant action.
public struct ApprovalRequest: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let toolName: String
    public let summary: String
    public let input: JSONValue
}

/// Bridges the assistant's approval requests to the interface. Mutating tools wait here until
/// the user answers; without an attached interface, or after `timeout`, the answer is "no".
public actor ToolApprovalBroker: ToolApprovalHandler {
    private var pending: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var observers: [UUID: AsyncStream<ApprovalRequest>.Continuation] = [:]
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 120) {
        self.timeout = timeout
    }

    /// Requests as they arrive. The interface presents each and calls `resolve`.
    public func requests() -> AsyncStream<ApprovalRequest> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ApprovalRequest>.makeStream(bufferingPolicy: .bufferingNewest(8))
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    public func resolve(_ id: ApprovalRequest.ID, approved: Bool) {
        pending.removeValue(forKey: id)?.resume(returning: approved)
    }

    public var hasObservers: Bool { !observers.isEmpty }

    public nonisolated func approve(tool: ToolDefinition, input: JSONValue) async -> Bool {
        await waitForAnswer(tool: tool, input: input)
    }

    private func waitForAnswer(tool: ToolDefinition, input: JSONValue) async -> Bool {
        guard !observers.isEmpty else { return false }
        let request = ApprovalRequest(id: UUID(), toolName: tool.name, summary: Self.summary(tool: tool, input: input), input: input)
        let timeout = self.timeout
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await self?.resolve(request.id, approved: false)
        }
        return await withCheckedContinuation { continuation in
            pending[request.id] = continuation
            for observer in observers.values {
                observer.yield(request)
            }
        }
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
        if observers.isEmpty {
            // Nobody can answer anymore: decline everything still waiting.
            for continuation in pending.values { continuation.resume(returning: false) }
            pending.removeAll()
        }
    }

    /// A one-line description of what the tool is about to do.
    static func summary(tool: ToolDefinition, input: JSONValue) -> String {
        switch tool.name {
        case "create_task": return "Create the task “\(input["title"]?.stringValue ?? "")”"
        case "complete_task": return "Mark a task as done"
        case "create_note": return "Create the note “\(input["title"]?.stringValue ?? "")”"
        case "run_workflow": return "Run an automation"
        case "remember": return "Remember: \(input["content"]?.stringValue?.truncated(to: 80) ?? "")"
        default: return "Use \(tool.name.replacingOccurrences(of: "_", with: " "))"
        }
    }
}
