import CoreGraphics
import Foundation

/// Runtime binding for DisplayServices brightness control of Apple-attached panels.
///
/// **Why this exists.** `IODisplaySetFloatParameter(kIODisplayBrightnessKey)` and
/// `CGDisplaySetUserBrightness` have no effect on the built-in display of an Apple Silicon Mac. The
/// working entry points are in the private DisplayServices framework:
///
/// ```c
/// int DisplayServicesGetBrightness(CGDirectDisplayID, float *);
/// int DisplayServicesSetBrightness(CGDirectDisplayID, float);
/// void DisplayServicesBrightnessChanged(CGDirectDisplayID, double);
/// ```
///
/// **Evidence level: experimental observation** — symbol names and signatures from open-source
/// implementations and framework symbol inspection, not Apple documentation. See docs/private-apis.md.
///
/// **Known behaviour to design around:** `DisplayServicesSetBrightness` does not persist the value
/// into system preferences, so Control Center can overwrite it. Reading a different value back is
/// therefore not an error, and callers must not treat a mismatch as a failed write.
///
/// Immutable after `init` — every stored property is a `let` holding a C function pointer — so the
/// single shared instance is safe to touch from any isolation domain.
public final class DisplayServicesShim: @unchecked Sendable {

    public static let shared = DisplayServicesShim()

    private typealias GetBrightnessFn =
        @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias BrightnessChangedFn = @convention(c) (CGDirectDisplayID, Double) -> Void

    private let getFn: GetBrightnessFn?
    private let setFn: SetBrightnessFn?
    private let changedFn: BrightnessChangedFn?

    public let isAvailable: Bool
    public let unavailableReason: String?

    private init() {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        let handle = dlopen(path, RTLD_LAZY)

        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            resolveSymbol(handle, name, as: type)
        }

        let get = symbol("DisplayServicesGetBrightness", as: GetBrightnessFn.self)
        let set = symbol("DisplayServicesSetBrightness", as: SetBrightnessFn.self)
        changedFn = symbol("DisplayServicesBrightnessChanged", as: BrightnessChangedFn.self)
        getFn = get
        setFn = set

        // Get and set are required; the change notification is a nice-to-have, so its absence must
        // not disable native brightness.
        var missing: [String] = []
        if handle == nil { missing.append("dlopen(DisplayServices)") }
        if get == nil { missing.append("DisplayServicesGetBrightness") }
        if set == nil { missing.append("DisplayServicesSetBrightness") }

        isAvailable = missing.isEmpty
        unavailableReason = missing.isEmpty ? nil : "missing: \(missing.joined(separator: ", "))"
        if missing.isEmpty {
            Log.shims.debug("DisplayServices symbols resolved")
        } else {
            Log.shims.notice("DisplayServices unavailable: \(missing.joined(separator: ", "), privacy: .public)")
        }
    }

    /// Returns `nil` rather than a sentinel when the read fails, so callers cannot mistake a failure
    /// for "brightness is 0" and dim a display to black.
    ///
    /// Gated on `isAvailable`, not just `getFn`: if the set symbol is missing this shim must not
    /// half-work, or a probe would report a controller whose writes can never succeed.
    public func brightness(for display: CGDirectDisplayID) -> Float? {
        guard isAvailable, let getFn else { return nil }
        var value: Float = 0
        let status = getFn(display, &value)
        guard status == 0 else {
            Log.shims.debug("DisplayServicesGetBrightness returned \(status)")
            return nil
        }
        return value
    }

    @discardableResult
    public func setBrightness(_ value: Float, for display: CGDirectDisplayID) -> Bool {
        guard isAvailable, let setFn else { return false }
        let clamped = min(max(value, 0), 1)
        let status = setFn(display, clamped)
        guard status == 0 else {
            Log.shims.debug("DisplayServicesSetBrightness returned \(status)")
            return false
        }
        // Best-effort: nudges the OS so the on-screen brightness HUD and Control Center agree with us.
        changedFn?(display, Double(clamped))
        return true
    }
}
