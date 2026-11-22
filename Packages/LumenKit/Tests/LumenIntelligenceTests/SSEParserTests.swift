import Foundation
import Testing
@testable import LumenIntelligence

@Suite("SSEParser")
struct SSEParserTests {
    func parse(_ chunks: [Data]) -> [SSEEvent] {
        var parser = SSEParser()
        var events: [SSEEvent] = []
        for chunk in chunks {
            events += parser.feed(chunk)
        }
        return events + parser.finish()
    }

    func parse(_ text: String) -> [SSEEvent] {
        parse([Data(text.utf8)])
    }

    @Test("dispatches an event on a blank line with its type and data")
    func basic() {
        let events = parse("event: ping\ndata: {\"a\":1}\n\n")
        #expect(events == [SSEEvent(event: "ping", data: "{\"a\":1}")])
    }

    @Test("events without an event field are of type message")
    func defaultType() {
        #expect(parse("data: hello\n\n").map(\.event) == ["message"])
    }

    @Test("multi-line data is joined with newlines")
    func multiLineData() {
        #expect(parse("data: first\ndata: second\ndata:\ndata: fourth\n\n").map(\.data) == ["first\nsecond\n\nfourth"])
    }

    @Test("CRLF and lone CR line endings are accepted")
    func lineEndings() {
        let crlf = parse("event: a\r\ndata: 1\r\n\r\nevent: b\rdata: 2\r\r")
        #expect(crlf.map(\.event) == ["a", "b"])
        #expect(crlf.map(\.data) == ["1", "2"])
    }

    @Test("a CRLF split across chunks is one line ending, not two")
    func crlfAcrossChunks() {
        let events = parse([Data("data: x\r".utf8), Data("\ndata: y\r".utf8), Data("\n\r".utf8), Data("\n".utf8)])
        #expect(events.map(\.data) == ["x\ny"])
    }

    @Test("multi-byte characters split between chunks survive")
    func utf8AcrossChunks() {
        let text = "data: Grüße — 東京 🌍\n\n"
        let bytes = Array(text.utf8)
        let chunks = bytes.map { Data([$0]) }
        #expect(parse(chunks).map(\.data) == ["Grüße — 東京 🌍"])
    }

    @Test("byte-by-byte and arbitrary chunking produce the same events as one chunk")
    func chunkingInvariance() {
        let stream = Chunking.sse([("message_start", "{\"x\":\"é\"}"), (nil, "[DONE]")], lineEnding: "\r\n")
            + ": keep-alive\n" + "id: 7\ndata: last\n\n"
        let whole = parse(stream)
        #expect(whole.count == 3)
        for sizes in [[1], [2], [3, 1, 4], [5, 9, 2, 6], [64]] {
            #expect(parse(Chunking.split(stream, sizes: sizes)) == whole)
        }
    }

    @Test("comments are ignored")
    func comments() {
        #expect(parse(": this is a comment\n:another\ndata: x\n\n").map(\.data) == ["x"])
        #expect(parse(": only a comment\n\n").isEmpty)
    }

    @Test("only one leading space is removed from a value, and a missing space is fine")
    func valueSpaces() {
        #expect(parse("data:no-space\n\n").map(\.data) == ["no-space"])
        #expect(parse("data:  two\n\n").map(\.data) == [" two"])
    }

    @Test("a field without a colon has an empty value")
    func fieldWithoutColon() {
        #expect(parse("data\n\n").map(\.data) == [""])
    }

    @Test("blank lines without data dispatch nothing and reset the event type")
    func blankLinesWithoutData() {
        let events = parse("\n\nevent: lost\n\ndata: kept\n\n")
        #expect(events == [SSEEvent(event: "message", data: "kept")])
    }

    @Test("the last event ID persists across events and ignores values with NUL")
    func eventIDs() {
        let events = parse("id: 1\ndata: a\n\ndata: b\n\nid: bad\u{0}id\ndata: c\n\nid\ndata: d\n\n")
        #expect(events.map(\.id) == ["1", "1", "1", ""])
    }

    @Test("retry sets the reconnection time only for digits")
    func retryField() {
        var parser = SSEParser()
        _ = parser.feed("retry: 1500\n\nretry: soon\n\n")
        #expect(parser.reconnectionTime == 1500)
    }

    @Test("unknown fields are ignored")
    func unknownFields() {
        #expect(parse("foo: bar\ndata: x\n\n").map(\.data) == ["x"])
    }

    @Test("a leading byte order mark is ignored")
    func byteOrderMark() {
        let bytes: [UInt8] = [0xEF, 0xBB, 0xBF] + Array("data: x\n\n".utf8)
        #expect(parse([Data(bytes[..<2]), Data(bytes[2...])]).map(\.data) == ["x"])
    }

    @Test("finish dispatches a final event that lacks the closing blank line")
    func unterminatedFinalEvent() {
        #expect(parse("data: one\n\ndata: [DONE]").map(\.data) == ["one", "[DONE]"])
        #expect(parse("data: two\n").map(\.data) == ["two"])
    }

    @Test("events arrive as soon as their blank line does")
    func incremental() {
        var parser = SSEParser()
        #expect(parser.feed("data: a\n").isEmpty)
        #expect(parser.feed("\n").map(\.data) == ["a"])
        #expect(parser.feed("data: b\n\ndata: c").map(\.data) == ["b"])
        #expect(parser.finish().map(\.data) == ["c"])
    }
}
