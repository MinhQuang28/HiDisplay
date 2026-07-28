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
    /// Whether the leading host-address byte goes on the wire.
    ///
    /// Not a style choice — the same monitor needs different answers depending on how the link is
    /// running. `IOAVServiceWriteI2C` takes a sub-address (`dataOffset`, 0x51) alongside the data
    /// buffer, and DDC/CI frames begin with that identical byte. Whether the DCP driver emits it
    /// itself depends on the transport underneath: DisplayPort 1.1 carries DDC as I2C-over-AUX
    /// emulation, 1.2 and later use native AUX, and the two paths disagree.
    ///
    /// Measured on one ViewSonic VX2780-2K, toggling only the monitor's own "DisplayPort 1.1" OSD
    /// setting, nothing else changed:
    ///
    /// | DP 1.1 | frame that gets a reply |
    /// | --- | --- |
    /// | on  | `withoutHostAddress` — `82 01 10 AC` |
    /// | off | `withHostAddress` — `51 82 01 10 AC` |
    ///
    /// The wrong shape produces a null message, never an error, so nothing detects this except trying
    /// the other one. `DDCCommandQueue` learns which applies and remembers it.
    public enum FrameShape: Sendable, CaseIterable {
        /// Send the frame whole. The driver passes the buffer through untouched.
        case withHostAddress
        /// Drop the leading byte; the driver emits the sub-address itself. Sending it too makes the
        /// display receive `51 51 82 …`, which it cannot parse.
        case withoutHostAddress
    }

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
    /// The checksum always covers the whole frame including the leading host address, whichever shape
    /// is transmitted — a display given `82 01 10 AC` still reconstructs the 0x51 from the sub-address
    /// before verifying. That is why the checksum is computed here, once, rather than per shape.
    ///
    /// See `DDC.FrameShape` for why the shape is not a constant.
    private static func wireBytes(_ frame: [UInt8], shape: DDC.FrameShape) -> [UInt8] {
        let checksum = checksum(seed: DDC.displayAddress, bytes: frame)
        switch shape {
        case .withHostAddress: return frame + [checksum]
        case .withoutHostAddress: return Array(frame.dropFirst()) + [checksum]
        }
    }

    /// `Set VCP Feature` frame.
    ///
    /// ```
    /// 51 84 03 <code> <value hi> <value lo> <checksum>
    /// │  │  └─ Set VCP Feature opcode
    /// │  └──── 0x80 | payload length (4)
    /// └─────── host source address — always checksummed, transmitted only for `.withHostAddress`
    /// ```
    public static func setRequest(
        code: VCPCode, value: UInt16, shape: DDC.FrameShape = .withHostAddress
    ) -> [UInt8] {
        wireBytes([
            DDC.hostAddress,
            0x80 | 4,
            0x03,
            code.rawValue,
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ], shape: shape)
    }

    /// `Get VCP Feature` request frame.
    ///
    /// ```
    /// 51 82 01 <code> <checksum>
    /// ```
    public static func getRequest(
        code: VCPCode, shape: DDC.FrameShape = .withHostAddress
    ) -> [UInt8] {
        wireBytes([
            DDC.hostAddress,
            0x80 | 2,
            0x01,
            code.rawValue,
        ], shape: shape)
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

    /// The DDC/CI null message, `6E 80 BE`: a display saying it has nothing to send.
    ///
    /// Well-formed, correct checksum, zero payload. Reading a longer buffer just repeats these three
    /// bytes. It is what a display returns for a request it could not parse — so in practice it means
    /// the frame shape is wrong — and equally what it returns when DDC/CI is disabled in its OSD.
    public static let nullMessage: [UInt8] = [DDC.displayAddress, 0x80, 0xBE]

    public enum DecodeError: Error, Equatable, CustomStringConvertible {
        case shortFrame(got: Int)
        /// See `VCPCodec.nullMessage`. Distinguished from other malformed replies because it is the
        /// one the caller can act on: try the other frame shape.
        case nullMessage
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
            case .nullMessage:
                return "display returned a null message — it did not understand the request, or "
                    + "DDC/CI is switched off in its menu"
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

        // Before the checksum, which a null message fails only because the buffer is longer than the
        // three bytes the display actually sent. Reporting that as corruption would hide the one thing
        // this reply reliably means.
        guard !bytes.starts(with: nullMessage) else { throw DecodeError.nullMessage }

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
