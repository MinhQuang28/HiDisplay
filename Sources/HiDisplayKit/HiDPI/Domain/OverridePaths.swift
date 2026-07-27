import Foundation

/// Where display overrides live, and the guarantee that the app never writes anywhere else.
///
/// There are two override roots on macOS and only one of them is writable:
///
/// | Path | Writable |
/// | --- | --- |
/// | `/System/Library/Displays/Contents/Resources/Overrides` | No — SIP, read-only system volume |
/// | `/Library/Displays/Contents/Resources/Overrides` | Yes, with root |
///
/// The app targets the second exclusively. That is what makes "never disable SIP" and "never touch the
/// system volume" achievable rather than aspirational: there is simply no code path that names the
/// first one.
public enum OverridePaths {

    /// The one directory the privileged helper is allowed to write inside.
    public static let systemOverrideRoot = "/Library/Displays/Contents/Resources/Overrides"

    /// The SIP-protected root, listed only so it can be explicitly rejected.
    public static let forbiddenOverrideRoot = "/System/Library/Displays/Contents/Resources/Overrides"

    /// `DisplayVendorID-10ac` — lowercase hex, no zero padding, matching what macOS itself uses.
    public static func vendorDirectoryName(vendorID: UInt32) -> String {
        String(format: "DisplayVendorID-%x", vendorID)
    }

    /// `DisplayProductID-d0a1`. No file extension: macOS matches on the exact name.
    public static func productFileName(productID: UInt32) -> String {
        String(format: "DisplayProductID-%x", productID)
    }

    /// Path of an override relative to whichever root it is installed under. Relative on purpose —
    /// the generator produces this, and only the installer decides which root it joins onto, so
    /// generation cannot accidentally name a system path.
    public static func relativePath(vendorID: UInt32, productID: UInt32) -> String {
        "\(vendorDirectoryName(vendorID: vendorID))/\(productFileName(productID: productID))"
    }

    /// Resolves a relative override path against a root, and proves the result stays inside it.
    ///
    /// Rejects, in order: a relative path containing `..`, a resolved path that escapes the root, and
    /// a root or target that is reached through a symlink. Checking the *resolved* path rather than
    /// the joined string is what makes this robust against `a/../../etc` and against a symlinked
    /// vendor directory pointing outside the root.
    public static func resolve(
        relativePath: String,
        under root: URL
    ) throws -> URL {
        guard !relativePath.hasPrefix("/") else {
            throw OverridePathError.notRelative(relativePath)
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else { throw OverridePathError.empty }
        guard !components.contains("..") else { throw OverridePathError.traversal(relativePath) }

        let rootResolved = root.standardizedFileURL.resolvingSymlinksInPath()
        var target = rootResolved
        for component in components {
            target.appendPathComponent(String(component))
        }
        let targetStandard = target.standardizedFileURL

        // A symlink anywhere along the path is refused rather than followed: following one is how a
        // root-privileged write ends up landing outside the allowlisted root.
        var walk = rootResolved
        for component in components {
            walk.appendPathComponent(String(component))
            if let attributes = try? FileManager.default.attributesOfItem(atPath: walk.path),
               let type = attributes[.type] as? FileAttributeType,
               type == .typeSymbolicLink {
                throw OverridePathError.symlink(walk.path)
            }
        }

        guard targetStandard.path.hasPrefix(rootResolved.path + "/") else {
            throw OverridePathError.escapesRoot(target: targetStandard.path, root: rootResolved.path)
        }
        guard !targetStandard.path.hasPrefix(forbiddenOverrideRoot) else {
            throw OverridePathError.forbiddenRoot(targetStandard.path)
        }
        return targetStandard
    }
}

public enum OverridePathError: Error, Equatable, CustomStringConvertible {
    case notRelative(String)
    case empty
    case traversal(String)
    case symlink(String)
    case escapesRoot(target: String, root: String)
    case forbiddenRoot(String)

    public var description: String {
        switch self {
        case .notRelative(let path): return "override path must be relative, got '\(path)'"
        case .empty: return "override path is empty"
        case .traversal(let path): return "override path contains '..': '\(path)'"
        case .symlink(let path): return "refusing to follow symlink at '\(path)'"
        case .escapesRoot(let target, let root): return "'\(target)' is outside '\(root)'"
        case .forbiddenRoot(let path): return "'\(path)' is inside the SIP-protected system root"
        }
    }
}
