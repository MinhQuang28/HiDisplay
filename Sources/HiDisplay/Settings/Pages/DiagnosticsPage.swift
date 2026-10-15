import HiDisplayKit
import SwiftUI

/// The support report, and whether the private-API shims resolved on this macOS.
struct DiagnosticsPage: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Support report") {
                    HStack {
                        if let path = model.lastExportPath {
                            Button("Show in Finder") {
                                NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                            }
                        }
                        Button("Export Diagnostics…") { model.exportDiagnostics() }
                    }
                }
                if let path = model.lastExportPath {
                    LabeledContent("Last export") {
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                if let error = model.diagnosticsError {
                    Label(error, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Exports a JSON report describing your displays, which brightness controllers were "
                    + "found, and why each probe succeeded or failed. It contains no username, no file "
                    + "paths from your home folder, no monitor serial numbers and no raw EDID — serials "
                    + "appear only as the truncated hash already used to tell displays apart.")
            }

            Section {
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
            } header: {
                Text("Private API status")
            } footer: {
                Text("These two use symbols that are not part of the public macOS SDK. They are looked "
                    + "up at runtime, and if a future macOS removes them the app falls back to software "
                    + "dimming instead of failing.")
            }
        }
        .formStyle(.grouped)
    }

    private func shimStatus(available: Bool, reason: String?) -> some View {
        Label(
            available ? "Available" : (reason ?? "Unavailable"),
            systemImage: available ? "checkmark.circle.fill" : "xmark.circle.fill")
            .foregroundStyle(available ? .green : .orange)
    }
}
