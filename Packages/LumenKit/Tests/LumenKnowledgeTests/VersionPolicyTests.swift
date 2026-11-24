import Foundation
import Testing
import LumenKnowledge
import LumenTestSupport

@Suite("VersionPolicy")
struct VersionPolicyTests {
    let policy = VersionPolicy()
    let start = ManualTimeSource.referenceDate
    let noteID = Note.ID()
    let tenLines = (1...10).map { "line \($0)" }.joined(separator: "\n")

    func version(_ body: String, title: String = "T", at offset: TimeInterval = 0) -> NoteVersion {
        NoteVersion(noteID: noteID, title: title, body: body, savedAt: start.addingTimeInterval(offset))
    }

    @Test("defaults: 10 minutes, 30% of lines, 50 versions")
    func defaults() {
        #expect(policy.minimumInterval == 600)
        #expect(policy.largeChangeFraction == 0.3)
        #expect(policy.maximumVersionsPerNote == 50)
    }

    @Test("the first save always creates a version")
    func firstSave() {
        #expect(policy.evaluate(latest: nil, title: "", body: "", now: start) == .firstVersion)
    }

    @Test("unchanged content never creates a version, however old the latest one")
    func unchanged() {
        let latest = version(tenLines)
        #expect(policy.evaluate(latest: latest, title: "T", body: tenLines, now: start.addingTimeInterval(86_400)) == .unchanged)
    }

    @Test("small edits coalesce until the interval elapses")
    func interval() {
        let latest = version(tenLines)
        let edited = tenLines + " edited"
        #expect(policy.evaluate(latest: latest, title: "T", body: edited, now: start.addingTimeInterval(599)) == .tooRecent)
        #expect(policy.evaluate(latest: latest, title: "T", body: edited, now: start.addingTimeInterval(600)) == .intervalElapsed)
        #expect(policy.evaluate(latest: latest, title: "New title", body: tenLines, now: start.addingTimeInterval(60)) == .tooRecent)
        #expect(!policy.shouldCreateVersion(latest: latest, title: "T", body: edited, now: start.addingTimeInterval(1)))
    }

    @Test("large changes create a version immediately; exactly 30% does not")
    func largeChange() {
        let latest = version(tenLines)
        var lines = tenLines.components(separatedBy: "\n")
        for index in 0..<3 { lines[index] = "changed \(index)" }
        // 3 of 10 lines replaced: (3 + 3) / (10 + 10) = 0.3, not more than 0.3.
        #expect(policy.evaluate(latest: latest, title: "T", body: lines.joined(separator: "\n"), now: start.addingTimeInterval(1)) == .tooRecent)
        lines[3] = "changed 3"
        #expect(policy.evaluate(latest: latest, title: "T", body: lines.joined(separator: "\n"), now: start.addingTimeInterval(1)) == .largeChange)
        #expect(policy.evaluate(latest: version(""), title: "T", body: "brand new", now: start) == .largeChange)
    }

    @Test("pruning keeps the newest versions")
    func pruning() {
        let small = VersionPolicy(maximumVersionsPerNote: 3)
        let versions = (0..<5).map { version("v\($0)", at: TimeInterval($0) * 60) }
        let pruned = small.versionsToPrune(versions.shuffled())
        #expect(Set(pruned) == Set([versions[0].id, versions[1].id]))
        #expect(small.versionsToPrune(Array(versions.prefix(3))).isEmpty)

        // Same instant: earlier in the (newest-first) input counts as newer.
        let tied = [version("a"), version("b"), version("c"), version("d")]
        #expect(small.versionsToPrune(tied) == [tied[3].id])
    }

    @Test("configuration values are clamped to sensible ranges")
    func clamping() {
        let odd = VersionPolicy(minimumInterval: -5, largeChangeFraction: 4, maximumVersionsPerNote: 0)
        #expect(odd.minimumInterval == 0)
        #expect(odd.largeChangeFraction == 1)
        #expect(odd.maximumVersionsPerNote == 1)
        #expect(VersionPolicy.Outcome.allCases.filter(\.createsVersion) == [.firstVersion, .intervalElapsed, .largeChange])
    }
}
