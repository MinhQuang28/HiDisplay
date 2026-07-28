import XCTest
@testable import HiDisplayKit

/// Pins the DDC/CI wire format. A framing bug here looks exactly like a cable that blocks DDC, which
/// is why it has to be provable without a monitor.
final class VCPCodecTests: XCTestCase {

    func testSetRequestFraming() {
        let frame = VCPCodec.setRequest(code: .brightness, value: 50, shape: .withHostAddress)
        XCTAssertEqual(frame.count, 7)
        XCTAssertEqual(frame[0], 0x51, "host source address")
        XCTAssertEqual(frame[1], 0x84, "0x80 | payload length 4")
        XCTAssertEqual(frame[2], 0x03, "Set VCP Feature")
        XCTAssertEqual(frame[3], 0x10, "brightness")
        XCTAssertEqual(frame[4], 0x00, "value high byte")
        XCTAssertEqual(frame[5], 50, "value low byte")

        let expected = frame[0..<6].reduce(DDC.displayAddress) { $0 ^ $1 }
        XCTAssertEqual(frame[6], expected, "checksum is XOR seeded with the display address")
    }

    func testSetRequestSplitsValuesAboveOneByte() {
        let frame = VCPCodec.setRequest(code: .brightness, value: 0x0123)
        XCTAssertEqual(frame[4], 0x01)
        XCTAssertEqual(frame[5], 0x23)
    }

    func testGetRequestFraming() {
        let frame = VCPCodec.getRequest(code: .brightness, shape: .withHostAddress)
        XCTAssertEqual(frame.count, 5)
        XCTAssertEqual(Array(frame[0...3]), [0x51, 0x82, 0x01, 0x10])
        XCTAssertEqual(frame[4], frame[0..<4].reduce(DDC.displayAddress) { $0 ^ $1 })
    }

    /// Dropping the host address must change only which bytes are sent, never the checksum: the
    /// display reconstructs that byte from the I2C sub-address before verifying.
    func testTheTwoShapesDifferByExactlyTheLeadingByte() {
        for value in [UInt16(0), 30, 100, 0x0123] {
            let full = VCPCodec.setRequest(code: .brightness, value: value, shape: .withHostAddress)
            let short = VCPCodec.setRequest(code: .brightness, value: value, shape: .withoutHostAddress)
            XCTAssertEqual(Array(full.dropFirst()), short, "value \(value)")
        }
        XCTAssertEqual(
            Array(VCPCodec.getRequest(code: .brightness, shape: .withHostAddress).dropFirst()),
            VCPCodec.getRequest(code: .brightness, shape: .withoutHostAddress))
    }

    /// The exact bytes a ViewSonic VX2780-2K accepted, captured by `hidisplay-probe --ddc-sweep`.
    ///
    /// Both shapes are golden values because both are correct — on the same monitor, differing only in
    /// whether its OSD "DisplayPort 1.1" setting is on. Recomputed assertions would all still pass if
    /// the frame were shifted, and a shift is exactly the bug these pin.
    func testFramesMatchWhatRealHardwareAccepted() {
        XCTAssertEqual(
            VCPCodec.getRequest(code: .brightness, shape: .withHostAddress),
            [0x51, 0x82, 0x01, 0x10, 0xAC], "accepted with DisplayPort 1.1 off")
        XCTAssertEqual(
            VCPCodec.getRequest(code: .brightness, shape: .withoutHostAddress),
            [0x82, 0x01, 0x10, 0xAC], "accepted with DisplayPort 1.1 on")
        XCTAssertEqual(
            VCPCodec.setRequest(code: .brightness, value: 30, shape: .withoutHostAddress),
            [0x84, 0x03, 0x10, 0x00, 0x1E, 0xB6])
    }

    /// Both captured replies, from the two link modes. Same display, same brightness scale.
    func testDecodesRepliesFromBothLinkModes() throws {
        let cases: [(name: String, bytes: [UInt8], current: UInt16)] = [
            ("DP 1.1 on", [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x4B, 0x8B], 75),
            ("DP 1.1 off", [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x3A, 0xFA], 58),
        ]
        for testCase in cases {
            let reply = try VCPCodec.decodeReply(testCase.bytes, expecting: .brightness)
            XCTAssertEqual(reply.current, testCase.current, testCase.name)
            XCTAssertEqual(reply.maximum, 100, testCase.name)
            XCTAssertTrue(reply.checksumValid, testCase.name)
        }
    }

    /// The exact reply that display sent back: brightness 75 of 100.
    func testDecodesTheReplyRealHardwareSent() throws {
        let captured: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x4B, 0x8B]
        let reply = try VCPCodec.decodeReply(captured, expecting: .brightness)
        XCTAssertEqual(reply.current, 75)
        XCTAssertEqual(reply.maximum, 100)
        XCTAssertTrue(reply.checksumValid, "0x8B verifies only against seed 0x50, not 0x51")
    }

    /// A null message must be reported as itself, not as corruption.
    ///
    /// The distinction is load-bearing: `nullMessage` is what tells `DDCCommandQueue` to try the other
    /// frame shape. Reported as `badChecksum` — which it also technically is, since the buffer runs
    /// past the three bytes the display sent — that recovery never happens.
    func testANullMessageIsReportedAsItself() {
        let null: [UInt8] = [0x6E, 0x80, 0xBE, 0x6E, 0x80, 0xBE, 0x6E, 0x80, 0xBE, 0x6E, 0x80]
        XCTAssertThrowsError(try VCPCodec.decodeReply(null, expecting: .brightness)) { error in
            XCTAssertEqual(error as? VCPCodec.DecodeError, .nullMessage)
        }
        // Also when the caller has opted to tolerate bad checksums, which would otherwise skip past
        // the check and misreport it as an unexpected opcode 0xBE.
        XCTAssertThrowsError(
            try VCPCodec.decodeReply(null, expecting: .brightness, tolerateChecksumMismatch: true)
        ) { error in
            XCTAssertEqual(error as? VCPCodec.DecodeError, .nullMessage)
        }
    }

    // MARK: - Reply decoding

    /// Builds a well-formed reply, with a correct checksum unless asked otherwise.
    private func makeReply(
        current: UInt16, maximum: UInt16, code: UInt8 = 0x10, result: UInt8 = 0x00,
        validChecksum: Bool = true
    ) -> [UInt8] {
        var frame: [UInt8] = [
            0x6E, 0x88, 0x02, result, code, 0x00,
            UInt8(maximum >> 8), UInt8(maximum & 0xFF),
            UInt8(current >> 8), UInt8(current & 0xFF),
        ]
        let checksum = frame.reduce(DDC.replyChecksumSeed) { $0 ^ $1 }
        frame.append(validChecksum ? checksum : checksum ^ 0xFF)
        return frame
    }

    func testDecodesValidReply() throws {
        let reply = try VCPCodec.decodeReply(makeReply(current: 42, maximum: 100), expecting: .brightness)
        XCTAssertEqual(reply.current, 42)
        XCTAssertEqual(reply.maximum, 100)
        XCTAssertTrue(reply.checksumValid)
    }

    func testDecodesNonStandardMaximum() throws {
        // Monitors are not all 0…100. A 0…255 range must be read as such, or every value is wrong by 2.5×.
        let reply = try VCPCodec.decodeReply(makeReply(current: 200, maximum: 255), expecting: .brightness)
        XCTAssertEqual(reply.maximum, 255)
        XCTAssertEqual(VCPCodec.normalized(fromRaw: 200, minimum: 0, maximum: 255), 200.0 / 255.0, accuracy: 0.0001)
    }

    func testRejectsBadChecksumByDefault() {
        XCTAssertThrowsError(
            try VCPCodec.decodeReply(makeReply(current: 42, maximum: 100, validChecksum: false),
                                     expecting: .brightness)
        ) { error in
            XCTAssertEqual(error as? VCPCodec.DecodeError, .badChecksum)
        }
    }

    func testToleratesBadChecksumWhenAskedButRecordsIt() throws {
        let reply = try VCPCodec.decodeReply(
            makeReply(current: 42, maximum: 100, validChecksum: false),
            expecting: .brightness, tolerateChecksumMismatch: true)
        XCTAssertEqual(reply.current, 42)
        XCTAssertFalse(reply.checksumValid, "the value is used, but the fact it was suspect is kept")
    }

    func testRejectsUnsupportedFeatureResultCode() {
        XCTAssertThrowsError(
            try VCPCodec.decodeReply(makeReply(current: 0, maximum: 100, result: 0x01), expecting: .brightness)
        ) { error in
            XCTAssertEqual(error as? VCPCodec.DecodeError, .unsupportedFeature(resultCode: 0x01))
        }
    }

    func testRejectsReplyForADifferentVCPCode() {
        XCTAssertThrowsError(
            try VCPCodec.decodeReply(makeReply(current: 0, maximum: 100, code: 0x12), expecting: .brightness)
        ) { error in
            XCTAssertEqual(error as? VCPCodec.DecodeError, .codeMismatch(expected: 0x10, got: 0x12))
        }
    }

    func testRejectsZeroMaximum() {
        // A zero maximum would make every normalisation divide by zero, and reliably indicates garbage.
        XCTAssertThrowsError(
            try VCPCodec.decodeReply(makeReply(current: 0, maximum: 0), expecting: .brightness)
        ) { error in
            XCTAssertEqual(error as? VCPCodec.DecodeError, .zeroMaximum)
        }
    }

    func testRejectsShortFrame() {
        XCTAssertThrowsError(try VCPCodec.decodeReply([0x6E, 0x88], expecting: .brightness)) { error in
            XCTAssertEqual(error as? VCPCodec.DecodeError, .shortFrame(got: 2))
        }
    }

    // MARK: - Value mapping

    func testNormalizedMappingRoundTrips() {
        for maximum in [UInt16(64), 100, 255] {
            for percent in stride(from: 0.0, through: 1.0, by: 0.1) {
                let raw = VCPCodec.rawValue(fromNormalized: Float(percent), minimum: 0, maximum: maximum)
                let back = VCPCodec.normalized(fromRaw: raw, minimum: 0, maximum: maximum)
                XCTAssertEqual(back, Float(percent), accuracy: 1.0 / Float(maximum),
                               "round trip must stay within one raw step for maximum \(maximum)")
            }
        }
    }

    func testMappingClampsOutOfRangeInput() {
        XCTAssertEqual(VCPCodec.rawValue(fromNormalized: -5, minimum: 0, maximum: 100), 0)
        XCTAssertEqual(VCPCodec.rawValue(fromNormalized: 5, minimum: 0, maximum: 100), 100)
    }

    func testMappingHonoursANonZeroMinimum() {
        // Some panels refuse values below a floor; the profile can record one.
        XCTAssertEqual(VCPCodec.rawValue(fromNormalized: 0, minimum: 20, maximum: 100), 20)
        XCTAssertEqual(VCPCodec.rawValue(fromNormalized: 0.5, minimum: 20, maximum: 100), 60)
        XCTAssertEqual(VCPCodec.normalized(fromRaw: 20, minimum: 20, maximum: 100), 0)
    }

    func testDegenerateRangeDoesNotCrash() {
        XCTAssertEqual(VCPCodec.rawValue(fromNormalized: 0.5, minimum: 50, maximum: 50), 50)
        XCTAssertEqual(VCPCodec.normalized(fromRaw: 50, minimum: 50, maximum: 50), 0)
    }
}
