import HiDisplayKit
import SwiftUI

/// HiDisplay — menu-bar HiDPI and brightness control for macOS 13+.
///
/// Original codebase. Public APIs throughout, except for the two documented private-API shims in
/// `HiDisplayKit/PlatformShims`, which are required for DDC and native brightness on Apple Silicon and
/// degrade cleanly when unavailable. See docs/private-apis.md.
@main
struct HiDisplayApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Shared rather than scene-owned so `AppDelegate` can run shutdown cleanup on the same instance
    /// that owns the shade windows — quit cleanup must not depend on SwiftUI teardown order.
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra("HiDisplay", systemImage: "display") {
            MenuContent()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window) // sliders need a real window; the plain menu style cannot host them

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

/// Menu-bar accessory lifecycle.
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu bar only, no Dock icon
        Log.app.notice("HiDisplay \(AppModel.version, privacy: .public) launched")
        Task { @MainActor in
            await AppModel.shared.start()
        }
    }

    /// Software dimming must not outlive the app.
    ///
    /// CoreGraphics reverts gamma when a process dies, so a crash is already covered — but a clean quit
    /// is fast enough that the display would visibly stay dim for a moment without this, and a shade
    /// window is not reverted by the OS at all.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppModel.shared.stop()
        }
        Log.app.notice("HiDisplay terminating")
    }
}
