import XCTest
@testable import HiDisplayKit

/// Generator, validator and path rules.
final class OverrideGeneratorTests: XCTestCase {

    private func makeDocument(
        vendorID: UInt32 = 0x10AC,
        productID: UInt32 = 0xD0A1,
        resolutions: [ScaledResolution] = [
            ScaledResolution(logicalWidth: 1920, logicalHeight: 1080),
            ScaledResolution(logicalWidth: 2048, logicalHeight: 1152),
        ]
    ) -> DisplayOverrideDocument {
        DisplayOverrideDocument(
            vendorID: vendorID, productID: productID,
            displayName: "TEST U2723QE", scaleResolutions: resolutions)
    }

    func testGeneratesXMLPlistWithDecimalIDs() throws {
        let generated = OverrideGenerator.generate(makeDocument())
        let text = try XCTUnwrap(String(data: generated.data, encoding: .utf8))

        XCTAssertTrue(text.contains("<?xml"), "XML so it can be read and repaired from Recovery")
        // Decimal in the plist even though the path is hex. 0x10AC = 4268, 0xD0A1 = 53409.
        XCTAssertTrue(text.contains("<integer>4268</integer>"))
        XCTAssertTrue(text.contains("<integer>53409</integer>"))
        XCTAssertEqual(generated.relativePath, "DisplayVendorID-10ac/DisplayProductID-d0a1")
    }

    func testOutputIsDeterministicAcrossRunsAndInputOrder() {
        let ascending = OverrideGenerator.generate(makeDocument(resolutions: [
            ScaledResolution(logicalWidth: 1920, logicalHeight: 1080),
            ScaledResolution(logicalWidth: 2048, logicalHeight: 1152),
        ]))
        let descending = OverrideGenerator.generate(makeDocument(resolutions: [
            ScaledResolution(logicalWidth: 2048, logicalHeight: 1152),
            ScaledResolution(logicalWidth: 1920, logicalHeight: 1080),
        ]))
        XCTAssertEqual(ascending.data, descending.data,
                       "byte-identical output regardless of selection order, so a regenerated file is not a diff")
        XCTAssertEqual(OverrideGenerator.generate(makeDocument()).data, ascending.data)
    }

    func testGeneratedEntriesDecodeBackToTheSameResolutions() throws {
        let resolutions = [
            ScaledResolution(logicalWidth: 1920, logicalHeight: 1080, backingScale: 2),
            ScaledResolution(logicalWidth: 2560, logicalHeight: 1440, backingScale: 1),
        ]
        let generated = OverrideGenerator.generate(makeDocument(resolutions: resolutions))
        let (parsed, unknownKeys) = try OverrideGenerator.parseExisting(generated.data)

        XCTAssertTrue(unknownKeys.isEmpty)
        // The requested modes come back, plus the 8-byte declaration of the HiDPI mode's backing store
        // — without which macOS ignores the HiDPI entry entirely. See `EmittedEntryTests`.
        XCTAssertEqual(
            Set(parsed.scaleResolutions.map(\.id)),
            Set(resolutions.map(\.id)).union(["3840x2160@1x"]))
        XCTAssertEqual(parsed.displayName, "TEST U2723QE")
        XCTAssertEqual(parsed.vendorID, 0x10AC)
    }

    func testEDIDIsOmittedUnlessExplicitlyRequested() throws {
        let withoutEDID = OverrideGenerator.generate(makeDocument())
        let text = try XCTUnwrap(String(data: withoutEDID.data, encoding: .utf8))
        XCTAssertFalse(text.contains("IODisplayEDID"),
                       "EDID injection must be opt-in: it is near-useless on Apple Silicon and raises black-screen risk")
    }

    /// Rewriting a file must not delete modes written in a form this app does not emit.
    func testUnrecognisedEntriesFromARealFileArePreserved() throws {
        let url = try Fixtures.overrideURL(named: "apple-610-9cc3.plist")
        let original = try Data(contentsOf: url)
        let (parsed, _) = try OverrideGenerator.parseExisting(original)

        // Every entry in this Apple file is the 12-byte form, which the app never emits, so all of them
        // must land in `preservedEntries` rather than being re-encoded.
        XCTAssertTrue(parsed.scaleResolutions.isEmpty)
        XCTAssertEqual(parsed.preservedEntries.count, 7)

        var document = parsed
        document.scaleResolutions = [ScaledResolution(logicalWidth: 1920, logicalHeight: 1080)]
        let regenerated = OverrideGenerator.generate(document)
        let (reparsed, _) = try OverrideGenerator.parseExisting(regenerated.data)

        XCTAssertEqual(reparsed.preservedEntries, parsed.preservedEntries,
                       "Apple's original entries must survive untouched")
        // The new HiDPI mode plus its 8-byte backing declaration.
        XCTAssertEqual(reparsed.scaleResolutions.count, 2)
        XCTAssertTrue(reparsed.scaleResolutions.contains { $0.id == "1920x1080@2x" })
        XCTAssertTrue(reparsed.scaleResolutions.contains { $0.id == "3840x2160@1x" })
    }

    /// Unknown top-level keys used to be merely *reported* as about-to-be-dropped; now they are
    /// captured and survive regeneration, so a merge genuinely preserves the whole file.
    func testUnknownTopLevelKeysAreCapturedAndSurviveRegeneration() throws {
        let url = try Fixtures.overrideURL(named: "apple-610-9cc3.plist")
        let original = try Data(contentsOf: url)
        let (parsed, unknownKeys) = try OverrideGenerator.parseExisting(original)

        // This file carries gamma and colour-point keys the app knows nothing about. They land in
        // the carried-through set, and `unknownKeys` — the genuinely droppable remainder — is empty.
        XCTAssertNotNil(parsed.preservedTopLevelEntries["DisplayGammaTable"])
        XCTAssertNotNil(parsed.preservedTopLevelEntries["DisplayWhitePointX"])
        XCTAssertTrue(unknownKeys.isEmpty, "every key in this fixture is preservable")

        // And they must survive a regenerate byte-for-byte in value.
        let originalPlist = try PropertyListSerialization.propertyList(
            from: original, options: [], format: nil) as? [String: Any]
        let regeneratedPlist = try PropertyListSerialization.propertyList(
            from: OverrideGenerator.generate(parsed).data, options: [], format: nil) as? [String: Any]
        for key in ["DisplayGammaTable", "DisplayWhitePointX"] {
            XCTAssertNotNil(originalPlist?[key], "fixture no longer carries \(key)")
            XCTAssertEqual(regeneratedPlist?[key] as? NSObject, originalPlist?[key] as? NSObject,
                           "\(key) changed across a regenerate")
        }
    }

    func testRejectsNonDictionaryPlist() {
        let arrayPlist = try! PropertyListSerialization.data(
            fromPropertyList: [1, 2, 3], format: .xml, options: 0)
        XCTAssertThrowsError(try OverrideGenerator.parseExisting(arrayPlist))
    }
}

final class OverrideValidatorTests: XCTestCase {

    private func report(
        _ resolutions: [ScaledResolution],
        native: (width: Int, height: Int)? = (3840, 2160),
        vendorID: UInt32 = 0x10AC,
        productID: UInt32 = 0xD0A1,
        edid: Data? = nil
    ) -> ValidationReport {
        OverrideValidator.validate(
            DisplayOverrideDocument(
                vendorID: vendorID, productID: productID,
                scaleResolutions: resolutions, patchedEDID: edid),
            nativePixelSize: native)
    }

    func testAcceptsAReasonableSet() {
        let result = report([
            ScaledResolution(logicalWidth: 1920, logicalHeight: 1080),
            ScaledResolution(logicalWidth: 2560, logicalHeight: 1440),
        ])
        XCTAssertTrue(result.isInstallable)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testRejectsZeroVendorOrProduct() {
        XCTAssertFalse(report([ScaledResolution(logicalWidth: 1920, logicalHeight: 1080)], vendorID: 0).isInstallable)
        XCTAssertFalse(report([ScaledResolution(logicalWidth: 1920, logicalHeight: 1080)], productID: 0).isInstallable)
    }

    func testRejectsEmptySelection() {
        XCTAssertFalse(report([]).isInstallable)
    }

    func testRejectsDuplicates() {
        let duplicate = ScaledResolution(logicalWidth: 1920, logicalHeight: 1080)
        let result = report([duplicate, duplicate])
        XCTAssertFalse(result.isInstallable)
        XCTAssertTrue(result.errors.contains { $0.message.contains("more than once") })
    }

    func testRejectsResolutionLargerThanThePanel() {
        let result = report([ScaledResolution(logicalWidth: 5120, logicalHeight: 2880)], native: (2560, 1440))
        XCTAssertFalse(result.isInstallable)
        XCTAssertTrue(result.errors.contains { $0.message.contains("larger than the panel") })
    }

    func testRejectsAbsurdlySmallResolution() {
        XCTAssertFalse(report([ScaledResolution(logicalWidth: 320, logicalHeight: 200)]).isInstallable)
    }

    func testRejectsBackingStoreBeyondTheHardLimit() {
        let result = report([ScaledResolution(logicalWidth: 10000, logicalHeight: 6000)], native: (20000, 12000))
        XCTAssertFalse(result.isInstallable)
        XCTAssertTrue(result.errors.contains { $0.message.contains("px limit") })
    }

    func testRejectsUnsupportedBackingScale() {
        let result = report([ScaledResolution(logicalWidth: 1920, logicalHeight: 1080, backingScale: 3)])
        XCTAssertFalse(result.isInstallable)
    }

    func testRejectsTooManyResolutions() {
        // Bound to the constant, not a magic number: the cap moved from 32 to 128 once hardware showed
        // an override with 89 modes working, and a hard-coded 40 silently stopped testing anything.
        let many = (1...(OverrideValidator.maximumResolutionCount + 1)).map {
            ScaledResolution(logicalWidth: 640 + $0 * 2, logicalHeight: 480 + $0)
        }
        XCTAssertFalse(report(many, native: (8000, 8000)).isInstallable)
    }

    func testWarnsButAllowsMismatchedAspectRatio() {
        // 4:3 on a 16:9 panel is unusual but legal, and the user may want it. Warn, do not block.
        let result = report([ScaledResolution(logicalWidth: 1600, logicalHeight: 1200)], native: (3840, 2160))
        XCTAssertTrue(result.isInstallable)
        XCTAssertTrue(result.warnings.contains { $0.message.contains("aspect ratio") })
    }

    func testWarnsAboutOddDimensions() {
        let result = report([ScaledResolution(logicalWidth: 1921, logicalHeight: 1081)])
        XCTAssertTrue(result.warnings.contains { $0.message.contains("odd dimension") })
    }

    func testRejectsAMalformedPatchedEDID() {
        let result = report([ScaledResolution(logicalWidth: 1920, logicalHeight: 1080)],
                            edid: Data(repeating: 0xAB, count: 128))
        XCTAssertFalse(result.isInstallable, "an EDID that fails header/checksum must never be written")
    }

    func testWarnsWheneverEDIDInjectionIsUsedAtAll() {
        let result = report([ScaledResolution(logicalWidth: 1920, logicalHeight: 1080)],
                            edid: Fixtures.makeEDID())
        XCTAssertTrue(result.isInstallable, "a valid EDID is allowed")
        XCTAssertTrue(result.warnings.contains { $0.message.contains("EDID injection") })
    }
}

final class OverridePathTests: XCTestCase {

    func testDirectoryAndFileNamesAreLowercaseHexWithoutPadding() {
        // Matches macOS's own layout: /System/.../Overrides/DisplayVendorID-610/DisplayProductID-1f4
        XCTAssertEqual(OverridePaths.vendorDirectoryName(vendorID: 0x610), "DisplayVendorID-610")
        XCTAssertEqual(OverridePaths.productFileName(productID: 0x1F4), "DisplayProductID-1f4")
        XCTAssertEqual(OverridePaths.relativePath(vendorID: 0x10AC, productID: 0xD0A1),
                       "DisplayVendorID-10ac/DisplayProductID-d0a1")
    }

    func testFixtureFilenamesMatchGeneratedPaths() {
        // The fixture came from DisplayVendorID-5a63/DisplayProductID-3f on a real system.
        XCTAssertEqual(OverridePaths.relativePath(vendorID: 23139, productID: 63),
                       "DisplayVendorID-5a63/DisplayProductID-3f")
    }

    func testResolvesInsideTheRoot() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolved = try OverridePaths.resolve(
            relativePath: "DisplayVendorID-10ac/DisplayProductID-d0a1", under: root)
        XCTAssertTrue(resolved.path.hasSuffix("DisplayVendorID-10ac/DisplayProductID-d0a1"))
        XCTAssertTrue(resolved.path.hasPrefix(root.resolvingSymlinksInPath().path))
    }

    func testRejectsTraversal() {
        let root = URL(fileURLWithPath: "/tmp/hidisplay-test-root")
        XCTAssertThrowsError(try OverridePaths.resolve(relativePath: "../../etc/passwd", under: root))
        XCTAssertThrowsError(try OverridePaths.resolve(relativePath: "a/../../b", under: root))
    }

    func testRejectsAbsolutePath() {
        let root = URL(fileURLWithPath: "/tmp/hidisplay-test-root")
        XCTAssertThrowsError(try OverridePaths.resolve(relativePath: "/etc/passwd", under: root))
    }

    func testRejectsEmptyPath() {
        let root = URL(fileURLWithPath: "/tmp/hidisplay-test-root")
        XCTAssertThrowsError(try OverridePaths.resolve(relativePath: "", under: root))
    }

    /// A symlinked vendor directory is the realistic route to a root-privileged write landing outside
    /// the allowlisted root, so it must be refused rather than followed.
    func testRefusesToFollowASymlink() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("root")
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("DisplayVendorID-10ac"), withDestinationURL: outside)

        XCTAssertThrowsError(
            try OverridePaths.resolve(relativePath: "DisplayVendorID-10ac/DisplayProductID-d0a1", under: root)
        ) { error in
            guard case .symlink = error as? OverridePathError else {
                return XCTFail("expected a symlink rejection, got \(error)")
            }
        }
    }

    func testTheSystemRootIsNeverAValidTarget() {
        // Belt and braces: even if a root were misconfigured to the SIP-protected path, it is rejected.
        XCTAssertThrowsError(
            try OverridePaths.resolve(
                relativePath: "DisplayVendorID-10ac/DisplayProductID-d0a1",
                under: URL(fileURLWithPath: OverridePaths.forbiddenOverrideRoot)))
    }
}

/// Every HiDPI entry needs its backing size repeated as a plain 8-byte entry.
///
/// Measured twice, the second time the hard way. A 62-step ladder written as 16-byte HiDPI entries
/// *with* 8-byte companions produced 61 modes on an M3 with a 2560 × 1600 panel. The same ladder with
/// the companions removed produced **zero**, and the removal had been justified by a probe that never
/// tested a 16-byte entry standalone — all three of its 16-byte entries carried companions.
///
/// So this file asserts the pairing, and the assertions exist because deleting it silently broke a
/// working install rather than failing a test.
final class EmittedEntryTests: XCTestCase {

    private func entries(for resolutions: [ScaledResolution]) throws -> (oneX: Set<String>, hiDPI: [(Int, Int)]) {
        let generated = OverrideGenerator.generate(
            DisplayOverrideDocument(vendorID: 0x10AC, productID: 0xD0A1, scaleResolutions: resolutions))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: generated.data, options: [], format: nil) as? [String: Any])
        let blobs = try XCTUnwrap(plist["scale-resolutions"] as? [Data])

        var oneX = Set<String>()
        var hiDPI: [(Int, Int)] = []
        for blob in blobs {
            guard case .entry(let entry) = ScaleResolutionCodec.decode(blob) else { continue }
            if entry.isHiDPI {
                hiDPI.append((entry.storedWidth, entry.storedHeight))
            } else {
                oneX.insert("\(entry.storedWidth)x\(entry.storedHeight)")
            }
        }
        return (oneX, hiDPI)
    }

    func testEveryHiDPIEntryGetsAMatching8ByteBackingEntry() throws {
        let result = try entries(for: [
            ScaledResolution(logicalWidth: 1680, logicalHeight: 1050),
            ScaledResolution(logicalWidth: 1920, logicalHeight: 1200),
            ScaledResolution(logicalWidth: 2048, logicalHeight: 1280),
            ScaledResolution(logicalWidth: 2304, logicalHeight: 1440),
        ])

        XCTAssertEqual(result.hiDPI.count, 4)
        for (width, height) in result.hiDPI {
            XCTAssertTrue(
                result.oneX.contains("\(width)x\(height)"),
                "HiDPI backing \(width)x\(height) has no 8-byte companion — macOS ignores the mode")
        }
    }

    func testBackingSizesAreTheDoubledLogicalSizes() throws {
        let result = try entries(for: [
            ScaledResolution(logicalWidth: 2048, logicalHeight: 1280),
        ])
        XCTAssertEqual(result.hiDPI.first.map { [$0.0, $0.1] }, [4096, 2560])
        XCTAssertTrue(result.oneX.contains("4096x2560"))
    }

    func testNoDuplicateBackingWhenTheSameSizeIsRequestedTwice() throws {
        // A requested 1× mode can collide with a HiDPI mode's backing size; it must be emitted once.
        let generated = OverrideGenerator.generate(
            DisplayOverrideDocument(
                vendorID: 0x10AC, productID: 0xD0A1,
                scaleResolutions: [
                    ScaledResolution(logicalWidth: 2048, logicalHeight: 1280, backingScale: 2),
                    ScaledResolution(logicalWidth: 4096, logicalHeight: 2560, backingScale: 1),
                ]))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: generated.data, options: [], format: nil) as? [String: Any])
        let blobs = try XCTUnwrap(plist["scale-resolutions"] as? [Data])
        XCTAssertEqual(blobs.count, Set(blobs).count, "no duplicate entries")
    }

    func testPlain1xResolutionsGetNoExtraEntry() throws {
        let result = try entries(for: [
            ScaledResolution(logicalWidth: 2560, logicalHeight: 1600, backingScale: 1),
        ])
        XCTAssertTrue(result.hiDPI.isEmpty)
        XCTAssertEqual(result.oneX, ["2560x1600"], "a 1× mode is already its own backing")
    }

    /// The install that proved the pairing is required: a full ladder must emit two entries per step.
    func testTheFullLadderGeneratesAPairPerStep() throws {
        let ladder = ResolutionPresets.scalingSteps(nativePixels: (width: 2560, height: 1600))
        let generated = OverrideGenerator.generate(
            DisplayOverrideDocument(vendorID: 0x10AC, productID: 0xD0A1, scaleResolutions: ladder))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: generated.data, options: [], format: nil) as? [String: Any])
        let blobs = try XCTUnwrap(plist["scale-resolutions"] as? [Data])
        XCTAssertEqual(blobs.count, ladder.count * 2)
    }

    func testOutputStaysDeterministic() {
        let resolutions = [
            ScaledResolution(logicalWidth: 2048, logicalHeight: 1280),
            ScaledResolution(logicalWidth: 1680, logicalHeight: 1050),
        ]
        let a = OverrideGenerator.generate(
            DisplayOverrideDocument(vendorID: 0x10AC, productID: 0xD0A1, scaleResolutions: resolutions))
        let b = OverrideGenerator.generate(
            DisplayOverrideDocument(
                vendorID: 0x10AC, productID: 0xD0A1, scaleResolutions: resolutions.reversed()))
        XCTAssertEqual(a.data, b.data)
    }
}

/// The full ladder — every aspect-correct step.
///
/// The 32-resolution cap this replaced was a guess, not a measurement. Real hardware accepted an
/// override declaring 89 HiDPI modes, so the cap was blocking the exact case the feature exists for.
/// Later confirmed directly: a 62-entry override generated by this app installed on an M3 and 61 of
/// its 62 modes appeared.
final class FullLadderTests: XCTestCase {

    private let panel = (width: 2560, height: 1600)

    func testTheWholeLadderValidates() {
        let ladder = ResolutionPresets.scalingSteps(nativePixels: panel)
        XCTAssertGreaterThan(ladder.count, 32, "the ladder must exceed the old cap, or this proves nothing")
        XCTAssertLessThanOrEqual(ladder.count, OverrideValidator.maximumResolutionCount)

        let report = OverrideValidator.validate(
            DisplayOverrideDocument(vendorID: 0x10AC, productID: 0xD0A1, scaleResolutions: ladder),
            nativePixelSize: panel)
        XCTAssertTrue(report.isInstallable, "errors: \(report.errors.prefix(3).map(\.message))")
    }

    /// The budget is what keeps the slider usable and the ladder selectable in one go.
    func testTheLadderIsCappedAtTheStepBudget() {
        // A 6K-class panel: the widest range this can produce, and where an unbounded ladder used to
        // run past 300 entries.
        for panel in [panel, (width: 5120, height: 2880), (width: 3840, height: 2160)] {
            let ladder = ResolutionPresets.scalingSteps(nativePixels: panel)
            XCTAssertLessThanOrEqual(ladder.count, ResolutionPresets.maximumScalingSteps,
                                     "\(panel.width)×\(panel.height) produced \(ladder.count) steps")
            XCTAssertLessThanOrEqual(ladder.count, OverrideValidator.maximumResolutionCount,
                                     "the full ladder must be selectable in one go")
        }
    }

    func testTheLadderSpansThirtyPercentToJustUnderNativeWidth() throws {
        let ladder = ResolutionPresets.scalingSteps(nativePixels: panel)
        let first = try XCTUnwrap(ladder.first)
        let last = try XCTUnwrap(ladder.last)

        XCTAssertGreaterThanOrEqual(
            Double(first.logicalWidth) / Double(panel.width), ResolutionPresets.smallestScaleFraction,
            "\(first.label) is below the floor — those sizes are unusably large and nobody picks them")
        XCTAssertLessThan(last.logicalWidth, panel.width,
                          "a HiDPI mode at the panel's own size is rejected, so the ladder stops below it")
        XCTAssertGreaterThan(
            Double(last.logicalWidth) / Double(panel.width), 0.95,
            "\(last.label) — the top of the slider should still be the most desktop space available")
    }

    /// Thinning must cost granularity, never a stop someone is actually aiming for.
    func testThinningKeepsTheNativeHiDPILandmarks() {
        let widths = Set(ResolutionPresets.scalingSteps(nativePixels: panel).map(\.logicalWidth))

        XCTAssertTrue(widths.contains(panel.width / 2),
                      "the pixel-perfect step (\(panel.width / 2)) is the whole point of HiDPI")
        XCTAssertFalse(widths.contains(panel.width),
                       "native width rendered HiDPI is rejected by the validator and must not be offered")
        XCTAssertTrue(widths.contains(2048), "dropping the native step must not shift the rest of the grid")
        for fraction in ResolutionPresets.landmarkFractions {
            let width = Int((Double(panel.width) * fraction).rounded())
            guard width % 16 == 0 else { continue } // 16:10 → 16 px per step
            XCTAssertTrue(widths.contains(width), "landmark \(width) was thinned away")
        }
    }

    /// A panel small enough that the whole range fits is not thinned at all.
    func testASmallPanelKeepsEveryStep() {
        let small = (width: 1920, height: 1080)
        let ladder = ResolutionPresets.scalingSteps(nativePixels: small)
        let widths = ladder.map(\.logicalWidth)
        // 16:9 reduces to 16×9, forced even → 32×18. Contiguous multiples, no gaps.
        for (previous, next) in zip(widths, widths.dropFirst()) {
            XCTAssertEqual(next - previous, 32, "an unthinned ladder must not skip steps")
        }
    }

    /// Every step becomes a HiDPI entry plus its 8-byte backing companion. See `EmittedEntryTests`.
    func testEveryLadderStepBecomesAHiDPIEntryAndItsBacking() throws {
        let ladder = ResolutionPresets.scalingSteps(nativePixels: panel)
        let generated = OverrideGenerator.generate(
            DisplayOverrideDocument(vendorID: 0x10AC, productID: 0xD0A1, scaleResolutions: ladder),
            nativePixelSize: panel)

        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: generated.data, options: [], format: nil) as? [String: Any])
        let blobs = try XCTUnwrap(plist["scale-resolutions"] as? [Data])

        var oneX = Set<String>()
        var hiDPI: [(Int, Int)] = []
        for blob in blobs {
            guard case .entry(let entry) = ScaleResolutionCodec.decode(blob) else { continue }
            if entry.isHiDPI { hiDPI.append((entry.storedWidth, entry.storedHeight)) }
            else { oneX.insert("\(entry.storedWidth)x\(entry.storedHeight)") }
        }

        XCTAssertEqual(hiDPI.count, ladder.count)
        for (step, entry) in zip(ladder, hiDPI) {
            XCTAssertEqual(entry.0, step.logicalWidth * 2)
            XCTAssertEqual(entry.1, step.logicalHeight * 2)
            XCTAssertTrue(oneX.contains("\(entry.0)x\(entry.1)"),
                          "backing \(entry.0)x\(entry.1) undeclared — macOS would ignore this mode")
        }
    }

    /// The generated file must stay well inside the installer's size limit.
    func testAFullLadderFileStaysSmall() {
        let ladder = ResolutionPresets.scalingSteps(nativePixels: panel)
        let generated = OverrideGenerator.generate(
            DisplayOverrideDocument(vendorID: 0x10AC, productID: 0xD0A1, scaleResolutions: ladder),
            nativePixelSize: panel)
        XCTAssertLessThan(generated.data.count, OverrideInstaller.maximumOverrideBytes / 10,
                          "a full ladder is \(generated.data.count) bytes")
    }

    func testTheCapStillRejectsAbsurdCounts() {
        let tooMany = (1...(OverrideValidator.maximumResolutionCount + 1)).map {
            ScaledResolution(logicalWidth: 640 + $0 * 16, logicalHeight: 400 + $0 * 10)
        }
        let report = OverrideValidator.validate(
            DisplayOverrideDocument(vendorID: 0x10AC, productID: 0xD0A1, scaleResolutions: tooMany),
            nativePixelSize: (40000, 25000))
        XCTAssertFalse(report.isInstallable)
    }
}

/// The path allowlist guarding the one privileged command.
///
/// `PrivilegedInstaller` runs a shell string as root, so the rule "never build a privileged command
/// from user input" has to hold literally. These pin the properties the generated paths must have for
/// that rule to be true — if a path could ever contain a quote, a space or `..`, the escaping question
/// becomes live and the guarantee is gone.
final class PrivilegedPathSafetyTests: XCTestCase {

    private let shellUnsafe = CharacterSet(charactersIn: " '\"`$;&|<>()\n\t\\*?[]{}!#~")

    func testGeneratedOverridePathsContainNoShellMetacharacters() {
        // Sweep the whole 16-bit ID space at a stride, plus the values seen on real hardware.
        var ids: [UInt32] = [0x0610, 0x10AC, 0x4A8B, 0x5A63, 0xD0A1, 0x2560, 0x0000, 0xFFFF]
        ids += stride(from: UInt32(0), through: 0xFFFF, by: 977)

        for vendor in ids {
            for product in ids {
                let path = OverridePaths.relativePath(vendorID: vendor, productID: product)
                XCTAssertNil(
                    path.rangeOfCharacter(from: shellUnsafe),
                    "path '\(path)' contains a character that would need shell escaping")
                XCTAssertFalse(path.contains(".."), "path '\(path)' contains a traversal sequence")
            }
        }
    }

    func testFullDestinationStaysInsideTheOverrideRoot() throws {
        let root = URL(fileURLWithPath: OverridePaths.systemOverrideRoot)
        for (vendor, product) in [(UInt32(0x4A8B), UInt32(0x2560)), (0x10AC, 0xD0A1)] {
            let relative = OverridePaths.relativePath(vendorID: vendor, productID: product)
            // `resolve` throws unless the result is provably inside the root.
            let resolved = try OverridePaths.resolve(relativePath: relative, under: root)
            XCTAssertTrue(resolved.path.hasPrefix(OverridePaths.systemOverrideRoot + "/"))
            XCTAssertNil(resolved.path.rangeOfCharacter(from: shellUnsafe))
        }
    }

    func testTheSystemRootIsStillRejectedOutright() {
        XCTAssertThrowsError(try OverridePaths.resolve(
            relativePath: OverridePaths.relativePath(vendorID: 0x610, productID: 0xa059),
            under: URL(fileURLWithPath: OverridePaths.forbiddenOverrideRoot)))
    }
}

/// The shell string run as root, exercised for real — with bash, in a temporary directory.
///
/// The property that matters: the script itself verifies the staged file's hash after copying it,
/// so swapping the staged file between the app's checks and the privileged copy installs nothing.
final class PrivilegedInstallScriptTests: XCTestCase {

    private var base: URL!

    override func setUpWithError() throws {
        // /tmp rather than NSTemporaryDirectory(): every character of these paths ends up inside a
        // shell command, and the per-user temp path is not guaranteed to satisfy the allowlist.
        base = URL(fileURLWithPath: "/tmp/hidisplay-script-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func makeScript(payload: Data, stagedAs staged: Data? = nil) throws
        -> (script: String, destination: URL)
    {
        let staging = base.appendingPathComponent("staging")
        try (staged ?? payload).write(to: staging)
        let vendor = base.appendingPathComponent("root/DisplayVendorID-10ac")
        let destination = vendor.appendingPathComponent("DisplayProductID-d0a1")
        let script = try PrivilegedInstallScript.install(
            staging: staging.path, vendorDirectory: vendor.path,
            destination: destination.path, sha256: SHA256Hash.hex(of: payload))
        return (script, destination)
    }

    @discardableResult
    private func runBash(_ script: String) throws -> Int32 {
        let bash = Process()
        bash.executableURL = URL(fileURLWithPath: "/bin/bash")
        bash.arguments = ["-c", script]
        bash.standardError = FileHandle.nullDevice
        try bash.run()
        bash.waitUntilExit()
        return bash.terminationStatus
    }

    func testRefusesUnsafePathsAndMalformedDigests() {
        let goodHash = String(repeating: "ab", count: 32)
        for bad in ["/tmp/a b", "/tmp/a'b", "/tmp/a$(b)", "/tmp/../etc", ""] {
            XCTAssertThrowsError(try PrivilegedInstallScript.install(
                staging: bad, vendorDirectory: "/tmp/v", destination: "/tmp/v/d", sha256: goodHash),
                "accepted unsafe path '\(bad)'")
        }
        for badHash in ["abc", String(repeating: "zz", count: 32), goodHash + "'; rm x;'"] {
            XCTAssertThrowsError(try PrivilegedInstallScript.install(
                staging: "/tmp/s", vendorDirectory: "/tmp/v", destination: "/tmp/v/d", sha256: badHash),
                "accepted malformed digest '\(badHash)'")
        }
    }

    func testScriptVerifiesBeforeMovingIntoPlace() throws {
        let (script, _) = try makeScript(payload: Data("payload".utf8))
        XCTAssertFalse(script.contains("\n"), "AppleScript string literals cannot hold a raw newline")
        XCTAssertFalse(script.contains("\""), "a double quote would fight the AppleScript wrapper")
        let verify = try XCTUnwrap(script.range(of: "shasum"))
        let move = try XCTUnwrap(script.range(of: "mv "))
        XCTAssertLessThan(verify.lowerBound, move.lowerBound, "the copy must be verified before the move")
    }

    func testScriptInstallsAMatchingStagedFile() throws {
        let payload = Data("the approved bytes".utf8)
        let (script, destination) = try makeScript(payload: payload)

        XCTAssertEqual(try runBash(script), 0)
        XCTAssertEqual(try Data(contentsOf: destination), payload)
    }

    func testScriptRefusesASwappedStagedFile() throws {
        let (script, destination) = try makeScript(
            payload: Data("the approved bytes".utf8),
            stagedAs: Data("swapped in after the app's own hash check".utf8))

        XCTAssertNotEqual(try runBash(script), 0, "a swapped staged file must fail the install")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path),
                       "nothing may land at the destination")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path + ".hidisplay-partial"),
                       "the partial file must be cleaned up on failure")
    }
}
