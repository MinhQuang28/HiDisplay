import CoreGraphics
import Foundation

public enum BrightnessControllerKind: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Apple-attached panel via DisplayServices / IODisplay.
    case native
    /// External monitor's own backlight over DDC/CI.
    case ddc
    /// Software dimming by shrinking the display's gamma ramp.
    case gamma
    /// Software dimming by covering the display with a translucent black window.
    case shade

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .native: return "Native"
        case .ddc: return "DDC"
        case .gamma: return "Gamma (software)"
        case .shade: return "Shade (software)"
        }
    }

    /// True when the controller changes real backlight output rather than faking it.
    public var isHardware: Bool { self == .native || self == .ddc }
}

public struct BrightnessProbeResult: Sendable {
    public var isSupported: Bool
    public var kind: BrightnessControllerKind
    /// Value read during the probe, when the controller can read. `nil` is normal for write-only paths.
    public var currentValue: Float?
    /// Raw monitor range, for DDC. Monitors are not all 0…100.
    public var rawMinimum: UInt16?
    public var rawMaximum: UInt16?
    /// Why the probe concluded what it did — shown in diagnostics and in the Settings UI, so an
    /// unsupported display explains itself instead of just being greyed out.
    public var detail: String
    /// True when a failed probe may succeed if repeated — a display that has just woken needs a few
    /// seconds before its registry attributes and DDC bus answer again. False both for success and
    /// for failures the display itself proved, like answering every read with the null message.
    public var isTransient: Bool
    /// DDC only: the monitor answered every frame shape with the null message. Steady-state that
    /// means "no DDC" and is deliberately not transient — but observed on real hardware right after
    /// a replug, when a monitor's DDC firmware can lag its link by a moment. The coordinator uses
    /// this to grant exactly one delayed re-probe after a settle, without reclassifying null answers
    /// as transient everywhere.
    public var isNullAnswer: Bool

    public init(
        isSupported: Bool,
        kind: BrightnessControllerKind,
        currentValue: Float? = nil,
        rawMinimum: UInt16? = nil,
        rawMaximum: UInt16? = nil,
        detail: String = "",
        isTransient: Bool = false,
        isNullAnswer: Bool = false
    ) {
        self.isSupported = isSupported
        self.kind = kind
        self.currentValue = currentValue
        self.rawMinimum = rawMinimum
        self.rawMaximum = rawMaximum
        self.detail = detail
        self.isTransient = isTransient
        self.isNullAnswer = isNullAnswer
    }
}

/// One way of changing a display's apparent brightness.
///
/// `probe` must never change what the user sees. Probing by writing a value and reading it back is
/// tempting and is how other tools do it, but it makes plugging in a monitor visibly flicker, and on
/// a monitor that accepts writes but reports nonsense it can leave the panel at the probe value.
public protocol BrightnessController: AnyObject, Sendable {
    var kind: BrightnessControllerKind { get }

    func probe(display: DisplayDevice) async -> BrightnessProbeResult
    func getBrightness(display: DisplayDevice) async throws -> Float
    func setBrightness(_ value: Float, display: DisplayDevice) async throws
    /// Returns the display to an undimmed state and drops any resources held for it.
    func reset(display: DisplayDevice) async
}

/// A display's brightness as the app understands it.
public struct BrightnessState: Codable, Equatable, Sendable {
    /// What the user asked for, 0…1. Shown in the UI immediately.
    public var requestedValue: Float
    /// What the app believes is on screen after mapping and clamping.
    public var effectiveValue: Float
    /// Hardware component, when hardware and software dimming are combined.
    public var hardwareValue: Float?
    public var softwareValue: Float?
    public var controller: BrightnessControllerKind

    public init(
        requestedValue: Float,
        effectiveValue: Float,
        hardwareValue: Float? = nil,
        softwareValue: Float? = nil,
        controller: BrightnessControllerKind
    ) {
        self.requestedValue = requestedValue
        self.effectiveValue = effectiveValue
        self.hardwareValue = hardwareValue
        self.softwareValue = softwareValue
        self.controller = controller
    }
}

// MARK: - Controller-specific extra surfaces

/// The bookkeeping every software-dimming controller needs beyond `BrightnessController`: an
/// immediate, total undo. Hardware controllers have no equivalent — DDC and native hold their value
/// in the monitor, not in a table this app owns — which is why this is its own protocol rather than
/// folded into `BrightnessController`.
///
/// Kept `@MainActor`, same as `BrightnessCoordinator` itself: `ShadeBrightnessController` touches
/// `NSWindow` and is only safely callable from the main actor, and `reapplySoftwareDimming` /
/// `handleDisplaysChanged` depend on these calls staying synchronous from the coordinator's own
/// MainActor methods — making them `async` would reintroduce the reconfiguration flash the fast path
/// exists to avoid (see `reapplySoftwareDimming`'s doc comment).
@MainActor
public protocol SoftwareDimmingController: BrightnessController {
    /// Clears every applied dim immediately. Backs `BrightnessCoordinator.resetAllDimming`.
    func resetAll()
}

/// `GammaBrightnessController`'s extra surface, named separately so `BrightnessCoordinator` can hold
/// (and tests can inject a fake for) gamma-specific bookkeeping without a concrete CoreGraphics
/// dependency.
public protocol GammaDimmingController: SoftwareDimmingController {
    func prune(keeping live: Set<CGDirectDisplayID>)
    func reapplyAll()
}

/// `ShadeBrightnessController`'s extra surface, same reasoning as `GammaDimmingController`.
public protocol ShadeDimmingController: SoftwareDimmingController {
    func reposition(displays: [DisplayDevice])
}

/// `DDCBrightnessController`'s extra surface: persisted session facts and bulk invalidation. No other
/// controller has a notion of "facts learned about the bus", so this stays off `BrightnessController`.
public protocol DDCControlling: BrightnessController {
    func seedFacts(_ facts: DDCSessionFacts, for key: String) async
    func facts(for key: String) async -> DDCSessionFacts?
    func invalidateAll(except liveKeys: Set<String>) async
}

// Structural conformance only. `GammaBrightnessController` and `ShadeBrightnessController` already
// implement every requirement of their protocol above; declaring the conformance here — rather than
// editing their own files — keeps those files owned by the software-dimming phase while still letting
// `BrightnessCoordinator` depend on a protocol it can fake in tests.
extension GammaBrightnessController: GammaDimmingController {}
extension ShadeBrightnessController: ShadeDimmingController {}
