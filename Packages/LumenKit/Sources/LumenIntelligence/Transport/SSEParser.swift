import Foundation

/// One dispatched server-sent event.
public struct SSEEvent: Sendable, Hashable {
    /// The `event:` field, or `"message"` when the event had none.
    public var event: String
    /// `data:` lines joined with `\n`.
    public var data: String
    /// The last event ID seen on the stream so far (it persists across events).
    public var id: String?

    public init(event: String = "message", data: String, id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}

/// Incremental parser for `text/event-stream` (WHATWG HTML, "Server-sent events").
///
/// Pure and push-based: feed byte chunks split anywhere — including inside a UTF-8 sequence or
/// between the `\r` and `\n` of a line ending — and collect the events completed by each chunk.
/// Lines end with `\n`, `\r\n` or a lone `\r`. Lines are split on bytes and decoded only once
/// complete, so multi-byte characters can never be cut in half.
///
/// One deliberate deviation from the specification: `finish()` dispatches a pending event that
/// was not followed by a blank line, because several OpenAI-compatible servers end their stream
/// right after the last `data:` line.
public struct SSEParser: Sendable {
    private var line: [UInt8] = []
    private var lastByteWasCR = false
    private var atStreamStart = true
    private var dataBuffer = ""
    private var hasData = false
    private var eventType = ""
    private var lastEventID: String?

    /// The most recent valid `retry:` value, in milliseconds.
    public private(set) var reconnectionTime: Int?

    public init() {}

    /// Consumes a chunk and returns the events it completed, in order.
    public mutating func feed(_ chunk: Data) -> [SSEEvent] {
        var events: [SSEEvent] = []
        for byte in chunk {
            if lastByteWasCR {
                lastByteWasCR = false
                // The `\n` of a `\r\n` pair, possibly delivered in the next chunk.
                if byte == 0x0A { continue }
            }
            switch byte {
            case 0x0A, 0x0D:
                lastByteWasCR = byte == 0x0D
                if let event = processLine() { events.append(event) }
                line.removeAll(keepingCapacity: true)
            default:
                line.append(byte)
            }
        }
        return events
    }

    public mutating func feed(_ text: String) -> [SSEEvent] {
        feed(Data(text.utf8))
    }

    /// Signals the end of the stream: processes an unterminated last line and dispatches any
    /// pending event (see the type documentation).
    public mutating func finish() -> [SSEEvent] {
        var events: [SSEEvent] = []
        if !line.isEmpty {
            if let event = processLine() { events.append(event) }
            line.removeAll()
        }
        if let event = dispatch() { events.append(event) }
        lastByteWasCR = false
        return events
    }

    private mutating func processLine() -> SSEEvent? {
        var bytes = line[...]
        if atStreamStart {
            atStreamStart = false
            // A UTF-8 byte order mark at the very start of the stream is ignored.
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
                bytes = bytes.dropFirst(3)
            }
        }
        if bytes.isEmpty {
            return dispatch()
        }
        if bytes.first == 0x3A {
            // `:` starts a comment (servers use them as keep-alives).
            return nil
        }
        let field: String
        var value: String
        if let colon = bytes.firstIndex(of: 0x3A) {
            field = String(decoding: bytes[bytes.startIndex..<colon], as: UTF8.self)
            var valueBytes = bytes[bytes.index(after: colon)...]
            if valueBytes.first == 0x20 {
                valueBytes = valueBytes.dropFirst()
            }
            value = String(decoding: valueBytes, as: UTF8.self)
        } else {
            field = String(decoding: bytes, as: UTF8.self)
            value = ""
        }
        switch field {
        case "event":
            eventType = value
        case "data":
            value.append("\n")
            dataBuffer.append(value)
            hasData = true
        case "id":
            if !value.contains("\u{0}") {
                lastEventID = value
            }
        case "retry":
            if !value.isEmpty, value.utf8.allSatisfy({ (0x30...0x39).contains($0) }), let milliseconds = Int(value) {
                reconnectionTime = milliseconds
            }
        default:
            // Unknown fields are ignored, as the specification requires.
            break
        }
        return nil
    }

    private mutating func dispatch() -> SSEEvent? {
        defer {
            dataBuffer = ""
            hasData = false
            eventType = ""
        }
        guard hasData else { return nil }
        var data = dataBuffer
        if data.hasSuffix("\n") {
            data.removeLast()
        }
        return SSEEvent(event: eventType.isEmpty ? "message" : eventType, data: data, id: lastEventID)
    }
}
