import HiDisplayKit
import SwiftUI

/// Everything about one monitor: what it is, its resolution, how its brightness is driven, and the
/// identity its settings are saved under.
///
/// One page per display rather than a list-and-detail split inside the page, because the sidebar
/// *is* the list now. The built-in panel gets the same header and then a note, since macOS owns both
/// its resolution and its brightness — see `BrightnessCoordinator.builtInExplanation`.
struct DisplayPage: View {

    let display: DisplayDevice
    @EnvironmentObject private var model: AppModel
    @State private var showAllResolutions = false

    var body: some View {
        Form {
            overviewSection
            if display.isBuiltIn {
                builtInSection
            } else {
                resolutionSection
                brightnessSection
            }
            identitySection
        }
        .formStyle(.grouped)
    }

    // MARK: Overview

    private var overviewSection: some View {
        Section {
            LabeledContent("Type") {
                Text(display.isBuiltIn ? "Built-in display" : "External display")
            }
            if display.isMain {
                LabeledContent("Role") { Text("Main display — holds the menu bar") }
            }
            if let native = display.nativePixelSize {
                // `Text(verbatim:)`: an interpolated Int is number-formatted, which turns 5088 into
                // "5.088" wherever the locale groups thousands with a period.
                LabeledContent("Native resolution") {
                    Text(verbatim: "\(native.width) × \(native.height)")
                }
            }
            if let mode = display.currentMode {
                LabeledContent("Current mode") {
                    Text("\(mode.displayLabel) @ \(Int(mode.refreshRate.rounded())) Hz")
                }
            }
            LabeledContent("Modes") {
                Text("\(display.availableModes.count) total, \(display.hiDPIModeCount) HiDPI")
            }
        }
    }

    /// Phrased as a boundary rather than a limitation, because it is one: macOS already owns the
    /// built-in panel's brightness through the keys, Control Center and ambient-light adaptation,
    /// and a second owner could only fight them — on the one screen the user cannot unplug.
    private var builtInSection: some View {
        Section("Managed by macOS") {
            Text(BrightnessCoordinator.builtInExplanation)
            Text("Resolution and brightness for the built-in display live in System Settings → "
                + "Displays, Control Center, or the brightness keys. HiDisplay does not duplicate them.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Resolution

    /// Resolution and refresh rate as two independent choices.
    ///
    /// Kept separate on purpose: picking a different resolution should not silently drop a 120 Hz
    /// panel to 60 Hz, which is what a single combined list would do whenever the highest rate is not
    /// available at the newly chosen size.
    @ViewBuilder
    private var resolutionSection: some View {
        let curated = display.curatedModes
        let rates = display.currentMode.map {
            DisplayModeSwitcher.refreshRates(
                forWidth: $0.width, height: $0.height, hiDPI: $0.isHiDPI, in: display.availableModes)
        } ?? []

        Section {
            if showAllResolutions {
                // The unfiltered list, for the case where the curated one hides a mode someone needs.
                Picker("Resolution", selection: modeBinding) {
                    ForEach(display.availableModes.filter(\.isUsableForDesktop)) { mode in
                        Text("\(mode.displayLabel) @ \(Int(mode.refreshRate.rounded())) Hz").tag(mode.id)
                    }
                }
            } else {
                Picker("Resolution", selection: sizeBinding) {
                    ForEach(curated) { mode in Text(mode.displayLabel).tag(mode.sizeKey) }
                }
                if rates.count > 1 {
                    Picker("Refresh rate", selection: modeBinding) {
                        ForEach(rates) { mode in
                            Text("\(Int(mode.refreshRate.rounded())) Hz").tag(mode.id)
                        }
                    }
                }
            }
            Toggle("Show all resolutions", isOn: $showAllResolutions)

            if let error = model.modeChangeError {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        } header: {
            Text("Resolution")
        } footer: {
            Text("A change shows a confirmation with a \(ModeChangeCoordinator.revertAfter)-second "
                + "countdown and reverts on its own if the display cannot show the new mode.")
        }
    }

    /// Selection is by `DisplayMode.id`, which encodes geometry and refresh rate — the runtime
    /// `ioDisplayModeID` is not stable across reconnects and cannot be used as a tag.
    ///
    /// Correct for the refresh-rate picker, whose rows are all one size and differ only in rate. The
    /// resolution picker must use `sizeBinding` instead.
    private var modeBinding: Binding<String> {
        Binding(
            get: { display.currentMode?.id ?? "" },
            set: { id in
                guard let mode = display.availableModes.first(where: { $0.id == id }) else { return }
                model.setMode(mode, for: display)
            })
    }

    /// Resolution selection, by size only.
    ///
    /// Both halves matter. The getter tags by size so a 120 Hz current mode still matches the curated
    /// 170 Hz row instead of leaving the picker blank; the setter re-resolves the rate so switching
    /// size keeps 120 Hz whenever the new size offers it.
    private var sizeBinding: Binding<String> {
        Binding(
            get: { display.currentMode?.sizeKey ?? "" },
            set: { key in
                guard let target = display.curatedModes.first(where: { $0.sizeKey == key }) else { return }
                let mode = DisplayModeSwitcher.mode(
                    matchingSizeOf: target,
                    preservingRate: display.currentMode?.refreshRate ?? 0,
                    in: display.availableModes)
                model.setMode(mode, for: display)
            })
    }

    // MARK: Brightness

    private var brightness: Float { model.brightness.brightness(for: display.id) }
    private var phase: BrightnessPhase { model.brightness.phase(for: display.id) }

    @ViewBuilder
    private var brightnessSection: some View {
        let availability = model.brightness.availability[display.id] ?? ControllerAvailability()
        let userOverride = model.brightness.userOverride(for: display.id)
        let details = model.brightness.probeDetails[display.id] ?? [:]

        Section("Brightness") {
            // The same slider as the menu's, so brightness can be set from here while comparing
            // controllers, without closing the window to reach the menu.
            LabeledContent {
                HStack(spacing: 8) {
                    Slider(
                        value: Binding(
                            get: { Double(brightness) },
                            set: { model.setBrightness(Float($0), for: display) }),
                        in: 0...1
                    ) {
                        Text("Brightness")
                    }
                    .labelsHidden()
                    .disabled(model.brightness.controller(for: display.id) == nil)
                    Text("\(Int((brightness * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            } label: {
                Text("Brightness")
            }

            Picker("Controller", selection: Binding(
                get: { userOverride },
                set: { model.setController($0, for: display) })
            ) {
                Text("Automatic").tag(BrightnessControllerKind?.none)
                ForEach(BrightnessControllerKind.allCases) { kind in
                    Text(kind.label + (availability.isAvailable(kind) ? "" : " (unavailable)"))
                        .tag(BrightnessControllerKind?.some(kind))
                }
            }
            .pickerStyle(.radioGroup)

            LabeledContent("Status") { phaseLabel }

            if let warning = model.brightness.warnings[display.id] {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            // The probe details explain the status above; worth having, not worth the space by
            // default.
            if !details.isEmpty {
                DisclosureGroup("Probe results") {
                    ForEach(BrightnessControllerKind.allCases) { kind in
                        if let detail = details[kind] {
                            LabeledContent(kind.label) {
                                Text(detail)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                            }
                            .font(.callout)
                        }
                    }
                }
            }
        }
    }

    /// The probe cycle, in words. "Checking" and "waiting for DDC" are the app doing the right
    /// thing, and used to be indistinguishable from "nothing works".
    @ViewBuilder
    private var phaseLabel: some View {
        switch phase {
        case .probing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking which controllers this display supports…")
            }
            .foregroundStyle(.secondary)
        case .heldForDDC:
            Label("Waiting for the monitor's DDC to answer — it has worked before, and the "
                + "brightness you set is kept in the meantime.", systemImage: "clock")
                .foregroundStyle(.secondary)
        case .ready(let kind):
            Label("Using \(kind.label)", systemImage: kind.isHardware ? "bolt.fill" : "circle.lefthalf.filled")
        case .unavailable:
            Label("No brightness control available", systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Identity

    /// The tier explanation is shown, not hidden: a `.location` key silently breaking on a port swap
    /// is confusing unless the user was told that is how it works.
    private var identitySection: some View {
        Section {
            LabeledContent("Vendor / Product") {
                Text(String(format: "0x%04X / 0x%04X", display.identity.vendorID, display.identity.productID))
                    .monospaced()
            }
            LabeledContent("Profile key") {
                Text(display.id).monospaced().textSelection(.enabled)
            }
            if model.ambiguousKeys.contains(display.id) {
                // Surfaced here as well as in the menu: an unconfirmed identity means brightness
                // and HiDPI settings may be attached to the wrong monitor.
                HStack(spacing: 8) {
                    Label("Identity unconfirmed", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("This is a separate display") { model.pinIdentity(for: display) }
                }
            }
        } header: {
            Text("Identity")
        } footer: {
            Text(display.identity.keyTier.explanation)
        }
    }
}
