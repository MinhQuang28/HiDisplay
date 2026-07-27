import Foundation

/// One `scale-resolutions` entry, modelled faithfully enough to round-trip byte-for-byte.
///
/// Round-tripping matters more than elegance here: an override file on a user's machine may contain
/// entries written by Apple or by another tool, in forms this app does not fully understand. Rewriting
/// the file must not alter them.
public struct ScaleResolutionEntry: Equatable, Sendable {
    /// Dimensions as stored. For a HiDPI entry these are *backing* pixels; for other forms their
    /// meaning is form-dependent (see `ScaleResolutionCodec`).
    public var storedWidth: Int
    public var storedHeight: Int
    /// Word at offset 8. Observed values: `0x1`, `0x2`, `0x9`. Meaning undocumented.
    public var marker: UInt32?
    /// Word at offset 12. `0x00200000` marks HiDPI; `0x00a00000` also occurs and additionally sets
    /// `0x00800000`, whose meaning is unknown.
    public var flags: UInt32?
    /// Any bytes past the modelled fields — including the stray 9th byte some Apple entries carry.
    public var trailing: Data

    public init(
        storedWidth: Int,
        storedHeight: Int,
        marker: UInt32? = nil,
        flags: UInt32? = nil,
        trailing: Data = Data()
    ) {
        self.storedWidth = storedWidth
        self.storedHeight = storedHeight
        self.marker = marker
        self.flags = flags
        self.trailing = trailing
    }

    public var isHiDPI: Bool { ((flags ?? 0) & ScaleResolutionCodec.hiDPIFlag) != 0 }

    /// Logical size, i.e. what appears in System Settings. Only meaningful for HiDPI entries, where the
    /// stored dimensions are the doubled backing store.
    public var logicalWidth: Int { isHiDPI ? storedWidth / 2 : storedWidth }
    public var logicalHeight: Int { isHiDPI ? storedHeight / 2 : storedHeight }

    /// Exact bytes, reproducing whichever form this entry was decoded from.
    public func encoded() -> Data {
        var data = Data()
        data.append(bigEndian: UInt32(clamping: storedWidth))
        data.append(bigEndian: UInt32(clamping: storedHeight))
        if let marker { data.append(bigEndian: marker) }
        if let flags { data.append(bigEndian: flags) }
        data.append(trailing)
        return data
    }

    public var asScaledResolution: ScaledResolution {
        ScaledResolution(
            logicalWidth: logicalWidth,
            logicalHeight: logicalHeight,
            backingScale: isHiDPI ? 2 : 1)
    }
}

/// Encoder/decoder for the `scale-resolutions` binary entries inside a display override plist.
///
/// ## Forms found in the wild
///
/// Surveyed across all 252 override files carrying `scale-resolutions` on a macOS 26 install — 251
/// Apple-supplied plus one third-party HiDPI override. All fields big-endian.
///
/// ```
///  8 bytes : width, height                              (502 entries)
///  9 bytes : width, height, + one stray 0x00 byte        (63 entries)
/// 12 bytes : width, height, marker                     (1860 entries; marker 0x1 or 0x2)
/// 16 bytes : width, height, marker, flags               (720 entries)
///            marker 0x1 with flags 0x00200000           (216)
///            marker 0x9 with flags 0x00a00000           (365)
///            marker 0x9 with flags 0x00200000           (139)
/// ```
///
/// `0x00200000` in the flags word is the HiDPI bit. In the 16-byte form the stored dimensions are the
/// **backing store**, so the logical size the user sees is half: the third-party override on this
/// machine contains `00001000 00000900 00000009 00200000` — 4096 × 2304 backing, i.e. 2048 × 1152
/// logical, which is exactly a standard scaled size for a 1440p panel.
///
/// ## What is known versus guessed
///
/// **Known from real files:** the byte layout, that `0x00200000` means HiDPI, that the 16-byte form
/// stores backing pixels, that the plist stores vendor/product as decimal while the path uses hex.
///
/// **Not known:** what the marker word means, why both `0x1` and `0x9` appear with the same flags,
/// what `0x00800000` in `0x00a00000` does, and why some entries carry a stray ninth byte.
///
/// **Not Apple-documented at all.** Nothing here is contractual.
///
/// ## Design consequences
///
/// * `decode` preserves every entry it cannot fully model, and `ScaleResolutionEntry.encoded()`
///   reproduces the original bytes — so rewriting a file never silently drops another tool's modes.
/// * `encode` emits only the one form that a working override is known to use: 16 bytes with
///   marker `0x1` and flags `0x00200000` for HiDPI, 8 bytes for 1×. The app does not invent forms it
///   cannot explain.
public enum ScaleResolutionCodec {

    /// The HiDPI bit in the flags word.
    public static let hiDPIFlag: UInt32 = 0x0020_0000
    /// Additional bit seen in `0x00a00000`. Meaning unknown; never emitted, only preserved.
    public static let unknownExtraFlag: UInt32 = 0x0080_0000
    /// Marker word this app writes. `0x9` also occurs in Apple's files; `0x1` is chosen because it is
    /// the value long-standing open-source HiDPI tooling emits, so it is the most field-proven.
    public static let emittedMarker: UInt32 = 0x0000_0001

    public enum Entry: Equatable, Sendable {
        case entry(ScaleResolutionEntry)
        /// Fewer than 8 bytes, or so large it cannot be a resolution. Preserved verbatim.
        case unrecognized(Data)
    }

    /// Above this an entry is not a resolution record. Two entries in the surveyed set were tens of
    /// megabytes; whatever they are, parsing them as dimensions would produce nonsense.
    static let maximumEntryBytes = 64

    public static func encode(_ resolution: ScaledResolution) -> Data {
        var data = Data()
        data.append(bigEndian: UInt32(clamping: resolution.pixelWidth))
        data.append(bigEndian: UInt32(clamping: resolution.pixelHeight))
        if resolution.isHiDPI {
            data.append(bigEndian: emittedMarker)
            data.append(bigEndian: hiDPIFlag)
        }
        return data
    }

    public static func encode(_ resolutions: [ScaledResolution]) -> [Data] {
        resolutions.map(encode)
    }

    public static func decode(_ data: Data) -> Entry {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, bytes.count <= maximumEntryBytes else {
            return .unrecognized(data)
        }

        let width = Int(readUInt32(bytes, at: 0))
        let height = Int(readUInt32(bytes, at: 4))
        var marker: UInt32?
        var flags: UInt32?
        var consumed = 8

        if bytes.count >= 12 {
            marker = readUInt32(bytes, at: 8)
            consumed = 12
        }
        if bytes.count >= 16 {
            flags = readUInt32(bytes, at: 12)
            consumed = 16
        }
        // Everything past the modelled fields is kept so `encoded()` is byte-exact — this is what
        // covers the 9-byte form and anything a future macOS adds.
        let trailing = consumed < bytes.count ? data.subdata(in: consumed..<bytes.count) : Data()

        return .entry(ScaleResolutionEntry(
            storedWidth: width, storedHeight: height,
            marker: marker, flags: flags, trailing: trailing))
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }
}

extension Data {
    mutating func append(bigEndian value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
}
