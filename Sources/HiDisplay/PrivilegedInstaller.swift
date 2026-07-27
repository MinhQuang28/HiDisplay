import Foundation
import HiDisplayKit

/// Installs a generated override into `/Library/Displays`, which needs root.
///
/// ## Why this shape
///
/// The intended end state is a signed helper registered through `SMAppService` with a narrow XPC
/// contract. That needs a Developer ID and notarization, which this build does not have — so the
/// fallback the plan anticipated is used instead: a single system authorization prompt.
///
/// ## The safety rules this obeys, because it runs a shell string as root
///
/// The project's own security rules say never to build a privileged command out of user input. That
/// rule is kept literally here:
///
/// * The only variable parts of the command are two paths.
/// * The destination is derived from the display's vendor and product IDs — `UInt32` values formatted
///   as hex, so they *cannot* contain a shell metacharacter.
/// * The source is a file this app wrote to its own temporary directory under a generated UUID.
/// * Both paths are re-validated against a strict character allowlist before the command is built,
///   and the destination is proved to resolve inside the override root. Anything else refuses.
/// * The command is three fixed operations — `mkdir -p`, `cp`, `chmod` — with no shell expansion, no
///   `rm`, and no recursion.
/// * The result is verified afterwards by reading the file back (unprivileged) and comparing SHA-256
///   against the plan. A privileged write that is not verified is a privileged write you do not know
///   the outcome of.
@MainActor
enum PrivilegedInstaller {

    enum InstallError: LocalizedError {
        case unsafePath(String)
        case authorizationFailed(String)
        case verificationFailed(expected: String, got: String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .unsafePath(let path):
                return "Refusing to build a privileged command with this path: \(path)"
            case .authorizationFailed(let message):
                return message
            case .verificationFailed(let expected, let got):
                return "The installed file does not match what was previewed "
                    + "(expected \(expected.prefix(12))…, got \(got.prefix(12))…). Nothing was trusted; "
                    + "check the recovery package before restarting."
            case .cancelled:
                return "Authorization was cancelled."
            }
        }
    }

    /// Characters a path may contain before it is allowed anywhere near a shell command.
    ///
    /// Deliberately narrow. Every legitimate path here is made of hex digits, ASCII letters, and the
    /// separators below — a space or a quote means something has gone wrong upstream, and the right
    /// response is to refuse rather than to escape harder.
    private static let allowedPathCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/-._")

    private static func requireSafe(_ path: String) throws {
        guard !path.isEmpty,
              path.unicodeScalars.allSatisfy({ allowedPathCharacters.contains($0) }),
              !path.contains("..")
        else { throw InstallError.unsafePath(path) }
    }

    /// Writes `payload` to the override root, prompting for authorization once.
    ///
    /// - Returns: the SHA-256 actually on disk afterwards, read back without privileges.
    @discardableResult
    static func install(plan: InstallationPlan, payload: Data) throws -> String {
        guard let action = plan.actions.last(where: { $0.kind != .createDirectory }) else {
            throw InstallError.unsafePath("plan has no file to write")
        }

        // Prove the destination is inside the override root before anything else happens.
        let destination = try OverridePaths.resolve(
            relativePath: action.relativePath, under: plan.root)
        let vendorDirectory = destination.deletingLastPathComponent()

        // Stage in our own temporary directory; the privileged step only copies.
        let staging = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hidisplay-install-\(UUID().uuidString)")
        try payload.write(to: staging, options: .atomic)
        defer { try? FileManager.default.removeItem(at: staging) }

        try requireSafe(staging.path)
        try requireSafe(destination.path)
        try requireSafe(vendorDirectory.path)

        // Three fixed operations. No expansion, no removal, no recursion.
        let script = """
            mkdir -p '\(vendorDirectory.path)' && \
            cp '\(staging.path)' '\(destination.path)' && \
            chmod 644 '\(destination.path)'
            """

        Log.hidpiInstaller.notice("requesting authorization to install override")
        try runWithAdministratorPrivileges(script)

        // Verify by reading it back ourselves rather than trusting the exit status.
        guard let written = SHA256Hash.hex(ofFileAt: destination) else {
            throw InstallError.verificationFailed(expected: action.sha256After ?? "", got: "unreadable")
        }
        guard written == action.sha256After else {
            throw InstallError.verificationFailed(expected: action.sha256After ?? "", got: written)
        }

        Log.hidpiInstaller.notice("override installed and verified")
        return written
    }

    private static func runWithAdministratorPrivileges(_ shellScript: String) throws {
        let source = "do shell script \"\(shellScript.replacingOccurrences(of: "\"", with: "\\\""))\""
            + " with administrator privileges"
        guard let script = NSAppleScript(source: source) else {
            throw InstallError.authorizationFailed("could not build the authorization request")
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            // -128 is the documented "user cancelled" code; it is a choice, not a failure.
            if (error[NSAppleScript.errorNumber] as? Int) == -128 { throw InstallError.cancelled }
            let message = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
            Log.hidpiInstaller.error("authorization failed: \(message, privacy: .public)")
            throw InstallError.authorizationFailed(message)
        }
    }

    /// Ends the login session so WindowServer re-reads the overrides.
    ///
    /// Logging out is the cheaper of the two and all that is actually required — WindowServer reads
    /// `/Library/Displays` when a session starts, not when the machine boots. Restart is offered as
    /// well only because it is the more familiar instruction, and because it is what someone reading
    /// an older guide will expect.
    ///
    /// Both go through System Events rather than `shutdown`, so apps are asked to save first. That
    /// needs `NSAppleEventsUsageDescription` in the bundle: without it macOS denies the event with no
    /// prompt, and the button looks broken.
    enum SessionEnd: String {
        case logOut = "log out"
        case restart = "restart"

        var failureDescription: String {
            "could not build the \(rawValue) request"
        }
    }

    static func endSession(_ kind: SessionEnd) throws {
        guard let script = NSAppleScript(
            source: "tell application \"System Events\" to \(kind.rawValue)")
        else {
            throw InstallError.authorizationFailed(kind.failureDescription)
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error, (error[NSAppleScript.errorNumber] as? Int) != -128 {
            let message = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
            Log.app.error("\(kind.rawValue, privacy: .public) failed: \(message, privacy: .public)")
            throw InstallError.authorizationFailed(message)
        }
    }
}
