import AppKit
import Combine
import Foundation
import HiDisplayKit
import SwiftUI

/// Single source of truth for the UI.
///
/// Wires discovery → brightness → profiles together so no view has to know about display events, and
/// so all the ordering rules (probe after settle, persist after change, restore after probe) live in
/// one place rather than being re-derived per view.
@MainActor
final class AppModel: ObservableObject {

    static let version = "0.6.3"
    /// One instance for the process. `AppDelegate` needs to reach the same object the scene shows in
    /// order to tear down shade windows and flush profiles on quit.
    static let shared = AppModel()

    let discovery = DisplayDiscoveryService()
    let brightness = BrightnessCoordinator()
    let profiles = ProfileStore()

    @Published var displays: [DisplayDevice] = []
    @Published var ambiguousKeys: Set<String> = []
    /// Last diagnostics export path, shown in Settings after an export.
    @Published var lastExportPath: String?
    @Published var lastError: String?

    // MARK: Brightness keys

    @Published var brightnessKeysEnabled = false
    @Published var brightnessKeyTarget: BrightnessKeyTarget = .displayUnderMouse
    /// Mirrors the Accessibility permission so Settings can react without polling from the view.
    @Published var isAccessibilityTrusted = BrightnessKeyTap.isAccessibilityTrusted
    /// Login-item state, read from the system rather than stored — the user can change it in System
    /// Settings at any time, so a cached copy would go stale and lie to them.
    @Published var loginItemState: LoginItem.State = .disabled

    private let keyTap = BrightnessKeyTap()
    private let osd = BrightnessOSD()
    private var permissionTimer: Timer?

    /// App-level preferences live in UserDefaults rather than the profile store: they are not
    /// per-display, and they must be readable before any display has been enumerated.
    private enum DefaultsKey {
        static let keysEnabled = "brightnessKeysEnabled"
        static let keyTarget = "brightnessKeyTarget"
    }

    private var cancellables: Set<AnyCancellable> = []
    /// Cached so a slider change does not have to await the actor just to know the saved value.
    private var savedBrightness: [String: Float] = [:]

    init() {
        // SwiftUI does not propagate changes through a nested ObservableObject: views observe
        // `AppModel`, so `brightness`'s own `@Published` updates would never invalidate them. The
        // slider still worked (it keeps its own drag state and the binding writes straight through),
        // which is what made this easy to miss — but everything *asynchronous* was invisible: the
        // percentage after Reset Dimming, the controller label once a probe finished, the warning when
        // a hardware write failed and forced a re-probe.
        brightness.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        discovery.$displays
            .sink { [weak self] displays in
                guard let self else { return }
                self.displays = displays
                self.brightness.handleDisplaysChanged(displays)
            }
            .store(in: &cancellables)

        discovery.$ambiguousKeys
            .assign(to: &$ambiguousKeys)

        // Undebounced, so a dimmed display is not left at full brightness for the length of the
        // settle delay every time the resolution changes. Write-only and synchronous — see
        // `DisplayDiscoveryService.reconfigured`.
        discovery.reconfigured
            .sink { [weak self] in self?.brightness.reapplySoftwareDimming() }
            .store(in: &cancellables)

        discovery.settled
            .sink { [weak self] displays in
                Task { await self?.handleSettled(displays) }
            }
            .store(in: &cancellables)

        keyTap.onBrightnessKey = { [weak self] delta, allDisplays in
            self?.handleBrightnessKey(delta: delta, forceAllDisplays: allDisplays) ?? false
        }

        // A monitor sleep/wake cycle can replace a display's IOAVService without any display
        // reconfiguration event — the display never "disconnects", so discovery stays quiet while
        // the DDC session underneath is dead. Worse, if a probe ran while the monitor slept, the
        // display downgraded to software dimming, and nothing on that path ever re-probes. Screens
        // waking is the moment to re-check what every external display can actually do.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.screensDidWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    for display in self.displays where !display.isBuiltIn {
                        await self.brightness.probeAndChoose(display: display)
                    }
                }
            }
            .store(in: &cancellables)
    }

    func start() async {
        let defaults = UserDefaults.standard
        brightnessKeysEnabled = defaults.bool(forKey: DefaultsKey.keysEnabled)
        if let raw = defaults.string(forKey: DefaultsKey.keyTarget),
           let target = BrightnessKeyTarget(rawValue: raw) {
            brightnessKeyTarget = target
        }
        // Re-arm the tap on launch, but only if permission is still granted — the user may have
        // revoked it since, and starting must not re-prompt on every launch.
        if brightnessKeysEnabled, BrightnessKeyTap.isAccessibilityTrusted {
            keyTap.start()
        }
        isAccessibilityTrusted = BrightnessKeyTap.isAccessibilityTrusted
        loginItemState = LoginItem.state
        // Logged at launch because "does it actually open at login" is otherwise only observable by
        // rebooting, and a support report needs the answer without one.
        Log.app.notice("login item state: \(String(describing: self.loginItemState), privacy: .public)")

        await profiles.load()
        let assignments = await profiles.userAssignments()
        savedBrightness = Dictionary(
            uniqueKeysWithValues: await profiles.allProfiles().map { ($0.displayKey, $0.brightness) })

        // Feed user identity pins in before the first enumeration, so a pinned display is recognised
        // on the very first pass rather than being briefly treated as new.
        discovery.setUserAssignments(assignments)
        discovery.start()

        // The first configuration never produces a reconfiguration callback, so probe explicitly.
        await handleSettled(discovery.displays)
    }

    func stop() {
        osd.hide()
        keyTap.stop()
        permissionTimer?.invalidate()
        discovery.stop()
        brightness.prepareForQuit()
        // `applicationWillTerminate` is synchronous and the process exits the moment it returns, so
        // a fire-and-forget Task here almost never ran — any change still inside the save debounce
        // was lost on quit. Block for the flush instead, bounded so a wedged disk cannot hang
        // quitting. Detached on purpose: a plain Task would inherit the main actor this method
        // blocks, which is a deadlock.
        let flushed = DispatchSemaphore(value: 0)
        Task.detached { [profiles] in
            await profiles.flush()
            flushed.signal()
        }
        _ = flushed.wait(timeout: .now() + 2)
    }

    private func handleSettled(_ displays: [DisplayDevice]) async {
        // Restoration reads the cache rather than the actor: `handleSettledDisplays` needs a
        // synchronous lookup, and the cache is refreshed whenever a value is written.
        await brightness.handleSettledDisplays(displays) { [savedBrightness] key in
            savedBrightness[key]
        }
        for display in displays {
            if let saved = await profiles.profile(for: display.id)?.brightnessController {
                brightness.setUserOverride(saved, for: display)
            }
        }
    }

    // MARK: - Actions

    func setBrightness(_ value: Float, for display: DisplayDevice) {
        savedBrightness[display.id] = value
        Task {
            await brightness.setBrightness(value, for: display)
            await profiles.setBrightness(value, for: display)
        }
    }

    func setController(_ kind: BrightnessControllerKind?, for display: DisplayDevice) {
        brightness.setUserOverride(kind, for: display)
        Task { await profiles.setController(kind, for: display) }
    }

    /// Every display this app is allowed to drive. The built-in panel is macOS's — see
    /// `BrightnessControllerResolver.resolve`.
    var brightnessManagedDisplays: [DisplayDevice] { displays.filter { !$0.isBuiltIn } }

    /// Applies one value to every external display. The source is the main display when that is itself
    /// external, so "sync" means "match this screen" — but never the built-in one, whose value this app
    /// does not read: taking it as the source would push a default of 100% onto every monitor.
    func syncAllDisplays() {
        let managed = brightnessManagedDisplays
        let source = managed.first(where: \.isMain) ?? managed.first
        guard let source else { return }
        let value = brightness.brightness(for: source.id)
        for display in managed where display.id != source.id {
            setBrightness(value, for: display)
        }
    }

    func resetDimming() {
        brightness.resetAllDimming()
        for display in brightnessManagedDisplays {
            savedBrightness[display.id] = 1.0
            Task { await profiles.setBrightness(1.0, for: display) }
        }
        if let external = displays.first(where: { !$0.isBuiltIn }) {
            osd.show(value: 1.0, display: external)
        }
    }

    /// Confirms an ambiguous display as a distinct monitor, pinning its identity permanently.
    func pinIdentity(for display: DisplayDevice) {
        let uuid = UUID()
        Task {
            await profiles.assignIdentity(uuid, toHeuristicKey: display.id)
            let assignments = await profiles.userAssignments()
            discovery.setUserAssignments(assignments)
        }
    }

    // MARK: - Launch at login

    func setLaunchAtLogin(_ enabled: Bool) {
        loginItemState = LoginItem.set(enabled)
    }

    /// Re-reads the system's view. Called when Settings appears, because the user may have flipped the
    /// switch in System Settings while the app was running.
    func refreshLoginItemState() {
        loginItemState = LoginItem.state
    }

    // MARK: - Brightness keys

    func setBrightnessKeysEnabled(_ enabled: Bool) {
        brightnessKeysEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: DefaultsKey.keysEnabled)
        guard enabled else {
            keyTap.stop()
            permissionTimer?.invalidate()
            return
        }
        if !keyTap.start() {
            // Not yet trusted. Prompt, then watch for the grant — macOS posts no notification for this,
            // and the user has to leave the app to grant it, so polling briefly is the only way to pick
            // the permission up without making them toggle the switch again.
            BrightnessKeyTap.requestAccessibility()
            startWatchingForPermission()
        }
    }

    func setBrightnessKeyTarget(_ target: BrightnessKeyTarget) {
        brightnessKeyTarget = target
        UserDefaults.standard.set(target.rawValue, forKey: DefaultsKey.keyTarget)
    }

    private func startWatchingForPermission() {
        permissionTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                self.isAccessibilityTrusted = BrightnessKeyTap.isAccessibilityTrusted
                guard self.isAccessibilityTrusted else { return }
                timer.invalidate()
                if self.brightnessKeysEnabled { self.keyTap.start() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    /// Applies a brightness key press.
    ///
    /// - Returns: true when every adjusted display was external, which tells the tap it may consume the
    ///   event. Returning false keeps macOS in the loop so it can drive the built-in panel and show its
    ///   own HUD, rather than this app having to reimplement both.
    private func handleBrightnessKey(delta: Float, forceAllDisplays: Bool) -> Bool {
        guard brightnessKeysEnabled, !displays.isEmpty else { return false }

        // CoreGraphics' flipped global space, matching `DisplayDevice.frame`.
        let pointer = CGEvent(source: nil)?.location ?? .zero
        let targets = BrightnessKeyResolver.targets(
            strategy: brightnessKeyTarget,
            displays: displays,
            pointer: pointer,
            forceAllDisplays: forceAllDisplays)
        guard !targets.isEmpty else { return false }

        for display in targets where !display.isBuiltIn {
            let current = brightness.brightness(for: display.id)
            let next = BrightnessKeyResolver.adjusted(current, by: delta)
            setBrightness(next, for: display)
            // Only for external displays: macOS draws its own HUD for the built-in panel, and two
            // indicators side by side would look like a bug.
            osd.show(value: next, display: display)
        }

        let touchedBuiltIn = targets.contains(where: \.isBuiltIn)
        let touchedExternal = targets.contains(where: { !$0.isBuiltIn })
        return touchedExternal && !touchedBuiltIn
    }

    // MARK: - Resolution

    /// Applies a display mode, then refreshes so the UI reflects whatever actually took effect —
    /// which may be the previous mode, if the change was reverted.
    func setMode(_ mode: DisplayMode, for display: DisplayDevice) {
        let outcome = ModeChangeCoordinator.change(to: mode, on: display)
        switch outcome {
        case .kept, .reverted:
            lastError = nil
        case .failed(let message):
            lastError = "Could not change resolution: \(message)"
        }
        // A resolution change invalidates cached frames, and shade overlays are positioned from them.
        // It also clears the gamma ramp, which `handleDisplaysChanged` puts back — the reconfiguration
        // callback normally gets there first, but this path does not depend on that.
        discovery.refreshNow()
        brightness.handleDisplaysChanged(displays)
    }

    // MARK: - HiDPI install

    enum InstallOutcome {
        case installed(recoveryPackage: URL, requiresLogout: Bool)
        case cancelled
        case failed(String)
    }

    /// The policy the app installs with. Merge, because that is what the UI promises: the tab is
    /// titled "Resolutions to add", and the confirmation says existing entries are kept. `.replace`
    /// here would make both of those false — it briefly did, and destroyed a 242-entry override
    /// written by another tool. Removing modes is a different feature (the recovery package), not a
    /// side effect of adding some. Export uses the same policy so both routes stage the same file.
    static let installPolicy = OverrideInstaller.ExistingContentPolicy.merge

    /// Works out what installing would change, writing nothing.
    ///
    /// Separate from `performInstall` so the UI can put the whole plan — the destination, the file
    /// being replaced, what is discarded, the undo command — in front of the user *before* asking for
    /// a password. A privileged write the user has not seen described is not a reviewable one.
    func planInstall(
        _ generated: GeneratedOverride, for display: DisplayDevice
    ) throws -> InstallationPlan {
        let installer = OverrideInstaller(
            root: URL(fileURLWithPath: OverridePaths.systemOverrideRoot),
            appVersion: Self.version)
        return try installer.plan(generated: generated, display: display, policy: Self.installPolicy)
    }

    /// Backs up, installs and verifies a plan the user has already approved, prompting for
    /// authorization once.
    ///
    /// The recovery package is created **before** the privileged write, not after: if the write goes
    /// wrong, the way back has to already exist.
    /// - Note: the bytes written come from `plan.payload`, not from any `GeneratedOverride` the caller
    ///   still has to hand. Those two differ whenever an override is already installed, and writing
    ///   the caller's copy is what silently discarded another tool's modes.
    func performInstall(_ plan: InstallationPlan) -> InstallOutcome {
        guard plan.isInstallable else {
            return .failed(plan.validation.errors.map(\.message).joined(separator: "\n"))
        }
        do {
            let downloads = try FileManager.default.url(
                for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let package = try RecoveryPackageBuilder.create(manifest: plan.manifest, in: downloads)

            // Copy the file being replaced into the package while we can still read it. This throws
            // if the file no longer matches the plan — the plan (and its merged payload) is then
            // stale, and installing it would both lose the newer content and produce a recovery
            // package whose own restore script rejects the backup.
            let installer = OverrideInstaller(root: plan.root, appVersion: Self.version)
            do {
                try installer.stageBackups(for: plan.manifest, into: package.backupDirectory)
            } catch InstallerError.manifestMismatch {
                try? FileManager.default.removeItem(at: package.directory)
                return .failed("""
                    The override file changed after this install was planned. Nothing was written. \
                    Click Install again to re-read the file and see an updated plan.
                    """)
            }

            do {
                try PrivilegedInstaller.install(plan: plan, payload: plan.payload)
            } catch PrivilegedInstaller.InstallError.cancelled {
                // Cancelling happens before anything runs as root, so nothing on the system changed.
                // Leaving a recovery package behind would contradict the message the UI then shows —
                // and a recovery folder for a change that never happened is only confusing later.
                try? FileManager.default.removeItem(at: package.directory)
                return .cancelled
            }
            return .installed(recoveryPackage: package.directory, requiresLogout: plan.requiresLogout)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Ends the session so the new override takes effect. Profiles are flushed first — a logout gives
    /// the app no more warning than a restart does — and *awaited*: firing the logout Apple event in
    /// the same breath as an unawaited flush was a race the flush usually lost.
    func endSession(_ kind: PrivilegedInstaller.SessionEnd) {
        Task {
            await profiles.flush()
            do { try PrivilegedInstaller.endSession(kind) } catch { lastError = error.localizedDescription }
        }
    }

    // MARK: - Diagnostics

    func exportDiagnostics() {
        let report = DiagnosticsBuilder.build(
            displays: displays,
            ambiguousKeys: ambiguousKeys,
            brightnessStates: brightness.states,
            availability: brightness.availability,
            probeDetails: brightness.probeDetails,
            warnings: brightness.warnings,
            chosenControllers: Dictionary(
                uniqueKeysWithValues: displays.compactMap { display in
                    brightness.controller(for: display.id).map { (display.id, $0) }
                }),
            appVersion: Self.version)

        do {
            let data = try report.jsonData()
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            let url = FileManager.default
                .urls(for: .downloadsDirectory, in: .userDomainMask).first?
                .appendingPathComponent("HiDisplay-diagnostics-\(formatter.string(from: Date())).json")
            guard let url else { return }
            try data.write(to: url, options: .atomic)
            lastExportPath = url.path
            Log.app.notice("wrote diagnostics to \(url.lastPathComponent, privacy: .public)")
        } catch {
            lastError = "Could not write diagnostics: \(error)"
        }
    }
}
