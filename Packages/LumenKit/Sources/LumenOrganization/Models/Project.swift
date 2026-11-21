import Foundation
import LumenFoundation

public enum ProjectStatus: String, Sendable, Codable, Hashable, CaseIterable {
    case planned
    case active
    case onHold
    case completed
    case archived

    public var title: String {
        switch self {
        case .planned: return "Planned"
        case .active: return "Active"
        case .onHold: return "On hold"
        case .completed: return "Completed"
        case .archived: return "Archived"
        }
    }

    public var isLive: Bool { self == .planned || self == .active || self == .onHold }
}

/// Identity colors a project can use. The design system maps each to a palette token.
public enum ProjectColor: String, Sendable, Codable, Hashable, CaseIterable {
    case blue, indigo, teal, green, amber, orange, rose, slate
}

public struct Project: Sendable, Hashable, Codable, Identifiable {
    public typealias ID = Identifier<Project>

    public let id: ID
    public var name: String
    public var summary: String
    public var status: ProjectStatus
    public var color: ProjectColor
    public var startDate: CalendarDate?
    public var targetDate: CalendarDate?
    public var sortOrder: Double
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?

    public init(
        id: ID = ID(),
        name: String,
        summary: String = "",
        status: ProjectStatus = .active,
        color: ProjectColor = .blue,
        startDate: CalendarDate? = nil,
        targetDate: CalendarDate? = nil,
        sortOrder: Double = 0,
        createdAt: Date,
        updatedAt: Date,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.status = status
        self.color = color
        self.startDate = startDate
        self.targetDate = targetDate
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }

    public var reference: EntityReference { EntityReference(kind: .project, id: id) }
}

extension Project {
    private enum CodingKeys: String, CodingKey {
        case id, name, summary, status, color, startDate, targetDate, sortOrder, createdAt, updatedAt, completedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(ID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        self.status = try c.decodeIfPresent(ProjectStatus.self, forKey: .status) ?? .active
        self.color = try c.decodeIfPresent(ProjectColor.self, forKey: .color) ?? .blue
        self.startDate = try c.decodeIfPresent(CalendarDate.self, forKey: .startDate)
        self.targetDate = try c.decodeIfPresent(CalendarDate.self, forKey: .targetDate)
        self.sortOrder = try c.decodeIfPresent(Double.self, forKey: .sortOrder) ?? 0
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        self.completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
    }
}
