import AppKit
import HiDisplayKit

/// Applies a resolution change and makes sure the user cannot end up stuck with one they cannot see.
///
/// A display can advertise a mode it fails to sync to — common over adapters and docks — and the result
/// is a black screen with no way back, because the control that would undo it is on the display that
/// went dark. macOS's own Displays panel solves this with a confirm-or-revert countdown, and so does
/// this: the change is applied, a dialog appears on the **main** display, and the previous mode is
/// restored automatically unless the user actively confirms.
///
/// The dialog is deliberately modal and app-activating: a passive notification would be missed by
/// someone staring at a screen that just went blank.
@MainActor
enum ModeChangeCoordinator {

    /// Long enough to read the dialog and find the trackpad, short enough not to leave someone staring
    /// at a dead screen. Matches the macOS Displays panel.
    static let revertAfter = 15

    enum Outcome {
        case kept
        case reverted
        case failed(String)
    }

    static func change(to mode: DisplayMode, on display: DisplayDevice) -> Outcome {
        let previous: DisplayMode
        do {
            previous = try DisplayModeSwitcher.apply(mode, to: display.cgDisplayID)
        } catch DisplayModeSwitcher.SwitchError.sameMode {
            return .kept
        } catch {
            return .failed("\(error)")
        }

        if confirmKeep(newMode: mode, previous: previous, displayName: display.name) {
            Log.modes.notice("resolution change kept")
            return .kept
        }

        do {
            try DisplayModeSwitcher.apply(previous, to: display.cgDisplayID)
            Log.modes.notice("resolution change reverted")
            return .reverted
        } catch {
            // Reverting failed too. Say so plainly rather than reporting success — the user needs to
            // know to use System Settings, and the recovery doc explains the rest.
            return .failed("could not revert to \(previous.displayLabel): \(error)")
        }
    }

    /// Returns true if the user confirmed before the countdown expired.
    private static func confirmKeep(newMode: DisplayMode, previous: DisplayMode, displayName: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Keep this resolution?"
        alert.addButton(withTitle: "Keep")
        alert.addButton(withTitle: "Revert")

        func text(_ remaining: Int) -> String {
            """
            \(displayName) is now \(newMode.displayLabel).

            Reverting to \(previous.displayLabel) in \(remaining) second\(remaining == 1 ? "" : "s").
            """
        }
        alert.informativeText = text(revertAfter)

        // An accessory app has no windows and would otherwise show this behind whatever is frontmost.
        NSApp.activate(ignoringOtherApps: true)

        var remaining = revertAfter
        let timer = Timer(timeInterval: 1, repeats: true) { timer in
            // A timer added to the main run loop fires on the main thread, so this isolation holds —
            // the compiler just cannot see it through the nonisolated closure type.
            MainActor.assumeIsolated {
                remaining -= 1
                if remaining <= 0 {
                    timer.invalidate()
                    NSApp.abortModal() // treated as "revert" below
                } else {
                    alert.informativeText = text(remaining)
                }
            }
        }
        // `.modalPanel` is required: while `runModal` is running, the main run loop is in modal mode and
        // a timer added only to `.default` would never fire — the countdown would freeze and the revert
        // would never happen, which is exactly the failure this whole mechanism exists to prevent.
        RunLoop.main.add(timer, forMode: .modalPanel)

        let response = alert.runModal()
        timer.invalidate()
        return response == .alertFirstButtonReturn
    }
}
