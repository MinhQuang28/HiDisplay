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

    public init(
        isSupported: Bool,
        kind: BrightnessControllerKind,
        currentValue: Float? = nil,
        rawMinimum: UInt16? = nil,
        rawMaximum: UInt16? = nil,
        detail: String = ""
    ) {
        self.isSupported = isSupported
        self.kind = kind
        self.currentValue = currentValue
        self.rawMinimum = rawMinimum
        self.rawMaximum = rawMaximum
        self.detail = detail
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
