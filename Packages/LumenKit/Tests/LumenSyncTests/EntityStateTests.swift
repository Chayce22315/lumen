import Foundation
import Testing
import LumenFoundation
import LumenPersistence
import LumenSync

@Suite("EntityState and builder")
struct EntityStateTests {
    func ts(_ ms: Int64, _ replica: String = "a") -> HybridTimestamp {
        HybridTimestamp(milliseconds: ms, counter: 0, replica: replica)
    }

    func state(_ fields: [String: (JSONValue?, Int64)], tombstone: Int64? = nil, replica: String = "a") -> EntityState {
        EntityState(fields: fields.mapValues { FieldState(value: $0.0, timestamp: ts($0.1, replica)) }, tombstone: tombstone.map { ts($0, replica) })
    }

    @Test("merge is commutative, associative and idempotent")
    func crdtLaws() {
        let a = state(["title": ("A", 10), "body": ("x", 5)], replica: "a")
        let b = state(["title": ("B", 12), "pinned": (true, 3)], replica: "b")
        let c = state(["body": ("z", 20)], tombstone: 8, replica: "c")
        #expect(a.merged(with: b) == b.merged(with: a))
        #expect(a.merged(with: b).merged(with: c) == a.merged(with: b.merged(with: c)))
        #expect(a.merged(with: a) == a)
        let merged = a.merged(with: b).merged(with: c)
        #expect(merged.snapshot == ["title": "B", "body": "z", "pinned": true])
    }

    @Test("a tombstone deletes only when it is the newest write")
    func tombstones() {
        #expect(state(["title": ("A", 10)], tombstone: 11).isDeleted)
        #expect(!state(["title": ("A", 12)], tombstone: 11).isDeleted)
        #expect(state([:], tombstone: 1).snapshot == nil)
        #expect(EntityState.empty.snapshot == nil)
        // An absent value removes the key from the snapshot.
        #expect(state(["title": ("A", 1), "pinned": (nil, 2)]).snapshot == ["title": "A"])
    }

    @Test("the builder stamps only fields each local change actually modified")
    func preciseStamps() {
        let entity = EntityReference(kind: "memo", id: UUID())
        let shadow = state(["title": ("Old", 1), "body": ("Body", 1)], replica: "s")
        func change(_ sequence: Int64, _ payload: JSONValue?, _ ms: Int64, origin: ChangeOrigin = .local, op: ChangeOperation = .upsert) -> ChangeRecord {
            ChangeRecord(sequence: sequence, entity: entity, operation: op, payload: payload, timestamp: ts(ms, origin == .local ? "me" : "them"), origin: origin, recordedAt: Date())
        }
        let local = EntityStateBuilder.localState(shadow: shadow, previous: .some(["title": "Old", "body": "Body"]), pending: [
            change(5, ["title": "New", "body": "Body"], 50),
            // A remote merge brought in a body change; it must not be restamped as local.
            change(6, ["title": "New", "body": "Remote body"], 40, origin: .remote),
            change(7, ["title": "Newer", "body": "Remote body"], 60),
        ])
        #expect(local.fields["title"] == FieldState(value: "Newer", timestamp: ts(60, "me")))
        #expect(local.fields["body"] == FieldState(value: "Body", timestamp: ts(1, "s")))

        let deleted = EntityStateBuilder.localState(shadow: shadow, previous: nil, pending: [change(8, nil, 70, op: .delete)])
        #expect(deleted.isDeleted)
    }

    @Test("conflicts are fields both sides changed since the shadow")
    func conflictDetection() {
        let shadow = state(["title": ("Base", 1), "body": ("Base", 1)], replica: "s")
        let local = state(["title": ("Mine", 5), "body": ("Base", 1)], replica: "a")
        let remote = state(["title": ("Theirs", 7), "body": ("Edited", 6)], replica: "b")
        let conflicts = EntityStateBuilder.conflicts(shadow: shadow, local: local, remote: remote)
        #expect(conflicts.map(\.field) == ["title"])
        #expect(conflicts.first?.chosen == .remote)
        #expect(conflicts.first?.localValue == "Mine")
    }
}
