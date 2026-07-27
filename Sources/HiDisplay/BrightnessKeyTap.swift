import AppKit
import HiDisplayKit

/// Intercepts the keyboard's brightness keys so they can drive an external display.
///
/// macOS routes F1/F2 to the built-in panel only; on a laptop docked to an external monitor they do
/// nothing useful. This taps the system-defined event stream, works out which display the user means,
/// and adjusts it.
///
/// **Pass-through rule.** When the built-in display is among the targets, the event is returned
/// unmodified so macOS handles that panel itself — which keeps the native brightness HUD and the
/// system's own preference tracking. Only a press that concerns *external* displays exclusively is
/// consumed. That way the feature adds behaviour without taking any away.
///
/// **Accessibility is optional.** Without permission the tap simply never starts; the menu-bar sliders
/// keep working, and Settings explains what is missing and why.
@MainActor
final class BrightnessKeyTap {

    /// `NSEvent.EventTypeSystemDefined`. Media and brightness keys arrive here, not as key-down events.
    private static let systemDefinedEventType = CGEventType(rawValue: 14)!
    /// `NX_SUBTYPE_AUX_CONTROL_BUTTONS`.
    private static let auxControlSubtype: Int16 = 8
    private static let brightnessUp = 2   // NX_KEYTYPE_BRIGHTNESS_UP
    private static let brightnessDown = 3 // NX_KEYTYPE_BRIGHTNESS_DOWN

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Called with the signed step to apply and whether the "all displays" modifier was held.
    /// Returns true if an external display was adjusted, which is what decides consumption.
    var onBrightnessKey: ((Float, Bool) -> Bool)?

    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system permission prompt. Harmless to call when already trusted.
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard Self.isAccessibilityTrusted else {
            Log.app.notice("brightness key tap not started: Accessibility permission not granted")
            return false
        }

        let mask = CGEventMask(1 << Self.systemDefinedEventType.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // `.defaultTap` rather than `.listenOnly`: consuming the event is the whole point when the
            // press concerns an external display, otherwise macOS would also dim the built-in one.
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: brightnessTapCallback,
            userInfo: context)
        else {
            Log.app.error("CGEvent.tapCreate failed for the brightness key tap")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        tap = port
        runLoopSource = source
        Log.app.notice("brightness key tap started")
        return true
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        self.tap = nil
        runLoopSource = nil
        Log.app.notice("brightness key tap stopped")
    }

    /// The system disables a tap that takes too long to respond. Re-enabling is the documented recovery,
    /// and without it the keys silently stop working until the app restarts.
    fileprivate func reenableAfterTimeout() {
        guard let tap else { return }
        Log.app.notice("brightness key tap was disabled by timeout; re-enabling")
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// - Returns: `nil` to consume the event, or the event to pass it on.
    fileprivate func handle(_ event: CGEvent) -> CGEvent? {
        guard let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == Self.auxControlSubtype
        else { return event }

        // data1 packs the key code in the high half and state flags in the low half.
        let data1 = nsEvent.data1
        let keyCode = Int((data1 & 0xFFFF_0000) >> 16)
        let keyFlags = data1 & 0x0000_FFFF
        let isKeyDown = ((keyFlags & 0xFF00) >> 8) == 0x0A

        guard keyCode == Self.brightnessUp || keyCode == Self.brightnessDown else { return event }
        // Key-up is the other half of every press; acting on both would double every step.
        guard isKeyDown else { return event }

        let flags = event.flags
        // Option for a finer step, Control to hit every display — chosen because neither collides with
        // a system brightness shortcut.
        let fine = flags.contains(.maskAlternate)
        let allDisplays = flags.contains(.maskControl)

        let magnitude = BrightnessKeyResolver.step(fine: fine)
        let delta = keyCode == Self.brightnessUp ? magnitude : -magnitude

        let handledExternally = onBrightnessKey?(delta, allDisplays) ?? false
        // Consume only when nothing else needs to see it. If a built-in display was involved, macOS
        // must still get the event so it adjusts that panel and shows its HUD.
        return handledExternally ? nil : event
    }
}

/// C callback trampoline.
private let brightnessTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<BrightnessKeyTap>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { tap.reenableAfterTimeout() }
        return Unmanaged.passUnretained(event)
    }

    // Event taps are delivered on the thread that registered the run-loop source, which is main here.
    return MainActor.assumeIsolated {
        tap.handle(event).map { Unmanaged.passUnretained($0) }
    }
}
