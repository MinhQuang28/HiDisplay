import XCTest
@testable import HiDisplayKit

/// Covers the wake path's reassert-before-probe ordering, `resetAllDimming`'s software-only scope, and
/// a held display's one-shot recovery probe when the user acts on it.
@MainActor
final class BrightnessCoordinatorWakeTests: XCTestCase {

    /// `handleScreensDidWake` must write the saved value on the controller the display already had
    /// *before* probing it — a monitor that woke on its own OSD brightness is corrected by one write
    /// instead of waiting out a probe (and, when the wake also reconfigures displays, the settle
    /// behind it). Observed here as event order in a shared log, not just that both happened.
    func testWakeWritesSavedValueBeforeProbing() async {
        let (coordinator, ddc, _, _) = makeTestCoordinator()
        let display = makeExternalDisplay(serial: 10)
        await ddc.setProbeScript([supportedDDCResult(0.5)], for: display.id)
        coordinator.savedBrightnessLookup = { _ in 0.5 }
        await coordinator.probeAndChoose(display: display)
        XCTAssertEqual(coordinator.controller(for: display.id), .ddc)

        let log = CallLog()
        await ddc.attachLog(log)
        await coordinator.handleScreensDidWake([display])

        let events = await log.events
        let setIndex = events.firstIndex { $0.hasPrefix("ddc.set:") }
        let probeIndex = events.firstIndex { $0.hasPrefix("ddc.probe:") }
        XCTAssertNotNil(setIndex, "the optimistic reassert must have written to ddc")
        XCTAssertNotNil(probeIndex, "the wake probe must still run afterwards")
        if let setIndex, let probeIndex {
            XCTAssertLessThan(setIndex, probeIndex,
                              "the saved value must be written before the wake's probe starts")
        }
    }

    /// `resetAllDimming` must clear gamma and shade unconditionally but leave a hardware-controlled
    /// display's brightness untouched — that value is the monitor's own backlight, and blasting it to
    /// full would be a surprise rather than a rescue.
    func testResetAllDimmingTouchesOnlySoftwareControllers() async {
        let (coordinator, ddc, gamma, shade) = makeTestCoordinator()
        let hardwareDisplay = makeExternalDisplay(serial: 11)
        let softwareDisplay = makeExternalDisplay(serial: 12)
        await ddc.setProbeScript([supportedDDCResult(0.4)], for: hardwareDisplay.id)
        await ddc.setProbeScript([unsupportedDDCResult()], for: softwareDisplay.id)
        coordinator.savedBrightnessLookup = { key in
            key == hardwareDisplay.id ? 0.4 : 0.3
        }
        await coordinator.probeAndChoose(display: hardwareDisplay)
        await coordinator.probeAndChoose(display: softwareDisplay)
        let hardwareBrightnessBefore = coordinator.brightness(for: hardwareDisplay.id)

        coordinator.resetAllDimming()

        XCTAssertEqual(coordinator.brightness(for: hardwareDisplay.id), hardwareBrightnessBefore,
                       "a DDC-controlled display's backlight must be left alone")
        XCTAssertEqual(coordinator.brightness(for: softwareDisplay.id), 1.0,
                       "a gamma-dimmed display must snap back to undimmed")
        XCTAssertEqual(gamma.resetAllCount, 1)
        XCTAssertEqual(shade.resetAllCount, 1)
    }

    /// A user brightness action on a held display is the recovery trigger past the retry ladder: the
    /// write still lands on the current (software) controller so the user sees a response, and exactly
    /// one re-probe follows to try handing control back to DDC.
    func testUserActionOnAHeldDisplayTriggersOneReprobe() async {
        // Empty ladder: the very first probe already exhausts it, so the display is held
        // deterministically without waiting on background retry timers.
        let (coordinator, ddc, gamma, _) = makeTestCoordinator(retryDelays: [])
        let display = makeExternalDisplay(serial: 13)
        await coordinator.seedDDCFacts(DDCSessionFacts(), for: display.id)
        await ddc.setProbeScript([nullDDCResult()], for: display.id)
        coordinator.savedBrightnessLookup = { _ in 0.6 }

        await coordinator.probeAndChoose(display: display)
        XCTAssertTrue(coordinator.isHeld(display.id))
        let probesBeforeAction = await ddc.probeCallCounts[display.id] ?? 0

        // DDC now answers, simulating the monitor having finished waking.
        await ddc.setProbeScript([supportedDDCResult(0.6)], for: display.id)
        await coordinator.setBrightness(0.5, for: display)

        XCTAssertEqual(gamma.setBrightnessCalls.map(\.value), [0.5],
                       "the held display's write must still land on its current controller")
        let probesAfterAction = await ddc.probeCallCounts[display.id] ?? 0
        XCTAssertEqual(probesAfterAction, probesBeforeAction + 1,
                       "exactly one re-probe must follow a user action on a held display")
        XCTAssertFalse(coordinator.isHeld(display.id), "DDC answered again, so the hold must clear")
        XCTAssertEqual(coordinator.controller(for: display.id), .ddc)
    }
}
