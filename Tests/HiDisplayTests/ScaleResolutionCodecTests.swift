import XCTest
@testable import HiDisplayKit

/// Pins the `scale-resolutions` binary format against **real override files** copied off a macOS 26
/// install, not against the codec's own output.
///
/// This matters because the format is undocumented. A test that only round-trips the encoder would
/// pass just as happily with a wrong format, so the load-bearing assertions here are the ones that
/// read Apple's and a third-party tool's actual bytes.
final class ScaleResolutionCodecTests: XCTestCase {

    // MARK: - Encoding

    func testHiDPIEncodingMatchesTheFormUsedByAWorkingOverride() {
        // 2048 × 1152 logical → 4096 × 2304 backing. This exact entry (modulo the marker word) is
        // present in the third-party override installed on the development machine.
        let resolution = ScaledResolution(logicalWidth: 2048, logicalHeight: 1152, backingScale: 2)
        let encoded = ScaleResolutionCodec.encode(resolution)
        XCTAssertEqual(encoded.count, 16)
        XCTAssertEqual(encoded.map { String(format: "%02x", $0) }.joined(),
                       "00001000" + "00000900" + "00000001" + "00200000")
    }

    func testNonHiDPIEncodingIsEightBytes() {
        let resolution = ScaledResolution(logicalWidth: 2560, logicalHeight: 1440, backingScale: 1)
        let encoded = ScaleResolutionCodec.encode(resolution)
        XCTAssertEqual(encoded.count, 8)
        XCTAssertEqual(encoded.map { String(format: "%02x", $0) }.joined(), "00000a00" + "000005a0")
    }

    func testEncodingStoresBackingPixelsNotLogical() {
        let encoded = ScaleResolutionCodec.encode(
            ScaledResolution(logicalWidth: 1920, logicalHeight: 1080, backingScale: 2))
        let decoded = ScaleResolutionCodec.decode(encoded)
        guard case .entry(let entry) = decoded else { return XCTFail("expected a parsed entry") }
        XCTAssertEqual(entry.storedWidth, 3840, "the file stores the backing store, not the logical size")
        XCTAssertEqual(entry.storedHeight, 2160)
        XCTAssertEqual(entry.logicalWidth, 1920)
        XCTAssertEqual(entry.logicalHeight, 1080)
        XCTAssertTrue(entry.isHiDPI)
    }

    // MARK: - Decoding each observed form

    func testDecodesEightByteForm() {
        let data = Data([0x00, 0x00, 0x19, 0x00, 0x00, 0x00, 0x0E, 0x10]) // 6400 × 3600, seen in Apple's files
        guard case .entry(let entry) = ScaleResolutionCodec.decode(data) else {
            return XCTFail("expected a parsed entry")
        }
        XCTAssertEqual(entry.storedWidth, 6400)
        XCTAssertEqual(entry.storedHeight, 3600)
        XCTAssertNil(entry.marker)
        XCTAssertNil(entry.flags)
        XCTAssertFalse(entry.isHiDPI)
    }

    func testDecodesNineByteFormWithStrayTrailingByte() {
        // 3840 × 2400 plus one 0x00, from SYS:DisplayVendorID-610/DisplayProductID-a040. Unexplained,
        // and therefore something the codec must preserve rather than normalise away.
        let data = Data([0x00, 0x00, 0x0F, 0x00, 0x00, 0x00, 0x09, 0x60, 0x00])
        guard case .entry(let entry) = ScaleResolutionCodec.decode(data) else {
            return XCTFail("expected a parsed entry")
        }
        XCTAssertEqual(entry.storedWidth, 3840)
        XCTAssertEqual(entry.trailing, Data([0x00]))
        XCTAssertEqual(entry.encoded(), data, "the stray byte must survive a round trip")
    }

    func testDecodesTwelveByteAppleForm() {
        // 1680 × 1050 with marker 0x1 and no flags word — Apple's most common form (1704 entries).
        let data = Data([0x00, 0x00, 0x06, 0x90, 0x00, 0x00, 0x04, 0x1A, 0x00, 0x00, 0x00, 0x01])
        guard case .entry(let entry) = ScaleResolutionCodec.decode(data) else {
            return XCTFail("expected a parsed entry")
        }
        XCTAssertEqual(entry.marker, 0x1)
        XCTAssertNil(entry.flags)
        XCTAssertFalse(entry.isHiDPI, "no flags word means no HiDPI bit")
        XCTAssertEqual(entry.encoded(), data)
    }

    func testDecodesSixteenByteFormWithMarkerNine() {
        // 1920 × 1080 backing, marker 0x9, HiDPI flag — 139 such entries in the surveyed set.
        let data = Data([0x00, 0x00, 0x07, 0x80, 0x00, 0x00, 0x04, 0x38,
                         0x00, 0x00, 0x00, 0x09, 0x00, 0x20, 0x00, 0x00])
        guard case .entry(let entry) = ScaleResolutionCodec.decode(data) else {
            return XCTFail("expected a parsed entry")
        }
        XCTAssertEqual(entry.marker, 0x9)
        XCTAssertEqual(entry.flags, 0x0020_0000)
        XCTAssertTrue(entry.isHiDPI)
        XCTAssertEqual(entry.encoded(), data)
    }

    func testDecodesUnknownExtraFlagWithoutLosingIt() {
        // flags 0x00a00000 — the HiDPI bit plus 0x00800000, whose meaning is unknown.
        let data = Data([0x00, 0x00, 0x0F, 0x00, 0x00, 0x00, 0x09, 0x60,
                         0x00, 0x00, 0x00, 0x09, 0x00, 0xA0, 0x00, 0x00])
        guard case .entry(let entry) = ScaleResolutionCodec.decode(data) else {
            return XCTFail("expected a parsed entry")
        }
        XCTAssertTrue(entry.isHiDPI)
        XCTAssertEqual(entry.flags! & ScaleResolutionCodec.unknownExtraFlag,
                       ScaleResolutionCodec.unknownExtraFlag)
        XCTAssertEqual(entry.encoded(), data)
    }

    func testRejectsShortAndAbsurdEntries() {
        XCTAssertEqual(ScaleResolutionCodec.decode(Data([1, 2, 3])), .unrecognized(Data([1, 2, 3])))
        let huge = Data(repeating: 0, count: 4096)
        XCTAssertEqual(ScaleResolutionCodec.decode(huge), .unrecognized(huge))
    }

    // MARK: - Round trip over real files

    /// Every entry in every bundled real override must survive decode → encode unchanged.
    ///
    /// This is the test that would catch a format misunderstanding: if the codec dropped the marker
    /// word, normalised the ninth byte, or mishandled `0x00a00000`, the bytes would differ here.
    func testAllFixtureEntriesRoundTripByteForByte() throws {
        var totalEntries = 0
        for url in try Fixtures.overrideFileURLs() {
            let data = try Data(contentsOf: url)
            guard let plist = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
                  let entries = plist["scale-resolutions"] as? [Data]
            else { continue }

            for entry in entries {
                totalEntries += 1
                switch ScaleResolutionCodec.decode(entry) {
                case .entry(let decoded):
                    XCTAssertEqual(
                        decoded.encoded(), entry,
                        "entry in \(url.lastPathComponent) did not round trip: \(entry.map { String(format: "%02x", $0) }.joined())")
                case .unrecognized(let blob):
                    XCTAssertEqual(blob, entry)
                }
            }
        }
        XCTAssertGreaterThan(totalEntries, 50, "fixtures should contain a meaningful number of entries")
    }

    /// The third-party override is the only sample of a *generated* HiDPI override, so it is the one
    /// that tells us what the app must produce.
    func testThirdPartyFixtureContainsTheExpectedHiDPIShape() throws {
        let url = try Fixtures.overrideURL(named: "thirdparty-hidpi-5a63-3f.plist")
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: try Data(contentsOf: url), options: [], format: nil) as? [String: Any])

        // Vendor and product are decimal in the plist; the path that locates this file uses hex.
        XCTAssertEqual(plist["DisplayVendorID"] as? Int, 23139)
        XCTAssertEqual(plist["DisplayProductID"] as? Int, 63)
        XCTAssertEqual(OverridePaths.relativePath(vendorID: 23139, productID: 63),
                       "DisplayVendorID-5a63/DisplayProductID-3f")

        let entries = try XCTUnwrap(plist["scale-resolutions"] as? [Data])
        let hiDPI = entries.compactMap { entry -> ScaleResolutionEntry? in
            guard case .entry(let decoded) = ScaleResolutionCodec.decode(entry), decoded.isHiDPI
            else { return nil }
            return decoded
        }
        XCTAssertFalse(hiDPI.isEmpty, "the third-party override should contain HiDPI entries")

        // Every HiDPI entry stores an even backing size, consistent with "logical × 2".
        for entry in hiDPI {
            XCTAssertEqual(entry.storedWidth % 2, 0)
            XCTAssertEqual(entry.storedHeight % 2, 0)
            XCTAssertEqual(entry.flags! & ScaleResolutionCodec.hiDPIFlag, ScaleResolutionCodec.hiDPIFlag)
        }

        // 4096 × 2304 backing = 2048 × 1152 logical, one of the plan's 1440p presets.
        XCTAssertTrue(
            hiDPI.contains { $0.logicalWidth == 2048 && $0.logicalHeight == 1152 },
            "expected the 2048 × 1152 HiDPI mode this override was installed for")
    }
}
