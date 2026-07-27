import CoreGraphics
import Foundation

/// Applies display modes, and curates the raw mode list into something a human can choose from.
///
/// Changing resolution is the one runtime operation in this app that can leave a display showing
/// nothing — a mode the panel advertises but cannot actually sync to is not rare, especially over
/// adapters. So the apply path is built around being undoable: it always reports the mode it replaced,
/// and the caller is expected to arm a revert timer before the user has a chance to be stuck.
public enum DisplayModeSwitcher {

    public enum SwitchError: Error, Equatable, CustomStringConvertible {
        case modeNotFound
        case configurationFailed(CGError)
        case sameMode

        public var description: String {
            switch self {
            case .modeNotFound: return "that mode is no longer offered by the display"
            case .configurationFailed(let error): return "CoreGraphics rejected the change (error \(error.rawValue))"
            case .sameMode: return "the display is already using that mode"
            }
        }
    }

    /// Switches `displayID` to `mode`, returning the mode that was replaced so the caller can revert.
    ///
    /// The whole change goes through one begin/complete transaction: a partially-applied configuration
    /// is how a multi-display setup ends up with overlapping frames.
    @discardableResult
    public static func apply(_ mode: DisplayMode, to displayID: CGDirectDisplayID) throws -> DisplayMode {
        guard let previous = DisplayModeService.currentMode(for: displayID) else {
            throw SwitchError.modeNotFound
        }
        guard previous.id != mode.id else { throw SwitchError.sameMode }
        guard let cgMode = findCGMode(matching: mode, on: displayID) else {
            throw SwitchError.modeNotFound
        }

        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success, let config else { throw SwitchError.configurationFailed(begin) }

        let set = CGConfigureDisplayWithDisplayMode(config, displayID, cgMode, nil)
        guard set == .success else {
            CGCancelDisplayConfiguration(config)
            throw SwitchError.configurationFailed(set)
        }

        // `.permanently` rather than `.forSession`: a session-scoped change still leaves the user stuck
        // until they log out, which is not meaningfully safer. Recoverability comes from the caller's
        // revert timer, not from the scope.
        let complete = CGCompleteDisplayConfiguration(config, .permanently)
        guard complete == .success else { throw SwitchError.configurationFailed(complete) }

        Log.modes.notice("switched display to \(mode.id, privacy: .public) from \(previous.id, privacy: .public)")
        return previous
    }

    /// Re-finds the live `CGDisplayMode` for a value-type `DisplayMode`.
    ///
    /// Matching on `ioDisplayModeID` alone is not enough: several `CGDisplayMode` objects can share one
    /// ID across pixel encodings, and the IDs are not stable across reconnects. Geometry plus refresh
    /// rate is what actually identifies the mode the user picked.
    static func findCGMode(matching mode: DisplayMode, on displayID: CGDirectDisplayID) -> CGDisplayMode? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: kCFBooleanTrue] as CFDictionary
        guard let all = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
            return nil
        }
        return all.first { candidate in
            candidate.width == mode.width
                && candidate.height == mode.height
                && candidate.pixelWidth == mode.pixelWidth
                && candidate.pixelHeight == mode.pixelHeight
                && abs(candidate.refreshRate - mode.refreshRate) < 0.5
                && candidate.isUsableForDesktopGUI()
        }
    }

    // MARK: - Curation

    /// The short list a person actually wants to choose from.
    ///
    /// The raw list from CoreGraphics runs to dozens of entries for a 4K panel — the same logical size
    /// repeated at several refresh rates and both scale factors. This collapses it to one entry per
    /// logical size, preferring the HiDPI variant (sharper at the same size) and then the highest
    /// refresh rate, which is what the macOS Displays panel effectively shows.
    public static func curated(from modes: [DisplayMode]) -> [DisplayMode] {
        var best: [String: DisplayMode] = [:]
        for mode in modes where mode.isUsableForDesktop {
            let key = "\(mode.width)x\(mode.height)"
            guard let existing = best[key] else {
                best[key] = mode
                continue
            }
            if isPreferred(mode, over: existing) { best[key] = mode }
        }
        return best.values.sorted { lhs, rhs in
            lhs.width * lhs.height > rhs.width * rhs.height
        }
    }

    static func isPreferred(_ candidate: DisplayMode, over existing: DisplayMode) -> Bool {
        // Sharpness first: a HiDPI mode at a given logical size is strictly better looking than the 1×
        // one, and is the reason the HiDPI half of this app exists.
        if candidate.isHiDPI != existing.isHiDPI { return candidate.isHiDPI }
        return candidate.refreshRate > existing.refreshRate
    }

    /// Refresh rates available at one logical size and scale, highest first.
    ///
    /// Split from resolution selection because they are independent choices: picking 1440p should not
    /// silently drop the display from 120 Hz to 60 Hz.
    public static func refreshRates(
        forWidth width: Int, height: Int, hiDPI: Bool, in modes: [DisplayMode]
    ) -> [DisplayMode] {
        modes
            .filter { $0.width == width && $0.height == height && $0.isHiDPI == hiDPI && $0.isUsableForDesktop }
            // A reported rate of 0 means "not applicable" (common on internal panels), not 0 Hz, so it
            // must not be offered as a choice alongside real rates.
            .filter { $0.refreshRate > 0 }
            .sorted { $0.refreshRate > $1.refreshRate }
    }
}
