import HiDisplayKit
import SwiftUI

/// App-level settings: launch at login, the escape hatch, and the version.
struct GeneralPage: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Open HiDisplay at login", isOn: Binding(
                    get: { model.loginItemState.isOn },
                    set: { model.setLaunchAtLogin($0) }))
                loginItemStatus
            } footer: {
                Text("Brightness settings are remembered per display and reapplied when it reconnects, "
                    + "so opening at login means an external monitor comes back at the brightness you "
                    + "left it.")
            }

            Section {
                // Duplicated from the menu on purpose: someone whose screen is too dark to read the
                // menu may already have Settings open.
                LabeledContent("Software dimming") {
                    Button("Reset All Dimming") { model.resetDimming() }
                }
            } header: {
                Text("Recovery")
            } footer: {
                Text("Clears gamma and overlay dimming on every display. Does not touch a monitor's own "
                    + "backlight, which is its real setting.")
            }

            Section("About") {
                LabeledContent("Version") { Text(AppModel.version).monospacedDigit() }
                LabeledContent("Displays detected") { Text("\(model.displays.count)") }
                LabeledContent("License") { Text("PolyForm Noncommercial 1.0.0") }
            }
        }
        .formStyle(.grouped)
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
                    Text("Waiting for approval in System Settings")
                    Text("HiDisplay is registered but switched off under Login Items & Extensions.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open Login Items…") {
                        if let url = URL(string:
                            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        case .unavailable(let reason):
            Label(reason, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.callout)
        }
    }
}
