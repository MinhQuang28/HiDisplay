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

    private let avService: CFTypeRef?
    private let shim = IOAVServiceShim.shared

    /// - Parameter identity: the display to bind to. Only its vendor/product/serial are used.
    public init(identity: DisplayIdentity) {
        guard IOAVServiceShim.shared.isAvailable else {
            avService = nil
            bindFailureReason = IOAVServiceShim.shared.unavailableReason ?? "IOAVService unavailable"
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

        if candidates.isEmpty {
            reason = "no external DCPAVServiceProxy found for display unit \(token)"
        } else {
            created = IOAVServiceShim.shared.makeService(for: candidates[0])
            if created == nil {
                reason = "IOAVServiceCreateWithService returned null for \(token)"
            }
        }

        avService = created
        bindFailureReason = reason
        if created != nil {
            Log.ddcTransport.debug("bound IOAVService for \(identity.stableKey, privacy: .public)")
        } else if let reason {
            Log.ddcTransport.notice("DDC bind failed: \(reason, privacy: .public)")
        }
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
        guard let avService else { throw DDCError.unsupported(reason: bindFailureReason ?? "not bound") }
        let buffer = bytes
        let status = buffer.withUnsafeBytes { raw -> IOReturn in
            guard let base = raw.baseAddress else { return kIOReturnBadArgument }
            return shim.write(
                service: avService,
                chipAddress: DDC.chipAddress,
                offset: DDC.dataOffset,
                from: base,
                length: UInt32(raw.count))
        }
        guard status == kIOReturnSuccess else {
            throw status == kIOReturnTimeout ? DDCError.timeout : DDCError.ioError(code: status)
        }
    }

    public func read(length: Int) async throws -> [UInt8] {
        guard let avService else { throw DDCError.unsupported(reason: bindFailureReason ?? "not bound") }
        var buffer = [UInt8](repeating: 0, count: length)
        let status = buffer.withUnsafeMutableBytes { raw -> IOReturn in
            guard let base = raw.baseAddress else { return kIOReturnBadArgument }
            return shim.read(
                service: avService,
                chipAddress: DDC.chipAddress,
                offset: DDC.dataOffset,
                into: base,
                length: UInt32(raw.count))
        }
        guard status == kIOReturnSuccess else {
            throw status == kIOReturnTimeout ? DDCError.timeout : DDCError.ioError(code: status)
        }
        return buffer
    }
}
