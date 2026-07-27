import CryptoKit
import Foundation

/// Minimal EDID 1.x block-0 parser.
///
/// Deliberately parses only the fields the app actually needs — manufacturer, product code, serial,
/// manufacture date, native timing and the monitor-name descriptor. Extension blocks (CTA-861, HDR
/// static metadata, …) are left alone: nothing in the MVP depends on them, and a half-understood
/// parser over vendor-specific extension data is a liability.
public struct EDID: Equatable, Sendable {
    public static let blockSize = 128
    private static let header: [UInt8] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]

    public let raw: Data
    /// Three-letter PnP ID, e.g. `DEL`, `GSM`, `APP`.
    public let manufacturerCode: String
    /// Numeric vendor ID as macOS reports it — the same 16-bit value the PnP letters encode.
    public let vendorID: UInt32
    public let productID: UInt32
    /// `0` when the panel reports no serial, which is common and not an error.
    public let serialNumber: UInt32
    public let weekOfManufacture: UInt8?
    public let yearOfManufacture: Int?
    public let versionMajor: UInt8
    public let versionMinor: UInt8
    public let monitorName: String?
    /// Active pixels from the first detailed timing descriptor, i.e. the panel's native mode.
    public let nativePixelWidth: Int?
    public let nativePixelHeight: Int?

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case tooShort(got: Int)
        case badHeader
        case badChecksum(expected: UInt8, got: UInt8)

        public var description: String {
            switch self {
            case .tooShort(let got):
                return "EDID must be at least 128 bytes, got \(got)"
            case .badHeader:
                return "EDID header does not match 00 FF FF FF FF FF FF 00"
            case .badChecksum(let expected, let got):
                return "EDID block-0 checksum mismatch (expected \(expected), got \(got))"
            }
        }
    }

    /// - Parameter validateChecksum: some monitors — and more often some KVMs and cheap HDMI
    ///   adapters — hand back an EDID with a wrong checksum but otherwise-correct fields. Callers
    ///   that only want identification can pass `false`; anything that will be written back into a
    ///   patched EDID must pass `true`.
    public init(data: Data, validateChecksum: Bool = true) throws {
        guard data.count >= Self.blockSize else { throw ParseError.tooShort(got: data.count) }
        let bytes = [UInt8](data.prefix(Self.blockSize))
        guard Array(bytes[0..<8]) == Self.header else { throw ParseError.badHeader }

        let sum = bytes.reduce(into: UInt8(0)) { $0 = $0 &+ $1 }
        if validateChecksum, sum != 0 {
            // The stored checksum byte is bytes[127]; report what it should have been.
            let expected = bytes[127] &- sum
            throw ParseError.badChecksum(expected: expected, got: bytes[127])
        }

        self.raw = data
        let manufacturerWord = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
        self.manufacturerCode = Self.decodeManufacturer(manufacturerWord)
        self.vendorID = UInt32(manufacturerWord)
        self.productID = UInt32(bytes[10]) | UInt32(bytes[11]) << 8
        self.serialNumber = UInt32(bytes[12]) | UInt32(bytes[13]) << 8
            | UInt32(bytes[14]) << 16 | UInt32(bytes[15]) << 24
        self.weekOfManufacture = bytes[16] == 0 || bytes[16] == 0xFF ? nil : bytes[16]
        self.yearOfManufacture = bytes[17] == 0 ? nil : 1990 + Int(bytes[17])
        self.versionMajor = bytes[18]
        self.versionMinor = bytes[19]
        self.monitorName = Self.decodeMonitorName(bytes)

        let (nativeWidth, nativeHeight) = Self.decodePreferredTiming(bytes)
        self.nativePixelWidth = nativeWidth
        self.nativePixelHeight = nativeHeight
    }

    /// Bits 14–10 / 9–5 / 4–0 each hold a letter as 1…26.
    static func decodeManufacturer(_ word: UInt16) -> String {
        let letters = [
            (word >> 10) & 0x1F,
            (word >> 5) & 0x1F,
            word & 0x1F,
        ]
        let scalars = letters.compactMap { value -> Character? in
            guard value >= 1, value <= 26 else { return nil }
            return Character(UnicodeScalar(UInt8(value) + 64)) // 1 -> "A"
        }
        return scalars.count == 3 ? String(scalars) : ""
    }

    /// Descriptors live at 54…125 in four 18-byte slots. A display-product-name descriptor is
    /// flagged by `00 00 00 FC 00`.
    static func decodeMonitorName(_ bytes: [UInt8]) -> String? {
        for slot in 0..<4 {
            let start = 54 + slot * 18
            guard start + 18 <= Self.blockSize else { break }
            let descriptor = Array(bytes[start..<(start + 18)])
            guard descriptor[0] == 0, descriptor[1] == 0, descriptor[2] == 0, descriptor[3] == 0xFC
            else { continue }
            let text = descriptor[5..<18]
                .prefix { $0 != 0x0A } // descriptors are LF-terminated, space-padded
                .map { Character(UnicodeScalar($0)) }
            let name = String(text).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        return nil
    }

    /// First detailed timing descriptor = preferred (native) timing.
    /// Horizontal active: low 8 bits at +2, high 4 bits in the upper nibble of +4.
    /// Vertical active: low 8 bits at +5, high 4 bits in the upper nibble of +7.
    static func decodePreferredTiming(_ bytes: [UInt8]) -> (Int?, Int?) {
        let start = 54
        guard start + 18 <= Self.blockSize else { return (nil, nil) }
        let d = Array(bytes[start..<(start + 18)])
        // A pixel clock of zero means this slot is a monitor descriptor, not a timing.
        let pixelClock = UInt16(d[0]) | UInt16(d[1]) << 8
        guard pixelClock != 0 else { return (nil, nil) }
        let width = Int(d[2]) | (Int(d[4] & 0xF0) << 4)
        let height = Int(d[5]) | (Int(d[7] & 0xF0) << 4)
        return (width > 0 ? width : nil, height > 0 ? height : nil)
    }

    /// Stable, short, non-reversible fingerprint used as the `.strong` identity discriminator.
    ///
    /// Truncated to 16 hex characters: long enough that a collision between two monitors on one desk
    /// is not a practical concern, short enough to read in a diagnostics file. Hashing (rather than
    /// storing the EDID) also means the profile store never holds a raw serial.
    public static func fingerprint(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public var fingerprint: String { Self.fingerprint(of: raw) }
}
