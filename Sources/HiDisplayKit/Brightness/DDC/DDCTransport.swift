import Foundation

public enum DDCError: Error, Equatable, CustomStringConvertible {
    /// No transport on this machine (symbols missing, or no matching I2C service).
    case unsupported(reason: String)
    /// The monitor did not answer inside the timeout. Distinct from `.unsupported` because a
    /// timeout can be transient — a sleeping monitor answers again once awake.
    case timeout
    case ioError(code: Int32)
    case decode(VCPCodec.DecodeError)
    /// The display went away while a command was in flight.
    case disconnected

    public var description: String {
        switch self {
        case .unsupported(let reason): return "DDC unsupported: \(reason)"
        case .timeout: return "DDC timed out"
        case .ioError(let code): return "DDC I/O error \(IOReturnDescription.describe(code))"
        case .decode(let error): return "DDC decode failed: \(error)"
        case .disconnected: return "display disconnected"
        }
    }

    /// Whether retrying could plausibly help. Retrying `.unsupported` just wastes time and, on some
    /// hubs, generates bus traffic that upsets other displays.
    public var isRetryable: Bool {
        switch self {
        case .timeout, .ioError: return true
        case .unsupported, .decode, .disconnected: return false
        }
    }
}

/// A raw I2C channel to one display. Deliberately byte-level: framing lives in `VCPCodec`, so the
/// wire format is testable without a transport and a transport is testable without the wire format.
public protocol DDCTransport: Sendable {
    /// Diagnostic name of the concrete implementation.
    var name: String { get }
    /// False when this transport cannot reach the display at all.
    var isUsable: Bool { get }

    func write(_ bytes: [UInt8]) async throws
    func read(length: Int) async throws -> [UInt8]
}

/// Picks the transport that can actually reach a display.
///
/// One transport, because HiDisplay is Apple Silicon only. The Intel route — `IOFramebuffer`'s
/// `IOI2CSendRequest` — was never implemented here (it needs a C shim for `IOI2CRequest`, whose ABI
/// cannot be hand-declared safely) and has now been removed rather than left as a stub that always
/// reports `.unsupported`.
public enum DDCTransportFactory {

    /// Sendable handle to `makeTransport`, so it can be used as a default argument for the injected
    /// factory without the compiler having to assume a plain function reference is concurrency-safe.
    public static let make: @Sendable (DisplayIdentity) -> DDCTransport? = { makeTransport(for: $0) }

    /// Returns the transport if it binds, `nil` if it does not — the caller then treats the display as
    /// having no hardware brightness control.
    public static func makeTransport(for identity: DisplayIdentity) -> DDCTransport? {
        let transport = AppleSiliconAVServiceTransport(identity: identity)
        if transport.isUsable { return transport }

        Log.ddcTransport.notice(
            "no DDC transport for \(identity.stableKey, privacy: .public): \(transport.bindFailureReason ?? "unknown", privacy: .public)")
        return nil
    }
}

/// Records commands instead of sending them. Lives in the library, not the test target, so the debug
/// panel can drive the whole brightness stack with no monitor attached.
public final class FakeDDCTransport: DDCTransport, @unchecked Sendable {
    public let name = "fake"
    public var isUsable: Bool

    /// Simulated round-trip delay, used to prove the UI does not block on DDC latency.
    public var latency: Duration
    /// Frames to return from `read`, consumed in order. When exhausted the last one repeats, so a
    /// test can set one reply and poll freely.
    public var replies: [[UInt8]]
    /// Every frame successfully handed to `write`, in order. The assertion target for coalescing tests.
    public private(set) var recordedWrites: [[UInt8]] = []
    /// Every `write` call, including ones that threw. Counted separately because a retry test needs to
    /// know how many attempts were made, which `recordedWrites` cannot show when writes fail.
    public private(set) var writeAttempts = 0
    public var errorToThrow: DDCError?

    private var replyIndex = 0
    private let lock = NSLock()

    public init(
        isUsable: Bool = true,
        latency: Duration = .zero,
        replies: [[UInt8]] = []
    ) {
        self.isUsable = isUsable
        self.latency = latency
        self.replies = replies
    }

    public func write(_ bytes: [UInt8]) async throws {
        lock.withLock { writeAttempts += 1 }
        if let errorToThrow { throw errorToThrow }
        if latency > .zero { try await Task.sleep(for: latency) }
        lock.withLock { recordedWrites.append(bytes) }
    }

    public func read(length: Int) async throws -> [UInt8] {
        if let errorToThrow { throw errorToThrow }
        if latency > .zero { try await Task.sleep(for: latency) }
        return lock.withLock {
            guard !replies.isEmpty else { return [] }
            let reply = replies[min(replyIndex, replies.count - 1)]
            replyIndex += 1
            return reply
        }
    }

    /// Values decoded out of the recorded `Set VCP Feature` frames, for assertions.
    public var recordedBrightnessValues: [UInt16] {
        lock.withLock {
            recordedWrites.compactMap { frame in
                // Shape-agnostic: the leading host-address byte is present or absent depending on
                // `DDC.FrameShape`. Unambiguous to detect — a length byte is always 0x80 | n, so a
                // first byte below 0x80 can only be the host address. The opcode follows the length.
                let opcode = frame.first == DDC.hostAddress ? 2 : 1
                guard frame.count >= opcode + 4,
                      frame[opcode] == 0x03,
                      frame[opcode + 1] == VCPCode.brightness.rawValue
                else { return nil }
                return UInt16(frame[opcode + 2]) << 8 | UInt16(frame[opcode + 3])
            }
        }
    }

    public func reset() {
        lock.withLock {
            recordedWrites.removeAll()
            writeAttempts = 0
            replyIndex = 0
        }
    }
}
