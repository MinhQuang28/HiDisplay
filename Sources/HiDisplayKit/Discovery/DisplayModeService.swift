import CoreGraphics
import Foundation

/// Reads display modes out of CoreGraphics.
public enum DisplayModeService {

    /// All desktop-usable modes for a display, deduplicated and sorted largest-logical-first.
    ///
    /// The options dictionary matters: without `kCGDisplayShowDuplicateLowResolutionModes`,
    /// CoreGraphics hides the 1x twin of every HiDPI mode, and the resulting list cannot be used to
    /// tell whether a HiDPI variant of a given logical size already exists — which is the exact
    /// question the HiDPI override UI has to answer before offering to generate one.
    public static func modes(for displayID: CGDirectDisplayID) -> [DisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: kCFBooleanTrue] as CFDictionary
        guard let raw = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
            return []
        }

        var seen = Set<String>()
        var result: [DisplayMode] = []
        for cgMode in raw {
            guard let mode = DisplayMode(cgMode: cgMode), mode.isUsableForDesktop else { continue }
            // Several CGDisplayMode objects can describe the same user-visible mode (different pixel
            // encodings). Keying on the logical/backing/refresh triple collapses them.
            if seen.insert(mode.id).inserted {
                result.append(mode)
            }
        }

        result.sort { lhs, rhs in
            if lhs.width * lhs.height != rhs.width * rhs.height {
                return lhs.width * lhs.height > rhs.width * rhs.height
            }
            if lhs.isHiDPI != rhs.isHiDPI { return lhs.isHiDPI }
            return lhs.refreshRate > rhs.refreshRate
        }
        return result
    }

    public static func currentMode(for displayID: CGDirectDisplayID) -> DisplayMode? {
        guard let cgMode = CGDisplayCopyDisplayMode(displayID) else { return nil }
        return DisplayMode(cgMode: cgMode)
    }

    /// Whether a HiDPI mode of exactly this logical size is already offered by the system.
    /// Used to stop the override UI proposing something macOS already provides.
    public static func hasHiDPIMode(width: Int, height: Int, in modes: [DisplayMode]) -> Bool {
        modes.contains { $0.isHiDPI && $0.width == width && $0.height == height }
    }
}
