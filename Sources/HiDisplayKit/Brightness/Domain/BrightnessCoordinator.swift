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
    private let ddc: DDCControlling
    private let gamma: GammaDimmingController
    private let shade: ShadeDimmingController

    private var userOverrides: [String: BrightnessControllerKind] = [:]
    private var chosen: [String: BrightnessControllerKind] = [:]
    /// The user's saved brightness for a display key, supplied by the app.
    ///
    /// Every path that resolves a controller re-asserts this value, so the app never adopts whatever
    /// a display happens to report — a monitor that comes back from sleep on its own OSD brightness
    /// would otherwise make that wrong value the new truth.
    public var savedBrightnessLookup: ((String) -> Float?)?
    /// Monotonic per-display counter. Async work stamped with an old value is discarded, which is how
    /// a probe or restore belonging to a previous connection is prevented from writing into the new
    /// one — the failure mode where unplugging and replugging mid-probe applies a stale brightness.
    private var connectionEpoch: [String: Int] = [:]
    /// Display keys with proof of working DDC: persisted session facts seeded at settle, or a DDC
    /// probe that succeeded this session. Evidence changes how failure is read — on a monitor known
    /// to speak DDC, a null answer or an exhausted retry ladder means "still booting", not "no DDC",
    /// so the display is never downgraded to software dimming it would visibly flash out of later.
    private var ddcEvidence: Set<String> = []
    /// Displays currently *held* for DDC: evidence says the monitor speaks DDC, the last probe
    /// failed anyway, and no software dimming has been applied. Kept as state rather than re-derived
    /// because two other paths need the answer: the wake reassert must not dim a held display, and a
    /// user brightness action on one is the recovery trigger — see `setBrightness`.
    private var heldForDDC: Set<String> = []

    /// Backoff before each DDC re-probe after a transient failure, held per instance rather than as a
    /// static so tests can inject a short ladder instead of waiting out real seconds. The settled
    /// callback fires while a just-woken monitor may still be re-registering its attributes and waking
    /// its I2C bus; these bounded attempts cover that window without polling forever, and any newer
    /// probe or a disconnect cancels them through the epoch check. The default 20s tail exists for
    /// login after a cold boot, where the app's first probe races monitor firmware that takes far
    /// longer to bring its DDC up than a wake does — each attempt is one read on an otherwise idle bus,
    /// so the extra step costs nothing when the earlier ones succeed.
    private let retryDelays: [Duration]
    static let defaultRetryDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(10), .seconds(20)]

    /// Production path: the real controllers and the real retry ladder.
    public convenience init() {
        self.init(
            ddc: DDCBrightnessController(), gamma: GammaBrightnessController(),
            shade: ShadeBrightnessController())
    }

    /// Test seam. Not `public`: the app always goes through the no-argument `init()`, and only the
    /// test target — via `@testable import` — needs to substitute fakes for the controllers and a
    /// short ladder for the retry delays.
    init(
        ddc: DDCControlling, gamma: GammaDimmingController, shade: ShadeDimmingController,
        retryDelays: [Duration] = BrightnessCoordinator.defaultRetryDelays
    ) {
        self.ddc = ddc
        self.gamma = gamma
        self.shade = shade
        self.retryDelays = retryDelays
    }

    /// Whether a display is currently held for DDC — evidence says it speaks DDC, the last probe
    /// failed anyway, and no software dimming has been applied. Exposed (internal, not public) so
    /// tests can observe the hold directly instead of inferring it from the absence of a write.
    func isHeld(_ key: String) -> Bool { heldForDDC.contains(key) }

    // MARK: - Configuration

    public func setUserOverride(_ kind: BrightnessControllerKind?, for display: DisplayDevice) {
        if let kind {
            userOverrides[display.id] = kind
        } else {
            userOverrides.removeValue(forKey: display.id)
        }
        Task { await probeAndChoose(display: display) }
    }

    /// Records a saved override without probing.
    ///
    /// For settle time, when the override and the probe both come from the same event: seeding first
    /// lets the one probe in `handleSettledDisplays` resolve against it. Routing through
    /// `setUserOverride` instead re-probed every display that had a saved controller — two full DDC
    /// cycles on the bus per settle, and the brightness restore in between ran on the wrong
    /// controller.
    public func seedUserOverride(_ kind: BrightnessControllerKind?, for key: String) {
        if let kind {
            userOverrides[key] = kind
        } else {
            userOverrides.removeValue(forKey: key)
        }
    }

    /// Hands persisted DDC session facts to the DDC controller, ahead of the session being created.
    ///
    /// Facts only ever exist for a display whose DDC answered in a previous session, so seeding them
    /// is also the evidence that makes probe failures read as transient — see `ddcEvidence`.
    public func seedDDCFacts(_ facts: DDCSessionFacts, for key: String) async {
        ddcEvidence.insert(key)
        await ddc.seedFacts(facts, for: key)
    }

    /// What the live DDC session has learned about a display, for persisting.
    public func ddcFacts(for key: String) async -> DDCSessionFacts? {
        await ddc.facts(for: key)
    }

    public func userOverride(for key: String) -> BrightnessControllerKind? { userOverrides[key] }
    public func controller(for key: String) -> BrightnessControllerKind? { chosen[key] }

    // MARK: - Lifecycle

    /// Handles a settled display configuration: probes new displays, drops departed ones.
    ///
    /// Called from `DisplayDiscoveryService.settled` rather than on every reconfiguration callback,
    /// because a display often appears before its DDC bus answers.
    public func handleSettledDisplays(_ displays: [DisplayDevice]) async {
        let liveKeys = Set(displays.map(\.id))

        // Tear down anything that left, before probing what arrived: a departed display's queue must
        // stop retrying before new work is queued behind it.
        for key in states.keys where !liveKeys.contains(key) {
            connectionEpoch[key, default: 0] += 1
            states.removeValue(forKey: key)
            availability.removeValue(forKey: key)
            warnings.removeValue(forKey: key)
            chosen.removeValue(forKey: key)
            heldForDDC.remove(key)
        }
        gamma.prune(keeping: Set(displays.map(\.cgDisplayID)))
        await ddc.invalidateAll(except: liveKeys)

        // Displays probe concurrently: each has its own DDC queue and its own bus, so nothing is
        // shared across them, and waiting for one monitor's slow probe before starting the next
        // made settle-to-ready scale with display count. Within one display the probe order stays
        // sequential — see `probeAndChoose`.
        await withTaskGroup(of: Void.self) { group in
            for display in displays {
                group.addTask { await self.probeAndChoose(display: display) }
            }
        }
    }

    /// Handles screens waking, which is not a display reconfiguration and produces no settle.
    ///
    /// Two things happen, in this order, and the order is the point. The saved value is re-asserted
    /// first, on the controller the display already had: a monitor that came back on its own OSD
    /// brightness is then corrected by one DDC write, instead of staying wrong until a probe — and,
    /// when the wake does reconfigure displays, the two-second settle behind it — has finished. That
    /// gap is what the user sees as the screen waking too bright or too dark and snapping back a
    /// moment later. Then the display is re-probed, because a sleep/wake can swap the IOAVService
    /// underneath a live session without any display ever disconnecting.
    public func handleScreensDidWake(_ displays: [DisplayDevice]) async {
        // Concurrently, same as the settle path: each display has its own queue and bus, and waking
        // three monitors serially tripled the time to working sliders.
        await withTaskGroup(of: Void.self) { group in
            for display in displays where !display.isBuiltIn {
                group.addTask {
                    await self.reassertSavedBrightnessOptimistically(for: display)
                    await self.probeAndChoose(display: display)
                }
            }
        }
    }

    /// Writes the saved value on the controller chosen before the sleep, without waiting for a probe.
    ///
    /// Fire-and-forget on purpose. The transport may have gone stale while the monitor slept, in
    /// which case this write fails silently — and the probe that follows rebinds it and re-asserts
    /// the value properly. Nothing is lost by trying first, and on the common path where the session
    /// survived, the correction lands before the panel has finished lighting up.
    private func reassertSavedBrightnessOptimistically(for display: DisplayDevice) async {
        guard let kind = chosen[display.id], let saved = savedBrightnessLookup?(display.id) else {
            return
        }
        // A software controller on a held display is a hold, not a choice — see `probeAndChoose`.
        // Optimistically dimming it here would apply the software dim the hold exists to avoid; the
        // probe this returns into re-asserts the value once DDC answers.
        if heldForDDC.contains(display.id) { return }
        states[display.id] = BrightnessState(
            requestedValue: saved, effectiveValue: saved, controller: kind)
        // Errors are swallowed rather than re-probed here: the probe this returns into is that
        // recovery already, and running a second one would put a redundant read on the bus.
        try? await controllerInstance(kind).setBrightness(saved, display: display)
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

    public func probeAndChoose(display: DisplayDevice) async {
        await probeAndChoose(display: display, ddcRetryAttempt: 0)
    }

    /// - Parameter reassertSaved: false only on the re-probe that follows a failed write, where
    ///   putting the value back would call straight into the write that just failed and could
    ///   bounce between the two indefinitely.
    private func probeAndChoose(
        display: DisplayDevice, ddcRetryAttempt: Int, reassertSaved: Bool = true
    ) async {
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

        if ddcResult.isSupported { ddcEvidence.insert(display.id) }

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

        Log.brightness.debug(
            "\(display.id, privacy: .public): controller=\(decision.kind?.rawValue ?? "none", privacy: .public)")

        // Armed before anything is shown or written, because a pending retry means this display's
        // controller is provisional — it is on a software fallback only until the monitor's DDC bus
        // finishes waking — and both of the steps below depend on knowing that.
        let retryPending = scheduleDDCRetryIfNeeded(
            for: display, after: ddcResult, attempt: ddcRetryAttempt, epoch: epoch)

        // A display with DDC evidence whose probe failed anyway is treated as provisional even after
        // the retry ladder runs dry. The alternative was the flash seen at cold boot: monitor
        // firmware outlasts the ladder, the display downgrades to gamma, the saved value dims it in
        // software *on top of* a backlight that already holds that value — and when a later settle
        // finds DDC again, lifting the ramp snaps the screen visibly bright. Holding means the
        // monitor keeps showing its own (correct) backlight value and the next settle or wake probe
        // picks DDC back up. An explicit user override to a *software* controller is honoured over
        // the evidence — the user chose that dimming, and skipping it would make the override do
        // nothing. An override to DDC holds like no override does: the user wants hardware control,
        // not a gamma stand-in.
        let holdingForDDC = !ddcResult.isSupported && ddcEvidence.contains(display.id)
            && userOverrides[display.id]?.isHardware != false
        if holdingForDDC {
            heldForDDC.insert(display.id)
        } else {
            heldForDDC.remove(display.id)
        }

        // What the chosen controller reported, so a display with no saved value starts the slider at
        // its real brightness instead of jumping when first touched.
        let probed: Float
        switch decision.kind {
        case .native: probed = nativeResult.currentValue ?? 1.0
        case .ddc: probed = ddcResult.currentValue ?? 1.0
        case .gamma: probed = gammaResult.currentValue ?? 1.0
        case .shade: probed = shadeResult.currentValue ?? 1.0
        case nil: probed = 1.0
        }
        let saved = savedBrightnessLookup?(display.id)
        // A provisional controller reports the brightness of a controller the display is about to
        // stop using — 100% from an unapplied shade, say — so showing it would bounce the slider to
        // full and back for the length of the retry ladder.
        let shown = ((retryPending || holdingForDDC) ? saved : nil) ?? probed
        states[display.id] = BrightnessState(
            requestedValue: shown, effectiveValue: shown, controller: decision.kind ?? .shade)

        // Put the user's value back rather than keeping what the probe read. That reading is what the
        // display reports *now*, which after a wake or a reconnect is often the monitor's own OSD
        // brightness — adopting it silently discards the value the user set.
        //
        // Not while a retry is pending or the display is held for DDC: dimming a provisional display
        // with a gamma ramp or a shade window, then undoing it when DDC comes back, is exactly the
        // flash on wake and boot this is meant to remove. Not either when the display already holds
        // the saved value, so a settle does not put a pointless write on every monitor's bus.
        guard reassertSaved, !retryPending, !holdingForDDC, decision.kind != nil,
              let saved, abs(saved - probed) > 0.0005 else { return }
        await setBrightness(saved, for: display)
    }

    /// Re-probes after a transient DDC failure instead of leaving the display on software dimming
    /// until the next reconfiguration.
    ///
    /// This is the recovery for a monitor sleep/wake: the settled probe races the display's
    /// re-registration and loses — the bind finds no matching display unit, or the bound transport
    /// times out against an I2C bus that is not answering yet — and without a retry the downgrade to
    /// software dimming is permanent, because nothing else ever probes DDC again.
    /// - Returns: true when a re-probe was armed, so the caller knows this display's controller is
    ///   provisional and must not be dimmed in software yet.
    private func scheduleDDCRetryIfNeeded(
        for display: DisplayDevice, after ddcResult: BrightnessProbeResult, attempt: Int, epoch: Int
    ) -> Bool {
        // A null answer is steady-state "no DDC" and deliberately not transient — except on the
        // very first probe after a settle or wake, where real hardware (VX2780-2K) has been seen
        // answering null for both shapes because its DDC firmware lags the link by a moment.
        // Granting exactly one delayed re-probe covers that; a second null is believed — unless the
        // display has DDC evidence. At login after a cold boot the same hardware answers null for
        // well past one retry, and believing it there downgraded a known-DDC monitor to software
        // dimming for the whole session. Evidence keeps a null on the ladder to the end; a display
        // that never spoke DDC still gets today's fast answer.
        let nullDeservesRetry = ddcResult.isNullAnswer
            && (attempt == 0 || ddcEvidence.contains(display.id))
        guard !ddcResult.isSupported, ddcResult.isTransient || nullDeservesRetry,
              attempt < retryDelays.count else { return false }
        let delay = retryDelays[attempt]
        let totalAttempts = retryDelays.count
        Log.brightness.notice(
            "\(display.id, privacy: .public): DDC probe failed transiently (\(ddcResult.detail, privacy: .public)); retrying in \(String(describing: delay), privacy: .public) (attempt \(attempt + 1)/\(totalAttempts))")
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, self.isCurrent(epoch: epoch, for: display.id) else { return }
            await self.probeAndChoose(display: display, ddcRetryAttempt: attempt + 1)
        }
        return true
    }

    // MARK: - Setting

    /// Applies a brightness value. Updates published state synchronously so the slider tracks the
    /// user's finger, then hands the value to the controller without waiting for it.
    public func setBrightness(_ value: Float, for display: DisplayDevice) async {
        let clamped = min(max(value, 0), 1)
        guard let kind = chosen[display.id] else { return }

        states[display.id] = BrightnessState(
            requestedValue: clamped, effectiveValue: clamped, controller: kind)

        // A user action on a held display doubles as the recovery trigger: past the retry ladder,
        // nothing else re-probes DDC until a settle or a wake, which a desk that never sleeps may
        // not produce for hours. The write below still goes through the software controller — the
        // user gets immediate feedback — and the probe then either moves control back to DDC
        // (resetting the software dim and re-asserting this value on the backlight) or, still
        // failing, re-enters the hold. One-shot by the `remove`: a drag's stream of values does not
        // become a stream of probes.
        let wasHeld = heldForDDC.remove(display.id) != nil

        let epoch = connectionEpoch[display.id] ?? 0
        do {
            try await controllerInstance(kind).setBrightness(clamped, display: display)
            if wasHeld, !kind.isHardware, isCurrent(epoch: epoch, for: display.id) {
                await probeAndChoose(display: display)
            }
        } catch {
            guard isCurrent(epoch: epoch, for: display.id) else { return }
            Log.brightness.notice(
                "\(display.id, privacy: .public): \(kind.rawValue, privacy: .public) set failed: \(String(describing: error), privacy: .public)")
            // A hardware controller that starts failing mid-session (monitor asleep, cable pulled) is
            // re-probed so the app drops to a working fallback rather than silently doing nothing.
            if kind.isHardware {
                await probeAndChoose(display: display, ddcRetryAttempt: 0, reassertSaved: false)
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
        // Only software-dimmed states move to 1.0 — those are the ones the resets above actually
        // changed. A DDC or native display's backlight was deliberately left alone, and faking its
        // state to 100% would show the wrong number and make the next key press step from a
        // phantom value instead of the real one.
        for (key, state) in states where !state.controller.isHardware {
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
