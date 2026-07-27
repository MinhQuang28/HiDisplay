import HiDisplayKit
import SwiftUI

/// Generate, preview, install or export a HiDPI override.
///
/// Two routes, on purpose. **Install** writes to `/Library/Displays` after one authorization prompt,
/// having first shown exactly what it will do and put a recovery package in Downloads. **Export Only**
/// writes nothing outside Downloads and hands back the commands, for anyone who would rather run the
/// privileged part themselves — or who is installing on a different Mac.
struct HiDPISettingsTab: View {

    @EnvironmentObject private var model: AppModel

    @State private var selection: String?
    @State private var chosen: Set<String> = []
    @State private var customWidth = ""
    @State private var customResolutions: [ScaledResolution] = []
    @State private var scalingIndex: Double = -1
    @State private var showFullLadder = false
    @State private var showRestartPrompt = false
    @State private var recoveryPackagePath: String?
    /// The plan awaiting confirmation, held so the alert's Install button writes exactly what was
    /// described rather than re-planning against a file that may have changed in between.
    @State private var pendingInstall: (plan: InstallationPlan, generated: GeneratedOverride)?
    @State private var exportMessage: String?
    @State private var exportError: String?

    private var eligibleDisplays: [DisplayDevice] {
        model.displays.filter(\.capabilities.supportsHiDPIOverride)
    }

    private var display: DisplayDevice? {
        eligibleDisplays.first { $0.id == selection } ?? eligibleDisplays.first
    }

    /// Every aspect-correct step for the panel, the same set the scaling slider moves through.
    private var fullLadder: [ScaledResolution] {
        guard let native = display?.nativePixelSize else { return [] }
        return ResolutionPresets.scalingSteps(nativePixels: native)
    }

    private var candidates: [ScaledResolution] {
        guard let display else { return [] }
        let presetResolutions = showFullLadder
            ? fullLadder
            : ResolutionPresets
                .presets(forNativePixels: display.nativePixelSize)
                .flatMap(\.resolutions)
        // Custom entries come last and are de-duplicated against the presets, so typing a size that a
        // preset already offers does not produce two identical rows.
        var seen = Set(presetResolutions.map(\.id))
        return presetResolutions + customResolutions.filter { seen.insert($0.id).inserted }
    }

    private var selectedResolutions: [ScaledResolution] {
        candidates.filter { chosen.contains($0.id) }
    }

    private var generated: GeneratedOverride? {
        guard let display, !selectedResolutions.isEmpty else { return nil }
        let document = DisplayOverrideDocument(
            vendorID: display.identity.vendorID,
            productID: display.identity.productID,
            displayName: display.name,
            scaleResolutions: selectedResolutions)
        return OverrideGenerator.generate(document, nativePixelSize: display.nativePixelSize)
    }

    var body: some View {
        Group {
            if eligibleDisplays.isEmpty {
                noEligibleDisplays
            } else {
                content
            }
        }
        .padding()
        .alert(
            "Install this override?",
            isPresented: Binding(
                get: { pendingInstall != nil },
                set: { if !$0 { pendingInstall = nil } })
        ) {
            Button("Install", role: .destructive) { confirmInstall() }
            Button("Cancel", role: .cancel) { pendingInstall = nil }
        } message: {
            Text(pendingInstall.map { Self.confirmationMessage(for: $0.plan) } ?? "")
        }
        // Log out, not restart, as the primary action: WindowServer reads overrides when a login
        // session starts, so a full reboot buys nothing but minutes. Restart stays as the second
        // button because it is the instruction most guides give.
        .alert("Log out to apply?", isPresented: $showRestartPrompt) {
            Button("Log Out Now") { model.endSession(.logOut) }
            Button("Restart Now") { model.endSession(.restart) }
            Button("Later", role: .cancel) {}
        } message: {
            Text("macOS reads display overrides when your login session starts, so logging out and "
                + "back in is enough — a restart is not required. Your open apps will be asked to "
                + "save either way.")
        }
    }

    private var noEligibleDisplays: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No display can take a HiDPI override").font(.headline)
            Text("""
                An override is identified by the display's vendor and product ID, so a display that \
                does not report both cannot have one. Built-in displays are excluded — macOS already \
                manages their scaling.
                """)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    /// Display picker on top, scrollable middle, action buttons pinned to the bottom.
    ///
    /// The tab stacks nine sections into a fixed-height window, and an earlier version simply let them
    /// overflow: the Install button existed but was pushed past the bottom edge with no way to scroll
    /// to it, so the feature looked missing. A primary action must never require scrolling to reach.
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Display", selection: Binding(
                get: { display?.id ?? "" },
                set: { selection = $0; chosen = []; customResolutions = [] })
            ) {
                ForEach(eligibleDisplays) { Text($0.name).tag($0.id) }
            }
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    warningBanner
                    if let display {
                        scalingSlider(display)
                        ladderControls(display)
                        resolutionList(display)
                        customEntry
                        validationSection
                        previewSection
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 4) // room for the scroller
            }

            if let display {
                Divider().padding(.vertical, 8)
                exportSection(display)
            }
        }
    }

    private var warningBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Read this before installing an override", systemImage: "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(.orange)
            Text("""
                A display override changes a macOS configuration file. It takes effect only after a \
                logout. Some monitors respond badly — a black screen after wake is the usual \
                failure. The exported package includes a verified restore script and instructions that \
                work from the macOS Recovery Terminal. Keep it until you are sure the override is good.
                """)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    /// Split out of the view body: the optional-tuple `flatMap` inline defeated SwiftUI's `ForEach`
    /// overload resolution and produced an unrelated-looking Binding error.
    private static func sharpness(
        of resolution: ScaledResolution, on display: DisplayDevice
    ) -> HiDPISharpness? {
        guard let native = display.nativePixelSize else { return nil }
        return ResolutionPresets.sharpness(of: resolution, nativePixels: native)
    }

    /// Continuous custom scaling, the way people expect it from other display tools.
    ///
    /// Every step keeps the panel's exact aspect ratio and even dimensions, so no position on the slider
    /// can produce a letterboxed or unevenly-doubled mode — the invalid options simply do not exist
    /// rather than being offered and then rejected.
    ///
    /// Note this *stages* a resolution; it does not apply one. Adding a mode that the display driver
    /// does not already publish requires a display override and a new login session. Applying an arbitrary
    /// size live, with no logout, needs private CoreGraphics APIs or a virtual display driver — both
    /// deliberately out of scope here (see docs/hidpi-overrides.md).
    @ViewBuilder
    private func scalingSlider(_ display: DisplayDevice) -> some View {
        let steps = display.nativePixelSize.map { ResolutionPresets.scalingSteps(nativePixels: $0) } ?? []
        if steps.count > 1 {
            let index = min(max(Int(scalingIndex.rounded()), 0), steps.count - 1)
            let staged = steps[index]
            let sharpness = Self.sharpness(of: staged, on: display)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Custom scaling").font(.headline)
                    Spacer()
                    Text(staged.label).font(.caption).monospacedDigit()
                }

                Slider(value: $scalingIndex, in: 0...Double(steps.count - 1), step: 1)
                    .controlSize(.small)

                HStack {
                    Text("Larger text").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text("More space").font(.caption2).foregroundStyle(.secondary)
                }

                if let sharpness {
                    Text(sharpness.explanation)
                        .font(.caption2)
                        .foregroundStyle(sharpness.isRecommended ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button("Add \(staged.sizeLabel) to the list") {
                    guard !candidates.contains(where: { $0.id == staged.id }) else {
                        chosen.insert(staged.id)
                        return
                    }
                    customResolutions.append(staged)
                    chosen.insert(staged.id)
                }
                .disabled(display.hasHiDPIMode(
                    width: staged.logicalWidth, height: staged.logicalHeight))
            }
            .padding(8)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .onAppear {
                // Start from whatever the display is showing now, so the slider opens where the user is
                // rather than at an arbitrary end of the range.
                if scalingIndex < 0 {
                    let currentWidth = display.currentMode?.width ?? steps[0].logicalWidth
                    scalingIndex = Double(
                        ResolutionPresets.nearestStepIndex(to: currentWidth, in: steps) ?? 0)
                }
            }
        }
    }

    /// Bulk selection, for people who want every scaled size rather than a curated handful.
    ///
    /// Off by default: even capped at `ResolutionPresets.maximumScalingSteps`, System Settings shows
    /// every entry, which makes its resolution list unwieldy. Worth having, not worth defaulting to.
    @ViewBuilder
    private func ladderControls(_ display: DisplayDevice) -> some View {
        let usable = candidates.filter {
            !display.hasHiDPIMode(width: $0.logicalWidth, height: $0.logicalHeight)
        }
        HStack(spacing: 10) {
            Toggle("Show every step", isOn: $showFullLadder)
                .onChange(of: showFullLadder) { _ in chosen.removeAll() }
            Spacer()
            Button("Select all (\(usable.count))") {
                chosen.formUnion(usable.map(\.id))
            }
            .disabled(usable.isEmpty)
            Button("Clear") { chosen.removeAll() }
                .disabled(chosen.isEmpty)
        }
        .font(.caption)

        if showFullLadder {
            Text("Up to \(ResolutionPresets.maximumScalingSteps) aspect-correct sizes for this panel, "
                + "from 30% of native width to native. Each renders at twice its size and is scaled "
                + "down to the panel — the trade-off is GPU bandwidth, and a long list in System "
                + "Settings.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func resolutionList(_ display: DisplayDevice) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Resolutions to add").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(candidates) { resolution in
                        ResolutionRow(
                    resolution: resolution,
                    display: display,
                    isOn: Binding(
                        get: { chosen.contains(resolution.id) },
                        set: { isOn in
                            if isOn { chosen.insert(resolution.id) } else { chosen.remove(resolution.id) }
                                }))
                    }
                }
            }
            .frame(maxHeight: 180)
        }
    }

    /// Manual entry, locked to the panel's aspect ratio.
    ///
    /// Only a width is typed: the height is derived, and the result is snapped to the nearest size that
    /// is a whole multiple of the panel's reduced ratio. An earlier version took both numbers and merely
    /// *warned* when they did not match the panel — which meant the one place in the app that could
    /// produce a letterboxed or stretched mode was the place a person types into by hand.
    @ViewBuilder
    private var customEntry: some View {
        let native = display?.nativePixelSize
        let typedWidth = Int(customWidth)
        let match = native.flatMap { native -> ScaledResolution? in
            guard let typedWidth else { return nil }
            return ResolutionPresets.aspectCorrectResolution(forWidth: typedWidth, nativePixels: native)
        }
        let ratioLabel = native.map {
            ResolutionPresets.aspectRatioLabel(width: $0.width, height: $0.height)
        } ?? "?"

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Custom width").font(.caption)
                TextField("e.g. 2048", text: $customWidth).frame(width: 80)
                if let match {
                    Text("× \(match.logicalHeight)")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Button("Add") {
                    guard let match else { return }
                    if !candidates.contains(where: { $0.id == match.id }) {
                        customResolutions.append(match)
                    }
                    chosen.insert(match.id)
                    customWidth = ""
                }
                .disabled(match == nil)
            }

            if let match, let typedWidth, match.logicalWidth != typedWidth {
                Text("Snapped to \(match.sizeLabel) — the nearest size that "
                    + "keeps the panel's \(ratioLabel) shape.")
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Height is derived from the panel's \(ratioLabel) ratio, so a custom size can never "
                    + "be letterboxed or stretched.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var validationSection: some View {
        if let report = generated?.validation, !report.issues.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(report.issues) { issue in
                    Label(issue.message, systemImage: issue.severity == .error
                        ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(issue.severity == .error ? .red : .orange)
                }
            }
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        if let generated, let text = String(data: generated.data, encoding: .utf8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Preview — \(generated.relativePath)").font(.headline)
                ScrollView {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 120)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    @ViewBuilder
    private func exportSection(_ display: DisplayDevice) -> some View {
        let generated = generated
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Install…") { install(display: display, generated: generated) }
                    .buttonStyle(.borderedProminent)
                    .disabled(generated?.validation.isInstallable != true)
                Button("Export Only…") { exportPackage(display: display, generated: generated) }
                    .disabled(generated?.validation.isInstallable != true)
            }
            Text("Install asks for your password once, backs up the current override first, writes the "
                + "new one, and verifies it. It takes effect after you log out and back in.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let message = exportMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The recovery package is the thing to keep, so make it one click to find rather than a
            // folder name to go hunting for in Downloads.
            if let path = recoveryPackagePath {
                Button("Show Recovery Package in Finder") {
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                }
                .font(.caption)
            }
            if let error = exportError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    /// Step one of installing: plan it and describe it. Nothing is written here.
    private func install(display: DisplayDevice, generated: GeneratedOverride?) {
        exportMessage = nil
        exportError = nil
        recoveryPackagePath = nil
        guard let generated else { return }

        do {
            pendingInstall = (try model.planInstall(generated, for: display), generated)
        } catch {
            exportError = "Could not plan the install: \(error)"
        }
    }

    /// What the confirmation says. Every line is something the user can only act on before the write:
    /// where it lands, what is already there, what will not survive, and how to undo it without the app.
    private static func confirmationMessage(for plan: InstallationPlan) -> String {
        var parts: [String] = []
        if let action = plan.actions.last(where: { $0.kind != .createDirectory }) {
            parts.append("Writes \(action.absolutePath)")
            if action.kind == .replaceFile {
                parts.append("A file is already there. It is copied into a recovery package in your "
                    + "Downloads folder before anything is replaced.")
            }
        }
        if !plan.droppedUnknownKeys.isEmpty {
            parts.append("Replaced by your selection, and not carried over:\n"
                + plan.droppedUnknownKeys.map { "  • \($0)" }.joined(separator: "\n"))
        }
        parts.append("Takes effect after you log out and back in. To undo it without this app:\n"
            + plan.recoveryCommand)
        return parts.joined(separator: "\n\n")
    }

    /// Step two: the user has seen the plan and said yes. This is the only path that asks for a password.
    private func confirmInstall() {
        guard let pending = pendingInstall else { return }
        pendingInstall = nil

        switch model.performInstall(pending.plan, payload: pending.generated) {
        case .installed(let package, let requiresLogout):
            recoveryPackagePath = package.path
            exportMessage = """
                Installed and verified.

                A recovery package with the previous file and an undo script is in \
                \(package.lastPathComponent) in your Downloads folder.
                """
            showRestartPrompt = requiresLogout
        case .cancelled:
            exportMessage = "Cancelled — nothing was changed."
        case .failed(let message):
            exportError = message
        }
    }

    /// Writes the generated override and a recovery package into a Downloads subfolder, then reports
    /// the single command needed to install it.
    ///
    /// The plan is built against the **real** override root so the manifest and restore script contain
    /// the paths that will actually be used — but `apply` is never called here, so nothing is written
    /// outside Downloads.
    private func exportPackage(display: DisplayDevice, generated: GeneratedOverride?) {
        exportMessage = nil
        exportError = nil
        guard let generated else { return }

        do {
            let downloads = try FileManager.default.url(
                for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)

            let installer = OverrideInstaller(
                root: URL(fileURLWithPath: OverridePaths.systemOverrideRoot),
                appVersion: AppModel.version)
            // Same policy as Install, because the staged file below *is* `generated.data`: under the
            // merge policy the manifest would record the hash of a merged file that this folder does
            // not contain, and restore.command would then refuse the very file it shipped with.
            let plan = try installer.plan(generated: generated, display: display, policy: .replace)

            let package = try RecoveryPackageBuilder.create(manifest: plan.manifest, in: downloads)

            // The file to install sits next to the recovery package, named exactly as it must be on
            // disk, so the install command is a plain copy with no renaming step to get wrong.
            let stagedDirectory = package.directory
                .appendingPathComponent("install", isDirectory: true)
                .appendingPathComponent(
                    OverridePaths.vendorDirectoryName(vendorID: display.identity.vendorID),
                    isDirectory: true)
            try FileManager.default.createDirectory(at: stagedDirectory, withIntermediateDirectories: true)
            let stagedFile = stagedDirectory.appendingPathComponent(
                OverridePaths.productFileName(productID: display.identity.productID))
            try generated.data.write(to: stagedFile, options: .atomic)

            exportMessage = """
                Wrote \(package.directory.lastPathComponent) to Downloads.

                To install:
                  sudo mkdir -p "\(OverridePaths.systemOverrideRoot)/\(OverridePaths.vendorDirectoryName(vendorID: display.identity.vendorID))"
                  sudo cp "\(stagedFile.path)" "\(OverridePaths.systemOverrideRoot)/\(generated.relativePath)"
                  # then log out and back in (or: sudo reboot)

                To undo: run restore.command inside that folder.
                """
            Log.hidpiGenerator.notice("exported override package for \(display.id, privacy: .public)")
        } catch {
            exportError = "Export failed: \(error)"
        }
    }
}

/// One selectable resolution.
///
/// A separate `View` rather than an inline closure: the row needs a computed sharpness value and two
/// conditional labels, and expressing that inside `ForEach`'s trailing closure pushed SwiftUI's type
/// checker onto the wrong `ForEach` overload — reported as an unrelated-looking `Binding` error.
private struct ResolutionRow: View {

    let resolution: ScaledResolution
    let display: DisplayDevice
    @Binding var isOn: Bool

    /// True when macOS already offers this size as HiDPI. Overriding it is pure risk with no benefit.
    private var alreadyExists: Bool {
        display.hasHiDPIMode(width: resolution.logicalWidth, height: resolution.logicalHeight)
    }

    private var sharpness: HiDPISharpness? {
        guard let native = display.nativePixelSize else { return nil }
        return ResolutionPresets.sharpness(of: resolution, nativePixels: native)
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(resolution.label)
                    if alreadyExists {
                        Text("already available").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                // "HiDPI" alone does not say how sharp a mode will actually be — the backing store's
                // relationship to the panel's real pixels does.
                if let sharpness {
                    Text(sharpness.label)
                        .font(.caption2)
                        .foregroundStyle(sharpness.isRecommended ? Color.secondary : Color.orange)
                }
            }
        }
        .disabled(alreadyExists)
        .help(sharpness?.explanation ?? "")
    }
}
