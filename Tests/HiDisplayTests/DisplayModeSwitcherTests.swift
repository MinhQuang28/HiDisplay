import XCTest
@testable import HiDisplayKit

/// Curation logic for the resolution picker.
///
/// The raw list CoreGraphics returns is unusable as a menu — a 4K panel reports dozens of entries that
/// are the same logical size at different refresh rates and scale factors. These tests pin the rules
/// that turn it into a short list, because a wrong rule silently hides the mode someone wanted.
final class DisplayModeSwitcherTests: XCTestCase {

    private func mode(
        _ width: Int, _ height: Int, scale: Int = 1, refresh: Double = 60, usable: Bool = true
    ) -> DisplayMode {
        DisplayMode(
            width: width, height: height,
            pixelWidth: width * scale, pixelHeight: height * scale,
            refreshRate: refresh, isUsableForDesktop: usable)
    }

    func testCurationKeepsOneEntryPerLogicalSize() {
        let curated = DisplayModeSwitcher.curated(from: [
            mode(2560, 1440, refresh: 60),
            mode(2560, 1440, refresh: 120),
            mode(1920, 1080, refresh: 60),
        ])
        XCTAssertEqual(curated.count, 2)
        XCTAssertEqual(Set(curated.map { "\($0.width)x\($0.height)" }), ["2560x1440", "1920x1080"])
    }

    func testCurationPrefersTheHiDPIVariant() {
        // Same logical size, one sharp and one not — the sharp one is the whole point.
        let curated = DisplayModeSwitcher.curated(from: [
            mode(1920, 1080, scale: 1, refresh: 144),
            mode(1920, 1080, scale: 2, refresh: 60),
        ])
        XCTAssertEqual(curated.count, 1)
        XCTAssertTrue(curated[0].isHiDPI, "HiDPI wins even at a lower refresh rate")
    }

    func testCurationPrefersHigherRefreshWithinTheSameSharpness() {
        let curated = DisplayModeSwitcher.curated(from: [
            mode(2560, 1440, scale: 2, refresh: 60),
            mode(2560, 1440, scale: 2, refresh: 120),
        ])
        XCTAssertEqual(curated[0].refreshRate, 120)
    }

    func testCurationSortsLargestFirst() {
        let curated = DisplayModeSwitcher.curated(from: [
            mode(1280, 720), mode(2560, 1440), mode(1920, 1080),
        ])
        XCTAssertEqual(curated.map(\.width), [2560, 1920, 1280])
    }

    func testCurationDropsModesNotUsableForTheDesktop() {
        let curated = DisplayModeSwitcher.curated(from: [
            mode(2560, 1440),
            mode(720, 480, usable: false),
        ])
        XCTAssertEqual(curated.count, 1)
        XCTAssertEqual(curated[0].width, 2560)
    }

    func testCurationOfAnEmptyListIsEmpty() {
        XCTAssertTrue(DisplayModeSwitcher.curated(from: []).isEmpty)
    }

    // MARK: - Refresh rates

    func testRefreshRatesAreScopedToOneSizeAndSharpness() {
        let modes = [
            mode(2560, 1440, scale: 2, refresh: 60),
            mode(2560, 1440, scale: 2, refresh: 120),
            mode(2560, 1440, scale: 1, refresh: 144), // different sharpness — must not appear
            mode(1920, 1080, scale: 2, refresh: 240), // different size — must not appear
        ]
        let rates = DisplayModeSwitcher.refreshRates(
            forWidth: 2560, height: 1440, hiDPI: true, in: modes)
        XCTAssertEqual(rates.map(\.refreshRate), [120, 60], "highest first, scoped correctly")
    }

    /// Internal panels frequently report a rate of 0, meaning "not applicable" rather than 0 Hz.
    /// Offering it as a choice would put a nonsense "0 Hz" entry in the picker.
    func testZeroRefreshRateIsNotOfferedAsAChoice() {
        let modes = [
            mode(3024, 1964, scale: 2, refresh: 0),
            mode(3024, 1964, scale: 2, refresh: 120),
        ]
        let rates = DisplayModeSwitcher.refreshRates(
            forWidth: 3024, height: 1964, hiDPI: true, in: modes)
        XCTAssertEqual(rates.map(\.refreshRate), [120])
    }

    func testPreferenceRuleIsOrderIndependent() {
        let hiDPI = mode(1920, 1080, scale: 2, refresh: 60)
        let plain = mode(1920, 1080, scale: 1, refresh: 144)
        XCTAssertTrue(DisplayModeSwitcher.isPreferred(hiDPI, over: plain))
        XCTAssertFalse(DisplayModeSwitcher.isPreferred(plain, over: hiDPI))
    }

    /// Picker selection is tagged by `DisplayMode.id`, so two genuinely different modes must never
    /// share one — otherwise choosing 120 Hz could apply the 60 Hz entry.
    func testModeIDDistinguishesEverythingThePickerOffers() {
        let ids = [
            mode(2560, 1440, scale: 1, refresh: 60),
            mode(2560, 1440, scale: 2, refresh: 60),
            mode(2560, 1440, scale: 2, refresh: 120),
            mode(1920, 1080, scale: 2, refresh: 120),
        ].map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }
}

/// The scaling slider's domain. Every position must be a mode that is actually installable — an invalid
/// option should not exist rather than be offered and then rejected by the validator.
final class ScalingStepsTests: XCTestCase {

    private let panel = (width: 2560, height: 1600)

    func testEveryStepIsAspectCorrectAndEven() {
        let steps = ResolutionPresets.scalingSteps(nativePixels: panel)
        XCTAssertGreaterThan(steps.count, 5, "a slider needs enough positions to feel continuous")
        let panelRatio = Double(panel.width) / Double(panel.height)
        for step in steps {
            XCTAssertEqual(step.aspectRatio, panelRatio, accuracy: 0.0001)
            XCTAssertEqual(step.logicalWidth % 2, 0)
            XCTAssertEqual(step.logicalHeight % 2, 0)
        }
    }

    func testEveryStepPassesValidation() {
        for step in ResolutionPresets.scalingSteps(nativePixels: panel) {
            let report = OverrideValidator.validate(
                DisplayOverrideDocument(vendorID: 0x10AC, productID: 0xD0A1, scaleResolutions: [step]),
                nativePixelSize: panel)
            XCTAssertTrue(report.isInstallable, "\(step.label): \(report.errors.map(\.message))")
            XCTAssertTrue(report.warnings.isEmpty, "\(step.label): \(report.warnings.map(\.message))")
        }
    }

    /// A HiDPI mode has to be strictly smaller than the panel, so the ladder must stop short of it.
    ///
    /// At exactly native the backing store is twice the panel in both axes — the one size measured to
    /// be dropped by macOS — and it shows no more desktop than the plain 1× native mode.
    func testTheLadderStopsBelowTheNativeSize() {
        for panel in [panel, (width: 3840, height: 2160), (width: 3024, height: 1964), (width: 1920, height: 1080)] {
            guard let top = ResolutionPresets.scalingSteps(nativePixels: panel).last else { continue }
            XCTAssertLessThan(top.logicalWidth, panel.width, "\(panel) ladder reached native width")
            XCTAssertLessThan(top.logicalHeight, panel.height, "\(panel) ladder reached native height")
        }
    }

    func testAHiDPIModeAtTheNativeSizeIsRejected() {
        let report = OverrideValidator.validate(
            DisplayOverrideDocument(
                vendorID: 0x10AC, productID: 0xD0A1,
                scaleResolutions: [
                    ScaledResolution(logicalWidth: panel.width, logicalHeight: panel.height, backingScale: 2)
                ]),
            nativePixelSize: panel)
        XCTAssertFalse(report.isInstallable)
    }

    /// The same size at 1× is the panel's own native mode and must stay perfectly legal.
    func testAPlain1xModeAtTheNativeSizeIsStillAllowed() {
        let report = OverrideValidator.validate(
            DisplayOverrideDocument(
                vendorID: 0x10AC, productID: 0xD0A1,
                scaleResolutions: [
                    ScaledResolution(logicalWidth: panel.width, logicalHeight: panel.height, backingScale: 1)
                ]),
            nativePixelSize: panel)
        XCTAssertTrue(report.isInstallable, "\(report.errors.map(\.message))")
    }

    func testStepsRunLargestTextToMostSpace() {
        let steps = ResolutionPresets.scalingSteps(nativePixels: panel)
        for (earlier, later) in zip(steps, steps.dropFirst()) {
            XCTAssertLessThan(earlier.logicalWidth, later.logicalWidth)
        }
    }

    /// The range must span both sides of the pixel-perfect point.
    ///
    /// An earlier version started the ladder *at* pixel-perfect, which silently removed the entire
    /// "larger text" half — the part most people actually reach for. Comparing against a tool that
    /// injects modes at runtime made the omission obvious: it offered ~100 sizes below that point.
    func testRangeSpansBothSidesOfPixelPerfect() {
        let steps = ResolutionPresets.scalingSteps(nativePixels: panel)

        let pixelPerfect = steps.filter {
            ResolutionPresets.sharpness(of: $0, nativePixels: panel) == .pixelPerfect
        }
        XCTAssertEqual(pixelPerfect.count, 1, "exactly one size renders 1:1 with the panel")
        XCTAssertEqual(pixelPerfect[0].logicalWidth, 1280)

        let softer = steps.filter {
            if case .upscaled = ResolutionPresets.sharpness(of: $0, nativePixels: panel)! { return true }
            return false
        }
        let sharper = steps.filter {
            if case .supersampled = ResolutionPresets.sharpness(of: $0, nativePixels: panel)! { return true }
            return false
        }
        XCTAssertGreaterThan(softer.count, 10, "the larger-text half must exist")
        XCTAssertGreaterThan(sharper.count, 10, "the more-space half must exist")
    }

    func testRangeStaysWithinWhatTheValidatorAccepts() {
        for step in ResolutionPresets.scalingSteps(nativePixels: panel) {
            XCTAssertGreaterThanOrEqual(step.logicalWidth, OverrideValidator.minimumLogicalWidth)
            XCTAssertGreaterThanOrEqual(step.logicalHeight, OverrideValidator.minimumLogicalHeight)
        }
    }

    /// The size this was all asked for must be reachable by the slider, not only by typing.
    func testTheRequestedSizeIsAStep() {
        let steps = ResolutionPresets.scalingSteps(nativePixels: panel)
        XCTAssertTrue(steps.contains { $0.logicalWidth == 2048 && $0.logicalHeight == 1280 })
    }

    func testSeedingFromTheCurrentModeSnapsToTheNearestStep() {
        let steps = ResolutionPresets.scalingSteps(nativePixels: panel)
        let index = try! XCTUnwrap(ResolutionPresets.nearestStepIndex(to: 2050, in: steps))
        XCTAssertEqual(steps[index].logicalWidth, 2048)
    }

    func testUnknownPanelYieldsNoSteps() {
        XCTAssertTrue(ResolutionPresets.scalingSteps(nativePixels: (0, 0)).isEmpty)
        XCTAssertNil(ResolutionPresets.nearestStepIndex(to: 1920, in: []))
    }
}

/// Brightness-key targeting. Pure logic, because "which screen does F1 dim" is exactly the kind of
/// thing that is obvious until there are two monitors and a pointer in the gap between them.
/// Native size must not drift once an override is installed.
///
/// The regression: `nativePixelSize` was the largest mode by pixel area, which a HiDPI mode wins by
/// definition — it renders into a backing store bigger than the panel. On real hardware the app read a
/// 2560 × 1600 monitor as 5056 × 3160 and the 3024 × 1964 built-in as 3600 × 2338. Since the ladder is
/// generated from the native size, each reinstall would have been built from the last one's output.
final class NativePixelSizeTests: XCTestCase {

    private func device(modes: [DisplayMode]) -> DisplayDevice {
        DisplayDevice(
            identity: DisplayIdentity(cgDisplayID: 7, vendorID: 0x4A8B, productID: 0x2560),
            name: "Test", isBuiltIn: false, isOnline: true, isMain: false,
            availableModes: modes,
            frame: CGRect(x: 0, y: 0, width: 2560, height: 1600))
    }

    private func mode(_ width: Int, _ height: Int, scale: Int) -> DisplayMode {
        DisplayMode(
            width: width, height: height,
            pixelWidth: width * scale, pixelHeight: height * scale, refreshRate: 60)
    }

    func testNativeSizeIsTheLargest1xModeNotTheLargestBackingStore() {
        let device = device(modes: [
            mode(1280, 800, scale: 1),
            mode(2560, 1600, scale: 1),   // the panel
            mode(2528, 1580, scale: 2),   // 5056 × 3160 backing, from an installed override
            mode(1920, 1200, scale: 2),   // 3840 × 2400 backing
        ])
        XCTAssertEqual(device.nativePixelSize?.width, 2560)
        XCTAssertEqual(device.nativePixelSize?.height, 1600)
    }

    /// Reading the ladder back out of its own effect is what made this a loop rather than a one-off.
    func testTheLadderDoesNotGrowWhenItsOwnModesAreVisible() {
        let panel = (width: 2560, height: 1600)
        let ladder = ResolutionPresets.scalingSteps(nativePixels: panel)
        let withOverrideInstalled = device(
            modes: [mode(2560, 1600, scale: 1)]
                + ladder.map { mode($0.logicalWidth, $0.logicalHeight, scale: 2) })

        let native = try? XCTUnwrap(withOverrideInstalled.nativePixelSize)
        XCTAssertEqual(native?.width, panel.width)
        XCTAssertEqual(
            ResolutionPresets.scalingSteps(nativePixels: (native!.width, native!.height)).map(\.id),
            ladder.map(\.id),
            "regenerating from a display that already has the override must produce the same ladder")
    }

    func testFallsBackToTheLargestModeWhenThereIsNo1xMode() {
        let device = device(modes: [mode(1280, 800, scale: 2), mode(1920, 1200, scale: 2)])
        XCTAssertEqual(device.nativePixelSize?.width, 3840)
    }
}

final class BrightnessKeyResolverTests: XCTestCase {

    private func display(
        _ name: String, builtIn: Bool, main: Bool, frame: CGRect
    ) -> DisplayDevice {
        DisplayDevice(
            identity: DisplayIdentity(
                cgDisplayID: UInt32(abs(name.hashValue % 1000)),
                vendorID: 0x10AC, productID: UInt32(abs(name.hashValue % 100))),
            name: name, isBuiltIn: builtIn, isOnline: true, isMain: main, frame: frame)
    }

    /// Built-in on the left, external on the right — the ordinary docked-laptop layout.
    private var layout: [DisplayDevice] {
        [
            display("Built-in", builtIn: true, main: true, frame: CGRect(x: 0, y: 0, width: 1512, height: 982)),
            display("External", builtIn: false, main: false, frame: CGRect(x: 1512, y: 0, width: 2560, height: 1600)),
        ]
    }

    func testPointerPicksTheDisplayItIsOver() {
        let onExternal = BrightnessKeyResolver.targets(
            strategy: .displayUnderMouse, displays: layout, pointer: CGPoint(x: 2000, y: 500))
        XCTAssertEqual(onExternal.map(\.name), ["External"])

        let onBuiltIn = BrightnessKeyResolver.targets(
            strategy: .displayUnderMouse, displays: layout, pointer: CGPoint(x: 100, y: 100))
        XCTAssertEqual(onBuiltIn.map(\.name), ["Built-in"])
    }

    /// Display frames need not tile perfectly; a pointer in a gap must not swallow the key press.
    func testPointerOutsideEveryFrameFallsBackToMain() {
        let targets = BrightnessKeyResolver.targets(
            strategy: .displayUnderMouse, displays: layout, pointer: CGPoint(x: -500, y: -500))
        XCTAssertEqual(targets.map(\.name), ["Built-in"], "falls back to main rather than doing nothing")
    }

    func testAllExternalSkipsTheBuiltIn() {
        let targets = BrightnessKeyResolver.targets(
            strategy: .allExternal, displays: layout, pointer: .zero)
        XCTAssertEqual(targets.map(\.name), ["External"])
    }

    /// On a laptop with nothing plugged in, "all external" must still do something.
    func testAllExternalFallsBackWhenThereAreNoExternalDisplays() {
        let laptopOnly = [layout[0]]
        let targets = BrightnessKeyResolver.targets(
            strategy: .allExternal, displays: laptopOnly, pointer: .zero)
        XCTAssertEqual(targets.map(\.name), ["Built-in"])
    }

    func testControlModifierOverridesTheStrategy() {
        let targets = BrightnessKeyResolver.targets(
            strategy: .displayUnderMouse, displays: layout,
            pointer: CGPoint(x: 100, y: 100), forceAllDisplays: true)
        XCTAssertEqual(targets.count, 2)
    }

    func testMainDisplayStrategy() {
        XCTAssertEqual(
            BrightnessKeyResolver.targets(strategy: .mainDisplay, displays: layout, pointer: .zero)
                .map(\.name),
            ["Built-in"])
    }

    func testNoDisplaysYieldsNoTargets() {
        XCTAssertTrue(BrightnessKeyResolver.targets(
            strategy: .allDisplays, displays: [], pointer: .zero).isEmpty)
    }

    func testStepsMatchTheSystemFeelAndClamp() {
        XCTAssertEqual(BrightnessKeyResolver.step(fine: false), 1.0 / 16.0, "macOS moves in sixteenths")
        XCTAssertEqual(BrightnessKeyResolver.step(fine: true), 1.0 / 64.0)

        XCTAssertEqual(BrightnessKeyResolver.adjusted(1.0, by: 0.25), 1.0, "cannot exceed full")
        XCTAssertEqual(BrightnessKeyResolver.adjusted(0.0, by: -0.25), 0.0, "cannot go below zero")
        XCTAssertEqual(BrightnessKeyResolver.adjusted(0.5, by: 1.0 / 16.0), 0.5625, accuracy: 0.0001)
    }

    /// Sixteen presses from zero must land exactly on full, with no drift.
    func testSixteenCoarseStepsSpanTheWholeRange() {
        var value: Float = 0
        for _ in 0..<16 {
            value = BrightnessKeyResolver.adjusted(value, by: BrightnessKeyResolver.step(fine: false))
        }
        XCTAssertEqual(value, 1.0, accuracy: 0.0001)
    }
}

/// Manual entry can no longer produce an off-ratio size.
///
/// The ladder and presets were always aspect-correct by construction; the typed field was the one place
/// in the app that could produce a letterboxed or stretched mode, and it only *warned*.
final class AspectLockedEntryTests: XCTestCase {

    private let panel = (width: 2560, height: 1600)   // 16:10

    func testAnExactLadderWidthIsReturnedUnchanged() {
        let result = ResolutionPresets.aspectCorrectResolution(forWidth: 2048, nativePixels: panel)
        XCTAssertEqual(result?.logicalWidth, 2048)
        XCTAssertEqual(result?.logicalHeight, 1280, "16:10 of 2048")
    }

    func testAnOffLadderWidthSnapsToTheNearestAspectCorrectSize() {
        // 2050 is not a multiple of the reduced ratio step; it must snap, not round into 2050 × 1281.
        let result = ResolutionPresets.aspectCorrectResolution(forWidth: 2050, nativePixels: panel)
        XCTAssertEqual(result?.logicalWidth, 2048)
        XCTAssertEqual(result?.logicalHeight, 1280)
    }

    func testEveryResultMatchesThePanelRatioExactly() {
        let panelRatio = Double(panel.width) / Double(panel.height)
        for width in stride(from: 700, through: 2600, by: 37) {
            guard let result = ResolutionPresets.aspectCorrectResolution(
                forWidth: width, nativePixels: panel) else { continue }
            XCTAssertEqual(result.aspectRatio, panelRatio, accuracy: 0.0001,
                           "width \(width) produced \(result.label)")
            XCTAssertEqual(result.logicalWidth % 2, 0)
            XCTAssertEqual(result.logicalHeight % 2, 0)
        }
    }

    /// The result must always be installable, since the UI offers it directly.
    func testEveryResultPassesValidationWithoutWarnings() {
        for width in [800, 1280, 1600, 1920, 2048, 2304, 2500] {
            guard let result = ResolutionPresets.aspectCorrectResolution(
                forWidth: width, nativePixels: panel) else { continue }
            let report = OverrideValidator.validate(
                DisplayOverrideDocument(vendorID: 0x10AC, productID: 0xD0A1, scaleResolutions: [result]),
                nativePixelSize: panel)
            XCTAssertTrue(report.isInstallable, "\(result.label): \(report.errors.map(\.message))")
            XCTAssertFalse(report.warnings.contains { $0.message.contains("aspect ratio") },
                           "\(result.label) should never trip the aspect warning")
        }
    }

    func testWidthsOutsideTheRangeClampToTheNearestEnd() {
        let steps = ResolutionPresets.scalingSteps(nativePixels: panel)
        XCTAssertEqual(
            ResolutionPresets.aspectCorrectResolution(forWidth: 10, nativePixels: panel)?.logicalWidth,
            steps.first?.logicalWidth)
        XCTAssertEqual(
            ResolutionPresets.aspectCorrectResolution(forWidth: 99999, nativePixels: panel)?.logicalWidth,
            steps.last?.logicalWidth)
    }

    /// A 16:9 panel must produce 16:9 sizes, not the 16:10 ones tuned for the development monitor.
    func testWorksForOtherPanelShapes() {
        for panel in [(width: 3840, height: 2160), (width: 3440, height: 1440), (width: 3024, height: 1964)] {
            let ratio = Double(panel.width) / Double(panel.height)
            guard let result = ResolutionPresets.aspectCorrectResolution(
                forWidth: panel.width / 2, nativePixels: panel) else {
                return XCTFail("no result for \(panel)")
            }
            XCTAssertEqual(result.aspectRatio, ratio, accuracy: 0.0001)
        }
    }

    func testUnknownPanelYieldsNothing() {
        XCTAssertNil(ResolutionPresets.aspectCorrectResolution(forWidth: 1920, nativePixels: (0, 0)))
    }
}
