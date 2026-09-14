import Foundation

/// Persistence for per-display settings.
///
/// An actor because it is written from display-event handlers, from the UI, and from brightness
/// restoration, all concurrently. Serialising through the actor is what stops a reconnect handler and
/// a slider drag from racing to write the same file and losing one of the two changes.
public actor ProfileStore {

    public enum StoreError: Error, CustomStringConvertible {
        case unsupportedSchema(found: Int, supported: Int)
        /// Every file this app ever wrote carries `schemaVersion`; one without it is not ours.
        case missingSchemaVersion

        public var description: String {
            switch self {
            case .unsupportedSchema(let found, let supported):
                return "profile file uses schema \(found); this app understands up to \(supported)"
            case .missingSchemaVersion:
                return "profile file has no schemaVersion"
            }
        }
    }

    private var document: ProfileDocument
    private let fileURL: URL
    private let fileManager: FileManager
    /// Coalesces bursts of writes (a slider drag produces one profile update per frame) into one disk
    /// write, without ever dropping the final value.
    private var saveTask: Task<Void, Never>?
    private let saveDebounce: Duration

    /// Default location: `~/Library/Application Support/HiDisplay/profiles.json`.
    ///
    /// Injectable so tests use a temporary directory — nothing in the test suite may touch the real
    /// Application Support directory.
    public static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("HiDisplay", isDirectory: true)
            .appendingPathComponent("profiles.json")
    }

    public init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default,
        saveDebounce: Duration = .milliseconds(400)
    ) {
        self.fileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
        self.fileManager = fileManager
        self.saveDebounce = saveDebounce
        self.document = ProfileDocument()
    }

    // MARK: - Load / save

    public func load() {
        guard let data = fileManager.contents(atPath: fileURL.path) else {
            Log.profile.debug("no profile file yet; starting empty")
            return
        }
        do {
            document = try Self.decode(data)
            Log.profile.debug("loaded \(self.document.profiles.count) profile(s)")
            // A migrated document is written back straight away, so the upgrade does not depend on
            // some later change happening to trigger a save.
            if Self.schemaVersion(in: data) != ProfileDocument.currentSchemaVersion { scheduleSave() }
        } catch {
            // Keep the unreadable file rather than overwriting it: it is the user's data, and a
            // corrupt-looking file is often recoverable by hand. Remove a stale salvage first —
            // `copyItem` refuses to overwrite, so a second corruption would silently lose the newer
            // evidence while looking like it had been kept.
            let salvage = fileURL.appendingPathExtension("corrupt")
            try? fileManager.removeItem(at: salvage)
            try? fileManager.copyItem(at: fileURL, to: salvage)
            Log.profile.error("could not read profiles (\(String(describing: error), privacy: .public)); kept a copy at \(salvage.lastPathComponent, privacy: .public)")
        }
    }

    static func decode(_ data: Data) throws -> ProfileDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Read the version first so a future file shape can be rejected cleanly instead of failing
        // with a confusing key-not-found error.
        guard let version = schemaVersion(in: data) else { throw StoreError.missingSchemaVersion }
        guard version <= ProfileDocument.currentSchemaVersion else {
            throw StoreError.unsupportedSchema(
                found: version, supported: ProfileDocument.currentSchemaVersion)
        }

        return try migrate(decoder.decode(ProfileDocument.self, from: data))
    }

    private static func schemaVersion(in data: Data) -> Int? {
        struct VersionProbe: Decodable { let schemaVersion: Int }
        return (try? JSONDecoder().decode(VersionProbe.self, from: data))?.schemaVersion
    }

    /// Applies forward migrations, oldest first.
    ///
    /// Schema 2: keys of serial-identified displays carried the raw serial (`v10ac-pd0a1-s0000abcd`)
    /// and now carry its truncated hash. Every place a key lives is rewritten — the profile
    /// dictionary and the `displayKey` inside each profile, HiDPI profiles, and user-assignment
    /// lookups — so saved brightness and overrides survive the rename. No file was ever written
    /// without `schemaVersion`, so its absence is treated as corruption, not as schema 1.
    static func migrate(_ document: ProfileDocument) throws -> ProfileDocument {
        var migrated = document
        if migrated.schemaVersion < 2 {
            migrated.profiles = Dictionary(
                migrated.profiles.map { key, profile in
                    var renamed = profile
                    renamed.displayKey = hashedSerialKey(key)
                    return (renamed.displayKey, renamed)
                },
                uniquingKeysWith: { a, b in a.updatedAt >= b.updatedAt ? a : b })
            migrated.hiDPIProfiles = migrated.hiDPIProfiles.mapValues { profile in
                var renamed = profile
                renamed.displayKey = hashedSerialKey(profile.displayKey)
                return renamed
            }
            migrated.userAssignments = Dictionary(
                migrated.userAssignments.map { (hashedSerialKey($0.key), $0.value) },
                uniquingKeysWith: { a, _ in a })
        }
        migrated.schemaVersion = ProfileDocument.currentSchemaVersion
        return migrated
    }

    /// `v10ac-pd0a1-s0000abcd` → `v10ac-pd0a1-s<hash>`. Any other key shape is returned unchanged.
    static func hashedSerialKey(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              parts[0].hasPrefix("v"), parts[1].hasPrefix("p"),
              parts[2].hasPrefix("s"), parts[2].count == 9,
              let serial = UInt32(parts[2].dropFirst(), radix: 16)
        else { return key }
        return "\(parts[0])-\(parts[1])-s\(DisplayIdentity.serialHash(serial))"
    }

    /// Writes now, bypassing the debounce. Used on quit.
    public func flush() {
        saveTask?.cancel()
        saveTask = nil
        writeToDisk()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [saveDebounce] in
            try? await Task.sleep(for: saveDebounce)
            guard !Task.isCancelled else { return }
            // Already on the actor: the Task was created inside actor context and inherits it.
            self.writeToDisk()
        }
    }

    private func writeToDisk() {
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(document).write(to: fileURL, options: .atomic)
        } catch {
            Log.profile.error("could not save profiles: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Accessors

    public func profile(for key: String) -> DisplayProfile? { document.profiles[key] }
    public func allProfiles() -> [DisplayProfile] {
        document.profiles.values.sorted { $0.displayName < $1.displayName }
    }
    public func userAssignments() -> [String: UUID] { document.userAssignments }
    public func hiDPIProfile(id: UUID) -> HiDPIProfile? { document.hiDPIProfiles[id] }
    public func hiDPIProfiles(forDisplay key: String) -> [HiDPIProfile] {
        document.hiDPIProfiles.values.filter { $0.displayKey == key }
    }

    /// Creates the profile on first sight of a display, so callers never have to check for existence.
    public func upsert(_ update: (inout DisplayProfile) -> Void, for display: DisplayDevice) {
        var profile = document.profiles[display.id] ?? DisplayProfile(
            displayKey: display.id,
            keyTier: display.identity.keyTier,
            displayName: display.name)
        // Refresh the fields that describe the display rather than the user's choices — a monitor
        // renamed by a firmware update should not create a second profile.
        profile.displayName = display.name
        profile.keyTier = display.identity.keyTier
        update(&profile)
        profile.updatedAt = Date()
        document.profiles[display.id] = profile
        scheduleSave()
    }

    public func setBrightness(_ value: Float, for display: DisplayDevice) {
        upsert({ $0.brightness = value }, for: display)
    }

    public func setController(_ kind: BrightnessControllerKind?, for display: DisplayDevice) {
        upsert({ $0.brightnessController = kind }, for: display)
    }

    /// Caches what a live DDC session learned, so the next connection to the same display starts
    /// from the right frame shape, range and checksum tolerance instead of rediscovering them.
    public func setDDCFacts(_ facts: DDCSessionFacts, for display: DisplayDevice) {
        // Facts arrive on every settle and wake, and are almost always unchanged; skipping the
        // upsert then keeps `updatedAt` honest and stops each settle rewriting profiles.json.
        guard ddcFacts(for: display.id) != facts else { return }
        upsert({
            $0.ddcFrameShape = facts.frameShape
            $0.ddcMinimum = 0
            $0.ddcMaximum = Int(facts.maximum)
            $0.ddcTolerateChecksumMismatch = facts.tolerateChecksumMismatch
        }, for: display)
    }

    /// The seed for a display's next DDC session, when one was saved.
    public func ddcFacts(for key: String) -> DDCSessionFacts? {
        guard let profile = document.profiles[key], let shape = profile.ddcFrameShape else { return nil }
        return DDCSessionFacts(
            frameShape: shape,
            maximum: UInt16(clamping: profile.ddcMaximum ?? 100),
            tolerateChecksumMismatch: profile.ddcTolerateChecksumMismatch ?? false)
    }

    public func save(hiDPIProfile: HiDPIProfile) {
        var profile = hiDPIProfile
        profile.updatedAt = Date()
        document.hiDPIProfiles[profile.id] = profile
        scheduleSave()
    }

    public func assignIdentity(_ uuid: UUID, toHeuristicKey key: String) {
        document.userAssignments[key] = uuid
        scheduleSave()
    }

    public func resetProfile(key: String) {
        document.profiles.removeValue(forKey: key)
        scheduleSave()
    }

    /// Wipes everything. Exposed in Settings as the escape hatch when profile state has got confused
    /// — for instance after enough port swapping that several `.location`-tier keys are stale.
    public func resetAll() {
        document = ProfileDocument()
        scheduleSave()
    }

    // MARK: - Export / import

    public func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(document)
    }

    public func importData(_ data: Data) throws {
        document = try Self.decode(data)
        flush()
    }
}
