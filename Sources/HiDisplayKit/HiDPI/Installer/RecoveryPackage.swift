import Foundation

/// Builds the folder the user is told to keep before any override is installed.
///
/// The design constraint is that this has to work when the app does not: after a bad override the Mac
/// may boot to a black screen, and the only tool available is a Terminal in macOS Recovery. So the
/// package contains a plain shell script with literal paths, no dependency on the app, and no
/// interpolation of anything a user typed.
public struct RecoveryPackage: Sendable {
    public var directory: URL
    public var manifest: BackupManifest
    public var backupDirectory: URL
    public var restoreScript: URL
    public var readme: URL
}

public enum RecoveryPackageBuilder {

    /// Creates the package skeleton. Call before `OverrideInstaller.apply` and pass
    /// `backupDirectory` into it, so the backup lands inside the package the user was told to keep.
    public static func create(
        manifest: BackupManifest,
        in parentDirectory: URL,
        timestamp: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> RecoveryPackage {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        let name = "HiDisplay-Recovery-\(formatter.string(from: timestamp))"

        let directory = parentDirectory.appendingPathComponent(name, isDirectory: true)
        let backupDirectory = directory.appendingPathComponent("backup", isDirectory: true)
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

        let manifestURL = directory.appendingPathComponent("manifest.json")
        try manifest.jsonData().write(to: manifestURL, options: .atomic)

        let readmeURL = directory.appendingPathComponent("README.txt")
        try readmeText(manifest: manifest).data(using: .utf8)!.write(to: readmeURL, options: .atomic)

        let scriptURL = directory.appendingPathComponent("restore.command")
        try restoreScript(manifest: manifest).data(using: .utf8)!.write(to: scriptURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        return RecoveryPackage(
            directory: directory,
            manifest: manifest,
            backupDirectory: backupDirectory,
            restoreScript: scriptURL,
            readme: readmeURL)
    }

    static func readmeText(manifest: BackupManifest) -> String {
        let entry = manifest.entries.first
        let targetPath = entry.map { "\(manifest.overrideRoot)/\($0.relativePath)" } ?? manifest.overrideRoot
        return """
        HiDisplay recovery package
        ==========================

        Display : \(manifest.displayName)
        Created : \(ISO8601DateFormatter().string(from: manifest.createdAt))
        App     : \(manifest.appVersion)

        WHAT WAS CHANGED

            \(targetPath)

        \(entry?.existedBefore == true
            ? "A file already existed at that path. The original is in backup/ inside this folder."
            : "No file existed at that path before. Undoing the change means deleting it.")

        HOW TO UNDO IT — NORMAL CASE

            Double-click restore.command in this folder, enter your password, then unplug the
            display and plug it back in. (Logging out works too; a restart is not required.)

        HOW TO UNDO IT — IF THE MAC WILL NOT BOOT TO A USABLE SCREEN

            1. Hold the power button until "Loading startup options" appears, then choose Options
               to start macOS Recovery.
            2. Open Utilities > Terminal.
            3. Your normal disk is mounted under /Volumes/Macintosh HD (the name may differ).
               List it with:  ls /Volumes
            4. Run ONE of the following, replacing "Macintosh HD" with your disk's name:

        \(recoveryTerminalCommands(manifest: manifest))

            5. Restart. (From Recovery there is no session to log out of, so this is the way back.)

        WHY NOTHING HAPPENS UNTIL YOU DO ONE OF THOSE

            macOS reads a display override when the display is attached, and again when the window
            server starts at login. Editing the file changes nothing on its own. Reconnecting an
            external monitor is the fastest way to apply it and closes none of your apps; logging
            out does the same for every display, including a built-in one. A full restart is only
            the more familiar way to get the same thing.

        THIS FOLDER IS SAFE TO KEEP

            It contains no personal data — only the display override file and its checksum.
        """
    }

    /// Commands for the Recovery Terminal, with the volume prefix spelled out.
    ///
    /// Written as literal text with fixed paths from the manifest. Nothing here is built from user
    /// input, and no command removes a directory recursively.
    static func recoveryTerminalCommands(manifest: BackupManifest) -> String {
        guard let entry = manifest.entries.first else { return "        (nothing to undo)" }
        let target = "/Volumes/Macintosh HD\(manifest.overrideRoot)/\(entry.relativePath)"
        if entry.existedBefore {
            return """
                    # Put the original file back:
                    cp "<this folder>/backup/\(entry.relativePath)" "\(target)"
            """
        }
        return """
                # Delete the file HiDisplay added:
                rm "\(target)"
        """
    }

    /// The display name, made safe to appear inside the generated bash script.
    ///
    /// The name comes from the monitor's EDID/IORegistry — hardware-controlled input, not ours. In a
    /// double-quoted bash string a name containing `$(…)`, a backtick, `"` or `\\` would execute or
    /// break quoting, and a newline would escape a comment line entirely. So only an allowlist gets
    /// through: ASCII letters, digits, space, and `- _ . ( ) /`. The raw name still appears untouched
    /// where it is data, not code: manifest.json and README.txt.
    static func shellSafeDisplayName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics
            .intersection(.init(charactersIn: Unicode.Scalar(0)..<Unicode.Scalar(128)))
            .union(.init(charactersIn: " -_.()/"))
        let cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "?" })
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "unknown display" : cleaned
    }

    /// The restore script.
    ///
    /// Properties that matter: `set -euo pipefail`; every path is a quoted literal; the target is
    /// checked to be inside the override root before anything is removed; the backup is verified
    /// against the recorded SHA-256 before being copied back; and there is no `rm -rf` anywhere.
    static func restoreScript(manifest: BackupManifest) -> String {
        let entry = manifest.entries.first
        let relativePath = entry?.relativePath ?? ""
        let expectedHash = entry?.sha256Before ?? ""
        let existed = entry?.existedBefore ?? false
        let safeName = shellSafeDisplayName(manifest.displayName)

        return """
        #!/bin/bash
        # HiDisplay restore script — generated \(ISO8601DateFormatter().string(from: manifest.createdAt))
        # Undoes the display override installed for: \(safeName)
        #
        # Paths below are literals taken from manifest.json at generation time. This script never
        # builds a path from input, and never deletes a directory.
        set -euo pipefail

        HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        OVERRIDE_ROOT="\(manifest.overrideRoot)"
        RELATIVE="\(relativePath)"
        TARGET="${OVERRIDE_ROOT}/${RELATIVE}"
        BACKUP="${HERE}/backup/${RELATIVE}"
        EXPECTED_SHA="\(expectedHash)"

        # Refuse to act outside the override root, whatever the manifest says. The `..` check makes
        # the prefix check honest: without it, 'root/../anything' passes the first pattern.
        case "$TARGET" in
            *..*) echo "error: target '$TARGET' contains a traversal sequence" >&2; exit 1 ;;
        esac
        case "$TARGET" in
            "${OVERRIDE_ROOT}/"*) : ;;
            *) echo "error: target '$TARGET' is outside '$OVERRIDE_ROOT'" >&2; exit 1 ;;
        esac
        case "$TARGET" in
            /System/*) echo "error: refusing to touch the system volume" >&2; exit 1 ;;
        esac

        echo "HiDisplay restore"
        echo "  display : \(safeName)"
        echo "  target  : $TARGET"
        echo

        \(existed ? restoreExistingBranch() : removeAddedBranch())

        echo
        echo "Done. Reconnect the display, or log out and back in, for the change to take effect."
        """
    }

    private static func restoreExistingBranch() -> String {
        """
        if [ ! -f "$BACKUP" ]; then
            echo "error: backup file missing at $BACKUP" >&2
            exit 1
        fi

        # Verify the backup is the file that was actually replaced before putting it back.
        ACTUAL_SHA="$(shasum -a 256 "$BACKUP" | awk '{print $1}')"
        if [ -n "$EXPECTED_SHA" ] && [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
            echo "error: backup checksum mismatch" >&2
            echo "  expected $EXPECTED_SHA" >&2
            echo "  got      $ACTUAL_SHA" >&2
            exit 1
        fi

        echo "==> restoring the original file (requires your password)"
        sudo mkdir -p "$(dirname "$TARGET")"
        sudo cp "$BACKUP" "$TARGET"
        """
    }

    private static func removeAddedBranch() -> String {
        """
        if [ ! -e "$TARGET" ]; then
            echo "Nothing to do — $TARGET does not exist."
            exit 0
        fi

        echo "==> removing the override HiDisplay added (requires your password)"
        sudo rm "$TARGET"

        # Remove the vendor directory only if it is now empty. Never recursive.
        VENDOR_DIR="$(dirname "$TARGET")"
        if [ -d "$VENDOR_DIR" ] && [ -z "$(ls -A "$VENDOR_DIR")" ]; then
            sudo rmdir "$VENDOR_DIR"
        fi
        """
    }
}
