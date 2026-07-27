import Foundation
import IOKit

/// Reads display metadata from the DCP (display co-processor) branch used on Apple Silicon.
///
/// `IODisplayConnect` — the node every Intel-era guide reaches for — does not exist for external
/// displays on Apple Silicon. The equivalent information lives in a `DisplayAttributes` dictionary.
///
/// **Which node carries it has moved.** On macOS 26.5.2 it is on `AppleCLCD2`, and `DCPAVServiceProxy`
/// has no such property at all — the opposite of what community documentation describes. Hence the
/// ordered candidate list below rather than a single hard-coded class. Note that `DCPAVServiceProxy` is
/// still the node DDC binds to; the two are joined by their shared display unit token, which is why
/// `unitToken` is recorded here. See `IORegistryAccess.displayUnitToken`.
///
/// Shape:
///
/// ```
/// DisplayAttributes = {
///     ProductAttributes = {
///         ManufacturerID = "DEL";          // 3-letter PnP code
///         LegacyManufacturerID = 4268;     // numeric vendor ID
///         ProductID = 53409;
///         SerialNumber = 0;                // often absent or zero
///         ProductName = "DELL U2723QE";
///         YearOfManufacture = 2022;
///         WeekOfManufacture = 34;
///         NativeFormatHorizontalPixels = 3840;
///         NativeFormatVerticalPixels = 2160;
///     };
/// }
/// ```
///
/// This layout is **observed via `ioreg`, not documented by Apple** (docs/private-apis.md). Every key
/// read here is optional and every type is checked, so a layout change degrades the identity tier
/// instead of crashing.
///
/// Note this backend uses only ordinary IORegistry property reads — no `dlsym`, no private function
/// symbols. The private-API shims are needed for DDC and native brightness, not for this.
public struct AppleSiliconDisplayMetadataBackend: DisplayMetadataBackend {
    public let name = "apple-silicon-dcp"

    /// Service classes to try, in order. More than one is listed because the node that carries
    /// `DisplayAttributes` has moved between macOS releases.
    static let candidateClasses = ["DCPAVServiceProxy", "AppleCLCD2", "IOMobileFramebufferShim"]

    public init() {}

    public func enumerate() -> [DisplayMetadata] {
        for className in Self.candidateClasses {
            var records: [DisplayMetadata] = []
            IORegistryAccess.forEachService(matchingClass: className) { service, entryID in
                guard let attributes = IORegistryAccess.dictionaryProperty(service, "DisplayAttributes")
                else { return }
                // `Location` distinguishes the built-in panel from external ones. When the key is
                // missing, fall back to treating it as external: a false "external" only costs a
                // failed DDC probe, whereas a false "built-in" silently disables DDC entirely.
                let location = IORegistryAccess.stringProperty(service, "Location")
                let isExternal = location.map { $0.caseInsensitiveCompare("External") == .orderedSame } ?? true
                if var record = Self.parse(displayAttributes: attributes, registryEntryID: entryID) {
                    record.isExternal = isExternal
                    record.unitToken = IORegistryAccess.displayUnitToken(service)
                    // `Location` is absent on AppleCLCD2 in macOS 26, so fall back to the unit token:
                    // `dispext*` is an external port, `disp*` is the built-in panel.
                    if location == nil, let token = record.unitToken {
                        record.isExternal = token.hasPrefix("dispext")
                    }
                    records.append(record)
                }
            }
            if !records.isEmpty {
                Log.identity.debug("read \(records.count) display(s) from \(className, privacy: .public)")
                return records
            }
        }
        return []
    }

    /// Pure parse step, split out so tests can drive it from an `ioreg` fixture dictionary with no
    /// hardware attached.
    public static func parse(displayAttributes: [String: Any], registryEntryID: UInt64?) -> DisplayMetadata? {
        // ProductAttributes is the interesting sub-dictionary; some versions inline the keys instead.
        let product = displayAttributes["ProductAttributes"] as? [String: Any] ?? displayAttributes

        let vendorID = registryUInt32(product["LegacyManufacturerID"])
            ?? registryUInt32(product["ManufacturerID"])
            ?? (product["ManufacturerID"] as? String).flatMap(pnpCodeToVendorID)
        let productID = registryUInt32(product["ProductID"])

        // Nothing usable without at least a vendor and product.
        guard vendorID != nil || productID != nil else { return nil }

        var metadata = DisplayMetadata(
            vendorID: vendorID,
            productID: productID,
            serialNumber: registryUInt32(product["SerialNumber"]),
            productName: product["ProductName"] as? String,
            registryEntryID: registryEntryID,
            nativePixelWidth: registryUInt32(product["NativeFormatHorizontalPixels"]).map(Int.init),
            nativePixelHeight: registryUInt32(product["NativeFormatVerticalPixels"]).map(Int.init),
            source: "apple-silicon-dcp"
        )

        // There is no raw EDID here, but some builds expose an "EDID UUID" string that is stable per
        // panel. Hashing it gives the same `.strong` tier guarantee as hashing a real EDID.
        if let uuid = displayAttributes["EDID UUID"] as? String ?? product["EDID UUID"] as? String,
           let data = uuid.data(using: .utf8) {
            metadata.edidHash = EDID.fingerprint(of: data)
        } else if let edid = displayAttributes["IODisplayEDID"] as? Data {
            metadata.edidHash = EDID.fingerprint(of: edid)
        }

        return metadata
    }

    /// Inverse of `EDID.decodeManufacturer` — turns `"DEL"` back into `0x10AC`.
    ///
    /// Used when only the letter form is present, so the vendor ID that names the override directory
    /// still matches what CoreGraphics reports.
    public static func pnpCodeToVendorID(_ code: String) -> UInt32? {
        let letters = code.uppercased().unicodeScalars.filter { $0 >= "A" && $0 <= "Z" }
        guard letters.count == 3 else { return nil }
        var word: UInt16 = 0
        for scalar in letters {
            let value = UInt16(scalar.value - 64) // "A" -> 1
            word = (word << 5) | (value & 0x1F)
        }
        return UInt32(word)
    }
}
