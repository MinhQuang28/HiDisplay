import Foundation
import IOKit

/// DDC/CI transport for Intel Macs, over `IOFramebuffer`'s I2C interface.
///
/// **Not implemented in this build, on purpose.**
///
/// The Intel path needs `IOI2CSendRequest`, which takes an `IOI2CRequest` struct. That struct is not
/// projected into Swift (it contains a function-pointer completion field), so using it requires
/// either a C shim target or hand-declaring the struct layout in Swift. Hand-declaring a kernel ABI
/// struct from memory is exactly the kind of guess that turns into memory corruption when a field
/// order or padding assumption is wrong — and this project's own rule is not to present assumptions
/// as facts.
///
/// What the real implementation needs, once an Intel test machine is available:
///
/// 1. A C shim target exposing `IOI2CRequest` and `IOI2CSendRequest` with the header's own layout,
///    so the ABI comes from the SDK rather than from memory.
/// 2. `IOFramebufferPortFromCGDisplayID` (or a vendor/product match over `IOFramebuffer` services)
///    to find the right framebuffer.
/// 3. `IOI2CInterfaceCount` / `IOI2CCopyInterfaceForBus` / `IOI2CInterfaceOpen`, one bus at a time,
///    with the connection closed on every exit path.
///
/// Until then this reports `.unsupported`, which makes the brightness stack fall back to gamma or
/// shade dimming on Intel — degraded but correct. See docs/ddc.md.
public struct IntelI2CTransport: DDCTransport {
    public let name = "intel-iofb-i2c"
    public var isUsable: Bool { false }

    public init(identity: DisplayIdentity) {}

    private static let reason =
        "Intel IOFramebuffer I2C transport is not implemented in this build; see docs/ddc.md"

    public func write(_ bytes: [UInt8]) async throws {
        throw DDCError.unsupported(reason: Self.reason)
    }

    public func read(length: Int) async throws -> [UInt8] {
        throw DDCError.unsupported(reason: Self.reason)
    }
}

/// Picks the transport that can actually reach a display.
public enum DDCTransportFactory {

    /// Sendable handle to `makeTransport`, so it can be used as a default argument for the injected
    /// factory without the compiler having to assume a plain function reference is concurrency-safe.
    public static let make: @Sendable (DisplayIdentity) -> DDCTransport? = { makeTransport(for: $0) }
    /// Tries Apple Silicon first, then Intel, and returns whichever binds. Returns `nil` when neither
    /// does — the caller then treats the display as having no hardware brightness control.
    public static func makeTransport(for identity: DisplayIdentity) -> DDCTransport? {
        let appleSilicon = AppleSiliconAVServiceTransport(identity: identity)
        if appleSilicon.isUsable { return appleSilicon }

        let intel = IntelI2CTransport(identity: identity)
        if intel.isUsable { return intel }

        Log.ddcTransport.notice(
            "no DDC transport for \(identity.stableKey, privacy: .public): \(appleSilicon.bindFailureReason ?? "unknown", privacy: .public)")
        return nil
    }
}
