import Foundation
import Testing
import Synchronization
import LumenFoundation
import LumenCore
import LumenNotifications
import LumenTestSupport

final class RecordingScheduler: SystemNotificationScheduling {
    let status: NotificationAuthorization
    let scheduled = Mutex<[SystemNotificationRequest]>([])
    let cancelled = Mutex<[String]>([])

    init(status: NotificationAuthorization = .authorized) {
        self.status = status
    }

    func authorization() async -> NotificationAuthorization { status }
    func requestAuthorization() async throws -> Bool { status == .authorized }
    func schedule(_ request: SystemNotificationRequest) async throws {
        scheduled.withLock { $0.append(request) }
    }
    func cancel(identifiers: [String]) async {
        cancelled.withLock { $0.append(contentsOf: identifiers) }
    }
}

@Suite("NotificationService")
struct NotificationServiceTests {
    func make(status: NotificationAuthorization = .authorized) async throws -> (NotificationService, RecordingScheduler, CoreTestEnvironment) {
        let environment = try await CoreTestEnvironment.make(schemas: [NotificationService.schema])
        let scheduler = RecordingScheduler(status: status)
        let service = NotificationService(
            database: environment.database,
            settings: environment.settings,
            scheduler: scheduler,
            events: environment.events,
            timeSource: environment.clock,
            calendar: environment.calendar,
            logger: environment.logger("notifications")
        )
        return (service, scheduler, environment)
    }

    @Test("immediate notifications land in the inbox and as system alerts")
    func immediate() async throws {
        let (service, scheduler, _) = try await make()
        let entity = EntityReference(kind: "task", id: UUID())
        let posted = try #require(try await service.post(NotificationDraft(category: .automation, title: "Done", body: "Workflow finished", entity: entity)))
        #expect(try await service.inbox().map(\.id) == [posted.id])
        #expect(try await service.unreadCount() == 1)
        let request = try #require(scheduler.scheduled.withLock { $0.first })
        #expect(request.fireDate == nil)
        #expect(request.deepLink == "lumen://entity/\(entity.uri)")
        try await service.markAllRead()
        #expect(try await service.unreadCount() == 0)
    }

    @Test("scheduled reminders stay out of the inbox until due and can be cancelled")
    func scheduledReminder() async throws {
        let (service, scheduler, environment) = try await make()
        let entity = EntityReference(kind: "task", id: UUID())
        let due = environment.clock.now().addingTimeInterval(3_600)
        try await service.post(NotificationDraft(category: .reminder, title: "Call", body: "", entity: entity, deliverAt: due))
        #expect(try await service.inbox().isEmpty)
        #expect(try await service.upcoming().count == 1)
        #expect(scheduler.scheduled.withLock { $0.first?.fireDate } == due)

        try await service.cancelPending(for: entity)
        #expect(try await service.upcoming().isEmpty)
        #expect(scheduler.cancelled.withLock { $0.count } == 1)
    }

    @Test("quiet hours defer the alert but not the inbox entry")
    func quietHours() async throws {
        let (service, scheduler, environment) = try await make()
        // Reference time is 09:00 UTC; quiet from 08:00 to 10:00.
        try await service.updatePreferences(NotificationPreferences(quietHours: QuietHours(startMinute: 480, endMinute: 600)))
        try await service.post(NotificationDraft(category: .automation, title: "Ping", body: ""))
        let fire = try #require(scheduler.scheduled.withLock { $0.first?.fireDate })
        #expect(fire == environment.clock.now().addingTimeInterval(3_600))
        #expect(try await service.inbox().count == 1)

        try await service.post(NotificationDraft(category: .reminder, title: "Urgent", body: "", bypassesQuietHours: true))
        #expect(scheduler.scheduled.withLock { $0.last?.fireDate } == nil)
    }

    @Test("disabled categories and denied authorization are respected")
    func preferences() async throws {
        let (service, scheduler, _) = try await make(status: .denied)
        var preferences = NotificationPreferences()
        preferences.categories[.insight] = CategoryPreference(showsInInbox: false, deliversAlert: false)
        try await service.updatePreferences(preferences)
        #expect(try await service.post(NotificationDraft(category: .insight, title: "Weekly", body: "")) == nil)
        try await service.post(NotificationDraft(category: .automation, title: "Ran", body: ""))
        #expect(scheduler.scheduled.withLock { $0.isEmpty })
        #expect(try await service.inbox().count == 1)
    }
}
