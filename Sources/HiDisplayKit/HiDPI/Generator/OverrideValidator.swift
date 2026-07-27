import Foundation

public struct ValidationIssue: Equatable, Sendable, Identifiable {
    public enum Severity: String, Sendable {
        /// Blocks installation.
        case error
        /// Installation is allowed, but the user is told first.
        case warning
    }

    public var severity: Severity
    public var message: String
    /// Which resolution the issue is about, when it is about one.
    public var resolutionID: String?

    public var id: String { "\(severity.rawValue)-\(resolutionID ?? "-")-\(message)" }

    public init(severity: Severity, message: String, resolutionID: String? = nil) {
        self.severity = severity
        self.message = message
        self.resolutionID = resolutionID
    }
}

public struct ValidationReport: Equatable, Sendable {
    public var issues: [ValidationIssue]

    public init(issues: [ValidationIssue] = []) {
        self.issues = issues
    }

    public var errors: [ValidationIssue] { issues.filter { $0.severity == .error } }
    public var warnings: [ValidationIssue] { issues.filter { $0.severity == .warning } }
    /// Installation is permitted only when there are no errors. Warnings are shown, not enforced —
    /// the user is allowed to try an unusual resolution on their own hardware.
    public var isInstallable: Bool { errors.isEmpty }
}

/// Rejects overrides that cannot work, and warns about ones that probably should not be tried.
///
/// This is the gate in front of a privileged write, so the bias is toward refusing: a rejected
/// resolution costs the user one dialog, while an accepted absurd one can mean a black screen on next
/// boot and a trip through Recovery.
public enum OverrideValidator {

    /// Below this, a HiDPI mode leaves the desktop unusably large.
    public static let minimumLogicalWidth = 640
    public static let minimumLogicalHeight = 480
    /// Above this, we are past anything current hardware renders — and past what any real panel is.
    static let maximumPixelDimension = 16384
    /// Upper bound on how many resolutions one override may declare.
    ///
    /// This was 32, on the assumption that macOS stops offering scaled modes long before that and a
    /// longer list meant a generator bug. Hardware said otherwise: an override written by another tool
    /// on the development machine declared **89** HiDPI modes, all of which macOS accepted. The old cap
    /// was not a safety limit, it was a guess — and it would have blocked exactly the "give me the full
    /// ladder" case this feature exists for.
    ///
    /// 128 still bounds the damage (each entry also emits an 8-byte backing companion, so the file
    /// stays far under `OverrideInstaller.maximumOverrideBytes`) while covering any real panel's
    /// ladder. Confirmed on an M3: a 62-step ladder installed whole and 61 of its modes appeared.
    public static let maximumResolutionCount = 128

    public static func validate(
        _ document: DisplayOverrideDocument,
        nativePixelSize: (width: Int, height: Int)? = nil
    ) -> ValidationReport {
        var issues: [ValidationIssue] = []

        if document.vendorID == 0 {
            issues.append(.init(severity: .error, message: "Vendor ID is 0 — the override directory cannot be named."))
        }
        if document.productID == 0 {
            issues.append(.init(severity: .error, message: "Product ID is 0 — the override file cannot be named."))
        }
        if document.scaleResolutions.isEmpty && document.preservedEntries.isEmpty {
            issues.append(.init(severity: .error, message: "No resolutions selected."))
        }
        if document.scaleResolutions.count > maximumResolutionCount {
            issues.append(.init(
                severity: .error,
                message: "\(document.scaleResolutions.count) resolutions selected; the limit is \(maximumResolutionCount)."))
        }

        // Duplicates would produce two identical entries, which macOS tolerates but which makes the
        // resolution list in System Settings confusing and the generated file non-canonical.
        var seen = Set<String>()
        for resolution in document.scaleResolutions where !seen.insert(resolution.id).inserted {
            issues.append(.init(
                severity: .error,
                message: "\(resolution.label) is listed more than once.",
                resolutionID: resolution.id))
        }

        for resolution in document.scaleResolutions {
            issues.append(contentsOf: validate(resolution, nativePixelSize: nativePixelSize))
        }

        if let edid = document.patchedEDID {
            if edid.count < EDID.blockSize {
                issues.append(.init(
                    severity: .error,
                    message: "Patched EDID is only \(edid.count) bytes; a valid block is at least \(EDID.blockSize)."))
            } else if (try? EDID(data: edid, validateChecksum: true)) == nil {
                issues.append(.init(
                    severity: .error,
                    message: "Patched EDID fails header or checksum validation. Writing it could leave the display unusable."))
            }
            issues.append(.init(
                severity: .warning,
                message: "EDID injection is enabled. It has little effect on Apple Silicon and raises "
                    + "the risk of a black screen after wake. Leave it off unless a specific monitor needs it."))
        }

        return ValidationReport(issues: issues)
    }

    static func validate(
        _ resolution: ScaledResolution,
        nativePixelSize: (width: Int, height: Int)?
    ) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let id = resolution.id

        guard resolution.backingScale == 1 || resolution.backingScale == 2 else {
            return [.init(
                severity: .error,
                message: "Backing scale \(resolution.backingScale)× is not supported; use 1× or 2×.",
                resolutionID: id)]
        }

        if resolution.logicalWidth <= 0 || resolution.logicalHeight <= 0 {
            return [.init(severity: .error, message: "Resolution has a zero or negative dimension.", resolutionID: id)]
        }
        if resolution.logicalWidth < minimumLogicalWidth || resolution.logicalHeight < minimumLogicalHeight {
            issues.append(.init(
                severity: .error,
                message: "\(resolution.label) is smaller than \(minimumLogicalWidth) × \(minimumLogicalHeight) and would be unusable.",
                resolutionID: id))
        }
        if resolution.pixelWidth > maximumPixelDimension || resolution.pixelHeight > maximumPixelDimension {
            issues.append(.init(
                severity: .error,
                message: "\(resolution.label) needs a \(resolution.pixelWidth) × \(resolution.pixelHeight) backing store, beyond the \(maximumPixelDimension) px limit.",
                resolutionID: id))
        }
        // Odd logical dimensions cannot be doubled cleanly, which produces a backing store that does
        // not divide evenly and modes that macOS may simply ignore.
        if resolution.isHiDPI, resolution.logicalWidth % 2 != 0 || resolution.logicalHeight % 2 != 0 {
            issues.append(.init(
                severity: .warning,
                message: "\(resolution.label) has an odd dimension; HiDPI works best on even numbers.",
                resolutionID: id))
        }

        guard let native = nativePixelSize, native.width > 0, native.height > 0 else { return issues }

        // A logical size larger than the panel's own pixel count is not a scaled mode — there is
        // nothing to scale down from, and macOS will not offer it.
        if resolution.logicalWidth > native.width || resolution.logicalHeight > native.height {
            issues.append(.init(
                severity: .error,
                message: "\(resolution.label) is larger than the panel's native \(native.width) × \(native.height).",
                resolutionID: id))
        } else if resolution.isHiDPI,
                  resolution.logicalWidth == native.width || resolution.logicalHeight == native.height {
            // A HiDPI mode must be strictly smaller than the panel. At exactly native it asks for a
            // backing store twice the panel in both axes, and that is the one size measured to be
            // dropped: on an M3 with a 2560 × 1600 monitor, 61 of a 62-step ladder appeared and the
            // only casualty was logical 2560 × 1600 (a 5120 × 3200 backing), refused with no error,
            // while 5056 × 3160 one step below was accepted.
            //
            // It is also pointless even where it works: at native the interface is the same size as
            // the plain 1× native mode, so it buys sharpness the panel cannot show while costing four
            // times the pixels. An error rather than a warning, so the ladder cannot offer a step
            // that silently does nothing.
            issues.append(.init(
                severity: .error,
                message: "\(resolution.label) matches the panel's native \(native.width) × \(native.height). A HiDPI mode has to be smaller than the panel — this one needs a \(resolution.pixelWidth) × \(resolution.pixelHeight) backing store and macOS drops it.",
                resolutionID: id))
        }

        let nativeAspect = Double(native.width) / Double(native.height)
        if abs(resolution.aspectRatio - nativeAspect) > 0.02 {
            issues.append(.init(
                severity: .warning,
                message: String(
                    format: "%@ has aspect ratio %.2f but the panel is %.2f — the image will be letterboxed or stretched.",
                    resolution.label, resolution.aspectRatio, nativeAspect),
                resolutionID: id))
        }

        // Backing store beyond 2× the panel in each axis burns a lot of GPU bandwidth for no visible
        // gain, and on some connections costs the refresh rate.
        if resolution.pixelWidth > native.width * 2 || resolution.pixelHeight > native.height * 2 {
            issues.append(.init(
                severity: .warning,
                message: "\(resolution.label) renders at \(resolution.pixelWidth) × \(resolution.pixelHeight), more than twice the panel's pixels. This can reduce the maximum refresh rate.",
                resolutionID: id))
        }

        return issues
    }
}
