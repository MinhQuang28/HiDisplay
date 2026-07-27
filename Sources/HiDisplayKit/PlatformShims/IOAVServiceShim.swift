import Foundation
import IOKit

/// Runtime binding for the `IOAVService` I2C entry points used to speak DDC/CI on Apple Silicon.
///
/// **Why this exists.** `IOFramebuffer`'s `IOI2CSendRequest` path — what every Intel-era DDC tutorial
/// uses — does not work on Apple Silicon. The functioning route is a small set of `IOAVService`
/// symbols that live in IOKit but are absent from the public SDK headers:
///
/// ```c
/// IOAVServiceRef IOAVServiceCreateWithService(CFAllocatorRef, io_service_t);
/// IOReturn IOAVServiceReadI2C (IOAVServiceRef, uint32_t chip, uint32_t offset, void*, uint32_t);
/// IOReturn IOAVServiceWriteI2C(IOAVServiceRef, uint32_t chip, uint32_t offset, const void*, uint32_t);
/// ```
///
/// **Evidence level: experimental observation.** These signatures are reconstructed from
/// widely-deployed open-source implementations (MonitorControl and derivatives) plus symbol
/// inspection of IOKit — *not* from Apple documentation. They are unverified on hardware in this
/// build. See docs/private-apis.md.
///
/// **Safety contract.** Symbols are resolved with `dlsym`, never linked. If any lookup fails,
/// `isAvailable` is false, every call returns `kIOReturnUnsupported`, and the brightness stack falls
/// back to gamma or shade dimming. A future macOS that removes these symbols degrades the app; it
/// does not crash it.
///
/// Immutable after `init` — every stored property is a `let` holding a C function pointer — so the
/// single shared instance is safe to touch from any isolation domain.
public final class IOAVServiceShim: @unchecked Sendable {

    public static let shared = IOAVServiceShim()

    private typealias CreateWithServiceFn =
        @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias ReadI2CFn =
        @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    private typealias WriteI2CFn =
        @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeRawPointer, UInt32) -> IOReturn

    private let createWithService: CreateWithServiceFn?
    private let readI2C: ReadI2CFn?
    private let writeI2C: WriteI2CFn?

    /// All three symbols resolved. Anything less is treated as "no DDC on this machine".
    public let isAvailable: Bool
    /// Human-readable reason, surfaced in diagnostics so a support report explains itself.
    public let unavailableReason: String?

    private init() {
        // IOKit is already resident in every process; dlopen just gets us a handle to look symbols
        // up in. RTLD_NOLOAD would also work but fails on some SDK/dyld-cache combinations.
        let path = "/System/Library/Frameworks/IOKit.framework/IOKit"
        let handle = dlopen(path, RTLD_LAZY)

        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            resolveSymbol(handle, name, as: type)
        }

        guard handle != nil else {
            createWithService = nil
            readI2C = nil
            writeI2C = nil
            isAvailable = false
            unavailableReason = "could not dlopen IOKit at \(path)"
            Log.shims.error("IOAVService unavailable: dlopen failed")
            return
        }

        let create = symbol("IOAVServiceCreateWithService", as: CreateWithServiceFn.self)
        let read = symbol("IOAVServiceReadI2C", as: ReadI2CFn.self)
        let write = symbol("IOAVServiceWriteI2C", as: WriteI2CFn.self)

        createWithService = create
        readI2C = read
        writeI2C = write

        var missing: [String] = []
        if create == nil { missing.append("IOAVServiceCreateWithService") }
        if read == nil { missing.append("IOAVServiceReadI2C") }
        if write == nil { missing.append("IOAVServiceWriteI2C") }

        isAvailable = missing.isEmpty
        unavailableReason = missing.isEmpty ? nil : "missing symbols: \(missing.joined(separator: ", "))"
        if missing.isEmpty {
            Log.shims.debug("IOAVService symbols resolved")
        } else {
            Log.shims.notice("IOAVService unavailable: \(missing.joined(separator: ", "), privacy: .public)")
        }
    }

    /// Wraps an `IOAVServiceRef`. Holding it as `CFTypeRef` keeps ARC in charge of its lifetime, so
    /// there is no manual release to forget when a display disconnects mid-operation.
    public func makeService(for ioService: io_service_t) -> CFTypeRef? {
        guard let createWithService else { return nil }
        return createWithService(kCFAllocatorDefault, ioService)?.takeRetainedValue()
    }

    public func read(
        service: CFTypeRef,
        chipAddress: UInt32,
        offset: UInt32,
        into buffer: UnsafeMutableRawPointer,
        length: UInt32
    ) -> IOReturn {
        guard let readI2C else { return kIOReturnUnsupported }
        return readI2C(service, chipAddress, offset, buffer, length)
    }

    public func write(
        service: CFTypeRef,
        chipAddress: UInt32,
        offset: UInt32,
        from buffer: UnsafeRawPointer,
        length: UInt32
    ) -> IOReturn {
        guard let writeI2C else { return kIOReturnUnsupported }
        return writeI2C(service, chipAddress, offset, buffer, length)
    }
}
