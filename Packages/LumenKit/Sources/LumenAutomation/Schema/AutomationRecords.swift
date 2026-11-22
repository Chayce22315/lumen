import Foundation
import LumenFoundation
import LumenPersistence

extension WorkflowRun.Status: DatabaseValueConvertible {}
extension RunStep.Status: DatabaseValueConvertible {}
extension TriggerDefinition.Kind: DatabaseValueConvertible {}

/// JSON text columns. Encoding is explicit (and throwing) so a value that cannot be represented —
/// a non-finite number in an action's output — fails the write instead of being stored as NULL.
enum JSONText {
    static func encode(_ value: some Encodable) throws -> String {
        try JSONCoding.encodeString(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, column: String, in row: Row) throws -> T {
        let text: String = try row.get(column)
        return try JSONCoding.decode(T.self, from: text)
    }

    static func decodeIfPresent<T: Decodable>(_ type: T.Type, column: String, in row: Row) throws -> T? {
        let text: String? = try row.get(column)
        return try text.map { try JSONCoding.decode(T.self, from: $0) }
    }
}

extension Workflow {
    init(row: Row) throws {
        self.init(
            id: try row.get("id"),
            name: try row.get("name"),
            summary: try row.get("summary"),
            isEnabled: try row.get("is_enabled"),
            trigger: try JSONText.decode(TriggerDefinition.self, column: "trigger", in: row),
            graph: try JSONText.decode(WorkflowGraph.self, column: "graph", in: row),
            failurePolicy: try JSONText.decode(FailurePolicy.self, column: "failure_policy", in: row),
            createdAt: try row.get("created_at"),
            updatedAt: try row.get("updated_at")
        )
    }
}

extension WorkflowRun {
    init(row: Row) throws {
        self.init(
            id: try row.get("id"),
            workflowID: try row.get("workflow_id"),
            status: try row.get("status"),
            triggerPayload: try JSONText.decode(JSONValue.self, column: "trigger_payload", in: row),
            input: try JSONText.decode(JSONValue.self, column: "input", in: row),
            causationDepth: try row.get("causation_depth"),
            correlationID: try row.get("correlation_id", as: UUID.self),
            startedAt: try row.get("started_at"),
            finishedAt: try row.get("finished_at"),
            resumeAt: try row.get("resume_at"),
            currentNodeID: try row.get("current_node_id"),
            errorMessage: try row.get("error_message")
        )
    }
}

extension RunStep {
    init(row: Row) throws {
        self.init(
            id: try row.get("id"),
            runID: try row.get("run_id"),
            nodeID: try row.get("node_id"),
            sequence: try row.get("sequence"),
            status: try row.get("status"),
            attemptCount: try row.get("attempt_count"),
            startedAt: try row.get("started_at"),
            finishedAt: try row.get("finished_at"),
            output: try JSONText.decodeIfPresent(JSONValue.self, column: "output", in: row),
            message: try row.get("message"),
            errorMessage: try row.get("error_message"),
            warnings: try JSONText.decode([String].self, column: "warnings", in: row)
        )
    }
}
