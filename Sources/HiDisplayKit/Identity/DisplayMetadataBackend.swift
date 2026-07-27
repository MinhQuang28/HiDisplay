import Foundation

/// Per-display facts read out of the IORegistry, independent of how they were obtained.
public struct DisplayMetadata: Equatable, Sendable {
    public var vendorID: UInt32?
    public var productID: UInt32?
    /// `nil` when absent, `0` when the panel explicitly reports no serial. Both are treated as
    /// "no strong discriminator".
    public var serialNumber: UInt32?
    public var productName: String?
    public var registryEntryID: UInt64?
    public var edidHash: String?
    public var nativePixelWidth: Int?
    public var nativePixelHeight: Int?
    /// IOService display unit this record came from — `disp0`, `dispext0`. The join key between the
    /// metadata branch and the DDC branch; see `IORegistryAccess.displayUnitToken`.
    public var unitToken: String?
    /// `false` for built-in panels. Only external displays are DDC candidates.
    public var isExternal: Bool
    /// Which backend produced this, for diagnostics.
    public var source: String

    public init(
        vendorID: UInt32? = nil,
        productID: UInt32? = nil,
        serialNumber: UInt32? = nil,
        productName: String? = nil,
        registryEntryID: UInt64? = nil,
        edidHash: String? = nil,
        nativePixelWidth: Int? = nil,
        nativePixelHeight: Int? = nil,
        unitToken: String? = nil,
        isExternal: Bool = true,
        source: String = "unknown"
    ) {
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
        self.productName = productName
        self.registryEntryID = registryEntryID
        self.edidHash = edidHash
        self.nativePixelWidth = nativePixelWidth
        self.nativePixelHeight = nativePixelHeight
        self.unitToken = unitToken
        self.isExternal = isExternal
        self.source = source
    }

    /// Whether this record can be told apart from another record of the same monitor model.
    public var hasStrongDiscriminator: Bool {
        if let edidHash, !edidHash.isEmpty { return true }
        if let serialNumber, serialNumber != 0 { return true }
        return false
    }
}

/// One way of reading display metadata out of the system.
///
/// The protocol survives having only one implementation: it is the seam the tests inject fixtures
/// through, and it is where a second registry branch would be added if a future macOS moves external
/// displays somewhere new — see docs/private-apis.md. There was a second implementation reading
/// `IODisplayConnect`, the Intel-era node; it was removed when the project narrowed to Apple Silicon,
/// where that node has no matching services for external displays.
public protocol DisplayMetadataBackend {
    var name: String { get }
    func enumerate() -> [DisplayMetadata]
}

/// Tries each backend in order and returns the first non-empty result.
public struct CompositeDisplayMetadataBackend: DisplayMetadataBackend {
    public let name = "composite"
    public let backends: [DisplayMetadataBackend]

    public init(backends: [DisplayMetadataBackend] = [
        AppleSiliconDisplayMetadataBackend(),
    ]) {
        self.backends = backends
    }

    public func enumerate() -> [DisplayMetadata] {
        for backend in backends {
            let records = backend.enumerate()
            if !records.isEmpty {
                Log.identity.debug("metadata backend \(backend.name, privacy: .public) returned \(records.count) record(s)")
                return records
            }
        }
        Log.identity.notice("no metadata backend returned records; falling back to CoreGraphics only")
        return []
    }
}
