import Foundation
import LumenFoundation
import LumenCore
import LumenApplication
import LumenPresentation
import LumenTestSupport

let posix = Locale(identifier: "en_US_POSIX")

/// A started Lumen on an in-memory database with a manual clock.
func makeServices(clock: ManualTimeSource = ManualTimeSource()) async throws -> (LumenServices, LumenRuntime) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-ui-\(UUID().uuidString)")
    let services = try await LumenBootstrap.make(
        configuration: AppConfiguration(flavor: .test, dataDirectory: directory),
        platform: .ephemeral(),
        timeSource: clock,
        calendar: .testUTC
    )
    let runtime = LumenRuntime(services: services)
    await runtime.start()
    return (services, runtime)
}

/// Polls a main-actor condition (bounded).
@MainActor
func eventually(timeout: TimeInterval = 10, _ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}
