import CoreGraphics
import Foundation

/// One selectable display mode, flattened out of `CGDisplayMode` so it can be compared, encoded and
/// unit-tested without a live display.
public struct DisplayMode: Hashable, Codable, Sendable, Identifiable {
    /// Logical (point) size — what apps lay out against.
    public var width: Int
    public var height: Int
    /// Backing store size in real pixels.
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var refreshRate: Double
    /// `CGDisplayMode` ioDisplayModeID, used to select the mode again. Runtime only.
    public var ioDisplayModeID: Int32?
    public var isUsableForDesktop: Bool

    public var id: String {
        "\(width)x\(height)@\(pixelWidth)x\(pixelHeight)@\(Int(refreshRate.rounded()))"
    }

    /// Identifies the *size* alone, with the refresh rate deliberately left out.
    ///
    /// A resolution picker must tag its rows with this rather than `id`. Tagging with `id` binds the
    /// selected row to one particular refresh rate, so choosing 120 Hz on a panel whose curated entry
    /// is 170 Hz leaves the picker with a selection matching none of its rows — which AppKit renders
    /// as an empty box. Matches the key `DisplayModeSwitcher.curated(from:)` groups by, so every
    /// curated row has a distinct one.
    public var sizeKey: String { "\(width)x\(height)" }

    public init(
        width: Int,
        height: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        refreshRate: Double,
        ioDisplayModeID: Int32? = nil,
        isUsableForDesktop: Bool = true
    ) {
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
        self.ioDisplayModeID = ioDisplayModeID
        self.isUsableForDesktop = isUsableForDesktop
    }

    /// Backing-store scale factor, kept as a `Double` rather than tested against exactly 2.0.
    ///
    /// macOS ships modes at other ratios (and future hardware may add more), so the classification
    /// below uses a threshold instead of equality. Guard against a zero logical width, which shows
    /// up for some stub/virtual modes.
    public var scaleFactor: Double {
        guard width > 0, height > 0 else { return 1 }
        let horizontal = Double(pixelWidth) / Double(width)
        let vertical = Double(pixelHeight) / Double(height)
        // Non-square pixel ratios are not a thing for HiDPI backing stores; if the two disagree,
        // trust the smaller one so a bogus dimension cannot inflate the result.
        return min(horizontal, vertical)
    }

    /// A mode is HiDPI when its backing store is meaningfully larger than its logical size.
    ///
    /// 1.5 is the cut-off rather than 2.0 so a hypothetical 1.75x or 3x mode still classifies as
    /// HiDPI, while ordinary 1x modes (ratio exactly 1.0) never do.
    public var isHiDPI: Bool { scaleFactor >= 1.5 }

    /// Human label used in menus: `2560 × 1440 HiDPI`.
    public var displayLabel: String {
        isHiDPI ? "\(width) × \(height) HiDPI" : "\(width) × \(height)"
    }
}

extension DisplayMode {
    /// Reads a `CGDisplayMode`. Returns `nil` for modes with a zero logical dimension, which cannot
    /// be reasoned about and would poison `scaleFactor`.
    public init?(cgMode: CGDisplayMode) {
        let w = cgMode.width
        let h = cgMode.height
        guard w > 0, h > 0 else { return nil }
        self.init(
            width: w,
            height: h,
            pixelWidth: cgMode.pixelWidth,
            pixelHeight: cgMode.pixelHeight,
            // A refresh rate of 0 is reported for many internal panels; surface it as 60 only in
            // UI, never here — callers need to know the value was absent.
            refreshRate: cgMode.refreshRate,
            ioDisplayModeID: cgMode.ioDisplayModeID,
            // A method, not a property — the C free function is deprecated in favour of this.
            isUsableForDesktop: cgMode.isUsableForDesktopGUI()
        )
    }
}
