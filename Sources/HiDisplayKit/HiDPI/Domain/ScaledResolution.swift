import Foundation

/// One resolution to offer in System Settings.
///
/// Stored as *logical* size plus a scale, not as backing pixels, because that is how a user thinks
/// about it ("I want 1920 × 1080 that looks sharp") and because the encoder needs the scale
/// separately anyway to decide whether to emit the HiDPI flag.
public struct ScaledResolution: Hashable, Codable, Sendable, Identifiable {
    public var logicalWidth: Int
    public var logicalHeight: Int
    /// 1 for a plain mode, 2 for HiDPI. Kept as an `Int` rather than a Bool because the encoding is
    /// a multiplier, and because a future 3x would be a data change rather than a code change.
    public var backingScale: Int

    public init(logicalWidth: Int, logicalHeight: Int, backingScale: Int = 2) {
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.backingScale = backingScale
    }

    public var id: String { "\(logicalWidth)x\(logicalHeight)@\(backingScale)x" }

    public var pixelWidth: Int { logicalWidth * backingScale }
    public var pixelHeight: Int { logicalHeight * backingScale }
    public var isHiDPI: Bool { backingScale > 1 }

    public var label: String {
        isHiDPI
            ? "\(logicalWidth) × \(logicalHeight) HiDPI (\(pixelWidth) × \(pixelHeight))"
            : "\(logicalWidth) × \(logicalHeight)"
    }

    /// Aspect ratio, used to warn when a proposed mode does not match the panel.
    public var aspectRatio: Double {
        logicalHeight == 0 ? 0 : Double(logicalWidth) / Double(logicalHeight)
    }
}
