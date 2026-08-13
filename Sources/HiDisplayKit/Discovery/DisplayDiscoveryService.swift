import Combine
import CoreGraphics
import Foundation

/// Enumerates displays and republishes the list whenever the display configuration changes.
///
/// Two separate signals come out of this, on purpose:
///
/// * `displays` updates quickly (short debounce) so the menu never shows a monitor that is gone.
/// * `settled` fires after a longer grace period, and is what brightness restoration waits on. A
///   display frequently appears in `CGGetOnlineDisplayList` before its DDC bus will answer, so
///   restoring brightness on the fast signal produces timeouts and, on some monitors, a command
///   storm as retries pile up.
@MainActor
public final class DisplayDiscoveryService: ObservableObject {

    @Published public private(set) var displays: [DisplayDevice] = []
    /// Pairings the resolver was not sure about; the UI should offer to confirm these.
    @Published public private(set) var ambiguousKeys: Set<String> = []

    /// Fires once the configuration has stopped changing. Payload is the settled display list.
    public let settled = PassthroughSubject<[DisplayDevice], Never>()

    /// Fires the moment a reconfiguration lands, with no debounce and no display list.
    ///
    /// For work that must happen before the user can see the gap and that is too cheap to be worth
    /// coalescing — restoring a gamma ramp macOS just cleared. Anything that needs to *read* the new
    /// configuration must use `settled` instead; this fires while the list is still in flux, which is
    /// why it carries no payload.
    public let reconfigured = PassthroughSubject<Void, Never>()

    /// Fast enough that unplugging feels instant, slow enough to collapse the burst of callbacks a
    /// single replug produces (macOS emits several per display, per change flag).
    public var refreshDebounce: TimeInterval = 0.35
    /// Empirical grace period before the DDC bus is reliably up after a reconnect.
    public var settleDelay: TimeInterval = 2.0

    private let metadataBackend: DisplayMetadataBackend
    private var userAssignments: [String: UUID] = [:]
    private var refreshWorkItem: DispatchWorkItem?
    private var settleWorkItem: DispatchWorkItem?
    private var isRegistered = false

    /// Stamps every snapshot at the moment it starts. Bumped whenever the world may have moved past
    /// an in-flight snapshot — a reconfiguration callback, a synchronous `refreshNow`, `stop()` —
    /// so a background result that raced one of those is discarded instead of published stale.
    private var snapshotGeneration = 0
    /// True from a reconfiguration callback until the next snapshot publishes. When still false at
    /// settle time, the debounced refresh already saw everything and the settle can reuse its list
    /// instead of enumerating a second time.
    private var needsRefresh = false
    /// Set when settle fires while a snapshot is still due or in flight; the next publish that
    /// survives the generation check fires `settled` with the list it just published. This is what
    /// guarantees a settle event is never dropped — even a synchronous `refreshNow` landing in
    /// that window consumes it, correctly, with a strictly newer list.
    private var settlePending = false

    public init(metadataBackend: DisplayMetadataBackend = CompositeDisplayMetadataBackend()) {
        self.metadataBackend = metadataBackend
    }

    deinit {
        // Cannot touch main-actor state from deinit; the callback holds an unretained pointer, so
        // unregistering is the caller's job via `stop()`. Left as a no-op rather than doing something
        // unsound here.
    }

    public func start() {
        guard !isRegistered else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let error = CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, context)
        if error == .success {
            isRegistered = true
        } else {
            Log.discovery.error("CGDisplayRegisterReconfigurationCallback failed: \(error.rawValue)")
        }
        refreshNow()
    }

    public func stop() {
        guard isRegistered else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, context)
        isRegistered = false
        refreshWorkItem?.cancel()
        settleWorkItem?.cancel()
        // Discard any in-flight snapshot and the settle waiting on it: this is the quit path, and
        // a result landing after teardown must not republish or fire a late `settled`.
        snapshotGeneration += 1
        settlePending = false
    }

    public func setUserAssignments(_ assignments: [String: UUID]) {
        userAssignments = assignments
        refreshNow()
    }

    /// Coalesces a burst of reconfiguration callbacks into one refresh, then schedules the settle
    /// signal. Both timers are rescheduled from scratch each time, so a long series of changes
    /// (unplugging a dock, waking with three monitors) produces exactly one settle event at the end.
    func scheduleRefresh() {
        refreshWorkItem?.cancel()
        settleWorkItem?.cancel()
        // The world just moved: any snapshot already in flight predates this callback, and letting
        // it publish would show a pre-callback list (and clear `needsRefresh` under the settle).
        snapshotGeneration += 1
        needsRefresh = true
        // A settle still waiting on a snapshot is obsolete too — this callback just rescheduled a
        // new one. Carrying the flag over would let the *debounced* publish fire `settled` a few
        // hundred milliseconds after the burst, inside the DDC grace window the settle delay exists
        // to provide.
        settlePending = false

        // Before either timer: a reconfiguration has already cleared any gamma ramp the app applied,
        // so every millisecond spent debouncing is a millisecond of a display sitting at full
        // brightness. Subscribers to this must do only cheap, write-only work.
        reconfigured.send()

        let refresh = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refreshInBackground() }
        }
        refreshWorkItem = refresh
        DispatchQueue.main.asyncAfter(deadline: .now() + refreshDebounce, execute: refresh)

        let settle = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Both timers reset on every callback, so by construction no callback arrived
                // since the debounced refresh. When its snapshot has already published, this list
                // is current and enumerating a second time buys nothing. When it has not —
                // superseded, or still running — flag the settle and let the next publish fire it.
                if self.needsRefresh {
                    self.settlePending = true
                    self.refreshInBackground()
                } else {
                    self.sendSettled()
                }
            }
        }
        settleWorkItem = settle
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: settle)
    }

    /// Synchronous refresh, for the callers that read `displays` on the next line — `start()`,
    /// `setUserAssignments`, and the resolution-change path. Publishing here also supersedes any
    /// in-flight background snapshot: it would land with an older view than this one.
    public func refreshNow() {
        snapshotGeneration += 1
        publish(Self.snapshot(metadataBackend: metadataBackend, userAssignments: userAssignments))
    }

    /// Enumerates off the main actor and publishes back on it.
    ///
    /// The snapshot is IORegistry scans plus per-display mode enumeration — tens of milliseconds
    /// that used to block the menu bar during every replug burst. The CoreGraphics display queries
    /// involved are read-only WindowServer IPC with no formal thread-safety guarantee from Apple;
    /// ecosystem precedent treats them as safe off-main, and a display vanishing mid-snapshot
    /// degrades to empty modes/nil bounds rather than corrupting anything.
    private func refreshInBackground() {
        let generation = snapshotGeneration
        let backend = metadataBackend
        let assignments = userAssignments
        Task.detached(priority: .userInitiated) { [weak self] in
            let resolved = DisplayDiscoveryService.snapshot(
                metadataBackend: backend, userAssignments: assignments)
            guard let self else { return }
            await self.applySnapshot(resolved, ifCurrent: generation)
        }
    }

    private func applySnapshot(_ resolved: [Snapshot], ifCurrent generation: Int) {
        // A stale result is dropped whole: something newer either published already or is about
        // to, and `settlePending` — if set — survives for that newer publish to consume.
        guard generation == snapshotGeneration else { return }
        publish(resolved)
    }

    private func publish(_ resolved: [Snapshot]) {
        needsRefresh = false
        displays = resolved.map(\.device)
        ambiguousKeys = Set(resolved.filter { $0.pairing == .ambiguous }.map(\.device.id))
        if !ambiguousKeys.isEmpty {
            Log.discovery.notice("\(self.ambiguousKeys.count, privacy: .public) display(s) need the user to confirm identity")
        }
        if settlePending {
            settlePending = false
            sendSettled()
        }
    }

    private func sendSettled() {
        Log.discovery.debug("display configuration settled with \(self.displays.count) display(s)")
        settled.send(displays)
    }

    // MARK: - Snapshot

    public struct Snapshot: Sendable {
        public var device: DisplayDevice
        public var pairing: PairingConfidence
    }

    /// Pure-ish read of the current configuration. Static so it can be called before `start()` and so
    /// it has no dependency on published state; `nonisolated` because the debounced refresh runs it
    /// off the main actor — nothing in here may touch published state or AppKit.
    nonisolated public static func snapshot(
        metadataBackend: DisplayMetadataBackend,
        userAssignments: [String: UUID]
    ) -> [Snapshot] {
        let raws = onlineDisplays()
        let metadata = metadataBackend.enumerate()
        let resolved = DisplayIdentityResolver.resolve(
            displays: raws, metadata: metadata, userAssignments: userAssignments)

        let mainID = CGMainDisplayID()

        return resolved.map { entry in
            let displayID = entry.identity.cgDisplayID
            let modes = DisplayModeService.modes(for: displayID)
            let current = DisplayModeService.currentMode(for: displayID)
            let isBuiltIn = raws.first { $0.cgDisplayID == displayID }?.isBuiltIn ?? false

            var capabilities = DisplayCapabilities()
            capabilities.supportsNativeBrightness = isBuiltIn
            // DDC is only a *candidate* here; the real answer comes from a probe. Marking it true for
            // every external display up front would make the UI promise hardware control that may
            // not exist, so it stays false until `BrightnessProbe` says otherwise.
            capabilities.supportsDDC = false
            capabilities.supportsSoftwareDimming = true
            capabilities.supportsShadeDimming = true
            // A HiDPI override needs a real vendor+product to name the override directory.
            capabilities.supportsHiDPIOverride =
                !isBuiltIn && entry.identity.vendorID != 0 && entry.identity.productID != 0

            let device = DisplayDevice(
                identity: entry.identity,
                name: displayName(for: entry, isBuiltIn: isBuiltIn),
                isBuiltIn: isBuiltIn,
                isOnline: true,
                isMain: displayID == mainID,
                isMirrored: CGDisplayMirrorsDisplay(displayID) != kCGNullDirectDisplay,
                currentMode: current,
                availableModes: modes,
                capabilities: capabilities,
                frame: CGDisplayBounds(displayID)
            )
            return Snapshot(device: device, pairing: entry.pairing)
        }
    }

    nonisolated static func displayName(for entry: ResolvedDisplay, isBuiltIn: Bool) -> String {
        if let name = entry.metadata?.productName, !name.isEmpty { return name }
        if isBuiltIn { return "Built-in Display" }
        // Last resort: a vendor/product label is more useful for support than "Unknown Display",
        // because it is the same identifier that names the override directory.
        return String(format: "Display %04X:%04X", entry.identity.vendorID, entry.identity.productID)
    }

    nonisolated static func onlineDisplays() -> [RawDisplayInfo] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }

        return ids.prefix(Int(count)).map { id in
            RawDisplayInfo(
                cgDisplayID: id,
                vendorID: CGDisplayVendorNumber(id),
                productID: CGDisplayModelNumber(id),
                serialNumber: CGDisplaySerialNumber(id),
                unitNumber: CGDisplayUnitNumber(id),
                isBuiltIn: CGDisplayIsBuiltin(id) != 0
            )
        }
    }
}

/// C callback trampoline. Runs on the main thread (CoreGraphics guarantees this for
/// reconfiguration callbacks), and does nothing but hop into the debouncer — any real work here
/// would run while the display configuration is still mid-change.
private let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
    guard let userInfo else { return }
    // Ignore the "about to change" half of every event pair; acting on it means reading a
    // configuration that is guaranteed to be stale one moment later.
    guard !flags.contains(.beginConfigurationFlag) else { return }
    let service = Unmanaged<DisplayDiscoveryService>.fromOpaque(userInfo).takeUnretainedValue()
    MainActor.assumeIsolated { service.scheduleRefresh() }
}
