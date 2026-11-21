import Foundation
import Testing
import LumenFoundation
import LumenCore
import LumenTestSupport

@Suite("EventBus")
struct EventBusTests {
    let date = ManualTimeSource.referenceDate

    @Test("subscribers receive matching events in publish order")
    func delivery() async {
        let bus = EventBus()
        let all = EventRecorder(bus: bus)
        let tasksOnly = EventRecorder(bus: bus, filter: EventFilter(entityKinds: ["task"]))
        let named = EventRecorder(bus: bus, filter: EventFilter(names: ["organization.task.completed"]))
        bus.publish(DomainEvent(name: "organization.task.created", entity: EntityReference(kind: "task", id: UUID()), occurredAt: date))
        bus.publish(DomainEvent(name: "knowledge.note.created", entity: EntityReference(kind: "note", id: UUID()), occurredAt: date))
        bus.publish(DomainEvent(name: "organization.task.completed", entity: EntityReference(kind: "task", id: UUID()), occurredAt: date))

        #expect(await all.waitForEvents(3).map(\.name.rawValue) == [
            "organization.task.created", "knowledge.note.created", "organization.task.completed",
        ])
        #expect(await tasksOnly.waitForEvents(2).count == 2)
        #expect(await named.waitForEvents(1).map(\.name) == ["organization.task.completed"])
    }

    @Test("module filters use the first name segment")
    func moduleFilter() {
        let filter = EventFilter(modules: ["knowledge"])
        #expect(filter.matches(DomainEvent(name: "knowledge.note.created", occurredAt: date)))
        #expect(!filter.matches(DomainEvent(name: "organization.task.created", occurredAt: date)))
    }

    @Test("cancelled subscriptions are removed")
    func unsubscribe() async {
        let bus = EventBus()
        let recorder = EventRecorder(bus: bus)
        #expect(bus.subscriberCount == 1)
        recorder.stop()
        let deadline = Date().addingTimeInterval(2)
        while bus.subscriberCount > 0 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(bus.subscriberCount == 0)
    }

    @Test("action context stamps actor and causation on events")
    func context() {
        let correlation = UUID()
        let context = ActionContext(actor: .automation, correlationID: correlation, causationDepth: 2)
        let event = context.event("x.y.z", at: date)
        #expect(event.actor == .automation)
        #expect(event.correlationID == correlation)
        #expect(event.causationDepth == 2)
    }
}
