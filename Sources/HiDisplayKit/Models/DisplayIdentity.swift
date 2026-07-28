import Foundation

/// How much trust the stable key deserves. Persisted with the profile, because a profile written
/// under `.location` needs different reconnect handling than one written under `.strong`.
public enum DisplayKeyTier: Int, Codable, Sendable, CaseIterable {
    /// A serial number or EDID hash is present: survives reboot, port changes and hubs.
    case strong = 3
    /// Vendor + product only. Correct while just one such display is attached, and the only
    /// option when a monitor reports no serial at all.
    case weak = 1
    /// Vendor + product + IORegistry location. Distinguishes two identical monitors, but breaks
    /// when the user swaps ports, changes hub, or routes through a KVM.
    case location = 2

    public var explanation: String {
        switch self {
        case .strong:
            return "Identified by serial number or EDID — stable across reboots and port changes."
        case .weak:
            return "Identified by vendor and product only — this monitor reports no serial number."
        case .location:
            return "Identified by the port it is plugged into, because two identical monitors are "
                + "attached and neither reports a serial number. Moving it to another port will "
                + "look like a new display."
        }
    }
}

/// Everything known about one physical display that could contribute to identifying it again later.
///
/// `cgDisplayID` is deliberately excluded from `stableKey` and from `Codable` round-trips that feed
/// profiles: CoreGraphics display IDs are reassigned across reconnects and reboots.
public struct DisplayIdentity: Hashable, Codable, Sendable {
    /// Runtime handle only. Never persisted as a profile key.
    public var cgDisplayID: UInt32
    public var vendorID: UInt32
    public var productID: UInt32
    /// `nil` or `0` on a large share of Apple Silicon setups — see `DisplayIdentityResolver`.
    public var serialNumber: UInt32?
    /// IORegistry entry ID of the backing service. Diagnostic only: entry IDs are unique per *boot*,
    /// so a profile key built from one dissolves at every restart.
    public var registryLocation: UInt64?
    /// Boot-stable location proxy: the DCP unit token (`dispext0`, `dispext1`, …) that names the
    /// port the display is attached to. The same port produces the same token across reboots, which
    /// is exactly the promise the `.location` tier makes — "identified by the port it is plugged
    /// into" — and what `registryLocation` could not deliver.
    public var locationToken: String?
    /// SHA-256 (truncated) of the EDID or of the display's EDID UUID, when either is readable.
    public var edidHash: String?
    public var persistentUUID: UUID?
    public var keyTier: DisplayKeyTier
    /// Set when the user manually says "this is the display I previously called X". Once present it
    /// outranks every other tier, because the human is a better authority than the heuristic.
    public var userAssignedID: UUID?

    public init(
        cgDisplayID: UInt32,
        vendorID: UInt32,
        productID: UInt32,
        serialNumber: UInt32? = nil,
        registryLocation: UInt64? = nil,
        locationToken: String? = nil,
        edidHash: String? = nil,
        persistentUUID: UUID? = nil,
        keyTier: DisplayKeyTier = .weak,
        userAssignedID: UUID? = nil
    ) {
        self.cgDisplayID = cgDisplayID
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
        self.registryLocation = registryLocation
        self.locationToken = locationToken
        self.edidHash = edidHash
        self.persistentUUID = persistentUUID
        self.keyTier = keyTier
        self.userAssignedID = userAssignedID
    }

    /// The profile key. Deterministic, lowercase hex, no locale-dependent formatting.
    ///
    /// A user assignment wins outright. Otherwise the key reflects `keyTier`, and the tier is baked
    /// into the string so a display that is later identified more strongly does not silently adopt
    /// the weaker profile — it gets a new one, and the reconnect UI can offer to merge them.
    public var stableKey: String {
        if let userAssignedID {
            return "user-\(userAssignedID.uuidString.lowercased())"
        }
        let base = String(format: "v%04x-p%04x", vendorID, productID)
        switch keyTier {
        case .strong:
            if let edidHash, !edidHash.isEmpty {
                return "\(base)-e\(edidHash)"
            }
            // `.strong` without an EDID hash means the serial is the strong part.
            return String(format: "%@-s%08x", base, serialNumber ?? 0)
        case .location:
            // The unit token survives a reboot; the registry entry ID does not. The ID form is kept
            // only as the fallback for a backend that produced no token — those keys were already
            // per-boot, so nothing stable is lost by preferring the token whenever it exists.
            if let locationToken, !locationToken.isEmpty {
                let safe = locationToken.lowercased().filter { $0.isLetter || $0.isNumber }
                return "\(base)-t\(safe)"
            }
            return String(format: "%@-l%016llx", base, registryLocation ?? 0)
        case .weak:
            return base
        }
    }

    /// True when this identity carries something genuinely unique to the panel.
    public var hasStrongDiscriminator: Bool {
        if let edidHash, !edidHash.isEmpty { return true }
        if let serialNumber, serialNumber != 0 { return true }
        return false
    }
}
