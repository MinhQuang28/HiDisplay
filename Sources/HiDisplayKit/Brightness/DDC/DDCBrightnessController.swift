import Foundation

/// What a DDC session learns about a display by talking to it: which frame shape it answers, the
/// raw range it reports, and whether its reply checksums are trustworthy.
///
/// Persisted per display key and seeded into the next session for the same display, so a reconnect
/// or wake does not re-pay the discovery cost — a wrong-shape null-message round-trip, a failed
/// checksum read — on hardware whose quirks are already known. Every fact is a starting point, not
/// a promise: the queue still re-learns the shape on any null message, and the range is replaced by
/// the first reply.
public struct DDCSessionFacts: Equatable, Sendable, Codable {
    public var frameShape: DDC.FrameShape
    /// Monitor-reported raw maximum (MCCS default 100).
    public var maximum: UInt16
    public var tolerateChecksumMismatch: Bool

    public init(
        frameShape: DDC.FrameShape = .withHostAddress,
        maximum: UInt16 = 100,
        tolerateChecksumMismatch: Bool = false
    ) {
        self.frameShape = frameShape
        self.maximum = maximum
        self.tolerateChecksumMismatch = tolerateChecksumMismatch
    }
}

/// Hardware brightness over DDC/CI.
///
/// Owns exactly one `DDCCommandQueue` per display key, created lazily and torn down on disconnect.
/// Routing through a key rather than a `CGDirectDisplayID` is what stops a reconnect (which reassigns
/// display IDs) from sending one monitor's commands down another monitor's queue.
public actor DDCBrightnessController: DDCControlling {

    public nonisolated let kind: BrightnessControllerKind = .ddc

    private struct Session {
        let queue: DDCCommandQueue
        var range: DDCCommandQueue.Range
        /// Tracks whether the monitor's replies currently miscompute their checksum, so reads
        /// tolerate it instead of failing forever. Follows the latest observation in both
        /// directions: a valid reply clears it again, because latching true forever — and now
        /// persisting it — would let one bus glitch permanently disable checksum verification.
        var tolerateChecksumMismatch: Bool
    }

    private var sessions: [String: Session] = [:]
    /// Facts persisted from a previous connection, keyed by display key. Consulted once, when a
    /// session is created; deliberately never cleared on invalidate, because surviving the
    /// invalidate/rebind cycle is the entire point.
    private var seeds: [String: DDCSessionFacts] = [:]
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
    /// CoreGraphics reports a placeholder display with vendor `'unkn'` (and product `'virt'`) while
    /// a link renegotiates during replug. It never has a DDC bus, so probing it only burns registry
    /// scans and fills the log with bind failures and retry ladders for a display that is about to
    /// vanish.
    private static let unknownVendorID: UInt32 = 0x756e_6b6e // ASCII 'unkn'

    public func probe(display: DisplayDevice) async -> BrightnessProbeResult {
        guard !display.isBuiltIn else {
            return BrightnessProbeResult(
                isSupported: false, kind: .ddc, detail: "built-in displays have no DDC bus")
        }
        guard display.identity.vendorID != Self.unknownVendorID else {
            return BrightnessProbeResult(
                isSupported: false, kind: .ddc,
                detail: "virtual placeholder display (vendor 'unkn') has no DDC bus")
        }

        guard let session = session(for: display) else {
            // Transient: right after a monitor wakes, the registry node carrying `DisplayAttributes`
            // can be empty for a few seconds, so a bind that fails now may succeed shortly.
            return BrightnessProbeResult(
                isSupported: false, kind: .ddc, detail: "no DDC transport could bind to this display",
                isTransient: true)
        }

        let first = await probeRead(session, display: display)
        guard first.retryOnFreshTransport else { return first.result }

        // The session's transport bound its IOAVService when the session was created — possibly
        // before a monitor sleep/wake or a fast unplug/replug swapped the service underneath it.
        // The display's key never goes offline in those cases, so no disconnect tears the session
        // down; without this rebind the probe fails against the dead service, the display downgrades
        // to software dimming, and nothing ever tries DDC again.
        await invalidate(key: display.id)
        guard let fresh = self.session(for: display) else { return first.result }
        Log.ddcBrightness.notice(
            "\(display.id, privacy: .public): probe failed on a possibly stale transport; retrying on a fresh one")
        return await probeRead(fresh, display: display).result
    }

    /// One probe read, including the tolerate-bad-checksum retry.
    ///
    /// `retryOnFreshTransport` is true for failures a stale transport explains — timeouts and I/O
    /// errors — and false for answers that prove the transport works, like a monitor replying with
    /// the null message for both frame shapes.
    private func probeRead(
        _ session: Session, display: DisplayDevice
    ) async -> (result: BrightnessProbeResult, retryOnFreshTransport: Bool) {
        do {
            // Honour a seeded tolerance up front: a monitor already known to miscompute checksums
            // would otherwise fail this first read and re-pay the retry below on every reconnect.
            let reply = try await session.queue.readBrightness(
                tolerateChecksumMismatch: session.tolerateChecksumMismatch)
            updateRange(for: display.id, minimum: 0, maximum: reply.maximum,
                        tolerateChecksumMismatch: !reply.checksumValid)
            let normalized = VCPCodec.normalized(fromRaw: reply.current, minimum: 0, maximum: reply.maximum)
            return (BrightnessProbeResult(
                isSupported: true, kind: .ddc, currentValue: normalized,
                rawMinimum: 0, rawMaximum: reply.maximum,
                detail: "read \(reply.current)/\(reply.maximum)"
                    + (reply.checksumValid ? "" : " (monitor's reply checksum was wrong; tolerating)")),
                false)
        } catch {
            // Retry once tolerating a bad checksum: enough monitors get the checksum wrong that
            // failing here would wrongly mark working hardware as unsupported.
            if case DDCError.decode(.badChecksum) = error {
                do {
                    let reply = try await session.queue.readBrightness(tolerateChecksumMismatch: true)
                    updateRange(for: display.id, minimum: 0, maximum: reply.maximum,
                                tolerateChecksumMismatch: !reply.checksumValid)
                    let normalized = VCPCodec.normalized(fromRaw: reply.current, minimum: 0, maximum: reply.maximum)
                    return (BrightnessProbeResult(
                        isSupported: true, kind: .ddc, currentValue: normalized,
                        rawMinimum: 0, rawMaximum: reply.maximum,
                        detail: "read \(reply.current)/\(reply.maximum) with an invalid checksum"),
                        false)
                } catch {
                    // No fresh-transport retry — the first answer proved the transport works — but a
                    // timeout or I/O error here is still transient for the coordinator's re-probe,
                    // same as in the outer catch.
                    let ddcError = error as? DDCError
                    let transient = (ddcError?.isRetryable ?? false) || ddcError == .disconnected
                    return (BrightnessProbeResult(
                        isSupported: false, kind: .ddc, detail: "\(error)",
                        isTransient: transient,
                        isNullAnswer: ddcError == .decode(.nullMessage)), false)
                }
            }
            let ddcError = error as? DDCError
            let retry = (ddcError?.isRetryable ?? false) || ddcError == .disconnected
            // The same condition that justifies a fresh transport also marks the result transient: a
            // timeout or I/O error is what a monitor whose I2C is still waking up looks like.
            return (
                BrightnessProbeResult(
                    isSupported: false, kind: .ddc, detail: "\(error)", isTransient: retry,
                    isNullAnswer: ddcError == .decode(.nullMessage)),
                retry)
        }
    }

    public func getBrightness(display: DisplayDevice) async throws -> Float {
        guard let session = session(for: display) else {
            throw DDCError.unsupported(reason: "no DDC transport for this display")
        }
        let reply = try await session.queue.readBrightness(
            tolerateChecksumMismatch: session.tolerateChecksumMismatch)
        // Keep the cached range in step with the reply, so the next *write* scales against the same
        // maximum this read normalised with — mixing the cached range with a fresh reply is harmless
        // while the minimum is always 0, and a trap the moment it is not.
        updateRange(for: display.id, minimum: session.range.minimum, maximum: reply.maximum,
                    tolerateChecksumMismatch: !reply.checksumValid)
        return VCPCodec.normalized(
            fromRaw: reply.current, minimum: session.range.minimum, maximum: reply.maximum)
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

    // MARK: - Session facts

    /// Stores persisted facts to seed the next session created for this key. A session that already
    /// exists is left alone — it holds live, fresher knowledge than the disk does.
    public func seedFacts(_ facts: DDCSessionFacts, for key: String) {
        seeds[key] = facts
    }

    /// Reads what the live session currently knows, for persisting. `nil` when no session exists —
    /// the caller then has nothing newer than what it already saved.
    public func facts(for key: String) async -> DDCSessionFacts? {
        guard let session = sessions[key] else { return nil }
        return DDCSessionFacts(
            frameShape: await session.queue.currentFrameShape,
            maximum: session.range.maximum,
            tolerateChecksumMismatch: session.tolerateChecksumMismatch)
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
        // Persisted facts beat the MCCS defaults as a starting point; the probe still replaces the
        // range with whatever the monitor reports before any value is written, and the queue still
        // re-learns the shape on a null message.
        let seed = seeds[display.id] ?? DDCSessionFacts()
        let session = Session(
            queue: DDCCommandQueue(
                transport: transport, label: display.id, initialFrameShape: seed.frameShape),
            range: DDCCommandQueue.Range(minimum: 0, maximum: seed.maximum),
            tolerateChecksumMismatch: seed.tolerateChecksumMismatch)
        sessions[display.id] = session
        return session
    }

    private func updateRange(
        for key: String, minimum: UInt16, maximum: UInt16, tolerateChecksumMismatch: Bool
    ) {
        guard var session = sessions[key] else { return }
        session.range = DDCCommandQueue.Range(minimum: minimum, maximum: maximum)
        // Assigned, not latched: callers pass what the latest reply's checksum actually looked
        // like, so a monitor that starts computing checksums correctly gets verification back.
        session.tolerateChecksumMismatch = tolerateChecksumMismatch
        sessions[key] = session
    }
}
