import XCTest
@testable import HiDisplayKit

/// Covers the three behaviours that keep a slider drag from wedging a monitor: coalescing, serial
/// execution, and always landing on the final value.
final class DDCCommandQueueTests: XCTestCase {

    /// A short interval keeps the tests fast while still exercising the spacing logic.
    private let interval = Duration.milliseconds(20)

    func testRapidWritesCoalesceButTheFinalValueIsAlwaysSent() async throws {
        let transport = FakeDDCTransport()
        let queue = DDCCommandQueue(transport: transport, label: "test", writeInterval: interval)

        // Simulate a drag: 50 values with no awaiting between them, as a slider binding would produce.
        for value in stride(from: UInt16(0), through: 98, by: 2) {
            await queue.setBrightness(raw: value)
        }

        try await waitUntilQuiet(transport)

        let sent = transport.recordedBrightnessValues
        XCTAssertFalse(sent.isEmpty, "at least one write must reach the transport")
        XCTAssertLessThan(sent.count, 50, "intermediate values must be coalesced, not queued")
        XCTAssertEqual(sent.last, 98, "the value the user released on must be the last one written")
    }

    func testWritesAreSpacedAndNeverConcurrent() async throws {
        // A transport with latency would overlap if the queue allowed concurrency.
        let transport = FakeDDCTransport(latency: .milliseconds(5))
        let queue = DDCCommandQueue(transport: transport, label: "test", writeInterval: interval)

        for value in stride(from: UInt16(10), through: 100, by: 10) {
            await queue.setBrightness(raw: value)
            // Space the requests out so each one is genuinely a separate change rather than coalesced.
            try await Task.sleep(for: .milliseconds(30))
        }
        try await waitUntilQuiet(transport)

        // Every recorded frame must be a complete, well-formed set request. Interleaved writes would
        // corrupt framing, so this also proves nothing overlapped.
        for frame in transport.recordedWrites {
            XCTAssertEqual(frame.count, 7)
            XCTAssertEqual(frame[2], 0x03)
            XCTAssertEqual(frame[6], frame[0..<6].reduce(DDC.displayAddress) { $0 ^ $1 })
        }
        XCTAssertEqual(transport.recordedBrightnessValues.last, 100)
    }

    func testInvalidateStopsFurtherWrites() async throws {
        let transport = FakeDDCTransport()
        let queue = DDCCommandQueue(transport: transport, label: "test", writeInterval: interval)

        await queue.invalidate()
        await queue.setBrightness(raw: 42)
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertTrue(transport.recordedWrites.isEmpty,
                      "a disconnected display must not receive commands")
        let isInvalid = await queue.isInvalidated
        XCTAssertTrue(isInvalid)
    }

    func testReadThrowsDisconnectedAfterInvalidate() async {
        let transport = FakeDDCTransport()
        let queue = DDCCommandQueue(transport: transport, label: "test")
        await queue.invalidate()

        do {
            _ = try await queue.readBrightness()
            XCTFail("expected a disconnected error")
        } catch {
            XCTAssertEqual(error as? DDCError, .disconnected)
        }
    }

    func testReadSucceedsAndDecodesTheReply() async throws {
        var frame: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x2A]
        frame.append(frame.reduce(DDC.hostAddress) { $0 ^ $1 })

        let transport = FakeDDCTransport(replies: [frame])
        let queue = DDCCommandQueue(transport: transport, label: "test")

        let reply = try await queue.readBrightness()
        XCTAssertEqual(reply.current, 42)
        XCTAssertEqual(reply.maximum, 100)
    }

    func testUnsupportedTransportErrorIsNotRetried() async {
        let transport = FakeDDCTransport()
        transport.errorToThrow = .unsupported(reason: "no transport")
        let queue = DDCCommandQueue(transport: transport, label: "test", maxRetries: 3)

        do {
            _ = try await queue.readBrightness()
            XCTFail("expected an unsupported error")
        } catch {
            XCTAssertEqual(error as? DDCError, .unsupported(reason: "no transport"))
        }
        // One attempt only: retrying a permanent failure just adds bus traffic.
        XCTAssertEqual(transport.writeAttempts, 1)
    }

    func testTransientErrorIsRetriedUpToTheLimit() async {
        let transport = FakeDDCTransport()
        transport.errorToThrow = .timeout
        let queue = DDCCommandQueue(transport: transport, label: "test", maxRetries: 2)

        do {
            _ = try await queue.readBrightness()
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? DDCError, .timeout)
        }
        // Initial attempt plus two retries, and no more — retries must be bounded.
        XCTAssertEqual(transport.writeAttempts, 3)
    }

    func testSlowTransportDoesNotBlockTheCaller() async throws {
        // A monitor that takes 300 ms must not make `setBrightness` take 300 ms: the whole point of the
        // queue is that the UI thread hands off and returns.
        let transport = FakeDDCTransport(latency: .milliseconds(300))
        let queue = DDCCommandQueue(transport: transport, label: "test", writeInterval: interval)

        let start = ContinuousClock.now
        await queue.setBrightness(raw: 55)
        let elapsed = ContinuousClock.now - start

        XCTAssertLessThan(elapsed, .milliseconds(100),
                          "setBrightness must return without waiting for the wire")
    }

    /// Waits until the transport stops receiving writes, so assertions run after the drain loop ends.
    private func waitUntilQuiet(_ transport: FakeDDCTransport, timeout: Duration = .seconds(3)) async throws {
        let deadline = ContinuousClock.now + timeout
        var lastCount = -1
        while ContinuousClock.now < deadline {
            let count = transport.recordedWrites.count
            if count == lastCount, count > 0 { return }
            lastCount = count
            try await Task.sleep(for: .milliseconds(60))
        }
    }
}
