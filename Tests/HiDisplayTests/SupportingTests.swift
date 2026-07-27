import XCTest
@testable import HiDisplayKit

final class DisplayModeTests: XCTestCase {

    func testScaleFactorIsNotHardCodedToTwo() {
        // Kept as a Double so a hypothetical 1.75× or 3× mode classifies correctly instead of silently
        // being treated as 1×.
        XCTAssertEqual(
            DisplayMode(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, refreshRate: 60).scaleFactor,
            2.0, accuracy: 0.0001)
        XCTAssertEqual(
            DisplayMode(width: 1600, height: 900, pixelWidth: 2800, pixelHeight: 1575, refreshRate: 60).scaleFactor,
            1.75, accuracy: 0.0001)
    }

    func testHiDPIClassification() {
        let oneX = DisplayMode(width: 2560, height: 1440, pixelWidth: 2560, pixelHeight: 1440, refreshRate: 60)
        let twoX = DisplayMode(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, refreshRate: 60)
        let oneAndAHalf = DisplayMode(width: 1920, height: 1080, pixelWidth: 2880, pixelHeight: 1620, refreshRate: 60)

        XCTAssertFalse(oneX.isHiDPI)
        XCTAssertTrue(twoX.isHiDPI)
        XCTAssertTrue(oneAndAHalf.isHiDPI, "1.5× counts: the threshold is not equality with 2.0")
    }

    func testZeroLogicalSizeDoesNotDivideByZero() {
        let broken = DisplayMode(width: 0, height: 0, pixelWidth: 3840, pixelHeight: 2160, refreshRate: 60)
        XCTAssertEqual(broken.scaleFactor, 1)
        XCTAssertFalse(broken.isHiDPI)
    }

    func testMismatchedAxesTakeTheSmallerRatio() {
        // A bogus dimension must not inflate the scale factor into a false HiDPI classification.
        let odd = DisplayMode(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 1080, refreshRate: 60)
        XCTAssertEqual(odd.scaleFactor, 1.0, accuracy: 0.0001)
        XCTAssertFalse(odd.isHiDPI)
    }

    func testHasHiDPIModeLooksAtLogicalSize() {
        let modes = [
            DisplayMode(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, refreshRate: 60),
            DisplayMode(width: 2560, height: 1440, pixelWidth: 2560, pixelHeight: 1440, refreshRate: 60),
        ]
        XCTAssertTrue(DisplayModeService.hasHiDPIMode(width: 1920, height: 1080, in: modes))
        XCTAssertFalse(DisplayModeService.hasHiDPIMode(width: 2560, height: 1440, in: modes),
                       "2560×1440 exists but only as a 1× mode")
    }
}

final class EDIDTests: XCTestCase {

    func testParsesASyntheticEDID() throws {
        let edid = try EDID(data: Fixtures.makeEDID())
        XCTAssertEqual(edid.manufacturerCode, "DEL")
        XCTAssertEqual(edid.productID, 0xD0A1)
        XCTAssertEqual(edid.serialNumber, 0x1234_5678)
        XCTAssertEqual(edid.weekOfManufacture, 34)
        XCTAssertEqual(edid.yearOfManufacture, 2022)
        XCTAssertEqual(edid.monitorName, "TEST U2723QE")
        XCTAssertEqual(edid.nativePixelWidth, 3840)
        XCTAssertEqual(edid.nativePixelHeight, 2160)
    }

    func testManufacturerCodeRoundTripsThroughTheNumericVendorID() throws {
        let edid = try EDID(data: Fixtures.makeEDID(manufacturer: "GSM"))
        XCTAssertEqual(edid.manufacturerCode, "GSM")
        XCTAssertEqual(
            AppleSiliconDisplayMetadataBackend.pnpCodeToVendorID("GSM"), edid.vendorID,
            "the letter form and numeric form must agree, or the override directory name would be wrong")
    }

    func testRejectsShortData() {
        XCTAssertThrowsError(try EDID(data: Data(repeating: 0, count: 64))) { error in
            XCTAssertEqual(error as? EDID.ParseError, .tooShort(got: 64))
        }
    }

    func testRejectsBadHeader() {
        var bytes = [UInt8](Fixtures.makeEDID())
        bytes[0] = 0xFF
        XCTAssertThrowsError(try EDID(data: Data(bytes))) { error in
            XCTAssertEqual(error as? EDID.ParseError, .badHeader)
        }
    }

    func testRejectsBadChecksumButCanBeToldToTolerateIt() throws {
        var bytes = [UInt8](Fixtures.makeEDID())
        bytes[127] = bytes[127] &+ 1
        let corrupted = Data(bytes)

        XCTAssertThrowsError(try EDID(data: corrupted))
        // Cheap adapters and KVMs really do return a wrong checksum with usable fields, so
        // identification must still work.
        let tolerant = try EDID(data: corrupted, validateChecksum: false)
        XCTAssertEqual(tolerant.manufacturerCode, "DEL")
    }

    func testFingerprintIsStableAndShort() {
        let data = Fixtures.makeEDID()
        XCTAssertEqual(EDID.fingerprint(of: data), EDID.fingerprint(of: data))
        XCTAssertEqual(EDID.fingerprint(of: data).count, 16)
        XCTAssertNotEqual(
            EDID.fingerprint(of: data),
            EDID.fingerprint(of: Fixtures.makeEDID(serial: 0x9999_9999)),
            "two panels differing only in serial must fingerprint differently")
    }
}

final class MetadataBackendTests: XCTestCase {

    // MARK: - Apple Silicon

    /// Shaped like the `DisplayAttributes` dictionary observed under `DCPAVServiceProxy` via `ioreg`.
    private var appleSiliconFixture: [String: Any] {
        [
            "ProductAttributes": [
                "ManufacturerID": "DEL",
                "LegacyManufacturerID": 4268,
                "ProductID": 53409,
                "SerialNumber": 0,
                "ProductName": "DELL U2723QE",
                "WeekOfManufacture": 34,
                "YearOfManufacture": 2022,
                "NativeFormatHorizontalPixels": 3840,
                "NativeFormatVerticalPixels": 2160,
            ] as [String: Any],
        ]
    }

    func testParsesAppleSiliconDisplayAttributes() throws {
        let record = try XCTUnwrap(AppleSiliconDisplayMetadataBackend.parse(
            displayAttributes: appleSiliconFixture, registryEntryID: 0x4001))
        XCTAssertEqual(record.vendorID, 4268)
        XCTAssertEqual(record.productID, 53409)
        XCTAssertEqual(record.productName, "DELL U2723QE")
        XCTAssertEqual(record.nativePixelWidth, 3840)
        XCTAssertEqual(record.registryEntryID, 0x4001)
        XCTAssertFalse(record.hasStrongDiscriminator, "a zero serial is not a discriminator")
    }

    func testFallsBackToThePnPLetterCodeWhenNoNumericVendorIDIsPresent() throws {
        var attributes = appleSiliconFixture
        var product = attributes["ProductAttributes"] as! [String: Any]
        product.removeValue(forKey: "LegacyManufacturerID")
        attributes["ProductAttributes"] = product

        let record = try XCTUnwrap(AppleSiliconDisplayMetadataBackend.parse(
            displayAttributes: attributes, registryEntryID: nil))
        XCTAssertEqual(record.vendorID, 0x10AC, "\"DEL\" must decode to 0x10AC = 4268")
    }

    func testHandlesInlinedKeysWithoutTheProductAttributesWrapper() throws {
        let inlined: [String: Any] = ["LegacyManufacturerID": 4268, "ProductID": 53409]
        let record = try XCTUnwrap(AppleSiliconDisplayMetadataBackend.parse(
            displayAttributes: inlined, registryEntryID: nil))
        XCTAssertEqual(record.productID, 53409)
    }

    func testToleratesAMissingOrRenamedLayout() {
        // A macOS release that changes the layout must degrade the identity tier, not crash.
        XCTAssertNil(AppleSiliconDisplayMetadataBackend.parse(
            displayAttributes: ["SomethingElse": 1], registryEntryID: nil))
        XCTAssertNil(AppleSiliconDisplayMetadataBackend.parse(
            displayAttributes: [:], registryEntryID: nil))
    }

    func testUsesTheEDIDUUIDAsAStrongDiscriminatorWhenPresent() throws {
        var attributes = appleSiliconFixture
        attributes["EDID UUID"] = "12345678-ABCD-0000-0000-000000000000"
        let record = try XCTUnwrap(AppleSiliconDisplayMetadataBackend.parse(
            displayAttributes: attributes, registryEntryID: nil))
        XCTAssertNotNil(record.edidHash)
        XCTAssertTrue(record.hasStrongDiscriminator)
    }

    func testPnPCodeConversionRejectsGarbage() {
        XCTAssertNil(AppleSiliconDisplayMetadataBackend.pnpCodeToVendorID("TOOLONG"))
        XCTAssertNil(AppleSiliconDisplayMetadataBackend.pnpCodeToVendorID("D1L"))
        XCTAssertEqual(AppleSiliconDisplayMetadataBackend.pnpCodeToVendorID("APP"), 0x0610)
    }

    // MARK: - Registry value coercion

    func testRegistryUInt32AcceptsEveryRepresentationIOKitUses() {
        XCTAssertEqual(registryUInt32(NSNumber(value: 4268)), 4268)
        XCTAssertEqual(registryUInt32("4268"), 4268)
        XCTAssertEqual(registryUInt32("0x10ac"), 0x10AC)
        XCTAssertEqual(registryUInt32(Data([0xAC, 0x10, 0x00, 0x00])), 0x10AC, "little-endian data")
        XCTAssertNil(registryUInt32(nil))
        XCTAssertNil(registryUInt32(["unexpected": 1]))
    }
}

final class BrightnessControllerResolverTests: XCTestCase {

    private func display(builtIn: Bool) -> DisplayDevice {
        DisplayDevice(
            identity: DisplayIdentity(cgDisplayID: 1, vendorID: 0x10AC, productID: 0xD0A1),
            name: builtIn ? "Built-in Display" : "External",
            isBuiltIn: builtIn, isOnline: true, isMain: builtIn)
    }

    /// The built-in panel is macOS's. Asserted with *everything* reported as available, because the
    /// failure this guards against is a fallback quietly dimming the one screen a user cannot unplug.
    func testBuiltInGetsNoControllerEvenWhenEveryOneIsAvailable() {
        let decision = BrightnessControllerResolver.resolve(
            display: display(builtIn: true),
            availability: ControllerAvailability(native: true, ddc: true, gamma: true, shade: true))
        XCTAssertNil(decision.kind)
    }

    /// A stored override from an older version must not become a way back in — and must be explained
    /// rather than silently ignored.
    func testBuiltInIgnoresAUserOverrideAndSaysWhy() {
        let decision = BrightnessControllerResolver.resolve(
            display: display(builtIn: true),
            availability: ControllerAvailability(native: true, ddc: true, gamma: true, shade: true),
            userOverride: .gamma)
        XCTAssertNil(decision.kind)
        XCTAssertTrue(decision.overrideIgnoredReason?.contains("external") ?? false)
    }

    func testExternalPrefersDDCOverSoftware() {
        let decision = BrightnessControllerResolver.resolve(
            display: display(builtIn: false),
            availability: ControllerAvailability(native: false, ddc: true, gamma: true, shade: true))
        XCTAssertEqual(decision.kind, .ddc)
    }

    func testExternalWithoutDDCFallsBackToGammaBeforeShade() {
        // Gamma is preferred because a shade window appears in screenshots and recordings.
        let decision = BrightnessControllerResolver.resolve(
            display: display(builtIn: false),
            availability: ControllerAvailability(native: false, ddc: false, gamma: true, shade: true))
        XCTAssertEqual(decision.kind, .gamma)
    }

    func testShadeIsTheLastResort() {
        let decision = BrightnessControllerResolver.resolve(
            display: display(builtIn: false),
            availability: ControllerAvailability(native: false, ddc: false, gamma: false, shade: true))
        XCTAssertEqual(decision.kind, .shade)
    }

    func testNoControllerAvailableReportsNil() {
        let decision = BrightnessControllerResolver.resolve(
            display: display(builtIn: false),
            availability: ControllerAvailability(native: false, ddc: false, gamma: false, shade: false))
        XCTAssertNil(decision.kind)
    }

    func testUserOverrideWins() {
        let decision = BrightnessControllerResolver.resolve(
            display: display(builtIn: false),
            availability: ControllerAvailability(native: false, ddc: true, gamma: true, shade: true),
            userOverride: .gamma)
        XCTAssertEqual(decision.kind, .gamma)
        XCTAssertNil(decision.overrideIgnoredReason)
    }

    /// An override that cannot be honoured must be explained, not silently swapped.
    func testUnavailableOverrideFallsBackAndSaysSo() {
        let decision = BrightnessControllerResolver.resolve(
            display: display(builtIn: false),
            availability: ControllerAvailability(native: false, ddc: false, gamma: true, shade: true),
            userOverride: .ddc)
        XCTAssertEqual(decision.kind, .gamma)
        let reason = try? XCTUnwrap(decision.overrideIgnoredReason)
        XCTAssertTrue(reason?.contains("DDC") ?? false)
    }

    func testSupportedKindsListing() {
        let availability = ControllerAvailability(native: true, ddc: false, gamma: true, shade: true)
        XCTAssertEqual(availability.supportedKinds, [.native, .gamma, .shade])
    }
}

final class ResolutionPresetTests: XCTestCase {

    /// The defect this replaced: presets were keyed off panel *height* and returned hard-coded 16:9
    /// lists, so a 2560 × 1600 (16:10) display was offered 1920 × 1080 and 2304 × 1296 — shapes that do
    /// not match the panel and would be letterboxed or stretched.
    func testEveryPresetResolutionMatchesThePanelAspectRatioExactly() {
        let panels: [(width: Int, height: Int)] = [
            (2560, 1600), // 16:10 — the case that was broken
            (2560, 1440), // 16:9
            (3840, 2160), // 16:9 4K
            (3440, 1440), // 21:9 ultrawide
            (3024, 1964), // the built-in XDR panel's unusual ratio
        ]
        for panel in panels {
            let ladder = ResolutionPresets.aspectPreservingLadder(nativePixels: panel)
            XCTAssertFalse(ladder.isEmpty, "no ladder for \(panel)")
            let panelRatio = Double(panel.width) / Double(panel.height)
            for resolution in ladder {
                XCTAssertEqual(
                    resolution.aspectRatio, panelRatio, accuracy: 0.0001,
                    "\(resolution.label) does not match \(panel.width)×\(panel.height)")
            }
        }
    }

    func testLadderDimensionsAreAlwaysEven() {
        // An odd logical dimension cannot be doubled cleanly into a backing store.
        for panel in [(2560, 1600), (3440, 1440), (3024, 1964)] {
            for resolution in ResolutionPresets.aspectPreservingLadder(nativePixels: panel) {
                XCTAssertEqual(resolution.logicalWidth % 2, 0, "\(resolution.label)")
                XCTAssertEqual(resolution.logicalHeight % 2, 0, "\(resolution.label)")
            }
        }
    }

    /// The smallest rung renders into a backing store equal to the panel — nothing is resampled.
    func testLadderStartsAtThePixelPerfectSize() {
        let panel = (width: 2560, height: 1600)
        let ladder = ResolutionPresets.aspectPreservingLadder(nativePixels: panel)
        let smallest = try! XCTUnwrap(ladder.first)
        XCTAssertEqual(smallest.logicalWidth, 1280)
        XCTAssertEqual(smallest.logicalHeight, 800)
        XCTAssertEqual(ResolutionPresets.sharpness(of: smallest, nativePixels: panel), .pixelPerfect)
    }

    func testLadderStaysBelowTheNativeResolution() {
        let panel = (width: 2560, height: 1600)
        for resolution in ResolutionPresets.aspectPreservingLadder(nativePixels: panel) {
            XCTAssertLessThan(resolution.logicalWidth, panel.width,
                              "a logical size at or above native is not a scaled mode")
        }
    }

    /// 2048 × 1280 on a 2560 × 1600 panel — the size this feature was asked for.
    func testTheRequestedSizeIsValidAndSupersampled() {
        let panel = (width: 2560, height: 1600)
        let requested = ScaledResolution(logicalWidth: 2048, logicalHeight: 1280, backingScale: 2)

        XCTAssertEqual(requested.aspectRatio, Double(panel.width) / Double(panel.height), accuracy: 0.0001)
        XCTAssertEqual(requested.pixelWidth, 4096)
        XCTAssertEqual(requested.pixelHeight, 2560)

        guard case .supersampled(let ratio) =
            try! XCTUnwrap(ResolutionPresets.sharpness(of: requested, nativePixels: panel))
        else { return XCTFail("expected supersampling") }
        XCTAssertEqual(ratio, 1.6, accuracy: 0.001)

        let report = OverrideValidator.validate(
            DisplayOverrideDocument(vendorID: 0x10AC, productID: 0xD0A1, scaleResolutions: [requested]),
            nativePixelSize: panel)
        XCTAssertTrue(report.isInstallable, "errors: \(report.errors.map(\.message))")
        XCTAssertTrue(report.warnings.isEmpty, "warnings: \(report.warnings.map(\.message))")
    }

    /// The size originally asked for, 2048 × 1020, is not 16:10 and must be caught.
    func testAMismatchedAspectRatioIsFlagged() {
        let panel = (width: 2560, height: 1600)
        let mistyped = ScaledResolution(logicalWidth: 2048, logicalHeight: 1020, backingScale: 2)
        let report = OverrideValidator.validate(
            DisplayOverrideDocument(vendorID: 0x10AC, productID: 0xD0A1, scaleResolutions: [mistyped]),
            nativePixelSize: panel)
        XCTAssertTrue(report.warnings.contains { $0.message.contains("aspect ratio") })
    }

    func testSharpnessClassification() {
        let panel = (width: 2560, height: 1600)
        XCTAssertEqual(
            ResolutionPresets.sharpness(
                of: ScaledResolution(logicalWidth: 1280, logicalHeight: 800), nativePixels: panel),
            .pixelPerfect)
        // A logical size below half the panel renders smaller than the panel and is scaled up — soft.
        guard case .upscaled = try! XCTUnwrap(ResolutionPresets.sharpness(
            of: ScaledResolution(logicalWidth: 1024, logicalHeight: 640), nativePixels: panel))
        else { return XCTFail("expected upscaling") }
    }

    func testRecommendationCutoff() {
        XCTAssertTrue(HiDPISharpness.pixelPerfect.isRecommended)
        XCTAssertTrue(HiDPISharpness.supersampled(ratio: 1.6).isRecommended)
        XCTAssertFalse(HiDPISharpness.supersampled(ratio: 2.0).isRecommended)
        XCTAssertFalse(HiDPISharpness.upscaled(ratio: 0.8).isRecommended)
    }

    func testAspectRatioLabelsAreRecognisable() {
        XCTAssertEqual(ResolutionPresets.aspectRatioLabel(width: 2560, height: 1600), "16:10")
        XCTAssertEqual(ResolutionPresets.aspectRatioLabel(width: 3840, height: 2160), "16:9")
        XCTAssertEqual(ResolutionPresets.aspectRatioLabel(width: 3440, height: 1440), "43:18")
    }

    func testPresetsAreEmptyWithoutANativeSize() {
        XCTAssertTrue(ResolutionPresets.presets(forNativePixels: nil).isEmpty)
        XCTAssertTrue(ResolutionPresets.aspectPreservingLadder(nativePixels: (0, 0)).isEmpty)
    }

    func testMissingResolutionsExcludesModesMacOSAlreadyOffers() {
        let panel = (width: 2560, height: 1600)
        let preset = try! XCTUnwrap(ResolutionPresets.presets(forNativePixels: panel).first)
        let firstRung = try! XCTUnwrap(preset.resolutions.first)
        let existing = [
            DisplayMode(
                width: firstRung.logicalWidth, height: firstRung.logicalHeight,
                pixelWidth: firstRung.pixelWidth, pixelHeight: firstRung.pixelHeight, refreshRate: 60),
        ]
        let missing = ResolutionPresets.missingResolutions(from: preset, existingModes: existing)
        XCTAssertFalse(missing.contains { $0.id == firstRung.id },
                       "never offer to override a mode that already works")
    }
}
