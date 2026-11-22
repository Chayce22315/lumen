import Foundation
import LumenFoundation
import LumenCore

/// An attribute an event carries, offered by the editor when building trigger conditions.
public struct TriggerAttributeSpec: Sendable, Hashable, Codable {
    public enum ValueType: String, Sendable, Hashable, Codable, CaseIterable {
        case string, number, boolean, date, identifier
    }

    public var name: String
    public var title: String
    public var valueType: ValueType

    public init(name: String, title: String, valueType: ValueType) {
        self.name = name
        self.title = title
        self.valueType = valueType
    }

    /// The condition path for this attribute: `trigger.attributes.<name>`.
    public var path: String { "trigger.attributes.\(name)" }
}

/// Describes an event that can start a workflow.
public struct AutomationTriggerDescriptor: Sendable, Hashable, Codable, Identifiable {
    public var eventName: EventName
    public var title: String
    public var summary: String
    public var symbolName: String
    public var category: String
    public var attributes: [TriggerAttributeSpec]

    public init(
        eventName: EventName,
        title: String,
        summary: String,
        symbolName: String,
        category: String,
        attributes: [TriggerAttributeSpec] = []
    ) {
        self.eventName = eventName
        self.title = title
        self.summary = summary
        self.symbolName = symbolName
        self.category = category
        self.attributes = attributes
    }

    public var id: EventName { eventName }
}

/// A provider of trigger events (organization, knowledge, plugins). Engines publish events
/// regardless; sources only tell the editor which ones are meaningful triggers.
public protocol AutomationTriggerSource: Sendable {
    var triggers: [AutomationTriggerDescriptor] { get }
}
