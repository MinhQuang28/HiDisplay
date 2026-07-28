import Foundation

/// MCCS VCP feature codes. Only brightness is exposed in the MVP — contrast, volume and input source
/// are deliberately absent so a bug in this layer cannot mute a monitor or switch it to a dead input.
public enum VCPCode: UInt8, Sendable {
    case brightness = 0x10
}

/// DDC/CI framing constants.
public enum DDC {
    /// I2C chip address for DDC/CI (0x6E >> 1).
    public static let chipAddress: UInt32 = 0x37
    /// Sub-address the frame is written to / read from.
    public static let dataOffset: UInt32 = 0x51
    /// Destination address used as the checksum seed for host→display frames.
    public static let displayAddress: UInt8 = 0x6E
    /// Host source address — the first byte of every host→display frame, and the same value as
    /// `dataOffset` because that byte *is* the I2C sub-address.
    public static let hostAddress: UInt8 = 0x51
    /// Checksum seed for display→host replies.
    ///
    /// 0x50, not `hostAddress`. The two differ by the I2C read/write bit: 0x51 is the host address a
    /// display reads from, 0x50 the one it writes to, and a reply's checksum is seeded with the
    /// latter. Using 0x51 here rejects every well-formed reply as corrupt — verified against a real
    /// frame, `6E 88 02 00 10 00 00 64 00 4B 8B`, whose bytes XOR to 0xDB: 0xDB ^ 0x8B is 0x50.
    public static let replyChecksumSeed: UInt8 = 0x50
    /// MCCS asks for ~40 ms between a request and its reply. Some panels need more; this is the floor.
    public static let replyDelay: Duration = .milliseconds(50)
    /// Minimum spacing between consecutive writes. 40 ms ≈ 25 writes/s, inside the 10–20/s target
    /// with headroom, and slow enough that dragging a slider does not wedge the monitor's bus.
    public static let writeInterval: Duration = .milliseconds(40)
}

/// Encoding and decoding of DDC/CI frames.
///
/// Pure byte manipulation with no I/O, so the wire format is fully unit-testable with no monitor
/// attached — which matters because a framing bug shows up as a monitor that ignores the app, and
/// that is very hard to tell apart from a cable that blocks DDC.
public enum VCPCodec {

    /// XOR checksum over `bytes`, seeded with the frame's destination address.
    public static func checksum(seed: UInt8, bytes: [UInt8]) -> UInt8 {
        bytes.reduce(seed) { $0 ^ $1 }
    }

    /// Turns a complete DDC/CI frame into the bytes that actually go on the wire.
    ///
    /// The leading host-address byte is checksummed but **not transmitted**: `IOAVServiceWriteI2C`
    /// takes the sub-address as its own argument (`DDC.dataOffset`, the identical 0x51) and puts it on
    /// the bus itself. Sending it again makes the display see `51 51 82 …`, and a display that cannot
    /// parse a request answers with a null message — indistinguishable, from the outside, from DDC/CI
    /// being switched off in its OSD.
    ///
    /// Found by sweeping both shapes against a ViewSonic VX2780-2K. One byte apart: the frame with the
    /// leading 0x51 got `6E 80 BE` at every timing and address tried, the frame without it got
    /// `6E 88 02 00 10 00 00 64 00 4B 8B` on the first attempt. See `Tests/HardwareMatrix/results.md`.
    private static func wireBytes(_ frame: [UInt8]) -> [UInt8] {
        Array(frame.dropFirst()) + [checksum(seed: DDC.displayAddress, bytes: frame)]
    }

    /// `Set VCP Feature` frame.
    ///
    /// ```
    /// 51 84 03 <code> <value hi> <value lo> <checksum>
    /// │  │  └─ Set VCP Feature opcode
    /// │  └──── 0x80 | payload length (4)
    /// └─────── host source address — checksummed, but carried by the I2C sub-address
    /// ```
    public static func setRequest(code: VCPCode, value: UInt16) -> [UInt8] {
        wireBytes([
            DDC.hostAddress,
            0x80 | 4,
            0x03,
            code.rawValue,
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ])
    }

    /// `Get VCP Feature` request frame.
    ///
    /// ```
    /// 51 82 01 <code> <checksum>
    /// ```
    public static func getRequest(code: VCPCode) -> [UInt8] {
        wireBytes([
            DDC.hostAddress,
            0x80 | 2,
            0x01,
            code.rawValue,
        ])
    }

    /// Length of the `Get VCP Feature Reply` frame.
    public static let replyLength = 11

    public struct Reply: Equatable, Sendable {
        public let code: UInt8
        public let current: UInt16
        public let maximum: UInt16
        /// True when the frame's own checksum matched. Kept as data rather than an error because a
        /// non-trivial number of monitors compute this wrong while reporting correct values.
        public let checksumValid: Bool
    }

    public enum DecodeError: Error, Equatable, CustomStringConvertible {
        case shortFrame(got: Int)
        case notAFeatureReply(opcode: UInt8)
        /// Result code byte non-zero: the display understood the request and refused it, which is how
        /// a monitor says "I do not support this VCP code".
        case unsupportedFeature(resultCode: UInt8)
        case codeMismatch(expected: UInt8, got: UInt8)
        case zeroMaximum
        case badChecksum

        public var description: String {
            switch self {
            case .shortFrame(let got): return "DDC reply too short (\(got) bytes)"
            case .notAFeatureReply(let opcode): return "unexpected DDC opcode 0x\(String(opcode, radix: 16))"
            case .unsupportedFeature(let code): return "display refused the feature (result 0x\(String(code, radix: 16)))"
            case .codeMismatch(let expected, let got):
                return "reply is for VCP 0x\(String(got, radix: 16)), expected 0x\(String(expected, radix: 16))"
            case .zeroMaximum: return "display reported a maximum of 0"
            case .badChecksum: return "DDC reply checksum mismatch"
            }
        }
    }

    /// Decodes a `Get VCP Feature Reply`.
    ///
    /// ```
    /// 6E 88 02 <result> <code> <type> <max hi> <max lo> <cur hi> <cur lo> <checksum>
    ///  0  1  2     3      4      5      6       7        8        9        10
    /// ```
    ///
    /// - Parameter tolerateChecksumMismatch: when false (the default) a bad checksum is an error, so
    ///   line noise cannot be interpreted as a brightness value. Callers that have established a
    ///   given monitor always miscomputes it may opt in, and the returned `Reply` still records the
    ///   fact so diagnostics show why the value is suspect.
    public static func decodeReply(
        _ bytes: [UInt8],
        expecting code: VCPCode,
        tolerateChecksumMismatch: Bool = false
    ) throws -> Reply {
        guard bytes.count >= replyLength else { throw DecodeError.shortFrame(got: bytes.count) }

        // The checksum covers everything but the final byte. Unlike a request, the reply is
        // transmitted whole — the display's address is really there in byte 0 — so nothing is dropped.
        let computed = checksum(seed: DDC.replyChecksumSeed, bytes: Array(bytes[0..<(replyLength - 1)]))
        let checksumValid = computed == bytes[replyLength - 1]
        if !checksumValid, !tolerateChecksumMismatch {
            throw DecodeError.badChecksum
        }

        guard bytes[2] == 0x02 else { throw DecodeError.notAFeatureReply(opcode: bytes[2]) }
        guard bytes[3] == 0x00 else { throw DecodeError.unsupportedFeature(resultCode: bytes[3]) }
        guard bytes[4] == code.rawValue else {
            throw DecodeError.codeMismatch(expected: code.rawValue, got: bytes[4])
        }

        let maximum = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        let current = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
        // A zero maximum makes every normalisation a division by zero, and is a reliable sign the
        // monitor answered with garbage rather than a real feature description.
        guard maximum != 0 else { throw DecodeError.zeroMaximum }

        return Reply(code: bytes[4], current: current, maximum: maximum, checksumValid: checksumValid)
    }

    /// Maps a normalised 0…1 value onto a monitor's raw range.
    ///
    /// Monitors do not all use 0…100: 0…255 and odd ranges like 0…64 are common, which is why the
    /// range comes from the display's own reply rather than being assumed.
    public static func rawValue(fromNormalized value: Float, minimum: UInt16, maximum: UInt16) -> UInt16 {
        guard maximum > minimum else { return minimum }
        let clamped = Double(min(max(value, 0), 1))
        let span = Double(maximum - minimum)
        return minimum + UInt16((clamped * span).rounded())
    }

    public static func normalized(fromRaw raw: UInt16, minimum: UInt16, maximum: UInt16) -> Float {
        guard maximum > minimum else { return 0 }
        let clamped = min(max(raw, minimum), maximum)
        return Float(Double(clamped - minimum) / Double(maximum - minimum))
    }
}
