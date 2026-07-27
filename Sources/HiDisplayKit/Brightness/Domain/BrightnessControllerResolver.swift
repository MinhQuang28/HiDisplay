import Foundation

/// Which controllers a probe found usable for one display.
public struct ControllerAvailability: Equatable, Sendable {
    public var native: Bool
    public var ddc: Bool
    public var gamma: Bool
    /// Always true in practice — a window can be placed over anything.
    public var shade: Bool

    public init(native: Bool = false, ddc: Bool = false, gamma: Bool = true, shade: Bool = true) {
        self.native = native
        self.ddc = ddc
        self.gamma = gamma
        self.shade = shade
    }

    public func isAvailable(_ kind: BrightnessControllerKind) -> Bool {
        switch kind {
        case .native: return native
        case .ddc: return ddc
        case .gamma: return gamma
        case .shade: return shade
        }
    }

    public var supportedKinds: [BrightnessControllerKind] {
        BrightnessControllerKind.allCases.filter(isAvailable)
    }
}

public struct ControllerDecision: Equatable, Sendable {
    public var kind: BrightnessControllerKind?
    /// Set when the user asked for a controller that turned out to be unavailable. The UI shows this
    /// rather than silently substituting something else, because "my override was ignored" with no
    /// explanation is worse than the override not being honoured.
    public var overrideIgnoredReason: String?

    public init(kind: BrightnessControllerKind?, overrideIgnoredReason: String? = nil) {
        self.kind = kind
        self.overrideIgnoredReason = overrideIgnoredReason
    }
}

/// Chooses the safest controller that actually works for a display.
///
/// Pure function over values so the whole priority table is unit-testable — this is the logic that
/// decides whether a monitor gets real backlight control or a black window over it, and getting it
/// wrong is very visible.
public enum BrightnessControllerResolver {

    /// Priority order: real backlight before faked, and gamma before shade because gamma does not
    /// show up in screenshots.
    public static func resolve(
        display: DisplayDevice,
        availability: ControllerAvailability,
        userOverride: BrightnessControllerKind? = nil
    ) -> ControllerDecision {
        // The built-in panel is macOS's, and this app does not touch it. macOS already gives it a
        // slider, the brightness keys, Control Center and ambient-light adaptation; a second owner of
        // that value can only fight them. It is also the one screen a user cannot unplug, which makes
        // it the worst possible place for this app to leave a display dimmed by gamma or an overlay.
        //
        // Enforced here rather than in the UI so that no path — a saved override from an older
        // version, a sync, a brightness key — can route a write to it.
        if display.isBuiltIn {
            return ControllerDecision(
                kind: nil,
                overrideIgnoredReason: userOverride == nil ? nil
                    : "HiDisplay only adjusts external displays; macOS owns the built-in panel's "
                        + "brightness.")
        }

        if let userOverride {
            if availability.isAvailable(userOverride) {
                return ControllerDecision(kind: userOverride)
            }
            let fallback = automaticChoice(display: display, availability: availability)
            return ControllerDecision(
                kind: fallback,
                overrideIgnoredReason:
                    "\(userOverride.label) is not available for this display; using "
                    + (fallback?.label ?? "no controller"))
        }
        return ControllerDecision(kind: automaticChoice(display: display, availability: availability))
    }

    static func automaticChoice(
        display: DisplayDevice,
        availability: ControllerAvailability
    ) -> BrightnessControllerKind? {
        // Built-in panels never reach here — see `resolve`. `native` stays in the table for the
        // external displays macOS drives through DisplayServices rather than DDC.
        if display.isBuiltIn { return nil }
        if availability.ddc { return .ddc }
        if availability.native { return .native }
        if availability.gamma { return .gamma }
        if availability.shade { return .shade }
        return nil
    }
}
