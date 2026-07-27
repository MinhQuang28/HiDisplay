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
        // The requested modes come back, plus the 1× declaration of the HiDPI mode's backing store —
        // without which macOS ignores the HiDPI entry entirely. See `BackingDeclarationTests`.
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
        // The new HiDPI mode plus its 1× backing declaration.
        XCTAssertEqual(reparsed.scaleResolutions.count, 2)
        XCTAssertTrue(reparsed.scaleResolutions.contains { $0.id == "1920x1080@2x" })
        XCTAssertTrue(reparsed.scaleResolutions.contains { $0.id == "3840x2160@1x" })
    }

    func testUnknownTopLevelKeysAreReported() throws {
        let url = try Fixtures.overrideURL(named: "apple-610-9cc3.plist")
        let (_, unknownKeys) = try OverrideGenerator.parseExisting(try Data(contentsOf: url))
        // This file carries gamma and colour-point keys the app knows nothing about. Reporting them
        // lets the install preview warn that regenerating would drop them.
        XCTAssertTrue(unknownKeys.contains("DisplayGammaTable"))
        XCTAssertTrue(unknownKeys.contains("DisplayWhitePointX"))
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

/// The rule that only hardware testing revealed.
///
/// A HiDPI entry is ignored by macOS unless the same file also declares its backing resolution as a
/// plain 1× entry. The first version of this generator emitted only the HiDPI half; installed on a real
/// machine and rebooted, three of its four modes never appeared. An override written by another tool on
/// the same machine had 89 HiDPI entries and a matching 1× entry for every single one.
final class BackingDeclarationTests: XCTestCase {

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

    func testEveryHiDPIEntryGetsAMatching1xBackingEntry() throws {
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
                "HiDPI backing \(width)x\(height) has no 1× declaration — macOS would ignore the mode")
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
        // Two HiDPI modes cannot share a backing size, but a requested 1× mode can collide with one.
        let result = try entries(for: [
            ScaledResolution(logicalWidth: 2048, logicalHeight: 1280, backingScale: 2),
            ScaledResolution(logicalWidth: 4096, logicalHeight: 2560, backingScale: 1),
        ])
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
        XCTAssertTrue(result.oneX.contains("4096x2560"))
    }

    func testPlain1xResolutionsGetNoExtraEntry() throws {
        let result = try entries(for: [
            ScaledResolution(logicalWidth: 2560, logicalHeight: 1600, backingScale: 1),
        ])
        XCTAssertTrue(result.hiDPI.isEmpty)
        XCTAssertEqual(result.oneX, ["2560x1600"], "a 1× mode is already its own backing")
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

/// The full ladder — every aspect-correct step, each with its 1× backing declaration.
///
/// The 32-resolution cap this replaced was a guess, not a measurement. Real hardware accepted an
/// override declaring 89 HiDPI modes, so the cap was blocking the exact case the feature exists for.
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

    func testEveryLadderEntryGetsItsBackingDeclaration() throws {
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
        for (width, height) in hiDPI {
            XCTAssertTrue(oneX.contains("\(width)x\(height)"),
                          "backing \(width)x\(height) undeclared — macOS would ignore this mode")
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
