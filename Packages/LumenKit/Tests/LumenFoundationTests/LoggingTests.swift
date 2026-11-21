import Foundation
import Testing
import LumenFoundation
import LumenTestSupport

@Suite("Logging")
struct LoggingTests {
    @Test("entries below the minimum level are dropped without building the message")
    func filtering() {
        let capture = LogCapture()
        let system = LoggingSystem(sinks: [capture], minimumLevel: .warning)
        let logger = system.logger("test")
        var built = false
        logger.debug({ built = true; return "expensive" }())
        logger.warning("kept", metadata: ["k": "v"])
        #expect(built == false)
        #expect(capture.recorded.map(\.message) == ["kept"])
        #expect(capture.recorded.first?.metadata == ["k": "v"])
        #expect(capture.recorded.first?.category == "test")
    }

    @Test("ring buffer keeps the newest entries in order")
    func ringBuffer() {
        let ring = RingBufferLogSink(capacity: 3)
        let logger = LoggingSystem(sinks: [ring], minimumLevel: .debug).logger("ring")
        for index in 1...5 {
            logger.info("entry \(index)")
        }
        #expect(ring.snapshot().map(\.message) == ["entry 3", "entry 4", "entry 5"])
        ring.clear()
        #expect(ring.snapshot().isEmpty)
    }

    @Test("error overload records the error type")
    func errorMetadata() {
        struct Boom: Error {}
        let capture = LogCapture()
        capture.makeSystem().logger("x").error("failed", error: Boom())
        #expect(capture.recorded.first?.metadata["error.type"] == "Boom")
    }
}
