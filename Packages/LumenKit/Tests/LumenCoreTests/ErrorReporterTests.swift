import Foundation
import Testing
import LumenFoundation
import LumenCore
import LumenTestSupport

@Suite("ErrorReporter and secrets")
struct ErrorReporterTests {
    struct Friendly: PresentableError {
        var presentation: ErrorPresentation { ErrorPresentation(title: "Offline", message: "No connection.", isRetryable: true) }
    }

    struct Internal: Error {}

    @Test("reported errors are logged, retained and presented safely")
    func reporting() async throws {
        let environment = try await CoreTestEnvironment.make()
        let stream = environment.errors.issues()
        let friendly = environment.errors.report(Friendly(), context: "Syncing")
        let generic = environment.errors.report(Internal(), context: "Saving task")
        #expect(friendly.presentation.title == "Offline")
        #expect(generic.presentation.title == "Something went wrong")
        #expect(generic.technicalDescription.contains("Internal"))
        #expect(environment.errors.recentIssues.map(\.context) == ["Syncing", "Saving task"])
        #expect(environment.logs.entries(atLeast: .error).count == 2)

        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next()?.context == "Syncing")
    }

    @Test("in-memory secret store reads, overwrites and removes")
    func secrets() throws {
        let store = InMemorySecretStore()
        let key = SecretKey("provider.test")
        #expect(try store.secret(for: key) == nil)
        try store.setSecret("a", for: key)
        try store.setSecret("b", for: key)
        #expect(try store.secret(for: key) == "b")
        #expect(store.hasSecret(for: key))
        try store.removeSecret(for: key)
        #expect(!store.hasSecret(for: key))
    }
}
