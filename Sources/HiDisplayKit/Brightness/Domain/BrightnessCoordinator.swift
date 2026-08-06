import Combine
import Foundation

/// The one place that decides what happens when brightness changes.
///
/// Responsibilities kept here rather than in the UI:
/// * pick a controller per display, honouring a user override;
/// * show the requested value immediately and reconcile with hardware afterwards;
/// * drop work belonging to a connection that has ended;
/// * provide one emergency reset that undoes all software dimming.
@MainActor
public final class BrightnessCoordinator: ObservableObject {

    /// Per-display brightness as the UI should render it, keyed by stable display key.
    @Published public private(set) var states: [String: BrightnessState] = [:]
    /// Probe results, so Settings can explain why a display has the controller it has.
    @Published public private(set) var availability: [String: ControllerAvailability] = [:]
    @Published public private(set) var probeDetails: [String: [BrightnessControllerKind: String]] = [:]
    /// Set when a user override could not be honoured.
    @Published public private(set) var warnings: [String: String] = [:]

    /// What the UI says instead of offering a control for the built-in panel.
    public static let builtInExplanation =
        "macOS manages the built-in display. HiDisplay only adjusts external monitors."

    /// Retained although the coordinator no longer selects it: `hidisplay-probe` reports what
    /// DisplayServices would do, and that is the evidence behind `docs/private-apis.md`.
    private let native = NativeBrightnessController()
    private let ddc = DDCBrightnessController()
    private let gamma = GammaBrightnessController()
    private let shade = ShadeBrightnessController()

    private var userOverrides: [String: BrightnessControllerKind] = [:]
    private var chosen: [String: BrightnessControllerKind] = [:]
    /// Monotonic per-display counter. Async work stamped with an old value is discarded, which is how
    /// a probe or restore belonging to a previous connection is prevented from writing into the new
    /// one — the failure mode where unplugging and replugging mid-probe applies a stale brightness.
    private var connectionEpoch: [String: Int] = [:]

    public init() {}

    // MARK: - Configuration

    public func setUserOverride(_ kind: BrightnessControllerKind?, for display: DisplayDevice) {
        if let kind {
            userOverrides[display.id] = kind
        } else {
            userOverrides.removeValue(forKey: display.id)
        }
        Task { await probeAndChoose(display: display) }
    }

    public func userOverride(for key: String) -> BrightnessControllerKind? { userOverrides[key] }
    public func controller(for key: String) -> BrightnessControllerKind? { chosen[key] }

    // MARK: - Lifecycle

    /// Handles a settled display configuration: probes new displays, drops departed ones.
    ///
    /// Called from `DisplayDiscoveryService.settled` rather than on every reconfiguration callback,
    /// because a display often appears before its DDC bus answers.
    public func handleSettledDisplays(_ displays: [DisplayDevice], restore: (String) -> Float?) async {
        let liveKeys = Set(displays.map(\.id))

        // Tear down anything that left, before probing what arrived: a departed display's queue must
        // stop retrying before new work is queued behind it.
        for key in states.keys where !liveKeys.contains(key) {
            connectionEpoch[key, default: 0] += 1
            states.removeValue(forKey: key)
            availability.removeValue(forKey: key)
            warnings.removeValue(forKey: key)
            chosen.removeValue(forKey: key)
        }
        await ddc.invalidateAll(except: liveKeys)

        for display in displays {
            await probeAndChoose(display: display)
            if let saved = restore(display.id) {
                await setBrightness(saved, for: display)
            }
        }
    }

    public func handleDisplaysChanged(_ displays: [DisplayDevice]) {
        // Cheap, synchronous work only — this runs on the fast path.
        shade.reposition(displays: displays)
        reapplySoftwareDimming()
    }

    /// Puts software dimming back after macOS has reset it.
    ///
    /// A display reconfiguration — a resolution change is one — clears the gamma ramp, so a dimmed
    /// display snaps to full brightness. Restoring it from `handleSettledDisplays` meant waiting out
    /// the two-second settle delay, which the user saw as a bright flash on every resolution change.
    ///
    /// Only software dimming needs this. A DDC or native controller holds its value in the monitor,
    /// not in a table macOS owns, and re-issuing DDC writes on every reconfiguration would be slow and
    /// would put traffic on the bus for no reason.
    public func reapplySoftwareDimming() {
        gamma.reapplyAll()
    }

    // MARK: - Probing

    /// Backoff before each DDC re-probe after a transient failure. The settled callback fires while a
    /// just-woken monitor may still be re-registering its attributes and waking its I2C bus; these
    /// bounded attempts cover that window without polling forever, and any newer probe or a
    /// disconnect cancels them through the epoch check.
    private static let ddcRetrySeconds = [2, 5, 10]

    public func probeAndChoose(display: DisplayDevice) async {
        await probeAndChoose(display: display, ddcRetryAttempt: 0)
    }

    private func probeAndChoose(display: DisplayDevice, ddcRetryAttempt: Int) async {
        let epoch = bumpEpoch(for: display.id)

        // A built-in panel is not probed at all. Probing it would mean reading, and eventually
        // writing, a value macOS already owns — and the gamma and shade probes are not free of side
        // effects. `Self.builtInExplanation` is what Settings shows in place of a controller.
        guard !display.isBuiltIn else {
            availability[display.id] = ControllerAvailability(
                native: false, ddc: false, gamma: false, shade: false)
            probeDetails[display.id] = Dictionary(
                uniqueKeysWithValues: BrightnessControllerKind.allCases.map {
                    ($0, Self.builtInExplanation)
                })
            chosen.removeValue(forKey: display.id)
            states.removeValue(forKey: display.id)
            warnings.removeValue(forKey: display.id)
            return
        }

        // Probes run sequentially rather than concurrently: the DDC probe is the only slow one, and
        // running gamma/shade probes against the same display in parallel gains nothing while making
        // the log order unreadable when debugging a monitor that misbehaves.
        // Only built-in panels ever answered a native probe, and those no longer reach this line. The
        // result is kept in the report so Settings and the diagnostics export still show a row for
        // every controller rather than a gap.
        let nativeResult = BrightnessProbeResult(
            isSupported: false, kind: .native, detail: "not an Apple-attached panel")
        let ddcResult = await ddc.probe(display: display)
        let gammaResult = await gamma.probe(display: display)
        let shadeResult = await shade.probe(display: display)

        guard isCurrent(epoch: epoch, for: display.id) else {
            Log.brightness.debug("discarding stale probe for \(display.id, privacy: .public)")
            return
        }

        let found = ControllerAvailability(
            native: nativeResult.isSupported,
            ddc: ddcResult.isSupported,
            gamma: gammaResult.isSupported,
            shade: shadeResult.isSupported)
        availability[display.id] = found
        probeDetails[display.id] = [
            .native: nativeResult.detail,
            .ddc: ddcResult.detail,
            .gamma: gammaResult.detail,
            .shade: shadeResult.detail,
        ]

        let decision = BrightnessControllerResolver.resolve(
            display: display, availability: found, userOverride: userOverrides[display.id])
        let previousKind = chosen[display.id]
        chosen[display.id] = decision.kind
        // When hardware control takes over from software dimming — a DDC retry succeeding after the
        // monitor finished waking is the common case — the software effect must be undone, or the
        // display stays dimmed by a gamma ramp or shade underneath its now-DDC-controlled backlight.
        if let previousKind, !previousKind.isHardware, decision.kind != previousKind {
            await controllerInstance(previousKind).reset(display: display)
            // The reset suspends off the main actor, so a teardown can interleave here; without this
            // re-check the writes below would resurrect state for a display that just departed.
            // Resetting a departed display's software dimming above is itself harmless.
            guard isCurrent(epoch: epoch, for: display.id) else { return }
        }
        if let reason = decision.overrideIgnoredReason {
            warnings[display.id] = reason
        } else {
            warnings.removeValue(forKey: display.id)
        }

        // Seed the UI from whatever the chosen controller reported, so the slider starts at the
        // display's real brightness instead of jumping when first touched.
        let seed: Float
        switch decision.kind {
        case .native: seed = nativeResult.currentValue ?? 1.0
        case .ddc: seed = ddcResult.currentValue ?? 1.0
        case .gamma: seed = gammaResult.currentValue ?? 1.0
        case .shade: seed = shadeResult.currentValue ?? 1.0
        case nil: seed = 1.0
        }
        states[display.id] = BrightnessState(
            requestedValue: seed, effectiveValue: seed, controller: decision.kind ?? .shade)

        Log.brightness.debug(
            "\(display.id, privacy: .public): controller=\(decision.kind?.rawValue ?? "none", privacy: .public)")

        scheduleDDCRetryIfNeeded(
            for: display, after: ddcResult, attempt: ddcRetryAttempt, epoch: epoch)
    }

    /// Re-probes after a transient DDC failure instead of leaving the display on software dimming
    /// until the next reconfiguration.
    ///
    /// This is the recovery for a monitor sleep/wake: the settled probe races the display's
    /// re-registration and loses — the bind finds no matching display unit, or the bound transport
    /// times out against an I2C bus that is not answering yet — and without a retry the downgrade to
    /// software dimming is permanent, because nothing else ever probes DDC again.
    private func scheduleDDCRetryIfNeeded(
        for display: DisplayDevice, after ddcResult: BrightnessProbeResult, attempt: Int, epoch: Int
    ) {
        guard !ddcResult.isSupported, ddcResult.isTransient,
              attempt < Self.ddcRetrySeconds.count else { return }
        let seconds = Self.ddcRetrySeconds[attempt]
        Log.brightness.notice(
            "\(display.id, privacy: .public): DDC probe failed transiently (\(ddcResult.detail, privacy: .public)); retrying in \(seconds)s (attempt \(attempt + 1)/\(Self.ddcRetrySeconds.count))")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, self.isCurrent(epoch: epoch, for: display.id) else { return }
            await self.probeAndChoose(display: display, ddcRetryAttempt: attempt + 1)
        }
    }

    // MARK: - Setting

    /// Applies a brightness value. Updates published state synchronously so the slider tracks the
    /// user's finger, then hands the value to the controller without waiting for it.
    public func setBrightness(_ value: Float, for display: DisplayDevice) async {
        let clamped = min(max(value, 0), 1)
        guard let kind = chosen[display.id] else { return }

        states[display.id] = BrightnessState(
            requestedValue: clamped, effectiveValue: clamped, controller: kind)

        let epoch = connectionEpoch[display.id] ?? 0
        do {
            try await controllerInstance(kind).setBrightness(clamped, display: display)
        } catch {
            guard isCurrent(epoch: epoch, for: display.id) else { return }
            Log.brightness.notice(
                "\(display.id, privacy: .public): \(kind.rawValue, privacy: .public) set failed: \(String(describing: error), privacy: .public)")
            // A hardware controller that starts failing mid-session (monitor asleep, cable pulled) is
            // re-probed so the app drops to a working fallback rather than silently doing nothing.
            if kind.isHardware {
                await probeAndChoose(display: display)
            }
        }
    }

    public func brightness(for key: String) -> Float { states[key]?.requestedValue ?? 1.0 }

    // MARK: - Emergency reset

    /// Undoes every software dimming effect immediately.
    ///
    /// Deliberately does *not* touch native or DDC brightness: those are the display's real settings,
    /// and an "emergency reset" that also blasted the monitor's own backlight to full would be a
    /// surprise rather than a rescue. What it fixes is the failure the user cannot otherwise escape —
    /// a screen left dark by gamma or a shade overlay.
    public func resetAllDimming() {
        gamma.resetAll()
        shade.resetAll()
        for (key, state) in states {
            states[key] = BrightnessState(
                requestedValue: 1.0, effectiveValue: 1.0, controller: state.controller)
        }
        Log.recovery.notice("emergency reset: all software dimming cleared")
    }

    /// Clean-quit cleanup. Same as the emergency reset, minus the log noise.
    public func prepareForQuit() {
        gamma.resetAll()
        shade.resetAll()
    }

    // MARK: - Internals

    private func controllerInstance(_ kind: BrightnessControllerKind) -> BrightnessController {
        switch kind {
        case .native: return native
        case .ddc: return ddc
        case .gamma: return gamma
        case .shade: return shade
        }
    }

    private func bumpEpoch(for key: String) -> Int {
        let next = (connectionEpoch[key] ?? 0) + 1
        connectionEpoch[key] = next
        return next
    }

    private func isCurrent(epoch: Int, for key: String) -> Bool {
        (connectionEpoch[key] ?? 0) == epoch
    }
}
