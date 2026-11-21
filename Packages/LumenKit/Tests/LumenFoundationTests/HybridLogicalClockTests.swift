import Foundation
import Testing
import LumenFoundation

@Suite("HybridLogicalClock")
struct HybridLogicalClockTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("local ticks are strictly increasing even when the wall clock stalls or goes backwards")
    func monotonic() {
        var clock = HybridLogicalClock(replica: "a")
        let first = clock.tick(now: t0)
        let second = clock.tick(now: t0)
        let third = clock.tick(now: t0.addingTimeInterval(-10))
        #expect(first < second)
        #expect(second < third)
        #expect(third.milliseconds == first.milliseconds)
        let fourth = clock.tick(now: t0.addingTimeInterval(1))
        #expect(fourth.counter == 0)
        #expect(third < fourth)
    }

    @Test("receiving a timestamp from the future orders later local events after it")
    func receive() {
        var local = HybridLogicalClock(replica: "a")
        var remote = HybridLogicalClock(replica: "b")
        let remoteEvent = remote.tick(now: t0.addingTimeInterval(60)) // remote clock runs ahead
        let merged = local.receive(remoteEvent, now: t0)
        #expect(merged > remoteEvent)
        let next = local.tick(now: t0)
        #expect(next > remoteEvent)
    }

    @Test("string form sorts in timestamp order")
    func lexicographic() {
        let values = [
            HybridTimestamp(milliseconds: 5, counter: 10, replica: "z"),
            HybridTimestamp(milliseconds: 1_800_000_000_000, counter: 0, replica: "a"),
            HybridTimestamp(milliseconds: 5, counter: 9, replica: "z"),
            HybridTimestamp(milliseconds: 5, counter: 10, replica: "a"),
        ]
        let byValue = values.sorted()
        let byString = values.sorted { $0.description < $1.description }
        #expect(byValue == byString)
        for value in values {
            #expect(HybridTimestamp(value.description) == value)
        }
    }

    @Test("replica identifiers may contain dashes")
    func parsingReplicaWithSeparator() {
        let value = HybridTimestamp(milliseconds: 42, counter: 7, replica: "device-one")
        #expect(HybridTimestamp(value.description) == value)
        #expect(HybridTimestamp("not-a-timestamp") == nil)
    }
}
