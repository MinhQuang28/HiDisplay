import CoreGraphics
import Foundation
@testable import HiDisplayKit

/// Ordered event log shared across fakes, so a test can prove *ordering* between two controllers —
/// e.g. that the wake path's optimistic write lands before the probe that follows it — rather than
/// just that both happened.
actor CallLog {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

/// Stand-in for `DDCBrightnessController`. An actor, same as the real thing, so it is trivially
/// `Sendable` under strict concurrency without opting out of checking.
///
/// Probe results are scripted per display key: `setProbeScript` takes the exact sequence the fake
/// should hand back to `probeAndChoose`'s retry ladder. Once only one result remains it repeats
/// forever, so a test does not need to script every attempt of a ladder it expects to exhaust.
actor FakeDDCController: DDCControlling {
    nonisolated let kind: BrightnessControllerKind = .ddc

    private(set) var setBrightnessCalls: [(key: String, value: Float)] = []
    private(set) var resetCalls: [String] = []
    private(set) var probeCallCounts: [String: Int] = [:]
    private(set) var seededFacts: [String: DDCSessionFacts] = [:]

    private var probeScript: [String: [BrightnessProbeResult]] = [:]
    private var probeDelay: [String: Duration] = [:]
    private var currentValues: [String: Float] = [:]
    var log: CallLog?

    func setProbeScript(_ results: [BrightnessProbeResult], for key: String) {
        probeScript[key] = results
    }

    func setProbeDelay(_ delay: Duration, for key: String) {
        probeDelay[key] = delay
    }

    func attachLog(_ log: CallLog) {
        self.log = log
    }

    func probe(display: DisplayDevice) async -> BrightnessProbeResult {
        let key = display.id
        probeCallCounts[key, default: 0] += 1
        if let delay = probeDelay[key] {
            try? await Task.sleep(for: delay)
        }
        await log?.record("ddc.probe:\(key)")
        guard var queue = probeScript[key], !queue.isEmpty else {
            return BrightnessProbeResult(
                isSupported: false, kind: .ddc, detail: "fake ddc: no scripted probe result")
        }
        // Repeat the last scripted result once the queue is down to one entry, so a test does not
        // have to script an exact count for a ladder it expects to run dry.
        let result = queue.count > 1 ? queue.removeFirst() : queue[0]
        probeScript[key] = queue
        return result
    }

    func getBrightness(display: DisplayDevice) async throws -> Float {
        currentValues[display.id] ?? 1.0
    }

    func setBrightness(_ value: Float, display: DisplayDevice) async throws {
        setBrightnessCalls.append((display.id, value))
        currentValues[display.id] = value
        await log?.record("ddc.set:\(display.id):\(value)")
    }

    func reset(display: DisplayDevice) async {
        resetCalls.append(display.id)
    }

    func seedFacts(_ facts: DDCSessionFacts, for key: String) async {
        seededFacts[key] = facts
    }

    func facts(for key: String) async -> DDCSessionFacts? {
        seededFacts[key]
    }

    func invalidateAll(except liveKeys: Set<String>) async {}
}

/// Stand-in for both `GammaBrightnessController` and `ShadeBrightnessController`. One fake covers
/// both protocols since their extra surfaces (`prune`/`reapplyAll` vs. `reposition`) never overlap in
/// a way that matters to the coordinator tests — what the coordinator actually branches on is
/// `resetAll()`, `setBrightness`, and `reset(display:)`, which both real controllers share.
///
/// `@unchecked Sendable`, same pattern as `FakeDDCTransport`: state is protected by a lock rather than
/// actor isolation, because `ShadeDimmingController` is `@MainActor` and this fake must also satisfy
/// `GammaDimmingController`, which is not.
final class FakeSoftwareController: GammaDimmingController, ShadeDimmingController, @unchecked Sendable {
    let kind: BrightnessControllerKind
    private let lock = NSLock()
    private var _setBrightnessCalls: [(key: String, value: Float)] = []
    private var _resetCalls: [String] = []
    private var _resetAllCount = 0
    var probeResult: BrightnessProbeResult
    var log: CallLog?

    init(kind: BrightnessControllerKind, probeResult: BrightnessProbeResult) {
        self.kind = kind
        self.probeResult = probeResult
    }

    var setBrightnessCalls: [(key: String, value: Float)] { lock.withLock { _setBrightnessCalls } }
    var resetCalls: [String] { lock.withLock { _resetCalls } }
    var resetAllCount: Int { lock.withLock { _resetAllCount } }

    func probe(display: DisplayDevice) async -> BrightnessProbeResult { probeResult }
    func getBrightness(display: DisplayDevice) async throws -> Float { 1.0 }

    func setBrightness(_ value: Float, display: DisplayDevice) async throws {
        lock.withLock { _setBrightnessCalls.append((display.id, value)) }
        await log?.record("\(kind.rawValue).set:\(display.id):\(value)")
    }

    func reset(display: DisplayDevice) async {
        lock.withLock { _resetCalls.append(display.id) }
    }

    func resetAll() { lock.withLock { _resetAllCount += 1 } }
    func prune(keeping live: Set<CGDirectDisplayID>) {}
    func reapplyAll() {}
    func reposition(displays: [DisplayDevice]) {}
}

// MARK: - Shared test helpers

/// Builds a coordinator wired to fakes instead of real hardware/window/gamma-table access, with a
/// short retry ladder so tests never wait out real seconds.
@MainActor
func makeTestCoordinator(
    gammaProbe: BrightnessProbeResult = BrightnessProbeResult(
        isSupported: true, kind: .gamma, currentValue: 1.0, detail: "fake gamma: available"),
    shadeProbe: BrightnessProbeResult = BrightnessProbeResult(
        isSupported: true, kind: .shade, currentValue: 1.0, detail: "fake shade: always available"),
    retryDelays: [Duration] = Array(repeating: .milliseconds(5), count: 4)
) -> (
    coordinator: BrightnessCoordinator, ddc: FakeDDCController, gamma: FakeSoftwareController,
    shade: FakeSoftwareController
) {
    let ddc = FakeDDCController()
    let gamma = FakeSoftwareController(kind: .gamma, probeResult: gammaProbe)
    let shade = FakeSoftwareController(kind: .shade, probeResult: shadeProbe)
    let coordinator = BrightnessCoordinator(ddc: ddc, gamma: gamma, shade: shade, retryDelays: retryDelays)
    return (coordinator, ddc, gamma, shade)
}

/// A fresh external display with a unique identity, so several can coexist in one test without
/// colliding on `DisplayDevice.id`.
func makeExternalDisplay(serial: UInt32 = 1, cgDisplayID: CGDirectDisplayID = 1) -> DisplayDevice {
    DisplayDevice(
        identity: DisplayIdentity(
            cgDisplayID: cgDisplayID, vendorID: 0x1234, productID: 0x5678,
            serialNumber: serial, keyTier: .strong),
        name: "Fake Display \(serial)", isBuiltIn: false, isOnline: true, isMain: false)
}

func nullDDCResult() -> BrightnessProbeResult {
    BrightnessProbeResult(
        isSupported: false, kind: .ddc, detail: "fake: null message", isTransient: false,
        isNullAnswer: true)
}

/// A DDC failure that is neither transient nor a null answer — proves the display has no DDC, so the
/// coordinator downgrades without arming a retry.
func unsupportedDDCResult() -> BrightnessProbeResult {
    BrightnessProbeResult(isSupported: false, kind: .ddc, detail: "fake: no DDC")
}

func supportedDDCResult(_ value: Float) -> BrightnessProbeResult {
    BrightnessProbeResult(isSupported: true, kind: .ddc, currentValue: value, detail: "fake: ok")
}

/// Polls `probeCallCounts[key]` until it reaches `count`, so a test can wait for the async retry
/// ladder to finish without a fixed sleep.
func waitForDDCProbeCount(
    _ ddc: FakeDDCController, key: String, atLeast count: Int, timeout: Duration = .seconds(2)
) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await (ddc.probeCallCounts[key] ?? 0) >= count { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}
