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
    /// Host source address; also the checksum seed for display→host replies.
    public static let hostAddress: UInt8 = 0x51
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

    /// `Set VCP Feature` frame.
    ///
    /// ```
    /// 51 84 03 <code> <value hi> <value lo> <checksum>
    /// │  │  └─ Set VCP Feature opcode
    /// │  └──── 0x80 | payload length (4)
    /// └─────── host source address
    /// ```
    public static func setRequest(code: VCPCode, value: UInt16) -> [UInt8] {
        var frame: [UInt8] = [
            DDC.hostAddress,
            0x80 | 4,
            0x03,
            code.rawValue,
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ]
        frame.append(checksum(seed: DDC.displayAddress, bytes: frame))
        return frame
    }

    /// `Get VCP Feature` request frame.
    ///
    /// ```
    /// 51 82 01 <code> <checksum>
    /// ```
    public static func getRequest(code: VCPCode) -> [UInt8] {
        var frame: [UInt8] = [
            DDC.hostAddress,
            0x80 | 2,
            0x01,
            code.rawValue,
        ]
        frame.append(checksum(seed: DDC.displayAddress, bytes: frame))
        return frame
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

        // The checksum covers everything but the final byte, seeded with the host address.
        let computed = checksum(seed: DDC.hostAddress, bytes: Array(bytes[0..<(replyLength - 1)]))
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
