import Foundation

/// How sharp a HiDPI mode will actually look on a given panel.
///
/// "HiDPI" is not one thing. A 2× mode renders into a backing store of `logical × 2` and the GPU then
/// scales that to the panel's real pixels. Only when the backing store happens to equal the panel's
/// native resolution is the result pixel-exact; every other size is resampled. Still far better than a
/// 1× mode, but worth being honest about rather than labelling everything "HiDPI" and leaving the user
/// to wonder why one option looks crisper than another.
public enum HiDPISharpness: Equatable, Sendable {
    /// Backing store exactly matches the panel. Nothing is resampled — the sharpest possible result.
    case pixelPerfect
    /// Backing store is larger than the panel and is scaled down. Sharp, costs GPU bandwidth.
    /// The associated value is backing ÷ native, per axis.
    case supersampled(ratio: Double)
    /// Backing store is smaller than the panel and is scaled up. Soft — this is what to avoid.
    case upscaled(ratio: Double)

    public var label: String {
        switch self {
        case .pixelPerfect: return "pixel-perfect"
        case .supersampled(let ratio): return String(format: "%.2f× supersampled", ratio)
        case .upscaled(let ratio): return String(format: "%.2f× upscaled — soft", ratio)
        }
    }

    public var explanation: String {
        switch self {
        case .pixelPerfect:
            return "The rendered image matches the panel exactly — nothing is resampled. Sharpest "
                + "possible, but the interface is at its largest."
        case .supersampled(let ratio):
            return String(
                format: "Rendered at %.2f× the panel's pixels and scaled down. Sharp, and the usual "
                    + "trade-off for more desktop space; costs some GPU bandwidth.", ratio)
        case .upscaled(let ratio):
            return String(
                format: "Rendered at only %.2f× the panel's pixels and scaled up. This will look "
                    + "softer than the native resolution.", ratio)
        }
    }

    /// True when this is a reasonable thing to offer.
    public var isRecommended: Bool {
        switch self {
        case .pixelPerfect: return true
        case .supersampled(let ratio): return ratio <= 1.65
        case .upscaled: return false
        }
    }
}

/// Suggested resolution sets, derived from the panel rather than from a fixed table.
///
/// The earlier version keyed presets off panel *height* and returned hard-coded 16:9 lists. On a 16:10
/// panel — a 2560 × 1600 display, say — that proposed 1920 × 1080 and 2304 × 1296, which do not match
/// the panel's shape at all and would be letterboxed or stretched. Deriving from the native aspect
/// ratio means the suggestions are correct for whatever is actually plugged in, including 21:9 and 3:2.
public enum ResolutionPresets {

    public struct Preset: Identifiable, Sendable {
        public var id: String
        public var name: String
        public var detail: String
        public var resolutions: [ScaledResolution]
    }

    /// How sharp `resolution` will be on a panel of `nativePixels`.
    public static func sharpness(
        of resolution: ScaledResolution,
        nativePixels native: (width: Int, height: Int)
    ) -> HiDPISharpness? {
        guard native.width > 0, native.height > 0 else { return nil }
        let ratio = Double(resolution.pixelWidth) / Double(native.width)
        if abs(ratio - 1.0) < 0.001 { return .pixelPerfect }
        return ratio > 1 ? .supersampled(ratio: ratio) : .upscaled(ratio: ratio)
    }

    /// A ladder of HiDPI sizes that all share the panel's exact aspect ratio.
    ///
    /// Built from the reduced integer ratio of the native resolution, so every entry is a whole
    /// multiple and no rounding error creeps in. Both dimensions are kept even, because an odd logical
    /// dimension cannot be doubled cleanly into a backing store.
    ///
    /// The range runs from half the native resolution — where the backing store equals the panel and
    /// the result is pixel-perfect — up to just under native, where the desktop is largest.
    public static func aspectPreservingLadder(
        nativePixels native: (width: Int, height: Int),
        maximumCount: Int = 7
    ) -> [ScaledResolution] {
        guard native.width > 0, native.height > 0 else { return [] }

        let divisor = greatestCommonDivisor(native.width, native.height)
        var stepWidth = native.width / divisor
        var stepHeight = native.height / divisor
        // Force an even step so every generated size is even in both axes.
        if stepWidth % 2 != 0 || stepHeight % 2 != 0 {
            stepWidth *= 2
            stepHeight *= 2
        }

        let minimumMultiple = (native.width / 2) / stepWidth
        let maximumMultiple = (native.width - stepWidth) / stepWidth
        guard maximumMultiple >= minimumMultiple, minimumMultiple > 0 else { return [] }

        let span = maximumMultiple - minimumMultiple
        var multiples: Set<Int> = [minimumMultiple, maximumMultiple]
        if span > 0 {
            // Spread the remaining entries evenly across the range rather than clustering them.
            let wanted = max(1, maximumCount - 2)
            for index in 1...wanted {
                multiples.insert(minimumMultiple + span * index / (wanted + 1))
            }
        }

        return multiples.sorted().map {
            ScaledResolution(
                logicalWidth: stepWidth * $0, logicalHeight: stepHeight * $0, backingScale: 2)
        }
    }

    /// The most steps a scaling slider offers. Every step is also a checkbox in the full ladder and a
    /// line in a generated override, so this is a real budget rather than a UI nicety: the previous
    /// unbounded range produced 150+ entries on a 16:10 panel, which is both an unusable slider and
    /// more selections than `OverrideValidator.maximumResolutionCount` will accept at once.
    public static let maximumScalingSteps = 70

    /// The smallest logical width offered, as a fraction of the panel's native width.
    ///
    /// Below roughly a third of native the interface is enormous and the image is heavily upscaled;
    /// those steps spent slider travel on sizes nobody picks. The floor is a fraction rather than a
    /// fixed pixel count so it means the same thing on a 1080p panel and a 6K one.
    public static let smallestScaleFraction = 0.30

    /// Fractions of native width that must survive thinning, whatever the step budget.
    ///
    /// These are the sizes worth landing on exactly: `0.5` is the pixel-perfect point, where the 2×
    /// backing store equals the panel and nothing is resampled, and `1.0` is the panel's own native
    /// size rendered HiDPI — the two a person actually goes looking for. The quarters between them are
    /// the familiar "looks like" stops. Losing any of these to an evenly-spaced grid would mean the
    /// slider could not express the one setting the whole feature exists for.
    static let landmarkFractions: [Double] = [0.5, 0.625, 0.75, 0.875, 1.0]

    /// Aspect-correct logical sizes for a panel — the domain of a scaling slider.
    ///
    /// Where `aspectPreservingLadder` picks a handful of round numbers for a checkbox list, this spans
    /// the panel's whole usable range so the slider moves smoothly instead of snapping between six
    /// values. Both dimensions stay even and the aspect ratio stays exact, so no step can produce a
    /// letterboxed or unevenly-doubled mode.
    ///
    /// The range runs from `smallestScaleFraction` of native width up to native width itself, thinned
    /// to at most `maximumScalingSteps` entries. Thinning keeps both ends and every landmark first,
    /// then spreads the remaining budget evenly — so reducing the count costs granularity, never a
    /// meaningful stop. It deliberately extends *below* the pixel-perfect point: those sizes are
    /// softer, but they are the "larger text" half of the slider, which is what most people reach for.
    ///
    /// Ordered smallest (largest interface) to largest (most desktop space).
    ///
    /// The step is the panel's reduced integer ratio, forced even. A comparison against a tool that
    /// injects modes at runtime showed it also offers *odd* multiples — 1008 × 630, 1016 × 635 — which
    /// doubles the granularity. Those are not generated here: that tool adds modes live through private
    /// APIs, which is not evidence that an odd logical height behaves the same way when it arrives via
    /// an override file and a reboot. Keeping the step even is the conservative reading until there is
    /// evidence either way.
    public static func scalingSteps(
        nativePixels native: (width: Int, height: Int)
    ) -> [ScaledResolution] {
        guard native.width > 0, native.height > 0 else { return [] }

        let divisor = greatestCommonDivisor(native.width, native.height)
        var stepWidth = native.width / divisor
        var stepHeight = native.height / divisor
        if stepWidth % 2 != 0 || stepHeight % 2 != 0 {
            stepWidth *= 2
            stepHeight *= 2
        }

        let lowest = max(
            multiplesCovering(OverrideValidator.minimumLogicalWidth, step: stepWidth),
            multiplesCovering(OverrideValidator.minimumLogicalHeight, step: stepHeight),
            multiplesCovering(
                Int((Double(native.width) * smallestScaleFraction).rounded()), step: stepWidth),
            1)
        // Up to and including native width: at 2× that is the panel's own size rendered HiDPI, the
        // "most space" end of every tool's slider. `OverrideValidator` allows it and only warns beyond.
        let highest = native.width / stepWidth
        guard highest >= lowest, lowest > 0 else { return [] }

        let multiples = thinned(from: lowest, to: highest, nativeWidth: native.width, step: stepWidth)
        return multiples.map {
            ScaledResolution(
                logicalWidth: stepWidth * $0, logicalHeight: stepHeight * $0, backingScale: 2)
        }
    }

    /// How many whole `step`s it takes to reach at least `value` — the multiple at or above a bound.
    private static func multiplesCovering(_ value: Int, step: Int) -> Int {
        guard step > 0 else { return 1 }
        return value / step + (value % step == 0 ? 0 : 1)
    }

    /// Picks at most `maximumScalingSteps` multiples from `lowest...highest`, landmarks first.
    private static func thinned(
        from lowest: Int, to highest: Int, nativeWidth: Int, step: Int
    ) -> [Int] {
        let span = highest - lowest
        // Nothing to thin: a small panel, or a ratio whose step is coarse enough that the whole range
        // already fits. Returning every multiple keeps the finest granularity the panel can express.
        guard span + 1 > maximumScalingSteps else { return Array(lowest...highest) }

        var picked: Set<Int> = [lowest, highest]
        for fraction in landmarkFractions {
            let width = Int((Double(nativeWidth) * fraction).rounded())
            // Only exact multiples qualify. A landmark that is not one cannot be expressed without
            // breaking the panel's aspect ratio, and a nearby approximation would be a landmark in
            // name only — the neighbouring grid step already covers that.
            guard width % step == 0 else { continue }
            let multiple = width / step
            guard multiple >= lowest, multiple <= highest else { continue }
            picked.insert(multiple)
        }

        // Spend what is left of the budget on an even grid. Collisions with landmarks just mean a few
        // fewer steps than the maximum, which is invisible on a slider.
        let gridCount = max(2, maximumScalingSteps - picked.count)
        for index in 0..<gridCount {
            picked.insert(lowest + Int((Double(span) * Double(index) / Double(gridCount - 1)).rounded()))
        }
        return picked.sorted()
    }

    /// Index of the step closest to `resolution`, for seeding a slider from the current mode.
    public static func nearestStepIndex(
        to width: Int, in steps: [ScaledResolution]
    ) -> Int? {
        guard !steps.isEmpty else { return nil }
        return steps.enumerated()
            .min { abs($0.element.logicalWidth - width) < abs($1.element.logicalWidth - width) }?
            .offset
    }

    /// The one aspect-correct resolution at or nearest a requested width.
    ///
    /// Returns `nil` when the width falls outside what the panel can express as a whole multiple of its
    /// reduced ratio — which is the honest answer, rather than rounding to something that would be
    /// letterboxed. Used by the manual entry field, so a typed width can only ever produce a size that
    /// matches the panel's shape.
    public static func aspectCorrectResolution(
        forWidth width: Int,
        nativePixels native: (width: Int, height: Int)
    ) -> ScaledResolution? {
        let steps = scalingSteps(nativePixels: native)
        guard !steps.isEmpty else { return nil }
        // Exact match first; otherwise the closest step, so typing "2050" lands on 2048 rather than
        // silently producing 2050 × 1281.
        if let exact = steps.first(where: { $0.logicalWidth == width }) { return exact }
        return steps.min { abs($0.logicalWidth - width) < abs($1.logicalWidth - width) }
    }

    /// The preset offered for a panel, or nothing when the native size is unknown.
    public static func presets(forNativePixels native: (width: Int, height: Int)?) -> [Preset] {
        guard let native, native.width > 0, native.height > 0 else { return [] }
        let ladder = aspectPreservingLadder(nativePixels: native)
        guard !ladder.isEmpty else { return [] }

        let ratio = aspectRatioLabel(width: native.width, height: native.height)
        return [
            Preset(
                id: "native-aspect",
                name: "\(native.width) × \(native.height) panel (\(ratio))",
                detail: "Every size here matches your panel's shape exactly, so nothing is letterboxed "
                    + "or stretched. The smallest is pixel-perfect; larger ones give more desktop space "
                    + "and are supersampled. Add one at a time and check it before adding more.",
                resolutions: ladder),
        ]
    }

    /// `2560 × 1600` → `16:10`.
    public static func aspectRatioLabel(width: Int, height: Int) -> String {
        guard width > 0, height > 0 else { return "?" }
        let divisor = greatestCommonDivisor(width, height)
        var w = width / divisor
        var h = height / divisor
        // 8:5 is the same shape as 16:10, but people recognise the latter.
        if w == 8, h == 5 { w = 16; h = 10 }
        if w == 683, h == 384 { w = 16; h = 9 } // 1366×768 reduces to something unrecognisable
        return "\(w):\(h)"
    }

    static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var x = abs(a), y = abs(b)
        while y != 0 { (x, y) = (y, x % y) }
        return max(x, 1)
    }

    /// Filters out sizes the system already provides as HiDPI, so the UI never offers to override
    /// something that already works.
    public static func missingResolutions(
        from preset: Preset,
        existingModes: [DisplayMode]
    ) -> [ScaledResolution] {
        preset.resolutions.filter { resolution in
            !DisplayModeService.hasHiDPIMode(
                width: resolution.logicalWidth, height: resolution.logicalHeight, in: existingModes)
        }
    }
}
