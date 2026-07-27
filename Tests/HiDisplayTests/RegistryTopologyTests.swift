import XCTest
@testable import HiDisplayKit

/// Covers the registry-topology logic that hardware testing forced into existence.
///
/// The bug these guard against was real and silent: `IOAVServiceCreateWithService` returned null for
/// every external display, because the app was handing it the node that carries `DisplayAttributes`
/// (`AppleCLCD2`) rather than the node that is an AV service (`DCPAVServiceProxy`). Nothing crashed —
/// DDC simply never worked, and the app reported "no transport could bind" as though the hardware were
/// at fault.
final class DisplayUnitTokenTests: XCTestCase {

    /// Names taken verbatim from `ioreg` on macOS 26.5.2 with one external display attached.
    func testParsesRealRegistryNodeNames() {
        XCTAssertEqual(IORegistryAccess.parseDisplayUnitToken("disp0@7C000000"), "disp0")
        XCTAssertEqual(IORegistryAccess.parseDisplayUnitToken("dispext0@8000000"), "dispext0")
        XCTAssertEqual(IORegistryAccess.parseDisplayUnitToken("disp0:dcpav-service-epic:0"), "disp0")
        XCTAssertEqual(IORegistryAccess.parseDisplayUnitToken("dispext0:dcpav-service-epic:0"), "dispext0")
    }

    /// The two branches describing one display must produce the same token — that equality *is* the join.
    func testMetadataNodeAndAVServiceNodeAgreeOnTheToken() {
        XCTAssertEqual(
            IORegistryAccess.parseDisplayUnitToken("dispext0@8000000"),
            IORegistryAccess.parseDisplayUnitToken("dispext0:dcpav-service-epic:0"))
        XCTAssertEqual(
            IORegistryAccess.parseDisplayUnitToken("disp0@7C000000"),
            IORegistryAccess.parseDisplayUnitToken("disp0:dcpav-service-epic:0"))
    }

    /// And two different displays must not collide, or a DDC command could reach the wrong monitor.
    func testDifferentUnitsDoNotCollide() {
        XCTAssertNotEqual(
            IORegistryAccess.parseDisplayUnitToken("dispext0@8000000"),
            IORegistryAccess.parseDisplayUnitToken("dispext1@8000000"))
        XCTAssertNotEqual(
            IORegistryAccess.parseDisplayUnitToken("disp0@7C000000"),
            IORegistryAccess.parseDisplayUnitToken("dispext0@8000000"))
    }

    /// Real sibling nodes that start with "disp" but are not display units.
    func testRejectsNodesThatMerelyStartWithDisp() {
        XCTAssertNil(IORegistryAccess.parseDisplayUnitToken("display-crossbar0"))
        XCTAssertNil(IORegistryAccess.parseDisplayUnitToken("dispext"))
        XCTAssertNil(IORegistryAccess.parseDisplayUnitToken("dispextE:dcpav-controller-epic:0"),
                     "dispextE has a letter where the unit index belongs — not a unit node")
        XCTAssertNil(IORegistryAccess.parseDisplayUnitToken("dcp@7EC00000"))
        XCTAssertNil(IORegistryAccess.parseDisplayUnitToken(""))
    }

    func testBuiltInVersusExternalIsDecidableFromTheToken() {
        // `Location` is absent on AppleCLCD2 in macOS 26, so the token prefix carries this.
        XCTAssertTrue(IORegistryAccess.parseDisplayUnitToken("dispext0@8000000")!.hasPrefix("dispext"))
        XCTAssertFalse(IORegistryAccess.parseDisplayUnitToken("disp0@7C000000")!.hasPrefix("dispext"))
    }
}

final class RegistryValueCoercionTests: XCTestCase {

    /// The built-in panel on macOS 26 reports `ProductID = 62896309613633`.
    ///
    /// Truncating produced `0x30313441`, a plausible-looking value that then disagreed with
    /// CoreGraphics' product ID and silently prevented the built-in display from ever pairing with its
    /// registry record. Reporting the field as absent lets the matcher fall back to what it can trust.
    func testOversizedValuesAreReportedAsAbsentRatherThanTruncated() {
        XCTAssertNil(registryUInt32(NSNumber(value: UInt64(62_896_309_613_633))))
        XCTAssertNil(registryUInt32(NSNumber(value: UInt64(UInt32.max) + 1)))
        XCTAssertEqual(registryUInt32(NSNumber(value: UInt64(UInt32.max))), UInt32.max)
    }

    func testAnAbsentFieldDoesNotBlockPairing() {
        // Vendor matches, product is unreadable: the display must still pair rather than be orphaned.
        let displays = [
            RawDisplayInfo(cgDisplayID: 1, vendorID: 0x0610, productID: 0xA059, serialNumber: 0xFD62_6D62),
        ]
        let metadata = [DisplayMetadata(vendorID: 0x0610, productID: nil, registryEntryID: 0x5DA)]
        let resolved = DisplayIdentityResolver.resolve(displays: displays, metadata: metadata)

        XCTAssertEqual(resolved[0].pairing, .confident)
        XCTAssertNotNil(resolved[0].metadata)
    }
}

final class IOReturnDescriptionTests: XCTestCase {

    /// The exact value returned by `IOAVServiceWriteI2C` on a Realtek USB-C display path,
    /// macOS 26.5.2 — see Tests/HardwareMatrix/results.md.
    func testDecodesTheObservedNoI2CChannelError() {
        let text = IOReturnDescription.describe(Int32(bitPattern: 0xE011_4000))
        XCTAssertTrue(text.contains("0xe0114000"))
        XCTAssertTrue(text.contains("does not expose an I2C channel"),
                      "the message must tell the user this is the cable/dock, not a broken app")
        XCTAssertTrue(text.contains("software dimming"), "and what the app does instead")
    }

    func testNamesGeneralIOKitErrors() {
        XCTAssertTrue(IOReturnDescription.describe(Int32(bitPattern: 0xE000_02C0)).contains("kIOReturnNoDevice"))
        XCTAssertTrue(IOReturnDescription.describe(Int32(bitPattern: 0xE000_02C7)).contains("kIOReturnUnsupported"))
        XCTAssertTrue(IOReturnDescription.describe(Int32(bitPattern: 0xE000_02D6)).contains("kIOReturnTimeout"))
    }

    func testUnknownSubsystemStillReportsItsParts() {
        // An unrecognised driver subsystem must still be decoded into something reportable.
        let text = IOReturnDescription.describe(Int32(bitPattern: 0xE099_9123))
        XCTAssertTrue(text.contains("subsystem 0x999"))
        XCTAssertTrue(text.contains("code 0x123"))
    }

    func testNonIOKitErrorIsLabelled() {
        XCTAssertTrue(IOReturnDescription.describe(1234).contains("not an IOKit error"))
    }

    func testDDCErrorUsesTheDecoder() {
        let error = DDCError.ioError(code: Int32(bitPattern: 0xE011_4000))
        XCTAssertTrue(error.description.contains("does not expose an I2C channel"))
    }
}
