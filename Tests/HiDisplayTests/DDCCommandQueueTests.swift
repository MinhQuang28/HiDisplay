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
            XCTAssertEqual(frame.count, 7, "the queue's default shape sends the host address")
            XCTAssertEqual(frame[2], 0x03)
            XCTAssertEqual(frame[6], frame[0..<6].reduce(DDC.displayAddress) { $0 ^ $1 })
        }
        XCTAssertEqual(transport.recordedBrightnessValues.last, 100)

        // And "spaced" is measured, not assumed: consecutive write starts must be at least the
        // configured interval apart. `Task.sleep` never wakes early, so no tolerance is needed.
        let instants = transport.writeInstants
        XCTAssertGreaterThan(instants.count, 1, "the test needs at least two writes to measure a gap")
        for (earlier, later) in zip(instants, instants.dropFirst()) {
            XCTAssertGreaterThanOrEqual(
                earlier.duration(to: later), interval,
                "two frames went out closer together than the minimum spacing")
        }
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

    /// Records the *kind* of each transport call in order, so a test can prove a get/reply
    /// transaction was never split by a set write. Small latencies widen the windows a reentrancy
    /// bug would need.
    private final class InterleaveDetectingTransport: DDCTransport, @unchecked Sendable {
        enum Op: Equatable { case setWrite, getWrite, read }
        let name = "interleave-detecting"
        var isUsable: Bool { true }

        private let lock = NSLock()
        private var ops: [Op] = []
        private let reply: [UInt8]

        init(reply: [UInt8]) { self.reply = reply }

        func write(_ bytes: [UInt8]) async throws {
            let opcodeIndex = bytes.first == DDC.hostAddress ? 2 : 1
            let op: Op = bytes.count > opcodeIndex + 1 && bytes[opcodeIndex] == 0x03 ? .setWrite : .getWrite
            lock.withLock { ops.append(op) }
            try await Task.sleep(for: .milliseconds(5))
        }

        func read(length: Int) async throws -> [UInt8] {
            lock.withLock { ops.append(.read) }
            try await Task.sleep(for: .milliseconds(5))
            return reply
        }

        var snapshot: [Op] { lock.withLock { ops } }
    }

    /// The queue's central promise: exactly one frame on the wire at a time. Actor isolation alone
    /// does not deliver it — every `await` is a suspension point, so without an explicit bus token a
    /// drain loop can slip a Set frame into the ~50 ms gap between a Get request and its reply.
    func testAReadTransactionIsNeverInterleavedWithWrites() async throws {
        var frame: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x2A]
        frame.append(frame.reduce(DDC.replyChecksumSeed) { $0 ^ $1 })
        let transport = InterleaveDetectingTransport(reply: frame)
        let queue = DDCCommandQueue(transport: transport, label: "test", writeInterval: .milliseconds(1))

        // Several reads while a stream of writes arrives, so every reply-delay window is contested.
        let reads = Task {
            for _ in 0..<5 { _ = try await queue.readBrightness() }
        }
        for value: UInt16 in 1...30 {
            await queue.setBrightness(raw: value)
            try await Task.sleep(for: .milliseconds(8))
        }
        try await reads.value

        let ops = transport.snapshot
        XCTAssertEqual(ops.filter { $0 == .getWrite }.count, 5)
        for (index, op) in ops.enumerated() where op == .getWrite {
            XCTAssertEqual(
                ops[index + 1], .read,
                "a set write landed inside a get/reply transaction at index \(index)")
        }
    }

    /// A display that answers only one frame shape, like a real one on a given DisplayPort mode.
    ///
    /// Everything else gets the null message — which is what makes this bug so hard to see from the
    /// outside: nothing errors, nothing times out, the monitor politely says nothing at all.
    private final class ShapeSensitiveTransport: DDCTransport, @unchecked Sendable {
        let name = "shape-sensitive"
        var isUsable: Bool { true }

        private let answers: DDC.FrameShape
        private let current: UInt8
        private let lock = NSLock()
        private var lastWriteMatched = false
        private(set) var shapesSeen: [DDC.FrameShape] = []

        init(answers: DDC.FrameShape, current: UInt8) {
            self.answers = answers
            self.current = current
        }

        func write(_ bytes: [UInt8]) async throws {
            let shape: DDC.FrameShape =
                bytes.first == DDC.hostAddress ? .withHostAddress : .withoutHostAddress
            lock.withLock {
                shapesSeen.append(shape)
                lastWriteMatched = shape == answers
            }
        }

        func read(length: Int) async throws -> [UInt8] {
            let matched = lock.withLock { lastWriteMatched }
            guard matched else {
                return Array(repeating: VCPCodec.nullMessage, count: 4).flatMap { $0 }
            }
            var frame: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, current]
            frame.append(frame.reduce(DDC.replyChecksumSeed) { $0 ^ $1 })
            return frame
        }
    }

    /// The VX2780-2K regression: the same monitor needs the opposite frame shape once its DisplayPort
    /// 1.1 setting is toggled, and the wrong shape reports as "no DDC" rather than as an error.
    func testAReadRecoversByTryingTheOtherFrameShape() async throws {
        for expected in DDC.FrameShape.allCases {
            let transport = ShapeSensitiveTransport(answers: expected, current: 58)
            let queue = DDCCommandQueue(transport: transport, label: "test", writeInterval: interval)

            let reply = try await queue.readBrightness()
            XCTAssertEqual(reply.current, 58, "\(expected)")

            let adopted = await queue.currentFrameShape
            XCTAssertEqual(adopted, expected, "the working shape must be remembered, not rediscovered")
        }
    }

    /// Having learned the shape, writes must use it too — otherwise brightness reads back correctly
    /// while the slider does nothing.
    func testWritesUseTheLearnedFrameShape() async throws {
        let transport = ShapeSensitiveTransport(answers: .withoutHostAddress, current: 58)
        let queue = DDCCommandQueue(transport: transport, label: "test", writeInterval: interval)
        _ = try await queue.readBrightness()

        let framesBefore = transport.shapesSeen.count
        await queue.setBrightness(raw: 42)
        try await waitUntil { transport.shapesSeen.count > framesBefore }

        XCTAssertEqual(transport.shapesSeen.last, .withoutHostAddress,
                       "the write went out in the shape that failed")
    }

    /// A display that answers neither shape must still fail, and say why.
    func testBothShapesNullStillFails() async {
        let transport = FakeDDCTransport(
            replies: [Array(repeating: VCPCodec.nullMessage, count: 4).flatMap { $0 }])
        let queue = DDCCommandQueue(transport: transport, label: "test")

        do {
            _ = try await queue.readBrightness()
            XCTFail("expected a decode failure")
        } catch {
            XCTAssertEqual(error as? DDCError, .decode(.nullMessage))
        }
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
        frame.append(frame.reduce(DDC.replyChecksumSeed) { $0 ^ $1 })

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
    /// Polls until `condition` holds, for transports the `FakeDDCTransport`-shaped helper cannot take.
    private func waitUntil(
        timeout: Duration = .seconds(3), _ condition: @Sendable () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("condition never became true within \(timeout)")
    }

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

/// The transport-rebind path that recovers DDC after a monitor sleep/wake or fast replug.
///
/// In both cases the display's key never goes offline, so nothing tears the session down — the old
/// behaviour was to fail the probe against the dead IOAVService, downgrade to software dimming, and
/// never try DDC again.
final class DDCBrightnessControllerRebindTests: XCTestCase {

    private func makeExternalDisplay() -> DisplayDevice {
        DisplayDevice(
            identity: DisplayIdentity(
                cgDisplayID: 7, vendorID: 0x10AC, productID: 0xD0A1,
                serialNumber: 0xABCD, keyTier: .strong),
            name: "TEST U2723QE", isBuiltIn: false, isOnline: true, isMain: false)
    }

    private func validReply(current: UInt8) -> [UInt8] {
        var frame: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, current]
        frame.append(frame.reduce(DDC.replyChecksumSeed) { $0 ^ $1 })
        return frame
    }

    /// Thread-safe bind counter: the factory closure is `@Sendable` and called from the actor.
    private final class BindCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.withLock { count += 1; return count } }
        var value: Int { lock.withLock { count } }
    }

    func testProbeRebindsAFreshTransportWhenTheFirstReadTimesOut() async {
        let binds = BindCounter()
        let reply = validReply(current: 40)
        let controller = DDCBrightnessController(makeTransport: { _ in
            // First bind: the pre-sleep transport, now dead — every call times out.
            // Second bind: the fresh service, answering normally.
            if binds.next() == 1 {
                let dead = FakeDDCTransport()
                dead.errorToThrow = .timeout
                return dead
            }
            return FakeDDCTransport(replies: [reply])
        })

        let result = await controller.probe(display: makeExternalDisplay())

        XCTAssertTrue(result.isSupported, "a fresh transport answered; the display supports DDC")
        XCTAssertEqual(binds.value, 2, "the dead transport must be dropped and rebound exactly once")
    }

    func testProbeDoesNotRebindWhenTheMonitorAnswersNull() async {
        let binds = BindCounter()
        let nullReply = Array(repeating: VCPCodec.nullMessage, count: 4).flatMap { $0 }
        let controller = DDCBrightnessController(makeTransport: { _ in
            _ = binds.next()
            return FakeDDCTransport(replies: [nullReply])
        })

        let result = await controller.probe(display: makeExternalDisplay())

        XCTAssertFalse(result.isSupported)
        XCTAssertEqual(binds.value, 1,
                       "a null answer proves the transport works — rebinding would just repeat it")
    }

    func testProbeSucceedsFirstTimeWithoutRebinding() async {
        let binds = BindCounter()
        let reply = validReply(current: 60)
        let controller = DDCBrightnessController(makeTransport: { _ in
            _ = binds.next()
            return FakeDDCTransport(replies: [reply])
        })

        let result = await controller.probe(display: makeExternalDisplay())

        XCTAssertTrue(result.isSupported)
        XCTAssertEqual(binds.value, 1)
        XCTAssertFalse(result.isTransient)
    }

    func testProbeMarksABindFailureTransient() async {
        // A monitor that has just woken can be missing from the registry for a few seconds; the
        // coordinator retries transient failures, so the bind failure must be marked as one.
        let controller = DDCBrightnessController(makeTransport: { _ in nil })

        let result = await controller.probe(display: makeExternalDisplay())

        XCTAssertFalse(result.isSupported)
        XCTAssertTrue(result.isTransient)
    }

    func testProbeMarksATimeoutTransientEvenAfterTheFreshTransportAlsoTimesOut() async {
        // Both the stale and the freshly rebound transport time out — the monitor's I2C bus is not
        // answering yet. Still transient: the same monitor answers once it finishes waking.
        let controller = DDCBrightnessController(makeTransport: { _ in
            let dead = FakeDDCTransport()
            dead.errorToThrow = .timeout
            return dead
        })

        let result = await controller.probe(display: makeExternalDisplay())

        XCTAssertFalse(result.isSupported)
        XCTAssertTrue(result.isTransient)
    }

    func testProbeDoesNotMarkANullAnswerTransient() async {
        // The monitor answered — with the null message, in both frame shapes. That is a display
        // proving it has no brightness control, not one that needs another attempt.
        let nullReply = Array(repeating: VCPCodec.nullMessage, count: 4).flatMap { $0 }
        let controller = DDCBrightnessController(makeTransport: { _ in
            FakeDDCTransport(replies: [nullReply])
        })

        let result = await controller.probe(display: makeExternalDisplay())

        XCTAssertFalse(result.isSupported)
        XCTAssertFalse(result.isTransient)
    }
}
