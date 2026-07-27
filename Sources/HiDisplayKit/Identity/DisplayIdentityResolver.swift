import Foundation

/// What CoreGraphics alone knows about a display. Split out from the resolver so the whole pairing
/// algorithm is a pure function over plain values and can be tested with no display attached.
public struct RawDisplayInfo: Equatable, Sendable {
    public var cgDisplayID: UInt32
    public var vendorID: UInt32
    public var productID: UInt32
    /// `CGDisplaySerialNumber`. Frequently `0` on Apple Silicon.
    public var serialNumber: UInt32
    /// `CGDisplayUnitNumber` — a per-connection logical unit. Used only as a last-resort
    /// discriminator when no registry entry ID is available; it is not stable across port changes.
    public var unitNumber: UInt32
    public var isBuiltIn: Bool

    public init(
        cgDisplayID: UInt32,
        vendorID: UInt32,
        productID: UInt32,
        serialNumber: UInt32,
        unitNumber: UInt32 = 0,
        isBuiltIn: Bool = false
    ) {
        self.cgDisplayID = cgDisplayID
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
        self.unitNumber = unitNumber
        self.isBuiltIn = isBuiltIn
    }
}

/// How much to trust the CoreGraphics display ↔ IORegistry record pairing.
public enum PairingConfidence: String, Codable, Sendable {
    /// Exactly one registry record matched, or the serial number disambiguated it.
    case confident
    /// Several indistinguishable records matched. A record was assigned deterministically so the two
    /// displays still get *different* profile keys, but the assignment may be swapped between them.
    /// The UI must let the user confirm which is which before anything irreversible.
    case ambiguous
    /// No registry record matched. Identity falls back to CoreGraphics fields only.
    case unmatched
}

public struct ResolvedDisplay: Sendable {
    public var identity: DisplayIdentity
    public var metadata: DisplayMetadata?
    public var pairing: PairingConfidence
}

/// Builds stable, non-colliding profile keys out of whatever the system is willing to tell us.
///
/// The hard case this exists for: two identical monitors on Apple Silicon, both reporting serial `0`.
/// A naive `vendor-product-serial` key maps them onto one profile, so they fight over brightness and
/// HiDPI settings. The tier system below keeps them apart, and is explicit about the cost — a
/// `.location` key breaks when the user swaps ports, which the UI then handles by asking.
public struct DisplayIdentityResolver {

    public init() {}

    /// - Parameters:
    ///   - displays: CoreGraphics view of the world.
    ///   - metadata: IORegistry view of the world, from whichever backend answered.
    ///   - userAssignments: stableKey-as-computed → user-pinned UUID, from the profile store. Lets a
    ///     human override the heuristic permanently.
    public static func resolve(
        displays: [RawDisplayInfo],
        metadata: [DisplayMetadata],
        userAssignments: [String: UUID] = [:]
    ) -> [ResolvedDisplay] {
        // Deterministic iteration order: two runs on the same hardware must produce the same keys.
        let ordered = displays.sorted { $0.cgDisplayID < $1.cgDisplayID }

        // How many attached displays share each vendor+product pair. This — not the metadata list —
        // decides whether `.weak` is safe, because it is the attached set that can collide.
        var modelCounts: [ModelKey: Int] = [:]
        for display in ordered {
            modelCounts[ModelKey(display), default: 0] += 1
        }

        var pool = metadata.sorted { ($0.registryEntryID ?? 0) < ($1.registryEntryID ?? 0) }
        var results: [ResolvedDisplay] = []
        /// Models where an indistinguishable choice has already been made.
        ///
        /// Needed because of a subtlety: with two identical records and two identical displays, the
        /// first pairing is obviously a guess, but the second one then finds only one record left and
        /// would look "confident". It is not — it inherited the first coin flip. Marking the whole model
        /// group keeps the UI honest about both displays.
        var ambiguousModels: Set<ModelKey> = []

        for display in ordered {
            var (record, confidence) = takeMatch(for: display, from: &pool)
            let model = ModelKey(display)
            if confidence == .ambiguous {
                ambiguousModels.insert(model)
            } else if confidence == .confident, ambiguousModels.contains(model) {
                confidence = .ambiguous
            }

            let serial = strongSerial(display: display, record: record)
            let edidHash = record?.edidHash

            // A registry entry ID is the better location proxy; unit number is the fallback so that
            // two identical serial-less monitors still differ even when metadata is unavailable.
            let location = record?.registryEntryID ?? UInt64(display.unitNumber)

            let hasStrong = (serial != nil && serial != 0) || (edidHash?.isEmpty == false)
            let sharesModel = (modelCounts[ModelKey(display)] ?? 1) > 1

            let tier: DisplayKeyTier
            if hasStrong {
                tier = .strong
            } else if sharesModel {
                tier = .location
            } else {
                tier = .weak
            }

            var identity = DisplayIdentity(
                cgDisplayID: display.cgDisplayID,
                vendorID: display.vendorID != 0 ? display.vendorID : (record?.vendorID ?? 0),
                productID: display.productID != 0 ? display.productID : (record?.productID ?? 0),
                serialNumber: serial,
                registryLocation: location,
                edidHash: edidHash,
                keyTier: tier
            )
            // Apply a user pin only after the heuristic key is known, because that key is what the
            // pin is recorded against.
            if let pinned = userAssignments[identity.stableKey] {
                identity.userAssignedID = pinned
            }

            results.append(ResolvedDisplay(identity: identity, metadata: record, pairing: confidence))
        }

        return results
    }

    // MARK: - Internals

    private struct ModelKey: Hashable {
        let vendorID: UInt32
        let productID: UInt32
        init(_ display: RawDisplayInfo) {
            self.vendorID = display.vendorID
            self.productID = display.productID
        }
    }

    /// A serial worth keying on, preferring whichever source actually has one.
    private static func strongSerial(display: RawDisplayInfo, record: DisplayMetadata?) -> UInt32? {
        if display.serialNumber != 0 { return display.serialNumber }
        if let recorded = record?.serialNumber, recorded != 0 { return recorded }
        return nil
    }

    /// Removes and returns the best metadata match for `display`, along with how confident that
    /// match is. Consuming from the pool prevents two displays claiming the same record.
    private static func takeMatch(
        for display: RawDisplayInfo,
        from pool: inout [DisplayMetadata]
    ) -> (DisplayMetadata?, PairingConfidence) {
        let candidateIndices = pool.indices.filter { index in
            let record = pool[index]
            // Require agreement on any field both sides claim to know; treat a missing field on the
            // registry side as "no objection" rather than a mismatch.
            if let vendor = record.vendorID, display.vendorID != 0, vendor != display.vendorID { return false }
            if let product = record.productID, display.productID != 0, product != display.productID { return false }
            return true
        }

        guard !candidateIndices.isEmpty else { return (nil, .unmatched) }

        if candidateIndices.count == 1 {
            return (pool.remove(at: candidateIndices[0]), .confident)
        }

        // Several same-model records. A matching serial resolves it outright.
        if display.serialNumber != 0,
           let exact = candidateIndices.first(where: { pool[$0].serialNumber == display.serialNumber }) {
            return (pool.remove(at: exact), .confident)
        }

        // Genuinely indistinguishable. Take the lowest registry entry ID so the assignment is at
        // least deterministic, and tell the caller it is a guess.
        Log.identity.notice(
            "ambiguous display pairing: \(candidateIndices.count, privacy: .public) registry records match vendor/product; assignment is deterministic but unverified")
        return (pool.remove(at: candidateIndices[0]), .ambiguous)
    }
}
