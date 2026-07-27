import HiDisplayKit
import SwiftUI

/// The menu-bar panel: one section per display, then global commands.
struct MenuContent: View {

    @EnvironmentObject private var model: AppModel

    /// Opens the `Settings` scene.
    ///
    /// `SettingsLink` is the only reliable route from inside a `MenuBarExtra`. The obvious
    /// `NSApp.sendAction(Selector(("showSettingsWindow:")))` silently does nothing here: an accessory
    /// app has no key window, so the action finds no target in the responder chain and the button
    /// appears dead — which is exactly how it behaved before this was fixed.
    ///
    /// `SettingsLink` is macOS 14+, so the selector remains as the fallback for the 13 deployment
    /// target. It also activates the app first, without which the Settings window can open behind
    /// whatever is frontmost.
    @ViewBuilder
    private var settingsButton: some View {
        if #available(macOS 14.0, *) {
            SettingsLink { Text("Settings…") }
                .keyboardShortcut(",", modifiers: .command)
                .simultaneousGesture(TapGesture().onEnded {
                    NSApp.activate(ignoringOtherApps: true)
                })
        } else {
            Button("Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                if NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) { return }
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.displays.isEmpty {
                Text("No displays detected")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(model.displays) { display in
                    DisplaySection(display: display)
                    if display.id != model.displays.last?.id {
                        Divider()
                    }
                }
            }

            Divider()

            // Counts only what can be synced: with a laptop plus one monitor there is nothing to
            // match, since the built-in panel is not this app's to read or write.
            if model.brightnessManagedDisplays.count > 1 {
                Button("Sync Displays") { model.syncAllDisplays() }
            }

            // Always visible, never behind a submenu: this is the command someone needs when their
            // screen is too dark to navigate a nested menu.
            Button("Reset Dimming") { model.resetDimming() }

            Divider()

            settingsButton
            Button("Quit HiDisplay") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(12)
        .frame(width: 300)
    }
}

/// One display's row: name, brightness slider, controller and resolution.
struct DisplaySection: View {

    let display: DisplayDevice
    @EnvironmentObject private var model: AppModel

    private var brightness: Float { model.brightness.brightness(for: display.id) }
    private var controller: BrightnessControllerKind? { model.brightness.controller(for: display.id) }

    /// One entry per logical size, so the menu stays short. Refresh-rate choice lives in Settings,
    /// where there is room to show it without turning this into a two-level menu.
    ///
    /// Read from the snapshot's precomputed list — deriving it here would rebuild a dictionary on
    /// every body evaluation, which a profiler showed happening far more often than displays change.
    private var curatedModes: [DisplayMode] { display.curatedModes }

    @ViewBuilder
    private var resolutionPicker: some View {
        if curatedModes.count > 1 {
            Picker("Resolution", selection: Binding(
                get: { display.currentMode.map { "\($0.width)x\($0.height)" } ?? "" },
                set: { key in
                    guard let mode = curatedModes.first(where: { "\($0.width)x\($0.height)" == key })
                    else { return }
                    model.setMode(mode, for: display)
                })
            ) {
                ForEach(curatedModes) { mode in
                    Text(mode.displayLabel).tag("\(mode.width)x\(mode.height)")
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .font(.caption)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(display.name)
                    .font(.headline)
                    .lineLimit(1)
                if display.isMain {
                    Text("Main").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if !display.isBuiltIn {
                    Text("\(Int((brightness * 100).rounded()))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit() // stops the row jittering as the number changes width
                }
            }

            if display.isBuiltIn {
                // No slider, and no "unavailable" wording either: nothing is missing here. macOS drives
                // this panel, and the row exists for its resolution picker.
                Text("Brightness is managed by macOS")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let controller {
                Slider(
                    value: Binding(
                        get: { Double(brightness) },
                        // The binding writes straight through: the coordinator updates its published
                        // state synchronously and hands the hardware write off, so the slider tracks
                        // the pointer even when the monitor's I2C is slow.
                        set: { model.setBrightness(Float($0), for: display) }),
                    in: 0...1)
                .controlSize(.small)

                HStack {
                    Label(controller.label, systemImage: controller.isHardware ? "bolt.fill" : "circle.lefthalf.filled")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                Text("No brightness control available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            resolutionPicker

            if let warning = model.brightness.warnings[display.id] {
                Text(warning)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            // Surfaced in the menu, not buried in Settings: an unconfirmed identity means brightness
            // and HiDPI settings may be attached to the wrong monitor, which the user should fix now.
            if model.ambiguousKeys.contains(display.id) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Identity unconfirmed")
                        .font(.caption2)
                    Button("This is a separate display") { model.pinIdentity(for: display) }
                        .font(.caption2)
                        .buttonStyle(.link)
                }
            }
        }
    }
}
