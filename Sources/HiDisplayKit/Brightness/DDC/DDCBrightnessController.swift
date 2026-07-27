import Foundation

/// Hardware brightness over DDC/CI.
///
/// Owns exactly one `DDCCommandQueue` per display key, created lazily and torn down on disconnect.
/// Routing through a key rather than a `CGDirectDisplayID` is what stops a reconnect (which reassigns
/// display IDs) from sending one monitor's commands down another monitor's queue.
public actor DDCBrightnessController: BrightnessController {

    public nonisolated let kind: BrightnessControllerKind = .ddc

    private struct Session {
        let queue: DDCCommandQueue
        var range: DDCCommandQueue.Range
        /// Set once a monitor has been observed to miscompute reply checksums, so subsequent reads
        /// tolerate it instead of failing forever.
        var tolerateChecksumMismatch: Bool
    }

    private var sessions: [String: Session] = [:]
    private let makeTransport: @Sendable (DisplayIdentity) -> DDCTransport?

    /// - Parameter makeTransport: injected so tests can supply `FakeDDCTransport` without touching
    ///   IOKit. Defaults to the real factory.
    public init(makeTransport: @escaping @Sendable (DisplayIdentity) -> DDCTransport? = DDCTransportFactory.make) {
        self.makeTransport = makeTransport
    }

    /// Probes without changing monitor state: one read, no write of a value.
    ///
    /// The read itself does send a `Get VCP Feature` frame, which is unavoidable — but it cannot
    /// change what is on screen, which is the property that matters.
    public func probe(display: DisplayDevice) async -> BrightnessProbeResult {
        guard !display.isBuiltIn else {
            return BrightnessProbeResult(
                isSupported: false, kind: .ddc, detail: "built-in displays have no DDC bus")
        }

        guard let session = session(for: display) else {
            return BrightnessProbeResult(
                isSupported: false, kind: .ddc, detail: "no DDC transport could bind to this display")
        }

        do {
            let reply = try await session.queue.readBrightness()
            updateRange(for: display.id, minimum: 0, maximum: reply.maximum,
                        tolerateChecksumMismatch: !reply.checksumValid)
            let normalized = VCPCodec.normalized(fromRaw: reply.current, minimum: 0, maximum: reply.maximum)
            return BrightnessProbeResult(
                isSupported: true, kind: .ddc, currentValue: normalized,
                rawMinimum: 0, rawMaximum: reply.maximum,
                detail: "read \(reply.current)/\(reply.maximum)"
                    + (reply.checksumValid ? "" : " (monitor's reply checksum was wrong; tolerating)"))
        } catch {
            // Retry once tolerating a bad checksum: enough monitors get the checksum wrong that
            // failing here would wrongly mark working hardware as unsupported.
            if case DDCError.decode(.badChecksum) = error {
                do {
                    let reply = try await session.queue.readBrightness(tolerateChecksumMismatch: true)
                    updateRange(for: display.id, minimum: 0, maximum: reply.maximum,
                                tolerateChecksumMismatch: true)
                    let normalized = VCPCodec.normalized(fromRaw: reply.current, minimum: 0, maximum: reply.maximum)
                    return BrightnessProbeResult(
                        isSupported: true, kind: .ddc, currentValue: normalized,
                        rawMinimum: 0, rawMaximum: reply.maximum,
                        detail: "read \(reply.current)/\(reply.maximum) with an invalid checksum")
                } catch {
                    return BrightnessProbeResult(
                        isSupported: false, kind: .ddc, detail: "\(error)")
                }
            }
            return BrightnessProbeResult(isSupported: false, kind: .ddc, detail: "\(error)")
        }
    }

    public func getBrightness(display: DisplayDevice) async throws -> Float {
        guard let session = session(for: display) else {
            throw DDCError.unsupported(reason: "no DDC transport for this display")
        }
        let reply = try await session.queue.readBrightness(
            tolerateChecksumMismatch: session.tolerateChecksumMismatch)
        return VCPCodec.normalized(fromRaw: reply.current, minimum: session.range.minimum, maximum: reply.maximum)
    }

    /// Fire-and-forget by design: the queue coalesces and the UI has already moved. Awaiting the wire
    /// here would make a slider drag as slow as the monitor's I2C latency.
    public func setBrightness(_ value: Float, display: DisplayDevice) async throws {
        guard let session = session(for: display) else {
            throw DDCError.unsupported(reason: "no DDC transport for this display")
        }
        let raw = VCPCodec.rawValue(
            fromNormalized: value, minimum: session.range.minimum, maximum: session.range.maximum)
        await session.queue.setBrightness(raw: raw)
    }

    public func reset(display: DisplayDevice) async {
        await invalidate(key: display.id)
    }

    /// Cancels and drops the queue for a display. Called on disconnect so pending retries stop
    /// immediately rather than talking to a monitor that is no longer there.
    public func invalidate(key: String) async {
        guard let session = sessions.removeValue(forKey: key) else { return }
        await session.queue.invalidate()
        Log.ddcBrightness.debug("invalidated DDC queue for \(key, privacy: .public)")
    }

    public func invalidateAll(except liveKeys: Set<String>) async {
        for key in sessions.keys where !liveKeys.contains(key) {
            await invalidate(key: key)
        }
    }

    // MARK: - Sessions

    private func session(for display: DisplayDevice) -> Session? {
        if let existing = sessions[display.id] { return existing }
        guard let transport = makeTransport(display.identity), transport.isUsable else { return nil }
        let session = Session(
            queue: DDCCommandQueue(transport: transport, label: display.id),
            // 0…100 is the MCCS default and the right starting assumption; the probe replaces it with
            // whatever the monitor actually reports before any value is written.
            range: DDCCommandQueue.Range(minimum: 0, maximum: 100),
            tolerateChecksumMismatch: false)
        sessions[display.id] = session
        return session
    }

    private func updateRange(
        for key: String, minimum: UInt16, maximum: UInt16, tolerateChecksumMismatch: Bool
    ) {
        guard var session = sessions[key] else { return }
        session.range = DDCCommandQueue.Range(minimum: minimum, maximum: maximum)
        if tolerateChecksumMismatch { session.tolerateChecksumMismatch = true }
        sessions[key] = session
    }
}
