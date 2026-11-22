import Foundation
import Testing
import LumenFoundation
import LumenCore
import LumenAutomation
import LumenTestSupport

@Suite("AutomationCatalog")
struct AutomationCatalogTests {
    func invoke(_ action: any AutomationAction, _ parameters: [String: JSONValue]) async throws -> ActionOutcome {
        try await action.perform(ActionInvocation(
            parameters: parameters,
            context: ActionContext(actor: .automation),
            runID: WorkflowRun.ID(),
            workflowID: Workflow.ID(),
            nodeID: WorkflowNode.ID(),
            attempt: 1
        ))
    }

    @Test("built-in actions are registered and sorted by category, then title")
    func builtIns() {
        let catalog = AutomationCatalog()
        #expect(catalog.descriptors.map(\.id) == [SetVariableAction.id, StopRunAction.id, FormatTextAction.id])
        #expect(catalog.descriptors.allSatisfy { !$0.isMutating })
        #expect(AutomationCatalog(includeBuiltIns: false).descriptors.isEmpty)
    }

    @Test("registration rejects duplicates; unregistering removes the action")
    func registration() throws {
        let catalog = AutomationCatalog(includeBuiltIns: false)
        try catalog.register(RecordingAction("b.action", title: "Beta", category: "Zeta"))
        try catalog.register(RecordingAction("a.action", title: "Alpha", category: "Zeta"))
        try catalog.register(RecordingAction("c.action", title: "Gamma", category: "Alpha"))
        #expect(catalog.descriptors.map(\.id) == ["c.action", "a.action", "b.action"])
        #expect(throws: AutomationError.duplicateAction("a.action")) { try catalog.register(RecordingAction("a.action")) }
        #expect(catalog.descriptor("a.action")?.title == "Alpha")
        #expect(catalog.unregister("a.action"))
        #expect(!catalog.unregister("a.action"))
        #expect(catalog.action("a.action") == nil)
        #expect(Set(catalog.descriptorsByID.keys) == ["b.action", "c.action"])
    }

    @Test("concurrent registration is safe")
    func concurrency() async throws {
        let catalog = AutomationCatalog(includeBuiltIns: false)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                group.addTask { try catalog.register(RecordingAction(AutomationActionID("test.\(index)"))) }
            }
            try await group.waitForAll()
        }
        #expect(catalog.descriptors.count == 50)
    }

    @Test("trigger sources describe events; the latest description of an event wins")
    func triggers() {
        struct Source: AutomationTriggerSource {
            var triggers: [AutomationTriggerDescriptor] {
                [AutomationTriggerDescriptor(
                    eventName: "organization.task.completed", title: "Task Completed", summary: "", symbolName: "checkmark",
                    category: "Tasks", attributes: [TriggerAttributeSpec(name: "priority", title: "Priority", valueType: .number)]
                )]
            }
        }
        let catalog = AutomationCatalog()
        #expect(catalog.knownEventNames == [AutomationEvents.runSucceeded, AutomationEvents.runFailed])
        catalog.registerTriggers(from: Source())
        #expect(catalog.triggerDescriptors.map(\.title) == ["Workflow Failed", "Workflow Succeeded", "Task Completed"])
        #expect(catalog.triggerDescriptor(for: "organization.task.completed")?.attributes.first?.path == "trigger.attributes.priority")
        catalog.unregisterTriggers(["organization.task.completed"])
        #expect(catalog.triggerDescriptor(for: "organization.task.completed") == nil)
    }

    @Test("Format Text applies case and trimming")
    func formatText() async throws {
        let action = FormatTextAction()
        let plain = try await invoke(action, ["text": "  Hello World  "])
        #expect(plain.output == ["text": "Hello World", "length": 11])
        let upper = try await invoke(action, ["text": " hello ", "case": "uppercase", "trimWhitespace": false])
        #expect(upper.output["text"] == " HELLO ")
        #expect(try await invoke(action, ["text": "hello world", "case": "capitalized"]).output["text"] == "Hello World")
        #expect(try await invoke(action, ["text": 42]).output["text"] == "42")
        await #expect(throws: AutomationActionError.self) { try await invoke(action, ["text": "x", "case": "shouting"]) }
        await #expect(throws: AutomationActionError.self) { try await invoke(action, [:]) }
    }

    @Test("Set Variable outputs its value; Stop Workflow finishes the run")
    func flowActions() async throws {
        let value: JSONValue = ["items": [1, 2], "label": "x"]
        let set = try await invoke(SetVariableAction(), ["value": value])
        #expect(set.output == value)
        #expect(set.flow == .proceed)
        let stop = try await invoke(StopRunAction(), ["reason": "Nothing to do"])
        #expect(stop.flow == .finishRun)
        #expect(stop.output == ["reason": "Nothing to do"])
        #expect(stop.message == "Nothing to do")
        #expect(try await invoke(StopRunAction(), [:]).output == .null)
    }

    @Test("action errors steer retries and are presentable")
    func actionErrors() {
        #expect(AutomationActionError.transient("busy").isRetryable)
        #expect(!AutomationActionError.permanent("gone").isRetryable)
        #expect(AutomationActionError.permanent("gone").presentation.message == "gone")
    }
}
