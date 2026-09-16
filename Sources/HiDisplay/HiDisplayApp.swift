import HiDisplayKit
import SwiftUI

/// HiDisplay — menu-bar HiDPI and brightness control for macOS 15+.
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
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var terminationStarted = false
    private var terminationReplied = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu bar only, no Dock icon
        Log.app.notice("HiDisplay \(AppModel.version, privacy: .public) launched")
        Task { @MainActor in
            await AppModel.shared.start()
        }
    }

    /// Software dimming must not outlive the app, and the profile flush must finish before exit.
    ///
    /// CoreGraphics reverts gamma when a process dies, so a crash is already covered — but a clean quit
    /// is fast enough that the display would visibly stay dim for a moment without this, and a shade
    /// window is not reverted by the OS at all. `applicationWillTerminate` is synchronous and the
    /// process exits the moment it returns, so the async cleanup runs here under `.terminateLater`
    /// and the app replies once it is done.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // AppKit does not de-duplicate `terminate:`. A second ⌘Q while the flush is running must
        // not reply early; one reply for the first request ends the process for both.
        guard !terminationStarted else { return .terminateLater }
        terminationStarted = true
        Task {
            await AppModel.shared.stop()
            Log.app.notice("HiDisplay terminating")
            replyToTermination(sender)
        }
        // A stalled volume must not turn Quit into Force Quit: the flush is uncancellable, so the
        // bound is a second task racing it rather than a cancellation. (A task group cannot do this;
        // it awaits every child, including the one that cannot be cancelled.)
        Task {
            try? await Task.sleep(for: .seconds(3))
            if !terminationReplied { Log.app.error("profile flush did not finish in 3 s; quitting anyway") }
            replyToTermination(sender)
        }
        return .terminateLater
    }

    private func replyToTermination(_ app: NSApplication) {
        guard !terminationReplied else { return }
        terminationReplied = true
        app.reply(toApplicationShouldTerminate: true)
    }
}
