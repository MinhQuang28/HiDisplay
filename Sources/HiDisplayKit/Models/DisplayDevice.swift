import CoreGraphics
import Foundation

/// A display as the app sees it at one moment in time. Value type on purpose: the discovery service
/// republishes a fresh array on every reconfiguration, so UI never holds a stale live object whose
/// underlying display has gone away.
public struct DisplayDevice: Identifiable, Hashable, Sendable {
    public var identity: DisplayIdentity
    public var name: String
    public var isBuiltIn: Bool
    public var isOnline: Bool
    public var isMain: Bool
    public var isMirrored: Bool
    public var currentMode: DisplayMode?
    public var availableModes: [DisplayMode]
    public var capabilities: DisplayCapabilities
    /// Frame in global (menu-bar-origin) coordinates, needed to place shade overlays.
    public var frame: CGRect

    /// `id` is the persistent profile key, not the CoreGraphics ID — so SwiftUI keeps a row
    /// associated with the same physical monitor when display IDs get shuffled by a reconnect.
    public var id: String { identity.stableKey }

    public var cgDisplayID: CGDirectDisplayID { identity.cgDisplayID }

    public init(
        identity: DisplayIdentity,
        name: String,
        isBuiltIn: Bool,
        isOnline: Bool,
        isMain: Bool,
        isMirrored: Bool = false,
        currentMode: DisplayMode? = nil,
        availableModes: [DisplayMode] = [],
        capabilities: DisplayCapabilities = DisplayCapabilities(),
        frame: CGRect = .zero
    ) {
        self.identity = identity
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.isOnline = isOnline
        self.isMain = isMain
        self.isMirrored = isMirrored
        self.currentMode = currentMode
        self.availableModes = availableModes
        self.capabilities = capabilities
        self.frame = frame
        // Computed here, not lazily on first access, so it can never be absent. An earlier version made
        // this an optional filled in by discovery, which meant a `DisplayDevice` built anywhere else
        // silently reported no native resolution and no HiDPI modes — caught by a diagnostics test.
        self.derived = Self.deriveModeInfo(from: availableModes)
    }

    /// Derived values computed once per snapshot rather than per access.
    ///
    /// These are read from SwiftUI view bodies, which run far more often than displays change — a
    /// profiler run showed `curated(from:)` allocating a dictionary and `nativePixelSize` scanning
    /// every mode on each body evaluation. A display's mode list is fixed for the lifetime of the
    /// snapshot, so the work belongs here, once.
    public struct DerivedModeInfo: Hashable, Sendable {
        public var nativePixelWidth: Int
        public var nativePixelHeight: Int
        public var hiDPIModeCount: Int
        /// One entry per logical size, HiDPI preferred, highest refresh — the resolution menu's contents.
        public var curatedModes: [DisplayMode]
        /// Logical sizes that already exist as HiDPI, for "no override needed" checks.
        public var existingHiDPISizes: Set<String>
    }

    public let derived: DerivedModeInfo?

    /// Native panel resolution, taken as the largest backing-pixel mode.
    public var nativePixelSize: (width: Int, height: Int)? {
        guard let derived else { return nil }
        return (derived.nativePixelWidth, derived.nativePixelHeight)
    }

    public var hiDPIModeCount: Int { derived?.hiDPIModeCount ?? 0 }
    public var curatedModes: [DisplayMode] { derived?.curatedModes ?? [] }

    public func hasHiDPIMode(width: Int, height: Int) -> Bool {
        derived?.existingHiDPISizes.contains("\(width)x\(height)") ?? false
    }

    static func deriveModeInfo(from modes: [DisplayMode]) -> DerivedModeInfo? {
        guard let largest = modes.max(by: {
            $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight
        }) else { return nil }

        var sizes = Set<String>()
        var hiDPICount = 0
        for mode in modes where mode.isHiDPI {
            hiDPICount += 1
            sizes.insert("\(mode.width)x\(mode.height)")
        }
        return DerivedModeInfo(
            nativePixelWidth: largest.pixelWidth,
            nativePixelHeight: largest.pixelHeight,
            hiDPIModeCount: hiDPICount,
            curatedModes: DisplayModeSwitcher.curated(from: modes),
            existingHiDPISizes: sizes)
    }
}
