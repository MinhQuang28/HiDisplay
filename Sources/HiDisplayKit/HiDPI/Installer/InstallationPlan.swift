import Foundation

/// A single filesystem change the installer intends to make.
public struct PlannedAction: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case createDirectory
        case createFile
        /// A file already exists and will be backed up first.
        case replaceFile
    }

    public var kind: Kind
    /// Absolute destination, resolved under the plan's root.
    public var absolutePath: String
    public var relativePath: String
    public var sha256Before: String?
    public var sha256After: String?
    public var byteCount: Int

    public var id: String { "\(kind.rawValue):\(absolutePath)" }
}

/// Everything the user should see before authorising a privileged write.
///
/// The preview is not a courtesy — it is the mechanism that makes this operation reviewable. Every
/// field here appears in the UI: what will be created, what will be replaced, the hashes either side,
/// whether the session has to end for it to apply, and the exact command to undo it by hand.
public struct InstallationPlan: Sendable {
    public var root: URL
    public var actions: [PlannedAction]
    public var manifest: BackupManifest
    public var validation: ValidationReport
    /// WindowServer reads overrides when the login session starts, so **logging out and back in is
    /// enough** — a full restart is not needed, only the more familiar way to get one. Always true.
    public var requiresLogout: Bool
    /// Copy-pasteable shell command that reverses this install, for the case where the app itself
    /// will not launch.
    public var recoveryCommand: String
    /// Top-level keys in an existing override that this app does not understand and will drop.
    public var droppedUnknownKeys: [String]

    public var isInstallable: Bool { validation.isInstallable }
}

public enum InstallerError: Error, Equatable, CustomStringConvertible {
    case pathRejected(OverridePathError)
    case fileTooLarge(bytes: Int, limit: Int)
    case backupFailed(path: String)
    case writeFailed(path: String, underlying: String)
    case manifestMismatch(expected: String, got: String)
    case rootMissing(String)
    case notAppOwned(path: String)

    public var description: String {
        switch self {
        case .pathRejected(let error): return "path rejected: \(error)"
        case .fileTooLarge(let bytes, let limit): return "override is \(bytes) bytes, limit is \(limit)"
        case .backupFailed(let path): return "could not back up '\(path)'"
        case .writeFailed(let path, let underlying): return "could not write '\(path)': \(underlying)"
        case .manifestMismatch(let expected, let got):
            return "file content does not match the manifest (expected \(expected.prefix(12))…, got \(got.prefix(12))…)"
        case .rootMissing(let path): return "override root '\(path)' does not exist"
        case .notAppOwned(let path): return "'\(path)' was not created by HiDisplay; refusing to remove it"
        }
    }
}

/// Plans and performs override installation against an **injected** filesystem root.
///
/// The root is a constructor parameter with no default, so a test cannot accidentally target
/// `/Library/Displays/...` and the production call site has to name the real root explicitly. Every
/// write is confined to that root, checked by `OverridePaths.resolve` rather than by string
/// concatenation.
public struct OverrideInstaller {

    /// A display override is a few hundred bytes. A megabyte limit is generous and still rules out
    /// anything that could be a mistake or an attempt to fill the volume.
    public static let maximumOverrideBytes = 1_048_576

    public let root: URL
    public let appVersion: String
    private let fileManager: FileManager

    public init(root: URL, appVersion: String, fileManager: FileManager = .default) {
        self.root = root
        self.appVersion = appVersion
        self.fileManager = fileManager
    }

    // MARK: - Plan

    /// How to treat modes already present in an existing override file.
    public enum ExistingContentPolicy: Sendable {
        /// Carry through any entry this app does not itself emit. The safe default: a user's override
        /// may hold modes written by Apple or another tool, and regenerating must not delete them.
        case merge
        /// Write only the selected resolutions, discarding everything else in the file. For when the
        /// user explicitly wants a clean slate — for instance after uninstalling the tool that wrote
        /// the other entries. Destructive, so it is never the default.
        case replace
    }

    public func plan(
        generated: GeneratedOverride,
        display: DisplayDevice,
        policy: ExistingContentPolicy = .merge,
        now: Date = Date()
    ) throws -> InstallationPlan {
        guard generated.data.count <= Self.maximumOverrideBytes else {
            throw InstallerError.fileTooLarge(bytes: generated.data.count, limit: Self.maximumOverrideBytes)
        }

        let target: URL
        do {
            target = try OverridePaths.resolve(relativePath: generated.relativePath, under: root)
        } catch let error as OverridePathError {
            throw InstallerError.pathRejected(error)
        }

        let vendorDirectory = target.deletingLastPathComponent()
        var actions: [PlannedAction] = []

        if !fileManager.fileExists(atPath: vendorDirectory.path) {
            actions.append(PlannedAction(
                kind: .createDirectory,
                absolutePath: vendorDirectory.path,
                relativePath: vendorDirectory.lastPathComponent,
                sha256Before: nil, sha256After: nil, byteCount: 0))
        }

        let existingData = fileManager.contents(atPath: target.path)
        var droppedKeys: [String] = []
        var mergedData = generated.data

        if let existingData,
           let (existingDocument, unknownKeys) = try? OverrideGenerator.parseExisting(existingData) {
            droppedKeys = unknownKeys
            switch policy {
            case .merge:
                // An override may already contain modes from another tool, or from an earlier install
                // with different choices. Silently discarding them is the "not my file" failure.
                if !existingDocument.preservedEntries.isEmpty || existingDocument.patchedEDID != nil {
                    var document = try OverrideGenerator.parseExisting(generated.data).document
                    document.preservedEntries = existingDocument.preservedEntries
                    // The app never emits an EDID patch itself, so one found here was put there
                    // deliberately by whoever wrote the file — which makes it exactly the kind of
                    // content this policy exists to carry through.
                    document.patchedEDID = existingDocument.patchedEDID
                    mergedData = OverrideGenerator.generate(document).data
                }
            case .replace:
                // Caller asked for a clean slate. Report what is being discarded so the preview can
                // say so out loud rather than quietly dropping 258 modes.
                droppedKeys = unknownKeys + Self.discardedDescriptions(of: existingDocument)
            }
        }

        let finalHash = SHA256Hash.hex(of: mergedData)
        actions.append(PlannedAction(
            kind: existingData == nil ? .createFile : .replaceFile,
            absolutePath: target.path,
            relativePath: generated.relativePath,
            sha256Before: existingData.map(SHA256Hash.hex),
            sha256After: finalHash,
            byteCount: mergedData.count))

        let manifest = BackupManifest(
            appVersion: appVersion,
            createdAt: now,
            overrideRoot: root.path,
            displayKey: display.id,
            displayName: display.name,
            vendorID: display.identity.vendorID,
            productID: display.identity.productID,
            entries: [
                BackupEntry(
                    relativePath: generated.relativePath,
                    backupRelativePath: existingData == nil ? nil : generated.relativePath,
                    sha256Before: existingData.map(SHA256Hash.hex),
                    sha256After: finalHash,
                    existedBefore: existingData != nil,
                    byteCount: mergedData.count),
            ])

        return InstallationPlan(
            root: root,
            actions: actions,
            manifest: manifest,
            validation: generated.validation,
            requiresLogout: true,
            recoveryCommand: Self.recoveryCommand(for: manifest),
            droppedUnknownKeys: droppedKeys)
    }

    // MARK: - Apply

    /// Performs the plan, rolling back everything it managed to do if any step fails.
    ///
    /// - Parameter payload: the exact bytes to write, keyed by relative path. Passed separately from
    ///   the plan so that what is previewed and what is written are provably the same content — the
    ///   plan's `sha256After` is verified against it before anything is touched.
    /// - Parameter backupDirectory: where prior contents are copied. Required whenever the plan
    ///   replaces a file.
    @discardableResult
    public func apply(
        _ plan: InstallationPlan,
        payload: [String: Data],
        backupDirectory: URL?
    ) throws -> BackupManifest {
        // Verify first: a mismatch here means the preview the user approved is not what would land.
        for action in plan.actions where action.kind != .createDirectory {
            guard let data = payload[action.relativePath] else {
                throw InstallerError.writeFailed(path: action.relativePath, underlying: "no payload supplied")
            }
            let hash = SHA256Hash.hex(of: data)
            guard hash == action.sha256After else {
                throw InstallerError.manifestMismatch(expected: action.sha256After ?? "", got: hash)
            }
        }

        var createdDirectories: [URL] = []
        var replacedFiles: [(target: URL, backup: URL)] = []
        var createdFiles: [URL] = []

        func rollback() {
            // Reverse order so a directory is only removed after the file inside it.
            for (target, backup) in replacedFiles.reversed() {
                try? fileManager.removeItem(at: target)
                try? fileManager.copyItem(at: backup, to: target)
            }
            for file in createdFiles.reversed() {
                try? fileManager.removeItem(at: file)
            }
            for directory in createdDirectories.reversed() {
                // Only remove a directory this call created, and only if it is now empty.
                if let contents = try? fileManager.contentsOfDirectory(atPath: directory.path), contents.isEmpty {
                    try? fileManager.removeItem(at: directory)
                }
            }
        }

        do {
            for action in plan.actions {
                switch action.kind {
                case .createDirectory:
                    let url = URL(fileURLWithPath: action.absolutePath)
                    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
                    createdDirectories.append(url)

                case .replaceFile:
                    let target = URL(fileURLWithPath: action.absolutePath)
                    guard let backupDirectory else {
                        throw InstallerError.backupFailed(path: action.relativePath)
                    }
                    let backup = backupDirectory.appendingPathComponent(action.relativePath)
                    try fileManager.createDirectory(
                        at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fileManager.fileExists(atPath: backup.path) {
                        try fileManager.removeItem(at: backup)
                    }
                    try fileManager.copyItem(at: target, to: backup)
                    replacedFiles.append((target, backup))
                    try writeAtomically(payload[action.relativePath]!, to: target)

                case .createFile:
                    let target = URL(fileURLWithPath: action.absolutePath)
                    try writeAtomically(payload[action.relativePath]!, to: target)
                    createdFiles.append(target)
                }
            }
        } catch {
            Log.hidpiInstaller.error("install failed, rolling back: \(String(describing: error), privacy: .public)")
            rollback()
            throw error
        }

        Log.hidpiInstaller.notice("installed override for \(plan.manifest.displayKey, privacy: .public)")
        return plan.manifest
    }

    /// Restores the files recorded in a manifest.
    ///
    /// Verifies each backup against `sha256Before` before putting it back, so a corrupted or swapped
    /// backup file is refused rather than installed.
    public func restore(manifest: BackupManifest, backupDirectory: URL) throws {
        for entry in manifest.entries {
            let target = try resolveChecked(entry.relativePath)

            guard entry.existedBefore, let backupRelative = entry.backupRelativePath else {
                // Nothing was there before, so restoring means removing what we added.
                if fileManager.fileExists(atPath: target.path) {
                    try fileManager.removeItem(at: target)
                }
                continue
            }

            let backup = backupDirectory.appendingPathComponent(backupRelative)
            guard let data = fileManager.contents(atPath: backup.path) else {
                throw InstallerError.backupFailed(path: backup.path)
            }
            let hash = SHA256Hash.hex(of: data)
            if let expected = entry.sha256Before, hash != expected {
                throw InstallerError.manifestMismatch(expected: expected, got: hash)
            }
            try writeAtomically(data, to: target)
        }
        Log.recovery.notice("restored override files for \(manifest.displayKey, privacy: .public)")
    }

    /// Removes an override this app installed.
    ///
    /// Refuses when the file on disk does not hash to what the manifest says the app wrote — that
    /// means someone else has edited it since, and deleting it would be destroying another tool's work.
    /// Only the specific file is removed, and the vendor directory only if it is left empty; the
    /// override root itself is never touched.
    public func removeAppOwned(manifest: BackupManifest) throws {
        for entry in manifest.entries {
            let target = try resolveChecked(entry.relativePath)
            guard let data = fileManager.contents(atPath: target.path) else { continue }
            let hash = SHA256Hash.hex(of: data)
            guard hash == entry.sha256After else {
                throw InstallerError.notAppOwned(path: target.path)
            }
            try fileManager.removeItem(at: target)

            let parent = target.deletingLastPathComponent()
            if parent.path != root.standardizedFileURL.resolvingSymlinksInPath().path,
               let contents = try? fileManager.contentsOfDirectory(atPath: parent.path),
               contents.isEmpty {
                try? fileManager.removeItem(at: parent)
            }
        }
    }

    // MARK: - Internals

    private func resolveChecked(_ relativePath: String) throws -> URL {
        do {
            return try OverridePaths.resolve(relativePath: relativePath, under: root)
        } catch let error as OverridePathError {
            throw InstallerError.pathRejected(error)
        }
    }

    /// Writes via a temporary file plus an atomic replace, so an interrupted write can never leave a
    /// half-written override that WindowServer would try to parse at next login.
    private func writeAtomically(_ data: Data, to target: URL) throws {
        do {
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        } catch {
            throw InstallerError.writeFailed(path: target.path, underlying: "\(error)")
        }
    }

    /// What a `.replace` install throws away, phrased for the confirmation the user actually reads.
    ///
    /// Aggregated rather than one line per entry: a real override can hold hundreds of modes, and a
    /// warning made of 258 identical lines is a warning nobody reads. The EDID line matters most —
    /// nothing else in the app reports it, and a patched EDID is the hardest thing here to reproduce
    /// by hand if it is lost.
    static func discardedDescriptions(of document: DisplayOverrideDocument) -> [String] {
        var result: [String] = []
        let entryCount = document.scaleResolutions.count + document.preservedEntries.count
        if entryCount > 0 {
            result.append("\(entryCount) resolution "
                + (entryCount == 1 ? "entry" : "entries")
                + " already in that file, including any written by another tool")
        }
        if document.patchedEDID != nil {
            result.append("a patched EDID (IODisplayEDID) in the existing file")
        }
        return result
    }

    static func recoveryCommand(for manifest: BackupManifest) -> String {
        guard let entry = manifest.entries.first else { return "" }
        let target = "\(manifest.overrideRoot)/\(entry.relativePath)"
        // Ends with a reconnect hint rather than `reboot`: macOS re-reads the override file when a
        // display attaches, so for an external monitor the cheapest action is also the sufficient one.
        // Logging out is named too, because a built-in panel cannot be unplugged.
        let apply = "   # then reconnect the display, or log out and back in"
        return entry.existedBefore
            ? "sudo cp \"<recovery-package>/backup/\(entry.relativePath)\" \"\(target)\"\(apply)"
            : "sudo rm \"\(target)\"\(apply)"
    }
}
