import Foundation

/// Builds the one shell string the app ever runs as root, and refuses inputs that would make that
/// dangerous.
///
/// Lives in the kit rather than next to the AppleScript call that runs it, so both of its safety
/// properties — the path allowlist and the shape of the generated script — are covered by tests.
public enum PrivilegedInstallScript {

    public enum ScriptError: Error, Equatable {
        case unsafePath(String)
    }

    /// Characters a path may contain before it is allowed anywhere near a shell command.
    ///
    /// Deliberately narrow. Every legitimate path here is made of hex digits, ASCII letters, and the
    /// separators below — a space or a quote means something has gone wrong upstream, and the right
    /// response is to refuse rather than to escape harder.
    public static let allowedPathCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/-._")

    public static func requireSafe(_ path: String) throws {
        guard !path.isEmpty,
              path.unicodeScalars.allSatisfy({ allowedPathCharacters.contains($0) }),
              !path.contains("..")
        else { throw ScriptError.unsafePath(path) }
    }

    /// The install command run as root.
    ///
    /// The staged file lives in a user-writable temporary directory, so between the app's own hash
    /// check and the privileged copy, any process running as the same user could swap it — file
    /// permissions cannot prevent that. So root never trusts it: the script copies the staged file to
    /// a partial file *next to the destination* (inside the root-owned override tree), verifies that
    /// copy's SHA-256 against the hash the user approved, and only then moves it into place. A swap
    /// after the `cp` changes nothing, because the copy is what gets verified and moved; `mv` within
    /// one directory is atomic, so no half-written file is ever at the destination path.
    ///
    /// Fixed operations only — `mkdir -p`, `cp`, `chmod`, `shasum -c`, `mv` — plus one `rm -f` of the
    /// script's own partial file on the failure path, the single non-recursive delete it may perform.
    public static func install(
        staging: String, vendorDirectory: String, destination: String, sha256: String
    ) throws -> String {
        for path in [staging, vendorDirectory, destination] {
            try requireSafe(path)
        }
        guard sha256.count == 64, sha256.allSatisfy(\.isHexDigit) else {
            throw ScriptError.unsafePath(sha256)
        }
        let partial = destination + ".hidisplay-partial"
        return "mkdir -p '\(vendorDirectory)' && "
            + "cp '\(staging)' '\(partial)' && "
            + "chmod 644 '\(partial)' && "
            + "echo '\(sha256)  \(partial)' | /usr/bin/shasum -a 256 -c --status - && "
            + "mv '\(partial)' '\(destination)' || "
            + "{ rm -f '\(partial)'; "
            + "echo 'install failed: the file to install did not match the approved contents' >&2; "
            + "exit 1; }"
    }
}
