import HiDisplayKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            DisplaysSettingsTab()
                .tabItem { Label("Displays", systemImage: "display") }
            HiDPISettingsTab()
                .tabItem { Label("HiDPI", systemImage: "square.resize.up") }
            KeyboardSettingsTab()
                .tabItem { Label("Keyboard", systemImage: "keyboard") }
            DiagnosticsSettingsTab()
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        // A minimum rather than a fixed size: the HiDPI tab is content-heavy, and pinning the
        // window's height is what pushed its Install button out of sight in an earlier version.
        .frame(minWidth: 580, idealWidth: 580, minHeight: 520, idealHeight: 560)
    }
}

/// Per-display brightness controller choice, plus the probe detail that explains it.
struct DisplaysSettingsTab: View {

    @EnvironmentObject private var model: AppModel
    @State private var selection: String?
    @State private var showAllResolutions = false

    private var selectedDisplay: DisplayDevice? {
        model.displays.first { $0.id == selection } ?? model.displays.first
    }

    var body: some View {
        HSplitView {
            List(model.displays, selection: $selection) { display in
                VStack(alignment: .leading) {
                    Text(display.name).font(.body)
                    Text(display.isBuiltIn ? "Built-in" : "External")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .tag(display.id)
            }
            .frame(minWidth: 180)

            if let display = selectedDisplay {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        detailHeader(display)
                        resolutionSection(display)
                        if display.isBuiltIn {
                            builtInBrightnessNote
                        } else {
                            controllerPicker(display)
                            probeDetails(display)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("No display selected").foregroundStyle(.secondary).padding()
            }
        }
    }

    private func detailHeader(_ display: DisplayDevice) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(display.name).font(.title3.bold())
            LabeledContent("Vendor / Product") {
                Text(String(format: "0x%04X / 0x%04X", display.identity.vendorID, display.identity.productID))
                    .monospaced()
            }
            LabeledContent("Profile key") {
                Text(display.id).monospaced().textSelection(.enabled)
            }
            // The tier explanation is shown, not hidden: a `.location` key silently breaking on a port
            // swap is confusing unless the user was told that is how it works.
            Text(display.identity.keyTier.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let native = display.nativePixelSize {
                // `Text(verbatim:)`: an interpolated Int is number-formatted, which turns 5088 into
                // "5.088" wherever the locale groups thousands with a period.
                LabeledContent("Native resolution") {
                    Text(verbatim: "\(native.width) × \(native.height)")
                }
            }
            LabeledContent("Modes") {
                Text("\(display.availableModes.count) total, \(display.hiDPIModeCount) HiDPI")
            }
        }
    }

    /// Resolution and refresh rate as two independent choices.
    ///
    /// Kept separate on purpose: picking a different resolution should not silently drop a 120 Hz panel
    /// to 60 Hz, which is what a single combined list would do whenever the highest rate is not
    /// available at the newly chosen size.
    @ViewBuilder
    private func resolutionSection(_ display: DisplayDevice) -> some View {
        let curated = display.curatedModes
        let current = display.currentMode
        let rates = current.map {
            DisplayModeSwitcher.refreshRates(
                forWidth: $0.width, height: $0.height, hiDPI: $0.isHiDPI, in: display.availableModes)
        } ?? []

        VStack(alignment: .leading, spacing: 6) {
            Text("Resolution").font(.headline)

            if showAllResolutions {
                // The unfiltered list, for the case where the curated one hides a mode someone needs.
                Picker("", selection: modeBinding(display)) {
                    ForEach(display.availableModes.filter(\.isUsableForDesktop)) { mode in
                        Text("\(mode.displayLabel) @ \(Int(mode.refreshRate.rounded()))Hz").tag(mode.id)
                    }
                }
                .labelsHidden()
            } else {
                Picker("", selection: modeBinding(display)) {
                    ForEach(curated) { mode in Text(mode.displayLabel).tag(mode.id) }
                }
                .labelsHidden()

                if rates.count > 1 {
                    Picker("Refresh rate", selection: modeBinding(display)) {
                        ForEach(rates) { mode in
                            Text("\(Int(mode.refreshRate.rounded())) Hz").tag(mode.id)
                        }
                    }
                }
            }

            Toggle("Show all resolutions", isOn: $showAllResolutions)
                .font(.caption)

            Text("Changing resolution shows a confirmation with a \(ModeChangeCoordinator.revertAfter)-second "
                + "countdown. If the display cannot show the new mode, it reverts on its own.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    /// Selection is by `DisplayMode.id`, which encodes geometry and refresh rate — the runtime
    /// `ioDisplayModeID` is not stable across reconnects and cannot be used as a tag.
    private func modeBinding(_ display: DisplayDevice) -> Binding<String> {
        Binding(
            get: { display.currentMode?.id ?? "" },
            set: { id in
                guard let mode = display.availableModes.first(where: { $0.id == id }) else { return }
                model.setMode(mode, for: display)
            })
    }

    /// Shown instead of a controller picker for the built-in panel.
    ///
    /// Phrased as a boundary rather than a limitation, because it is one: macOS already owns that
    /// value through the brightness keys, Control Center and ambient-light adaptation, and a second
    /// owner could only fight them — on the one screen the user cannot unplug to recover.
    private var builtInBrightnessNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Brightness").font(.headline)
            Text(BrightnessCoordinator.builtInExplanation)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Use the brightness keys, Control Center, or System Settings → Displays for this one.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func controllerPicker(_ display: DisplayDevice) -> some View {
        let availability = model.brightness.availability[display.id] ?? ControllerAvailability()
        let current = model.brightness.userOverride(for: display.id)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Brightness controller").font(.headline)
            Picker("", selection: Binding(
                get: { current },
                set: { model.setController($0, for: display) })
            ) {
                Text("Automatic").tag(BrightnessControllerKind?.none)
                ForEach(BrightnessControllerKind.allCases) { kind in
                    Text(kind.label + (availability.isAvailable(kind) ? "" : " (unavailable)"))
                        .tag(BrightnessControllerKind?.some(kind))
                }
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)

            if let chosen = model.brightness.controller(for: display.id) {
                Text("Currently using: \(chosen.label)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func probeDetails(_ display: DisplayDevice) -> some View {
        let details = model.brightness.probeDetails[display.id] ?? [:]
        return VStack(alignment: .leading, spacing: 4) {
            Text("Probe results").font(.headline)
            ForEach(BrightnessControllerKind.allCases) { kind in
                if let detail = details[kind] {
                    HStack(alignment: .top, spacing: 6) {
                        Text(kind.label + ":").font(.caption).frame(width: 120, alignment: .trailing)
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct DiagnosticsSettingsTab: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diagnostics").font(.title3.bold())
            Text("""
                Exports a JSON report describing your displays, which brightness controllers were \
                found, and why each probe succeeded or failed. It contains no username, no file paths \
                from your home folder, no monitor serial numbers and no raw EDID — serials appear only \
                as the truncated hash already used to tell displays apart.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Export Diagnostics…") { model.exportDiagnostics() }
                if let path = model.lastExportPath {
                    Button("Show in Finder") {
                        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                    }
                }
            }

            if let path = model.lastExportPath {
                Text("Saved to \(URL(fileURLWithPath: path).lastPathComponent)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            Divider()

            Text("Private API status").font(.headline)
            LabeledContent("IOAVService (DDC on Apple Silicon)") {
                shimStatus(
                    available: IOAVServiceShim.shared.isAvailable,
                    reason: IOAVServiceShim.shared.unavailableReason)
            }
            LabeledContent("DisplayServices (built-in brightness)") {
                shimStatus(
                    available: DisplayServicesShim.shared.isAvailable,
                    reason: DisplayServicesShim.shared.unavailableReason)
            }
            Text("""
                These two use symbols that are not part of the public macOS SDK. They are looked up at \
                runtime, and if a future macOS removes them the app falls back to software dimming \
                instead of failing.
                """)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding()
    }

    private func shimStatus(available: Bool, reason: String?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: available ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(available ? .green : .orange)
            Text(available ? "Available" : (reason ?? "Unavailable")).font(.caption)
        }
    }
}


/// Brightness-key interception.
struct KeyboardSettingsTab: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Brightness keys").font(.title3.bold())
            Text("""
                macOS sends F1 and F2 to the built-in display only, so on a laptop connected to an \
                external monitor they do nothing useful. Turn this on to make them adjust the \
                external display instead.
                """)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Use F1 and F2 for external displays", isOn: Binding(
                get: { model.brightnessKeysEnabled },
                set: { model.setBrightnessKeysEnabled($0) }))

            Picker("Adjust", selection: Binding(
                get: { model.brightnessKeyTarget },
                set: { model.setBrightnessKeyTarget($0) })
            ) {
                ForEach(BrightnessKeyTarget.allCases) { Text($0.label).tag($0) }
            }
            .disabled(!model.brightnessKeysEnabled)

            GroupBox("Modifiers") {
                VStack(alignment: .leading, spacing: 3) {
                    LabeledContent("⌥ Option") { Text("Quarter-size steps") }
                    LabeledContent("⌃ Control") { Text("Every display at once") }
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            Divider()

            accessibilitySection

            Text("""
                When a press concerns the built-in display, the key is passed through to macOS \
                unchanged so that panel keeps its native behaviour and brightness HUD. Only presses \
                that affect external displays alone are intercepted.
                """)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding()
    }

    @ViewBuilder
    private var accessibilitySection: some View {
        HStack(spacing: 6) {
            Image(systemName: model.isAccessibilityTrusted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(model.isAccessibilityTrusted ? Color.green : Color.orange)
            if model.isAccessibilityTrusted {
                Text("Accessibility permission granted").font(.callout)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Accessibility permission needed").font(.callout)
                    Text("""
                        Reading key presses requires it. HiDisplay only looks at the brightness keys and \
                        ignores everything else. Without it, the menu-bar sliders still work.
                        """)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Privacy & Security…") {
                        BrightnessKeyTap.requestAccessibility()
                        if let url = URL(string:
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .font(.caption)
                }
            }
        }
    }
}


/// App-level settings: launch at login, version, and the escape hatch.
struct GeneralSettingsTab: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("General").font(.title3.bold())

            Toggle("Open HiDisplay at login", isOn: Binding(
                get: { model.loginItemState.isOn },
                set: { model.setLaunchAtLogin($0) }))

            loginItemStatus

            Text("""
                Brightness settings are remembered per display and reapplied when it reconnects, so \
                opening at login means an external monitor comes back at the brightness you left it.
                """)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            LabeledContent("Version") { Text(AppModel.version).monospacedDigit() }
            LabeledContent("Displays detected") { Text("\(model.displays.count)") }

            Divider()

            // Duplicated from the menu on purpose: someone whose screen is too dark to read the menu
            // may already have Settings open.
            Button("Reset All Dimming") { model.resetDimming() }
            Text("Clears gamma and overlay dimming on every display. Does not touch a monitor's own "
                + "backlight, which is its real setting.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding()
        // The user can flip this in System Settings behind our back, so re-read rather than trust state.
        .onAppear { model.refreshLoginItemState() }
    }

    @ViewBuilder
    private var loginItemStatus: some View {
        switch model.loginItemState {
        case .enabled, .disabled:
            EmptyView()
        case .requiresApproval:
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Waiting for approval in System Settings").font(.callout)
                    Text("HiDisplay is registered but switched off under Login Items & Extensions.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open Login Items…") {
                        if let url = URL(string:
                            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .font(.caption)
                }
            }
        case .unavailable(let reason):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Color.red)
                Text(reason).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
