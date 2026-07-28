import AppKit
import Foundation

/// Software dimming by covering a display with a translucent black window.
///
/// The universal fallback: it works on DisplayLink docks, AirPlay receivers and virtual displays,
/// none of which have a backlight or a usable gamma table. It is last in the chain because it is the
/// most intrusive — it appears in screenshots and screen recordings, and a window that stops ignoring
/// input would make the machine unusable.
///
/// Every window created here is configured so that it cannot:
/// * take keyboard or mouse input (`ignoresMouseEvents`, never becomes key or main),
/// * appear in the app switcher or Mission Control (`.stationary`, `.ignoresCycle`),
/// * stop the user reaching the menu bar to turn it off (level is below the menu bar's).
@MainActor
public final class ShadeBrightnessController: BrightnessController {

    public nonisolated let kind: BrightnessControllerKind = .shade

    /// The darkest the shade will go. A fully opaque black overlay is indistinguishable from a dead
    /// display and leaves the user no way to find the menu bar and undo it.
    public static let maximumOpacity: CGFloat = 0.85

    private var windows: [CGDirectDisplayID: NSWindow] = [:]

    public init() {}

    public func probe(display: DisplayDevice) async -> BrightnessProbeResult {
        // A shade can always be placed, so this is the one controller that never reports unsupported.
        BrightnessProbeResult(
            isSupported: true, kind: .shade,
            currentValue: currentValue(for: display.cgDisplayID),
            detail: "overlay window dimming is always available")
    }

    public func getBrightness(display: DisplayDevice) async throws -> Float {
        currentValue(for: display.cgDisplayID)
    }

    public func setBrightness(_ value: Float, display: DisplayDevice) async throws {
        let clamped = CGFloat(min(max(value, 0), 1))
        let opacity = (1 - clamped) * Self.maximumOpacity

        guard opacity > 0.001 else {
            // Fully bright: tear the window down instead of leaving an invisible one around, so an
            // undimmed display has no overlay in screenshots at all.
            removeWindow(for: display.cgDisplayID)
            return
        }

        let window = windows[display.cgDisplayID] ?? makeWindow()
        windows[display.cgDisplayID] = window
        // Reposition on every set: the display's frame changes with resolution and rearrangement, and
        // a stale frame leaves part of the screen undimmed or dims part of a neighbour.
        window.setFrame(Self.appKitFrame(for: display), display: false)
        window.backgroundColor = NSColor.black.withAlphaComponent(opacity)
        window.orderFrontRegardless()
    }

    public func reset(display: DisplayDevice) async {
        removeWindow(for: display.cgDisplayID)
    }

    /// Emergency reset: removes every shade window, including any whose display has gone away.
    public func resetAll() {
        for (_, window) in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        Log.shade.notice("removed all shade overlays")
    }

    /// Re-places existing shades after a display rearrangement.
    public func reposition(displays: [DisplayDevice]) {
        let displaysByID = Dictionary(uniqueKeysWithValues: displays.map { ($0.cgDisplayID, $0) })
        for (displayID, window) in windows {
            guard let display = displaysByID[displayID] else {
                // The display is gone; drop its overlay rather than leaving it stranded on whatever
                // display macOS decides to put it on.
                window.orderOut(nil)
                windows.removeValue(forKey: displayID)
                continue
            }
            window.setFrame(Self.appKitFrame(for: display), display: false)
        }
    }

    // MARK: - Coordinate spaces

    /// The AppKit frame to give the shade window for a display.
    ///
    /// `DisplayDevice.frame` is `CGDisplayBounds` — CoreGraphics' *top*-left-origin space — while
    /// `NSWindow.setFrame` expects AppKit's *bottom*-left-origin space. The two agree only when every
    /// display's top edge lines up with the primary's; stack a monitor above or below the laptop and
    /// a raw pass-through dims the wrong region entirely. Looking the display up in `NSScreen.screens`
    /// avoids converting at all (the same trick `BrightnessOSD` uses); the manual flip is only the
    /// fallback for the moment mid-reconfiguration when the screen list has not caught up yet.
    private static func appKitFrame(for display: DisplayDevice) -> CGRect {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[key] as? NSNumber)?.uint32Value == display.cgDisplayID
        }) {
            return screen.frame
        }
        return flippedFrame(display.frame, primaryHeight: CGDisplayBounds(CGMainDisplayID()).height)
    }

    /// Converts a CoreGraphics display frame to AppKit's space by flipping around the primary
    /// display's height. Pure, so the conversion — the part that is an easy off-by-a-screen bug —
    /// is testable without windows.
    static func flippedFrame(_ cgFrame: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: cgFrame.origin.x, y: primaryHeight - cgFrame.maxY,
               width: cgFrame.width, height: cgFrame.height)
    }

    // MARK: - Window

    private func currentValue(for displayID: CGDirectDisplayID) -> Float {
        guard let window = windows[displayID],
              let alpha = window.backgroundColor.alphaComponent as CGFloat?
        else { return 1.0 }
        return Float(1 - (alpha / Self.maximumOpacity))
    }

    private func makeWindow() -> NSWindow {
        let window = ShadeWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        // Below the menu bar on purpose: the user must always be able to reach the app's own
        // "Reset Dimming" command, even at maximum shade.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) - 1)
        window.collectionBehavior = [
            .canJoinAllSpaces,   // follows the user across Spaces instead of dimming only one
            .stationary,         // not dragged around by Mission Control
            .ignoresCycle,       // absent from the app switcher
            .fullScreenNone,     // never becomes its own full-screen Space
        ]
        window.animationBehavior = .none
        return window
    }

    private func removeWindow(for displayID: CGDirectDisplayID) {
        guard let window = windows.removeValue(forKey: displayID) else { return }
        window.orderOut(nil)
    }
}

/// A window that structurally cannot take focus.
///
/// Overriding these is belt-and-braces on top of `ignoresMouseEvents`: a borderless window can still
/// be made key programmatically, and a focused shade would swallow the user's keystrokes.
private final class ShadeWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { false }
}
