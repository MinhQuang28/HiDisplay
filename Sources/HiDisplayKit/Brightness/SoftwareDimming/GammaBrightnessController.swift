import CoreGraphics
import Foundation

/// Software dimming by shrinking the display's gamma ramp.
///
/// Cheap, needs no DDC, and works on displays that have no controllable backlight at all. The costs
/// are real and are why this is a fallback rather than a default: it changes colour output, it is
/// wrong under HDR, and a display left with a shrunk ramp looks broken.
///
/// **Crash safety.** CoreGraphics reverts gamma tables set by a process when that process dies, so a
/// crash cannot permanently leave a display dim. `resetAll()` still exists for clean quit and for the
/// emergency reset command, because relying on the crash path for normal shutdown would leave the
/// display dim for the moment between quit and cleanup.
public final class GammaBrightnessController: BrightnessController, @unchecked Sendable {

    public let kind: BrightnessControllerKind = .gamma

    /// Never dim all the way to black — a display at 0 with no visible UI is indistinguishable from
    /// broken hardware, and the user may not be able to find the menu bar to fix it.
    public static let minimumFactor: Float = 0.10

    private var appliedFactors: [CGDirectDisplayID: Float] = [:]
    private let lock = NSLock()

    public init() {}

    public func probe(display: DisplayDevice) async -> BrightnessProbeResult {
        // Gamma is available whenever CoreGraphics gives us a real display with a gamma table.
        let capacity = CGDisplayGammaTableCapacity(display.cgDisplayID)
        guard capacity > 0 else {
            return BrightnessProbeResult(
                isSupported: false, kind: .gamma,
                detail: "display reports no gamma table capacity")
        }
        return BrightnessProbeResult(
            isSupported: true, kind: .gamma,
            currentValue: lock.withLock { appliedFactors[display.cgDisplayID] } ?? 1.0,
            detail: "gamma table capacity \(capacity)")
    }

    public func getBrightness(display: DisplayDevice) async throws -> Float {
        // There is no way to ask the display what its gamma-dimmed brightness is, so the app's own
        // last applied value is the source of truth. Defaulting to 1.0 (undimmed) is the safe answer
        // for a display we have not touched.
        lock.withLock { appliedFactors[display.cgDisplayID] } ?? 1.0
    }

    public func setBrightness(_ value: Float, display: DisplayDevice) async throws {
        let factor = max(Self.minimumFactor, min(value, 1.0))
        // Formula rather than a table: it needs no allocation and no per-display capacity handling,
        // and scaling the maximum is exactly the "reduce output" operation wanted here.
        let error = CGSetDisplayTransferByFormula(
            display.cgDisplayID,
            0, factor, 1.0,
            0, factor, 1.0,
            0, factor, 1.0)
        guard error == .success else {
            throw DDCError.ioError(code: Int32(error.rawValue))
        }
        lock.withLock { appliedFactors[display.cgDisplayID] = factor }
    }

    public func reset(display: DisplayDevice) async {
        let hadFactor = lock.withLock { appliedFactors.removeValue(forKey: display.cgDisplayID) != nil }
        guard hadFactor else { return }
        // Restore the identity ramp for this display specifically, so resetting one display does not
        // clobber a colour profile the user has active on another.
        CGSetDisplayTransferByFormula(
            display.cgDisplayID,
            0, 1.0, 1.0,
            0, 1.0, 1.0,
            0, 1.0, 1.0)
    }

    /// Emergency reset: hands every display back to ColorSync.
    ///
    /// Uses the global restore rather than per-display formulas because the point of the emergency
    /// path is to work even when the app's own bookkeeping is wrong — including for displays it does
    /// not know it dimmed.
    public func resetAll() {
        lock.withLock { appliedFactors.removeAll() }
        CGDisplayRestoreColorSyncSettings()
        Log.gamma.notice("restored ColorSync gamma for all displays")
    }
}
