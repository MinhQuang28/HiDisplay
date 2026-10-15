import HiDisplayKit
import SwiftUI

/// Brightness-key interception: on/off, which display the keys target, and the permission it needs.
struct BrightnessKeysPage: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Use F1 and F2 for external displays", isOn: Binding(
                    get: { model.brightnessKeysEnabled },
                    set: { model.setBrightnessKeysEnabled($0) }))

                Picker("Keys adjust", selection: Binding(
                    get: { model.brightnessKeyTarget },
                    set: { model.setBrightnessKeyTarget($0) })
                ) {
                    ForEach(BrightnessKeyTarget.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!model.brightnessKeysEnabled)
            } footer: {
                Text("macOS sends F1 and F2 to the built-in display only, so on a laptop connected to "
                    + "an external monitor they do nothing useful. A press that concerns the built-in "
                    + "display is passed through unchanged, so that panel keeps its native behaviour "
                    + "and HUD.")
            }

            Section("Modifiers") {
                LabeledContent("⌥ Option") { Text("Quarter-size steps") }
                LabeledContent("⌃ Control") { Text("Every display at once") }
            }

            Section {
                accessibilityStatus
            } header: {
                Text("Permission")
            } footer: {
                Text("Reading key presses requires Accessibility access. HiDisplay only looks at the "
                    + "brightness keys and ignores everything else. Without it, the menu-bar sliders "
                    + "still work.")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var accessibilityStatus: some View {
        if model.isAccessibilityTrusted {
            Label("Accessibility permission granted", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            HStack {
                Label("Accessibility permission needed", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                Spacer()
                Button("Open Privacy & Security…") {
                    BrightnessKeyTap.requestAccessibility()
                    if let url = URL(string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}
