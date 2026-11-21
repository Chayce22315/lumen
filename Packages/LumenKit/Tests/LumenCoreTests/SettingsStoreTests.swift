import Foundation
import Testing
import LumenFoundation
import LumenCore
import LumenTestSupport

@Suite("SettingsStore")
struct SettingsStoreTests {
    struct Layout: Codable, Equatable, Sendable {
        var order: [String]
    }

    static let layoutKey = SettingKey("test.layout", default: Layout(order: ["a"]))
    static let countKey = SettingKey("test.count", default: 3)

    @Test("unset keys return their default")
    func defaults() async throws {
        let environment = try await CoreTestEnvironment.make()
        #expect(await environment.settings.value(Self.layoutKey) == Layout(order: ["a"]))
    }

    @Test("values persist across store instances and publish a change event")
    func persistence() async throws {
        let environment = try await CoreTestEnvironment.make()
        let recorder = EventRecorder(bus: environment.events)
        try await environment.settings.set(Layout(order: ["b", "c"]), for: Self.layoutKey)
        let reopened = SettingsStore(database: environment.database, events: environment.events, timeSource: environment.clock, logger: .disabled())
        #expect(await reopened.value(Self.layoutKey) == Layout(order: ["b", "c"]))
        let events = await recorder.waitForEvents(1)
        #expect(events.first?.name == SettingsStore.changedEvent)
        #expect(events.first?.attributes["key"] == "test.layout")
    }

    @Test("reset restores the default")
    func reset() async throws {
        let environment = try await CoreTestEnvironment.make()
        try await environment.settings.set(9, for: Self.countKey)
        #expect(await environment.settings.value(Self.countKey) == 9)
        try await environment.settings.reset(Self.countKey)
        #expect(await environment.settings.value(Self.countKey) == 3)
    }

    @Test("an unreadable stored value falls back to the default and is logged")
    func corruptValue() async throws {
        let environment = try await CoreTestEnvironment.make()
        try await environment.database.write { db in
            try db.execute("INSERT INTO core_settings (key, value, updated_at) VALUES ('test.count', '\"not a number\"', 0)")
        }
        #expect(await environment.settings.value(Self.countKey) == 3)
        #expect(environment.logs.entries(atLeast: .warning).contains { $0.metadata["key"] == "test.count" })
    }
}
