import Foundation
import Testing
import LumenFoundation

@Suite("JSONValue")
struct JSONValueTests {
    struct Sample: Codable, Equatable {
        var title: String
        var count: Int
        var flags: [Bool]
        var nested: [String: Double]
    }

    @Test("decodes booleans as booleans, not numbers")
    func booleanPrecedence() throws {
        let value = try JSONValue(parsing: #"{"a": true, "b": 1, "c": 1.5, "d": null, "e": "x"}"#)
        #expect(value["a"] == .bool(true))
        #expect(value["b"] == .number(1))
        #expect(value["b"]?.intValue == 1)
        #expect(value["c"]?.intValue == nil)
        #expect(value["d"]?.isNull == true)
        #expect(value["e"]?.stringValue == "x")
    }

    @Test("round-trips typed values")
    func typedRoundTrip() throws {
        let sample = Sample(title: "Plan", count: 3, flags: [true, false], nested: ["x": 0.5])
        let json = try JSONValue(encoding: sample)
        #expect(json["title"] == "Plan")
        #expect(try json.decode(as: Sample.self) == sample)
    }

    @Test("compact string is deterministic")
    func deterministic() throws {
        let a: JSONValue = ["b": 1, "a": [true, nil, "s"]]
        let b: JSONValue = ["a": [true, nil, "s"], "b": 1]
        #expect(try a.compactString() == b.compactString())
        #expect(try a.compactString() == #"{"a":[true,null,"s"],"b":1}"#)
    }

    @Test("display string renders whole numbers without a fraction")
    func display() {
        #expect(JSONValue.number(3).displayString == "3")
        #expect(JSONValue.number(2.5).displayString == "2.5")
        #expect(JSONValue.string("hi").displayString == "hi")
        #expect(JSONValue.null.displayString == "")
    }
}
