import Foundation
import IOKit

/// Reads display metadata from `IODisplayConnect`, the Intel-era path.
///
/// On Intel Macs this node carries the raw EDID under `IODisplayEDID`, which gives the strongest
/// possible identity: a hash of the panel's own descriptor block. On Apple Silicon this class has no
/// matching services for external displays, so `enumerate()` returns an empty array and the
/// composite backend moves on.
public struct IntelDisplayMetadataBackend: DisplayMetadataBackend {
    public let name = "intel-iodisplayconnect"

    public init() {}

    public func enumerate() -> [DisplayMetadata] {
        var records: [DisplayMetadata] = []
        IORegistryAccess.forEachService(matchingClass: "IODisplayConnect") { service, entryID in
            var properties: [String: Any] = [:]
            for key in ["DisplayVendorID", "DisplayProductID", "DisplaySerialNumber", "DisplayProductName"] {
                if let value = IORegistryAccess.property(service, key) {
                    properties[key] = value
                }
            }
            let edid = IORegistryAccess.dataProperty(service, "IODisplayEDID")
                ?? IORegistryAccess.searchProperty(service, "IODisplayEDID") as? Data
            if let record = Self.parse(properties: properties, edid: edid, registryEntryID: entryID) {
                records.append(record)
            }
        }
        if !records.isEmpty {
            Log.identity.debug("read \(records.count) display(s) from IODisplayConnect")
        }
        return records
    }

    /// Pure parse step, fixture-drivable.
    ///
    /// EDID is parsed with `validateChecksum: false`: a bad checksum coming through a KVM or a cheap
    /// adapter is common, and the vendor/product fields are still usable for identification. The
    /// hash is taken over the raw bytes regardless, so it stays stable even for a malformed EDID.
    public static func parse(
        properties: [String: Any],
        edid: Data?,
        registryEntryID: UInt64?
    ) -> DisplayMetadata? {
        var metadata = DisplayMetadata(
            vendorID: registryUInt32(properties["DisplayVendorID"]),
            productID: registryUInt32(properties["DisplayProductID"]),
            serialNumber: registryUInt32(properties["DisplaySerialNumber"]),
            productName: localizedProductName(properties["DisplayProductName"]),
            registryEntryID: registryEntryID,
            source: "intel-iodisplayconnect"
        )

        if let edid {
            metadata.edidHash = EDID.fingerprint(of: edid)
            if let parsed = try? EDID(data: edid, validateChecksum: false) {
                metadata.vendorID = metadata.vendorID ?? parsed.vendorID
                metadata.productID = metadata.productID ?? parsed.productID
                if metadata.serialNumber == nil || metadata.serialNumber == 0 {
                    metadata.serialNumber = parsed.serialNumber
                }
                metadata.productName = metadata.productName ?? parsed.monitorName
                metadata.nativePixelWidth = parsed.nativePixelWidth
                metadata.nativePixelHeight = parsed.nativePixelHeight
            }
        }

        guard metadata.vendorID != nil || metadata.productID != nil || metadata.edidHash != nil else {
            return nil
        }
        return metadata
    }

    /// `DisplayProductName` is a dictionary keyed by locale, e.g. `{ "en_US" = "DELL U2723QE"; }`.
    static func localizedProductName(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        guard let localized = value as? [String: Any] else { return nil }
        for locale in Locale.preferredLanguages + ["en_US", "en"] {
            if let name = localized[locale] as? String { return name }
        }
        return localized.values.compactMap { $0 as? String }.first
    }
}
