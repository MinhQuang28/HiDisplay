import CoreGraphics
import Foundation

/// Which display the brightness keys should act on.
public enum BrightnessKeyTarget: String, Codable, Sendable, CaseIterable, Identifiable {
    /// The display the pointer is currently over. The most predictable choice with two monitors, because
    /// it matches where the user is already looking.
    case displayUnderMouse
    /// Whichever display holds the menu bar.
    case mainDisplay
    /// Every external display, leaving the built-in panel to macOS.
    case allExternal
    /// Everything, built-in included.
    case allDisplays

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .displayUnderMouse: return "Display under the pointer"
        case .mainDisplay: return "Main display"
        case .allExternal: return "All external displays"
        case .allDisplays: return "All displays"
        }
    }
}

/// Turns a key press into the set of displays to adjust.
///
/// Pure so the whole targeting table is testable — this decides what happens when someone taps F1, and
/// getting it wrong means the wrong screen dims, which is both confusing and hard to report.
public enum BrightnessKeyResolver {

    /// macOS moves brightness in sixteenths; matching that makes the keys feel native rather than
    /// "some app is intercepting these".
    public static let coarseStep: Float = 1.0 / 16.0
    /// Quarter of a normal step, for the modifier-held case.
    public static let fineStep: Float = 1.0 / 64.0

    public static func step(fine: Bool) -> Float { fine ? fineStep : coarseStep }

    /// - Parameters:
    ///   - pointer: cursor position in CoreGraphics' flipped, global coordinate space — the same space
    ///     `DisplayDevice.frame` uses. Passing an AppKit `NSEvent.mouseLocation` here would silently
    ///     pick the wrong display on a multi-monitor desk, because that origin is bottom-left.
    ///   - forceAllDisplays: set when the "all displays" modifier is held.
    public static func targets(
        strategy: BrightnessKeyTarget,
        displays: [DisplayDevice],
        pointer: CGPoint,
        forceAllDisplays: Bool = false
    ) -> [DisplayDevice] {
        guard !displays.isEmpty else { return [] }
        if forceAllDisplays { return displays }

        switch strategy {
        case .allDisplays:
            return displays
        case .allExternal:
            let external = displays.filter { !$0.isBuiltIn }
            // Falling back to everything when there is no external display keeps the keys working on a
            // laptop with nothing plugged in, rather than doing nothing at all.
            return external.isEmpty ? displays : external
        case .mainDisplay:
            return [displays.first(where: \.isMain) ?? displays[0]]
        case .displayUnderMouse:
            if let hit = displays.first(where: { $0.frame.contains(pointer) }) {
                return [hit]
            }
            // The pointer can sit in a gap between mismatched display frames; fall back rather than
            // swallowing the key press.
            return [displays.first(where: \.isMain) ?? displays[0]]
        }
    }

    /// Applies a step to a current value, clamped.
    public static func adjusted(_ current: Float, by delta: Float) -> Float {
        min(max(current + delta, 0), 1)
    }
}
