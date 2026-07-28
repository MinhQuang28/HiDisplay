import XCTest
@testable import HiDisplayKit

/// Pins the DDC/CI wire format. A framing bug here looks exactly like a cable that blocks DDC, which
/// is why it has to be provable without a monitor.
final class VCPCodecTests: XCTestCase {

    /// The host address is checksummed but never transmitted — the I2C sub-address carries it. These
    /// tests assert the *wire* bytes, so a regression that puts 0x51 back is a test failure rather
    /// than a monitor that mysteriously answers null messages.
    func testSetRequestFraming() {
        let frame = VCPCodec.setRequest(code: .brightness, value: 50)
        XCTAssertEqual(frame.count, 6, "6 on the wire: the 7-byte frame minus its host-address byte")
        XCTAssertNotEqual(frame[0], 0x51, "the host address must not be transmitted")
        XCTAssertEqual(frame[0], 0x84, "0x80 | payload length 4")
        XCTAssertEqual(frame[1], 0x03, "Set VCP Feature")
        XCTAssertEqual(frame[2], 0x10, "brightness")
        XCTAssertEqual(frame[3], 0x00, "value high byte")
        XCTAssertEqual(frame[4], 50, "value low byte")

        // Seeded with the display address and covering the untransmitted 0x51, which is why the seed
        // here is `displayAddress ^ hostAddress` rather than `displayAddress` alone.
        let expected = frame[0..<5].reduce(DDC.displayAddress ^ DDC.hostAddress) { $0 ^ $1 }
        XCTAssertEqual(frame[5], expected, "checksum still covers the host address byte")
    }

    func testSetRequestSplitsValuesAboveOneByte() {
        let frame = VCPCodec.setRequest(code: .brightness, value: 0x0123)
        XCTAssertEqual(frame[3], 0x01)
        XCTAssertEqual(frame[4], 0x23)
    }

    func testGetRequestFraming() {
        let frame = VCPCodec.getRequest(code: .brightness)
        XCTAssertEqual(frame.count, 4)
        XCTAssertEqual(Array(frame[0...2]), [0x82, 0x01, 0x10])
        XCTAssertEqual(frame[3], frame[0..<3].reduce(DDC.displayAddress ^ DDC.hostAddress) { $0 ^ $1 })
    }

    /// The exact bytes a ViewSonic VX2780-2K accepted, captured by `hidisplay-probe --ddc-sweep`.
    ///
    /// Golden-value tests rather than recomputed ones: every derived assertion above would still pass
    /// if the whole frame were shifted, and a shift is precisely the bug that cost this project a day.
    func testFramesMatchWhatRealHardwareAccepted() {
        XCTAssertEqual(VCPCodec.getRequest(code: .brightness), [0x82, 0x01, 0x10, 0xAC])
        XCTAssertEqual(VCPCodec.setRequest(code: .brightness, value: 30), [0x84, 0x03, 0x10, 0x00, 0x1E, 0xB6])
    }

    /// The exact reply that display sent back: brightness 75 of 100.
    func testDecodesTheReplyRealHardwareSent() throws {
        let captured: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x4B, 0x8B]
        let reply = try VCPCodec.decodeReply(captured, expecting: .brightness)
        XCTAssertEqual(reply.current, 75)
        XCTAssertEqual(reply.maximum, 100)
        XCTAssertTrue(reply.checksumValid, "0x8B verifies only against seed 0x50, not 0x51")
    }

    /// The null message a display sends when it cannot parse the request. Must not decode as data.
    func testANullMessageIsNotMistakenForAReply() {
        let null: [UInt8] = [0x6E, 0x80, 0xBE, 0x6E, 0x80, 0xBE, 0x6E, 0x80, 0xBE, 0x6E, 0x80]
        XCTAssertThrowsError(try VCPCodec.decodeReply(null, expecting: .brightness))
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
