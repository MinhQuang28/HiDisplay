import Foundation

/// What the app believes it can do to a given display. Every flag starts pessimistic; probing only
/// ever turns things on, so a probe that fails to run leaves the display in a safe state rather
/// than promising hardware control that does not work.
public struct DisplayCapabilities: Hashable, Codable, Sendable {
    public var supportsNativeBrightness: Bool = false
    public var supportsDDC: Bool = false
    /// Gamma dimming needs a real `CGDirectDisplayID` we can install a transfer table on. True for
    /// almost everything, false for some virtual/streamed displays.
    public var supportsSoftwareDimming: Bool = true
    /// A shade overlay works anywhere we can put a window, so this is the universal fallback.
    public var supportsShadeDimming: Bool = true
    public var supportsHiDPIOverride: Bool = false
    public var supportsHDR: Bool = false

    public init() {}

    public init(
        supportsNativeBrightness: Bool,
        supportsDDC: Bool,
        supportsSoftwareDimming: Bool,
        supportsShadeDimming: Bool,
        supportsHiDPIOverride: Bool,
        supportsHDR: Bool
    ) {
        self.supportsNativeBrightness = supportsNativeBrightness
        self.supportsDDC = supportsDDC
        self.supportsSoftwareDimming = supportsSoftwareDimming
        self.supportsShadeDimming = supportsShadeDimming
        self.supportsHiDPIOverride = supportsHiDPIOverride
        self.supportsHDR = supportsHDR
    }
}
