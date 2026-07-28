import AppKit
import SwiftUI

// The deployment target is macOS 13, and two APIs this app needs changed shape in macOS 14. These
// helpers hold the availability dance in one place so call sites stay readable and the deprecation
// warnings stay silenced for the right reason rather than ignored.

extension NSApplication {
    /// `activate(ignoringOtherApps:)` is deprecated from macOS 14, where the cooperative
    /// `activate()` replaces it (and the parameter is ignored anyway).
    func activateCompat() {
        if #available(macOS 14.0, *) {
            activate()
        } else {
            activate(ignoringOtherApps: true)
        }
    }
}

extension View {
    /// `onChange(of:perform:)` is deprecated from macOS 14 in favour of the two-parameter form.
    /// This app's uses never need the old or new value, so one zero-argument action covers both.
    @ViewBuilder
    func onChangeCompat<Value: Equatable>(
        of value: Value, perform action: @escaping () -> Void
    ) -> some View {
        if #available(macOS 14.0, *) {
            onChange(of: value) { _, _ in action() }
        } else {
            onChange(of: value) { _ in action() }
        }
    }
}
