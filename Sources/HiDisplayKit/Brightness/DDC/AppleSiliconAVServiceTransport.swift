import Foundation
import IOKit

/// DDC/CI transport for Apple Silicon, over `IOAVService`.
///
/// The delicate part is not the I2C call — it is deciding *which* `DCPAVServiceProxy` belongs to the
/// display the caller means. The order of these registry nodes is not guaranteed to match
/// `CGGetOnlineDisplayList`, so matching by index would silently send one monitor's brightness
/// command to another. This transport therefore matches on vendor/product/serial read from
/// `DisplayAttributes`, and **refuses to bind at all** when two candidates are indistinguishable.
/// A display with no brightness control is a visible, explainable limitation; a slider that dims the
/// wrong monitor is not.
public final class AppleSiliconAVServiceTransport: DDCTransport, @unchecked Sendable {

    public let name = "apple-silicon-ioavservice"
    public var isUsable: Bool { avService != nil }
    /// Why binding failed, for the diagnostics report.
    public let bindFailureReason: String?
    /// The I2C chip address to use for this display: `DDC.chipAddress` (0x37) normally, or
    /// `DDC.mcdp29xxChipAddress` (0xB7) when it is behind Apple's MCDP29xx bridge. See
    /// `isBehindMCDP29xxBridge`.
    public let chipAddress: UInt32
    /// Whether this display sits behind Apple's MCDP29xx USB-C↔DisplayPort bridge (some docks, hubs,
    /// and Apple's own USB-C↔DP cables). Every I2C call at the normal chip address NAKs immediately on
    /// these, which otherwise looks identical to "no I2C channel at all" (docs/ddc.md).
    public let isBehindMCDP29xxBridge: Bool

    private let avService: CFTypeRef?
    private let shim = IOAVServiceShim.shared
    /// Every I2C call for this display runs here, one at a time. See `onIOQueue`.
    private let ioQueue = DispatchQueue(label: "com.hidisplay.ddc.i2c", qos: .userInitiated)

    /// - Parameter identity: the display to bind to. Only its vendor/product/serial are used.
    public init(identity: DisplayIdentity) {
        guard IOAVServiceShim.shared.isAvailable else {
            avService = nil
            bindFailureReason = IOAVServiceShim.shared.unavailableReason ?? "IOAVService unavailable"
            chipAddress = DDC.chipAddress
            isBehindMCDP29xxBridge = false
            return
        }

        var created: CFTypeRef?
        var reason: String?

        // Step 1: find which display unit this identity belongs to.
        //
        // The metadata and the DDC channel live on *different* registry nodes: on macOS 26
        // `DisplayAttributes` is on `AppleCLCD2`, while `IOAVServiceCreateWithService` only accepts a
        // `DCPAVServiceProxy`. Passing the metadata node to it returns null — which is exactly what
        // happened before this was corrected against real hardware. The two are joined by their shared
        // display unit token (`dispext0`), so resolve that first.
        let targetTokens = Self.unitTokens(matching: identity)

        guard !targetTokens.isEmpty else {
            avService = nil
            bindFailureReason = "no display unit matched vendor 0x\(String(identity.vendorID, radix: 16))"
                + "/product 0x\(String(identity.productID, radix: 16))"
            chipAddress = DDC.chipAddress
            isBehindMCDP29xxBridge = false
            Log.ddcTransport.notice("DDC bind failed: no matching display unit")
            return
        }
        guard targetTokens.count == 1 else {
            // Two identical monitors, neither reporting a serial. Refuse rather than guess: a display
            // with no brightness control is an explainable limitation, a slider that dims the wrong
            // monitor is not.
            avService = nil
            bindFailureReason = "\(targetTokens.count) indistinguishable display units matched; refusing "
                + "to bind to avoid sending commands to the wrong display"
            chipAddress = DDC.chipAddress
            isBehindMCDP29xxBridge = false
            Log.ddcTransport.notice("ambiguous display unit match; DDC disabled for this display")
            return
        }
        let token = targetTokens[0]

        // Step 2: bind the AV service belonging to that unit.
        var candidates: [io_service_t] = []
        IORegistryAccess.forEachService(matchingClass: "DCPAVServiceProxy") { service, _ in
            // Built-in panels have no DDC bus. `Location` is present on this node (unlike AppleCLCD2),
            // so use it, and fall back to the token prefix if a future release drops it.
            let location = IORegistryAccess.stringProperty(service, "Location")
            let isExternal = location.map { $0.caseInsensitiveCompare("External") == .orderedSame }
                ?? token.hasPrefix("dispext")
            guard isExternal else { return }
            guard IORegistryAccess.displayUnitToken(service) == token else { return }
            IOObjectRetain(service) // outlive the iteration; released below
            candidates.append(service)
        }
        defer { candidates.forEach { IOObjectRelease($0) } }

        var resolvedChipAddress = DDC.chipAddress
        var resolvedIsBehindBridge = false

        if candidates.isEmpty {
            reason = "no external DCPAVServiceProxy found for display unit \(token)"
        } else {
            created = IOAVServiceShim.shared.makeService(for: candidates[0])
            if created == nil {
                reason = "IOAVServiceCreateWithService returned null for \(token)"
            } else {
                // The bridge announces itself on the *parent* of the DCPAVServiceProxy we just bound,
                // not on the node itself — see `IORegistryAccess.parentStringProperty`.
                let providerClass = IORegistryAccess.parentStringProperty(candidates[0], "EPICProviderClass")
                resolvedChipAddress = Self.chipAddress(forProviderClass: providerClass)
                resolvedIsBehindBridge = resolvedChipAddress == DDC.mcdp29xxChipAddress
            }
        }

        avService = created
        bindFailureReason = reason
        chipAddress = resolvedChipAddress
        isBehindMCDP29xxBridge = resolvedIsBehindBridge
        if created != nil {
            Log.ddcTransport.notice("""
                bound IOAVService for \(identity.stableKey, privacy: .public), chip \
                0x\(String(resolvedChipAddress, radix: 16), privacy: .public)\
                \(resolvedIsBehindBridge ? " (MCDP29xx bridge)" : "", privacy: .public)
                """)
        } else if let reason {
            Log.ddcTransport.notice("DDC bind failed: \(reason, privacy: .public)")
        }
    }

    /// Chip address to use for a display whose bound `DCPAVServiceProxy` has `providerClass` as its
    /// parent's `EPICProviderClass`. Factored out as a pure function so the MCDP29xx bridge decision is
    /// unit-testable without hardware or an IORegistry lookup — see `MCDP29xxDetectionTests`.
    ///
    /// `"AppleDCPMCDP29XX"` is the class name m1ddc matches on (`isMCDP29XXProxy()`); anything else,
    /// including `nil` when the property is absent, means the display is not behind the bridge.
    static func chipAddress(forProviderClass providerClass: String?) -> UInt32 {
        providerClass == "AppleDCPMCDP29XX" ? DDC.mcdp29xxChipAddress : DDC.chipAddress
    }

    /// Display unit tokens whose metadata matches `identity`.
    ///
    /// More than one result means two attached monitors are genuinely indistinguishable from their
    /// registry records, which is the case the caller must refuse rather than resolve.
    ///
    /// Public so `hidisplay-probe` resolves sweep targets with the same matching rules the app uses,
    /// instead of grabbing whichever external AV service the registry lists first.
    ///
    /// Scans the same ordered candidate classes as `AppleSiliconDisplayMetadataBackend`: the node
    /// carrying `DisplayAttributes` has moved between macOS releases (on macOS 26 it is `AppleCLCD2`;
    /// community documentation for earlier releases puts it on `DCPAVServiceProxy`), and a transport
    /// hard-coded to one class would silently disable DDC on the releases using the other.
    public static func unitTokens(matching identity: DisplayIdentity) -> [String] {
        for className in AppleSiliconDisplayMetadataBackend.candidateClasses {
            let tokens = unitTokens(matching: identity, serviceClass: className)
            if !tokens.isEmpty { return tokens }
        }
        return []
    }

    static func unitTokens(matching identity: DisplayIdentity, serviceClass: String) -> [String] {
        var tokens: [(token: String, score: Int)] = []

        IORegistryAccess.forEachService(matchingClass: serviceClass) { service, _ in
            guard let attributes = IORegistryAccess.dictionaryProperty(service, "DisplayAttributes"),
                  let record = AppleSiliconDisplayMetadataBackend.parse(
                    displayAttributes: attributes, registryEntryID: nil),
                  let token = IORegistryAccess.displayUnitToken(service),
                  token.hasPrefix("dispext") // built-in panels have no DDC bus
            else { return }

            // Vendor and product rule a candidate out when present and different; a field the
            // registry does not report cannot disagree. Serial deliberately never excludes — real
            // hardware ships placeholder serials (0x01010101 observed), so a mismatch only withholds
            // the bonus score. Candidates separated by nothing but an untrusted serial then tie, and
            // the caller refuses the ambiguity rather than guessing.
            var score = 0
            if let vendor = record.vendorID {
                guard vendor == identity.vendorID else { return }
                score += 1
            }
            if let product = record.productID {
                guard product == identity.productID else { return }
                score += 1
            }
            if let serial = record.serialNumber, serial != 0, serial == identity.serialNumber {
                score += 2
            }
            tokens.append((token, score))
        }

        guard let best = tokens.map(\.score).max() else { return [] }
        return tokens.filter { $0.score == best }.map(\.token)
    }

    public func write(_ bytes: [UInt8]) async throws {
        guard avService != nil else { throw DDCError.unsupported(reason: bindFailureReason ?? "not bound") }
        let status = await onIOQueue { [self, shim] in
            bytes.withUnsafeBytes { raw -> IOReturn in
                guard let avService, let base = raw.baseAddress else { return kIOReturnBadArgument }
                return shim.write(
                    service: avService,
                    chipAddress: chipAddress,
                    offset: DDC.dataOffset,
                    from: base,
                    length: UInt32(raw.count))
            }
        }
        guard status == kIOReturnSuccess else {
            throw status == kIOReturnTimeout ? DDCError.timeout : DDCError.ioError(code: status)
        }
    }

    public func read(length: Int) async throws -> [UInt8] {
        guard avService != nil else { throw DDCError.unsupported(reason: bindFailureReason ?? "not bound") }
        let (status, buffer) = await onIOQueue { [self, shim] () -> (IOReturn, [UInt8]) in
            var buffer = [UInt8](repeating: 0, count: length)
            let status = buffer.withUnsafeMutableBytes { raw -> IOReturn in
                guard let avService, let base = raw.baseAddress else { return kIOReturnBadArgument }
                return shim.read(
                    service: avService,
                    chipAddress: chipAddress,
                    offset: DDC.dataOffset,
                    into: base,
                    length: UInt32(raw.count))
            }
            return (status, buffer)
        }
        guard status == kIOReturnSuccess else {
            throw status == kIOReturnTimeout ? DDCError.timeout : DDCError.ioError(code: status)
        }
        return buffer
    }

    /// Runs one IOKit call on the transport's serial queue.
    ///
    /// `IOAVServiceReadI2C`/`WriteI2C` block for the whole bus transaction and cannot be cancelled.
    /// Called directly from an `async` function they pinned a cooperative-pool thread for the
    /// duration — three monitors with slow buses could starve every other task in the process,
    /// including discovery. A serial queue per transport also makes the hardware order the call
    /// order on its own, independently of `DDCCommandQueue`'s bus token.
    private func onIOQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            ioQueue.async { continuation.resume(returning: body()) }
        }
    }
}
