import Foundation

/// Persistence for per-display settings.
///
/// An actor because it is written from display-event handlers, from the UI, and from brightness
/// restoration, all concurrently. Serialising through the actor is what stops a reconnect handler and
/// a slider drag from racing to write the same file and losing one of the two changes.
public actor ProfileStore {

    public enum StoreError: Error, CustomStringConvertible {
        case unsupportedSchema(found: Int, supported: Int)

        public var description: String {
            switch self {
            case .unsupportedSchema(let found, let supported):
                return "profile file uses schema \(found); this app understands up to \(supported)"
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
        struct VersionProbe: Decodable { let schemaVersion: Int }
        let version = (try? decoder.decode(VersionProbe.self, from: data))?.schemaVersion ?? 1
        guard version <= ProfileDocument.currentSchemaVersion else {
            throw StoreError.unsupportedSchema(
                found: version, supported: ProfileDocument.currentSchemaVersion)
        }

        return try migrate(decoder.decode(ProfileDocument.self, from: data))
    }

    /// Applies forward migrations. Currently a no-op — it exists so the first real schema change is a
    /// one-line addition rather than a redesign.
    static func migrate(_ document: ProfileDocument) throws -> ProfileDocument {
        var migrated = document
        if migrated.schemaVersion < ProfileDocument.currentSchemaVersion {
            migrated.schemaVersion = ProfileDocument.currentSchemaVersion
        }
        return migrated
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
