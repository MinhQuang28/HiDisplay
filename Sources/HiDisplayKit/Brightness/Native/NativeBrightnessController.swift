import CoreGraphics
import Foundation
import IOKit

/// Brightness control for Apple-attached panels.
///
/// Two paths, tried in order:
///
/// 1. `DisplayServicesSetBrightness` — the only thing that works for the built-in display on Apple
///    Silicon. Private, resolved via `DisplayServicesShim`.
/// 2. `IODisplaySetFloatParameter("brightness")` — the public Intel-era path. Kept because it is
///    public and costs nothing, but it is a no-op on Apple Silicon built-in panels.
///
/// If neither works the probe reports unsupported and the resolver drops to gamma dimming.
public final class NativeBrightnessController: BrightnessController {

    public let kind: BrightnessControllerKind = .native

    private let shim = DisplayServicesShim.shared

    public init() {}

    public func probe(display: DisplayDevice) async -> BrightnessProbeResult {
        // Reading is side-effect free, so unlike DDC this probe can safely read.
        if let value = shim.brightness(for: display.cgDisplayID) {
            return BrightnessProbeResult(
                isSupported: true, kind: .native, currentValue: value,
                detail: "DisplayServices reported \(String(format: "%.2f", value))")
        }
        if let value = Self.legacyBrightness(for: display.cgDisplayID) {
            return BrightnessProbeResult(
                isSupported: true, kind: .native, currentValue: value,
                detail: "IODisplay float parameter reported \(String(format: "%.2f", value))")
        }
        let reason = shim.isAvailable
            ? "neither DisplayServices nor IODisplay returned a brightness value"
            : (shim.unavailableReason ?? "DisplayServices unavailable")
        return BrightnessProbeResult(isSupported: false, kind: .native, detail: reason)
    }

    public func getBrightness(display: DisplayDevice) async throws -> Float {
        if let value = shim.brightness(for: display.cgDisplayID) { return value }
        if let value = Self.legacyBrightness(for: display.cgDisplayID) { return value }
        throw DDCError.unsupported(reason: "no native brightness read path")
    }

    public func setBrightness(_ value: Float, display: DisplayDevice) async throws {
        let clamped = min(max(value, 0), 1)
        if shim.setBrightness(clamped, for: display.cgDisplayID) { return }
        if Self.setLegacyBrightness(clamped, for: display.cgDisplayID) { return }
        throw DDCError.unsupported(reason: "no native brightness write path")
    }

    public func reset(display: DisplayDevice) async {
        // Native brightness is the display's real setting — there is nothing to undo. Resetting it to
        // some remembered value here would fight the user's own brightness keys.
    }

    // MARK: - Intel / legacy path

    /// Finds the `IODisplayConnect` service for a display and reads its float brightness parameter.
    ///
    /// Matching is by vendor/product because `CGDisplayIOServicePort` is long deprecated. On Apple
    /// Silicon there are no matching services, so this returns `nil` immediately and costs nothing.
    private static func withDisplayService<T>(
        _ displayID: CGDirectDisplayID,
        _ body: (io_service_t) -> T?
    ) -> T? {
        let wantVendor = CGDisplayVendorNumber(displayID)
        let wantProduct = CGDisplayModelNumber(displayID)
        var result: T?
        IORegistryAccess.forEachService(matchingClass: "IODisplayConnect") { service, _ in
            guard result == nil else { return }
            let vendor = registryUInt32(IORegistryAccess.property(service, "DisplayVendorID"))
            let product = registryUInt32(IORegistryAccess.property(service, "DisplayProductID"))
            guard vendor == wantVendor, product == wantProduct else { return }
            result = body(service)
        }
        return result
    }

    private static func legacyBrightness(for displayID: CGDirectDisplayID) -> Float? {
        withDisplayService(displayID) { service in
            var value: Float = 0
            // "brightness" is the string behind kIODisplayBrightnessKey, which is a C macro and so
            // is not projected into Swift.
            let status = IODisplayGetFloatParameter(service, 0, "brightness" as CFString, &value)
            return status == KERN_SUCCESS ? value : nil
        }
    }

    private static func setLegacyBrightness(_ value: Float, for displayID: CGDirectDisplayID) -> Bool {
        withDisplayService(displayID) { service in
            IODisplaySetFloatParameter(service, 0, "brightness" as CFString, value) == KERN_SUCCESS
                ? true : nil
        } ?? false
    }
}
