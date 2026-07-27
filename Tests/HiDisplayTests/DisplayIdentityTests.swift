import XCTest
@testable import HiDisplayKit

/// Guards the identity logic, which is the highest-consequence pure code in the project: a key
/// collision means two monitors share one profile and fight over brightness and HiDPI settings.
///
/// The scenario driving most of these is the one the original plan assumed away — two identical
/// monitors on Apple Silicon, both reporting serial `0`.
final class DisplayIdentityTests: XCTestCase {

    // MARK: - Key tiers

    func testSerialNumberProducesStrongTier() {
        let displays = [
            RawDisplayInfo(cgDisplayID: 1, vendorID: 0x10AC, productID: 0xD0A1, serialNumber: 0xABCD),
        ]
        let resolved = DisplayIdentityResolver.resolve(displays: displays, metadata: [])
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved[0].identity.keyTier, .strong)
        XCTAssertEqual(resolved[0].identity.stableKey, "v10ac-pd0a1-s0000abcd")
    }

    func testEDIDHashProducesStrongTierEvenWithoutSerial() {
        let displays = [
            RawDisplayInfo(cgDisplayID: 1, vendorID: 0x10AC, productID: 0xD0A1, serialNumber: 0),
        ]
        let metadata = [
            DisplayMetadata(vendorID: 0x10AC, productID: 0xD0A1, serialNumber: 0, edidHash: "deadbeefcafe1234"),
        ]
        let resolved = DisplayIdentityResolver.resolve(displays: displays, metadata: metadata)
        XCTAssertEqual(resolved[0].identity.keyTier, .strong)
        XCTAssertEqual(resolved[0].identity.stableKey, "v10ac-pd0a1-edeadbeefcafe1234")
    }

    func testLoneDisplayWithNoDiscriminatorUsesWeakTier() {
        let displays = [
            RawDisplayInfo(cgDisplayID: 1, vendorID: 0x10AC, productID: 0xD0A1, serialNumber: 0, unitNumber: 3),
        ]
        let resolved = DisplayIdentityResolver.resolve(displays: displays, metadata: [])
        // Weak is correct here: there is nothing to collide with, and a port-dependent key would
        // needlessly break when the user moves the cable.
        XCTAssertEqual(resolved[0].identity.keyTier, .weak)
        XCTAssertEqual(resolved[0].identity.stableKey, "v10ac-pd0a1")
    }

    /// The bug this whole tier system exists to prevent.
    func testTwoIdenticalSeriallessDisplaysDoNotCollide() {
        let displays = [
            RawDisplayInfo(cgDisplayID: 1, vendorID: 0x10AC, productID: 0xD0A1, serialNumber: 0, unitNumber: 1),
            RawDisplayInfo(cgDisplayID: 2, vendorID: 0x10AC, productID: 0xD0A1, serialNumber: 0, unitNumber: 2),
        ]
        let metadata = [
            DisplayMetadata(vendorID: 0x10AC, productID: 0xD0A1, serialNumber: 0, registryEntryID: 0x4001),
            DisplayMetadata(vendorID: 0x10AC, productID: 0xD0A1, serialNumber: 0, registryEntryID: 0x4002),
        ]
        let resolved = DisplayIdentityResolver.resolve(displays: displays, metadata: metadata)

        XCTAssertEqual(resolved.count, 2)
        XCTAssertNotEqual(
            resolved[0].identity.stableKey, resolved[1].identity.stableKey,
            "two identical monitors must not share a profile key")
        XCTAssertEqual(resolved[0].identity.keyTier, .location)
        XCTAssertEqual(resolved[1].identity.keyTier, .location)
        // And the pairing is honestly reported as a guess.
        XCTAssertEqual(resolved[0].pairing, .ambiguous)
        XCTAssertEqual(resolved[1].pairing, .ambiguous)
    }

    func testIdenticalDisplaysFallBackToUnitNumberWhenNoMetadata() {
        let displays = [
            RawDisplayInfo(cgDisplayID: 1, vendorID: 0x10AC, productID: 0xD0A1, serialNumber: 0, unitNumber: 7),
            RawDisplayInfo(cgDisplayID: 2, vendorID: 0x10AC, productID: 0xD0A1, serialNumber: 0, unitNumber: 8),
        ]
        // No IORegistry records at all — the resolver must still keep them apart.
        let resolved = DisplayIdentityResolver.resolve(displays: displays, metadata: [])
        XCTAssertNotEqual(resolved[0].identity.stableKey, resolved[1].identity.stableKey)
        XCTAssertEqual(resolved[0].pairing, .unmatched)
    }

    func testDifferentSerialsDisambiguateSameModel() {
        let displays = [
            RawDisplayInfo(cgDisplayID: 1, vendorID: 0x10AC, productID: 0xD0A1, serialNumber: 0x111),
            RawDisplayInfo(cgDisplayID: 2, vendorID: 0x10AC, productID: 0xD0A1, serialNumber: 0x222),
        ]
        let metadata = [
            DisplayMetadata(vendorID: 0x10AC, productID: 0xD0A1, serialNumber: 0x222, registryEntryID: 0x1),
            DisplayMetadata(vendorID: 0x10AC, productID: 0xD0A1, serialNumber: 0x111, registryEntryID: 0x2),
        ]
        let resolved = DisplayIdentityResolver.resolve(displays: displays, metadata: metadata)
        // Both pair confidently despite the metadata arriving in the opposite order.
        XCTAssertEqual(resolved.map(\.pairing), [.confident, .confident])
        XCTAssertEqual(resolved[0].identity.stableKey, "v10ac-pd0a1-s00000111")
        XCTAssertEqual(resolved[1].identity.stableKey, "v10ac-pd0a1-s00000222")
    }

    // MARK: - Determinism and pinning

    func testResolutionIsDeterministicRegardlessOfInputOrder() {
        let a = RawDisplayInfo(cgDisplayID: 9, vendorID: 0x10AC, productID: 0xD0A1, serialNumber: 0, unitNumber: 1)
        let b = RawDisplayInfo(cgDisplayID: 4, vendorID: 0x10AC, productID: 0xD0A1, serialNumber: 0, unitNumber: 2)
        let forward = DisplayIdentityResolver.resolve(displays: [a, b], metadata: []).map(\.identity.stableKey)
        let reversed = DisplayIdentityResolver.resolve(displays: [b, a], metadata: []).map(\.identity.stableKey)
        XCTAssertEqual(forward, reversed)
    }

    func testUserAssignmentOutranksEveryTier() {
        let displays = [
            RawDisplayInfo(cgDisplayID: 1, vendorID: 0x10AC, productID: 0xD0A1, serialNumber: 0, unitNumber: 5),
        ]
        let heuristicKey = "v10ac-pd0a1"
        let pinned = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let resolved = DisplayIdentityResolver.resolve(
            displays: displays, metadata: [], userAssignments: [heuristicKey: pinned])
        XCTAssertEqual(resolved[0].identity.stableKey, "user-11111111-2222-3333-4444-555555555555")
    }

    func testStableKeyIsLowercaseHexAndLocaleIndependent() {
        let identity = DisplayIdentity(
            cgDisplayID: 1, vendorID: 0xABCD, productID: 0x00EF,
            serialNumber: 0x1234_5678, keyTier: .strong)
        XCTAssertEqual(identity.stableKey, "vabcd-p00ef-s12345678")
    }

    // MARK: - Vendor/product fallback

    func testVendorAndProductFallBackToMetadataWhenCoreGraphicsReportsZero() {
        let displays = [
            RawDisplayInfo(cgDisplayID: 1, vendorID: 0, productID: 0, serialNumber: 0),
        ]
        let metadata = [DisplayMetadata(vendorID: 0x1E6D, productID: 0x5B11, registryEntryID: 1)]
        let resolved = DisplayIdentityResolver.resolve(displays: displays, metadata: metadata)
        XCTAssertEqual(resolved[0].identity.vendorID, 0x1E6D)
        XCTAssertEqual(resolved[0].identity.productID, 0x5B11)
    }
}
