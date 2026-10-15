import XCTest
@testable import HiDisplayKit

/// Covers `BrightnessCoordinator`'s DDC hold/evidence logic, the retry ladder, controller overrides,
/// the saved-brightness reassert, the software→hardware reset, and connection-epoch discard — the
/// intricate half of the coordinator that had zero tests before controller injection existed.
@MainActor
final class BrightnessCoordinatorTests: XCTestCase {

    /// A null DDC answer on a display with DDC evidence must stay on the retry ladder to its end and
    /// come out *held*: the saved value shown, no software write underneath it. The alternative — the
    /// cold-boot bug this hold exists to fix — is a gamma dim applied on top of a backlight that
    /// already holds the right value, then a bright flash when a later probe lifts the ramp.
    func testNullAnswerWithDDCEvidenceStaysHeldWithoutSoftwareWrite() async {
        let (coordinator, ddc, gamma, _) = makeTestCoordinator()
        let display = makeExternalDisplay(serial: 1)
        await coordinator.seedDDCFacts(DDCSessionFacts(), for: display.id)
        await ddc.setProbeScript([nullDDCResult()], for: display.id)
        coordinator.savedBrightnessLookup = { _ in 0.4 }

        await coordinator.probeAndChoose(display: display)
        // 1 initial probe + 4 retries from the default short ladder.
        await waitForDDCProbeCount(ddc, key: display.id, atLeast: 5)

        XCTAssertTrue(coordinator.isHeld(display.id), "evidence must keep an exhausted ladder held, not downgraded")
        XCTAssertTrue(gamma.setBrightnessCalls.isEmpty, "a held display must receive no software dimming")
        XCTAssertEqual(coordinator.brightness(for: display.id), 0.4, "the saved value must still be shown")
    }

    /// The same null answer with no DDC evidence gets today's fast path: one retry, then downgrade.
    func testNullAnswerWithoutEvidenceDowngradesToGammaAfterOneRetry() async {
        let (coordinator, ddc, gamma, _) = makeTestCoordinator()
        let display = makeExternalDisplay(serial: 2)
        await ddc.setProbeScript([nullDDCResult()], for: display.id)
        coordinator.savedBrightnessLookup = { _ in 0.7 }

        await coordinator.probeAndChoose(display: display)
        await waitForDDCProbeCount(ddc, key: display.id, atLeast: 2)
        // No evidence, so attempt 1's null is believed: the ladder must not run further.
        try? await Task.sleep(for: .milliseconds(60))

        let probeCount = await ddc.probeCallCounts[display.id]
        XCTAssertFalse(coordinator.isHeld(display.id))
        XCTAssertEqual(coordinator.controller(for: display.id), .gamma)
        XCTAssertEqual(probeCount, 2, "only the one post-settle retry is granted without evidence")
        XCTAssertEqual(gamma.setBrightnessCalls.map(\.value), [0.7], "the saved value must land on gamma once downgraded")
    }

    /// An explicit user override to a software controller must win over DDC evidence — the user chose
    /// that dimming, so the hold (which exists to protect DDC's own eventual answer) must not suppress it.
    func testExplicitSoftwareOverrideIsHonouredOverDDCEvidence() async {
        let (coordinator, ddc, _, _) = makeTestCoordinator()
        let display = makeExternalDisplay(serial: 3)
        await coordinator.seedDDCFacts(DDCSessionFacts(), for: display.id)
        coordinator.seedUserOverride(.gamma, for: display.id)
        await ddc.setProbeScript([nullDDCResult()], for: display.id)

        await coordinator.probeAndChoose(display: display)

        XCTAssertEqual(coordinator.controller(for: display.id), .gamma)
        XCTAssertFalse(coordinator.isHeld(display.id), "an override to software must not be treated as a hold")
    }

    /// Every resolved controller re-asserts the user's saved value when it differs from what the probe
    /// read — a probe seeds the UI from what the display reports *now*, which after a wake is often
    /// the monitor's own OSD value, and keeping it would silently make the wrong value the new truth.
    func testResolvedControllerReassertsSavedBrightnessWhenSeedDiffers() async {
        let (coordinator, ddc, _, _) = makeTestCoordinator()
        let display = makeExternalDisplay(serial: 4)
        await ddc.setProbeScript([supportedDDCResult(0.3)], for: display.id)
        coordinator.savedBrightnessLookup = { _ in 0.8 }

        await coordinator.probeAndChoose(display: display)

        let writtenValues = await ddc.setBrightnessCalls.map(\.value)
        XCTAssertEqual(coordinator.controller(for: display.id), .ddc)
        XCTAssertEqual(writtenValues, [0.8], "the saved value, not the probed 0.3, must be written back")
    }

    /// When DDC comes back after a monitor finishes waking, the display's previous software controller
    /// must be reset — otherwise the display stays dimmed by a gamma ramp or shade underneath its now
    /// DDC-controlled backlight.
    func testSoftwareToHardwareTransitionResetsThePreviousSoftwareController() async {
        let (coordinator, ddc, gamma, _) = makeTestCoordinator()
        let display = makeExternalDisplay(serial: 5)
        // First probe: no DDC (fast, non-null failure) -> falls back to gamma.
        await ddc.setProbeScript([unsupportedDDCResult(), supportedDDCResult(0.5)], for: display.id)
        coordinator.savedBrightnessLookup = { _ in 0.5 }

        await coordinator.probeAndChoose(display: display)
        XCTAssertEqual(coordinator.controller(for: display.id), .gamma)
        XCTAssertTrue(gamma.resetCalls.isEmpty, "no transition has happened yet")

        // Second probe (e.g. the retry that follows the monitor finishing its wake): DDC answers.
        await coordinator.probeAndChoose(display: display)

        XCTAssertEqual(coordinator.controller(for: display.id), .ddc)
        XCTAssertEqual(gamma.resetCalls, [display.id], "the abandoned gamma dim must be undone exactly once")
    }

    // MARK: - Phase, as the UI reads it

    /// Before the first probe a display reads as probing, not unavailable: that is the state of every
    /// external display for the two-second settle after it appears in the menu, and the menu used to
    /// say "No brightness control available" for exactly that window.
    func testPhaseIsProbingBeforeTheFirstProbeAndReadyAfterIt() async {
        let (coordinator, ddc, _, _) = makeTestCoordinator()
        let display = makeExternalDisplay(serial: 7)
        await ddc.setProbeScript([supportedDDCResult(0.5)], for: display.id)

        XCTAssertEqual(coordinator.phase(for: display.id), .probing, "unprobed must read as probing")

        await coordinator.probeAndChoose(display: display)

        XCTAssertEqual(coordinator.phase(for: display.id), .ready(.ddc))
    }

    /// A hold is its own phase, distinct from the software controller standing in underneath it: the
    /// menu shows "waiting for DDC" rather than claiming gamma control it has deliberately not applied.
    func testPhaseIsHeldWhileDDCEvidenceOutlastsTheLadder() async {
        let (coordinator, ddc, _, _) = makeTestCoordinator()
        let display = makeExternalDisplay(serial: 8)
        await coordinator.seedDDCFacts(DDCSessionFacts(), for: display.id)
        await ddc.setProbeScript([nullDDCResult()], for: display.id)
        coordinator.savedBrightnessLookup = { _ in 0.4 }

        await coordinator.probeAndChoose(display: display)
        await waitForDDCProbeCount(ddc, key: display.id, atLeast: 5)

        XCTAssertTrue(coordinator.isHeld(display.id))
        XCTAssertEqual(coordinator.phase(for: display.id), .heldForDDC)
    }

    /// A re-probe on a display that already has a controller must not flip it back to probing: the
    /// previous controller stays live for the duration, and the slider keeps working.
    func testReprobeOfAControlledDisplayDoesNotReportProbing() async {
        let (coordinator, ddc, _, _) = makeTestCoordinator()
        let display = makeExternalDisplay(serial: 9)
        await ddc.setProbeScript([supportedDDCResult(0.5)], for: display.id)
        await coordinator.probeAndChoose(display: display)
        XCTAssertEqual(coordinator.phase(for: display.id), .ready(.ddc))

        await ddc.setProbeDelay(.milliseconds(60), for: display.id)
        let reprobe = Task { await coordinator.probeAndChoose(display: display) }
        try? await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(coordinator.phase(for: display.id), .ready(.ddc), "still controlled mid-reprobe")
        await reprobe.value
        XCTAssertEqual(coordinator.phase(for: display.id), .ready(.ddc))
    }

    /// The built-in panel is never probed, and must say so rather than looking like it is still being
    /// checked forever.
    func testBuiltInPanelReadsAsUnavailable() async {
        let (coordinator, _, _, _) = makeTestCoordinator()
        let builtIn = DisplayDevice(
            identity: DisplayIdentity(
                cgDisplayID: 1, vendorID: 0x610, productID: 0xA040, serialNumber: 0, keyTier: .strong),
            name: "Built-in", isBuiltIn: true, isOnline: true, isMain: true)

        await coordinator.probeAndChoose(display: builtIn)

        XCTAssertEqual(coordinator.phase(for: builtIn.id), .unavailable)
    }

    /// A display that leaves while its very first probe is still in flight has a phase but no state;
    /// the teardown must drop the phase too, or it would read as probing forever.
    func testDepartedDisplayDropsItsPhaseEvenWithoutState() async {
        let (coordinator, ddc, _, _) = makeTestCoordinator()
        let display = makeExternalDisplay(serial: 10)
        await ddc.setProbeScript([supportedDDCResult(0.5)], for: display.id)
        await ddc.setProbeDelay(.milliseconds(80), for: display.id)

        let firstProbe = Task { await coordinator.probeAndChoose(display: display) }
        try? await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(coordinator.phases[display.id], .probing)
        await coordinator.handleSettledDisplays([])
        await firstProbe.value

        XCTAssertNil(coordinator.phases[display.id], "teardown must clear a phase-only entry")
        XCTAssertNil(coordinator.controller(for: display.id))
    }

    /// A probe that is still in flight when the display disconnects must not resurrect state for it:
    /// the connection epoch it was stamped with is stale by the time it completes.
    func testStaleProbeFromPreviousConnectionEpochIsDiscarded() async {
        let (coordinator, ddc, _, _) = makeTestCoordinator()
        let display = makeExternalDisplay(serial: 6)

        // Establish a known-good state first, so the display is one `handleSettledDisplays` can
        // recognise as "departed" — a first-ever probe for a display with no prior state is not in
        // `states` yet, so the teardown loop below would have nothing to tear down.
        await ddc.setProbeScript([supportedDDCResult(0.6)], for: display.id)
        await coordinator.probeAndChoose(display: display)
        XCTAssertEqual(coordinator.controller(for: display.id), .ddc)

        // Arm a second, slow probe, then tear the display down while it is still in flight.
        await ddc.setProbeScript([supportedDDCResult(0.9)], for: display.id)
        await ddc.setProbeDelay(.milliseconds(80), for: display.id)
        let staleProbe = Task { await coordinator.probeAndChoose(display: display) }
        try? await Task.sleep(for: .milliseconds(15))
        await coordinator.handleSettledDisplays([])
        await staleProbe.value

        XCTAssertNil(coordinator.controller(for: display.id), "a departed display must stay torn down")
        XCTAssertEqual(coordinator.brightness(for: display.id), 1.0, "the default, since no state exists")
    }
}
