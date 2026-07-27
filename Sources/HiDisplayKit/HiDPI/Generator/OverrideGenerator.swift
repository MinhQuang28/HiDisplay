import Foundation

/// The override document to be written for one display.
public struct DisplayOverrideDocument: Equatable, Sendable {
    public var vendorID: UInt32
    public var productID: UInt32
    public var displayName: String?
    public var scaleResolutions: [ScaledResolution]
    /// Entries read from an existing override that this codec does not understand. Carried through so
    /// regenerating an override never silently deletes another tool's modes.
    public var preservedEntries: [Data]
    /// Patched EDID to inject. Defaults to nil — see `OverrideGenerator` for why.
    public var patchedEDID: Data?

    public init(
        vendorID: UInt32,
        productID: UInt32,
        displayName: String? = nil,
        scaleResolutions: [ScaledResolution],
        preservedEntries: [Data] = [],
        patchedEDID: Data? = nil
    ) {
        self.vendorID = vendorID
        self.productID = productID
        self.displayName = displayName
        self.scaleResolutions = scaleResolutions
        self.preservedEntries = preservedEntries
        self.patchedEDID = patchedEDID
    }
}

public struct GeneratedOverride: Equatable, Sendable {
    /// XML plist bytes, ready to write.
    public var data: Data
    /// Path relative to the override root — never absolute, so generation cannot name a system path.
    public var relativePath: String
    public var validation: ValidationReport
}

/// Turns a set of chosen resolutions into override plist bytes.
///
/// Pure: no filesystem access, no shell, no privileged operation. That is what allows the whole HiDPI
/// feature to be developed and tested before any installer exists, and what makes the output
/// snapshot-testable against a captured real-world override.
public enum OverrideGenerator {

    /// - Parameter document: what to write.
    /// - Parameter nativePixelSize: the panel's real resolution, used only for validation.
    public static func generate(
        _ document: DisplayOverrideDocument,
        nativePixelSize: (width: Int, height: Int)? = nil
    ) -> GeneratedOverride {
        let validation = OverrideValidator.validate(document, nativePixelSize: nativePixelSize)

        var plist: [String: Any] = [:]
        // Note the asymmetry, which is a very easy thing to get wrong: the IDs are DECIMAL integers
        // inside the plist, while the directory and file names that locate this same override are
        // HEX. `OverridePathTests` pins both for one display.
        plist["DisplayVendorID"] = Int(document.vendorID)
        plist["DisplayProductID"] = Int(document.productID)

        if let name = document.displayName, !name.isEmpty {
            plist["DisplayProductName"] = name
        }

        // Deterministic ordering: sorted by pixel area then width, so regenerating the same set of
        // resolutions always produces byte-identical output. Without this, snapshot tests would be
        // flaky and every regeneration would look like a change in a diff.
        let sorted = document.scaleResolutions.sorted { lhs, rhs in
            let lhsArea = lhs.pixelWidth * lhs.pixelHeight
            let rhsArea = rhs.pixelWidth * rhs.pixelHeight
            if lhsArea != rhsArea { return lhsArea < rhsArea }
            if lhs.pixelWidth != rhs.pixelWidth { return lhs.pixelWidth < rhs.pixelWidth }
            return lhs.backingScale < rhs.backingScale
        }
        // A HiDPI entry alone is not enough: macOS also needs the backing resolution declared as a
        // plain 1× entry in the same file, otherwise it silently ignores the HiDPI one.
        //
        // Evidence: an override written by another tool on the development machine contained 89 HiDPI
        // entries, and **all 89** had a matching 1× entry for their backing size — no exceptions. The
        // first version of this generator emitted only the HiDPI half; installed and rebooted, three of
        // its four modes simply never appeared. See docs/hidpi-overrides.md.
        var entries = ScaleResolutionCodec.encode(sorted)
        entries.append(contentsOf: backingDeclarations(for: sorted))
        entries.append(contentsOf: document.preservedEntries)
        if !entries.isEmpty {
            plist["scale-resolutions"] = entries
        }

        // EDID injection is off unless explicitly requested. On Apple Silicon a patched EDID has
        // little or no effect and measurably raises the risk of a black screen on wake, so the app
        // must not add one just because it can.
        if let edid = document.patchedEDID {
            plist["IODisplayEDID"] = edid
        }

        let data: Data
        do {
            // XML rather than binary: a human can read it, diff it, and repair it from Recovery with
            // nothing but a text editor — which is the situation this app has to be survivable in.
            data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0)
        } catch {
            Log.hidpiGenerator.error("plist serialization failed: \(String(describing: error), privacy: .public)")
            data = Data()
        }

        return GeneratedOverride(
            data: data,
            relativePath: OverridePaths.relativePath(
                vendorID: document.vendorID, productID: document.productID),
            validation: validation)
    }

    /// The 1× entries that declare each HiDPI mode's backing resolution.
    ///
    /// Deduplicated and sorted so output stays deterministic, and skipped for 1× resolutions, which
    /// already are their own backing.
    static func backingDeclarations(for resolutions: [ScaledResolution]) -> [Data] {
        var seen = Set<String>()
        var backings: [ScaledResolution] = []
        for resolution in resolutions where resolution.isHiDPI {
            let backing = ScaledResolution(
                logicalWidth: resolution.pixelWidth,
                logicalHeight: resolution.pixelHeight,
                backingScale: 1)
            // A backing that coincides with a requested 1× mode must not be emitted twice.
            guard seen.insert(backing.id).inserted else { continue }
            backings.append(backing)
        }
        let alreadyRequested = Set(resolutions.filter { !$0.isHiDPI }.map(\.id))
        return backings
            .filter { !alreadyRequested.contains($0.id) }
            .sorted { $0.logicalWidth * $0.logicalHeight < $1.logicalWidth * $1.logicalHeight }
            .map(ScaleResolutionCodec.encode)
    }

    /// Reads an existing override so it can be merged rather than replaced.
    ///
    /// Unknown `scale-resolutions` entries come back in `preservedEntries`, and unknown top-level keys
    /// are reported separately so the installer's preview can tell the user what it is about to drop.
    public static func parseExisting(_ data: Data) throws -> (document: DisplayOverrideDocument, unknownKeys: [String]) {
        guard let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any]
        else {
            throw OverrideParseError.notADictionary
        }

        var resolutions: [ScaledResolution] = []
        var preserved: [Data] = []
        if let entries = plist["scale-resolutions"] as? [Data] {
            for entry in entries {
                switch ScaleResolutionCodec.decode(entry) {
                case .entry(let decoded):
                    // Only entries in the exact form this app emits are treated as editable. Anything
                    // else — Apple's 12-byte form, the marker-0x9 variant, the stray ninth byte — is
                    // carried through untouched, because re-emitting it in our own form would change
                    // semantics we do not understand.
                    if decoded.encoded() == ScaleResolutionCodec.encode(decoded.asScaledResolution) {
                        resolutions.append(decoded.asScaledResolution)
                    } else {
                        preserved.append(entry)
                    }
                case .unrecognized(let blob):
                    preserved.append(blob)
                }
            }
        }

        let known: Set<String> = [
            "DisplayVendorID", "DisplayProductID", "DisplayProductName",
            "scale-resolutions", "IODisplayEDID",
        ]
        let unknownKeys = plist.keys.filter { !known.contains($0) }.sorted()

        let document = DisplayOverrideDocument(
            vendorID: UInt32(plist["DisplayVendorID"] as? Int ?? 0),
            productID: UInt32(plist["DisplayProductID"] as? Int ?? 0),
            displayName: plist["DisplayProductName"] as? String,
            scaleResolutions: resolutions,
            preservedEntries: preserved,
            patchedEDID: plist["IODisplayEDID"] as? Data)
        return (document, unknownKeys)
    }
}

public enum OverrideParseError: Error, Equatable, CustomStringConvertible {
    case notADictionary

    public var description: String {
        "override file is not a plist dictionary"
    }
}
