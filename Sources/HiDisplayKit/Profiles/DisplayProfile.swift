import Foundation

/// Persisted mode, kept separate from `DisplayMode` because the runtime type carries an
/// `ioDisplayModeID` that is meaningless after a reconnect and must never be written to disk.
public struct PersistedDisplayMode: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var refreshRate: Double

    public init(_ mode: DisplayMode) {
        self.width = mode.width
        self.height = mode.height
        self.pixelWidth = mode.pixelWidth
        self.pixelHeight = mode.pixelHeight
        self.refreshRate = mode.refreshRate
    }
}

/// Everything remembered about one monitor.
public struct DisplayProfile: Codable, Equatable, Sendable, Identifiable {
    public var displayKey: String
    /// Recorded so the UI can warn when a profile was saved under a weak or port-dependent key.
    public var keyTier: DisplayKeyTier
    /// Last friendly name seen, used in UI when the display is not currently attached.
    public var displayName: String
    public var brightness: Float
    public var brightnessController: BrightnessControllerKind?
    /// Monitor-reported raw range, cached so the first slider move after a reconnect does not have to
    /// wait for a DDC read.
    public var ddcMinimum: Int?
    public var ddcMaximum: Int?
    public var keyboardTargetEnabled: Bool
    public var hiDPIProfileID: UUID?
    public var lastKnownMode: PersistedDisplayMode?
    public var updatedAt: Date

    public var id: String { displayKey }

    public init(
        displayKey: String,
        keyTier: DisplayKeyTier = .weak,
        displayName: String = "",
        brightness: Float = 1.0,
        brightnessController: BrightnessControllerKind? = nil,
        ddcMinimum: Int? = nil,
        ddcMaximum: Int? = nil,
        keyboardTargetEnabled: Bool = true,
        hiDPIProfileID: UUID? = nil,
        lastKnownMode: PersistedDisplayMode? = nil,
        updatedAt: Date = Date()
    ) {
        self.displayKey = displayKey
        self.keyTier = keyTier
        self.displayName = displayName
        self.brightness = brightness
        self.brightnessController = brightnessController
        self.ddcMinimum = ddcMinimum
        self.ddcMaximum = ddcMaximum
        self.keyboardTargetEnabled = keyboardTargetEnabled
        self.hiDPIProfileID = hiDPIProfileID
        self.lastKnownMode = lastKnownMode
        self.updatedAt = updatedAt
    }
}

/// A saved set of HiDPI resolutions for a display.
public struct HiDPIProfile: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var displayKey: String
    public var resolutions: [ScaledResolution]
    public var injectPatchedEDID: Bool
    public var displayNameOverride: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        displayKey: String,
        resolutions: [ScaledResolution],
        injectPatchedEDID: Bool = false,
        displayNameOverride: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayKey = displayKey
        self.resolutions = resolutions
        self.injectPatchedEDID = injectPatchedEDID
        self.displayNameOverride = displayNameOverride
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// The on-disk document. Versioned from day one so a schema change is a migration rather than a data
/// loss event.
public struct ProfileDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var profiles: [String: DisplayProfile]
    public var hiDPIProfiles: [UUID: HiDPIProfile]
    /// User-pinned identities: heuristic key → stable UUID. See `DisplayIdentityResolver`.
    public var userAssignments: [String: UUID]

    public init(
        schemaVersion: Int = ProfileDocument.currentSchemaVersion,
        profiles: [String: DisplayProfile] = [:],
        hiDPIProfiles: [UUID: HiDPIProfile] = [:],
        userAssignments: [String: UUID] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
        self.hiDPIProfiles = hiDPIProfiles
        self.userAssignments = userAssignments
    }
}
