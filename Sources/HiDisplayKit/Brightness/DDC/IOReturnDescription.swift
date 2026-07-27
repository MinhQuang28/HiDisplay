import Foundation
import IOKit

/// Turns a raw `IOReturn` into something a bug report can act on.
///
/// This exists because the first real DDC failure on hardware surfaced as `DDC I/O error -535740416`,
/// which tells a user nothing and tells a maintainer only slightly more. An `IOReturn` is a packed
/// triple, and the interesting part here is the *subsystem*: DCP returns its own codes that are not in
/// the standard `kIOReturn*` list at all, so decoding only the well-known constants would have printed
/// "unknown" and stopped there.
///
/// ```
/// bits 31..26  system    (0x38 = sys_iokit)
/// bits 25..12  subsystem (0 = general IOKit; anything else is driver-defined)
/// bits 11..0   code
/// ```
public enum IOReturnDescription {

    /// `sys_iokit`, the system field every IOKit error carries.
    static let iokitSystem: UInt32 = 0x38
    /// Subsystem seen from `IOAVServiceReadI2C`/`WriteI2C` on a connection with no I2C channel.
    /// Observed on macOS 26.5.2 through a Realtek USB-C display path — see Tests/HardwareMatrix.
    static let dcpAVSubsystem: UInt32 = 0x114

    public static func describe(_ code: Int32) -> String {
        let raw = UInt32(bitPattern: code)
        let system = (raw >> 26) & 0x3F
        let subsystem = (raw & 0x03FF_F000) >> 12
        let value = raw & 0xFFF

        let hex = String(format: "0x%08x", raw)

        guard system == iokitSystem else {
            return "\(hex) (not an IOKit error)"
        }

        if subsystem == 0, let known = generalIOKitNames[value] {
            return "\(hex) \(known)"
        }

        if subsystem == dcpAVSubsystem {
            // The actionable message. Every chip address and offset combination fails identically and
            // immediately on such a path, on both read and write — the signature of a link that carries
            // video but no I2C, rather than of a monitor that is merely slow or asleep.
            return "\(hex) — the display connection does not expose an I2C channel. This is normal for "
                + "many USB-C docks, HDMI adapters, KVM switches and virtual displays; the monitor's own "
                + "brightness cannot be reached, so software dimming is used instead."
        }

        return "\(hex) (IOKit subsystem 0x\(String(subsystem, radix: 16)), code 0x\(String(value, radix: 16)))"
    }

    /// The general `kIOReturn*` values worth naming. Deliberately not exhaustive — only the ones a DDC
    /// path realistically produces.
    private static let generalIOKitNames: [UInt32: String] = [
        0x2BC: "kIOReturnError",
        0x2BD: "kIOReturnNoMemory",
        0x2BE: "kIOReturnNoResources",
        0x2C0: "kIOReturnNoDevice",
        0x2C1: "kIOReturnNotPrivileged",
        0x2C2: "kIOReturnBadArgument",
        0x2C7: "kIOReturnUnsupported",
        0x2D0: "kIOReturnNotOpen",
        0x2D4: "kIOReturnBusy",
        0x2D6: "kIOReturnTimeout",
        0x2E2: "kIOReturnNotResponding",
    ]
}
