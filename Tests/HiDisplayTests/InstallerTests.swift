import XCTest
@testable import HiDisplayKit

/// Installer behaviour, entirely inside a temporary directory.
///
/// Nothing in this file may name `/Library/Displays` — the installer takes its root by injection
/// precisely so that a test cannot write to the real one.
final class InstallerTests: XCTestCase {

    private var base: URL!
    private var root: URL!
    private var backups: URL!

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hidisplay-installer-\(UUID().uuidString)")
        root = base.appendingPathComponent("Overrides")
        backups = base.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func makeInstaller() -> OverrideInstaller {
        OverrideInstaller(root: root, appVersion: "test-1.0")
    }

    private func makeDisplay() -> DisplayDevice {
        DisplayDevice(
            identity: DisplayIdentity(
                cgDisplayID: 1, vendorID: 0x10AC, productID: 0xD0A1,
                serialNumber: 0xABCD, keyTier: .strong),
            name: "TEST U2723QE", isBuiltIn: false, isOnline: true, isMain: true)
    }

    private func makeGenerated() -> GeneratedOverride {
        OverrideGenerator.generate(
            DisplayOverrideDocument(
                vendorID: 0x10AC, productID: 0xD0A1, displayName: "TEST U2723QE",
                scaleResolutions: [ScaledResolution(logicalWidth: 1920, logicalHeight: 1080)]),
            nativePixelSize: (3840, 2160))
    }

    // MARK: - Plan

    func testPlanForANewFileCreatesDirectoryAndFile() throws {
        let plan = try makeInstaller().plan(generated: makeGenerated(), display: makeDisplay())

        XCTAssertEqual(plan.actions.map(\.kind), [.createDirectory, .createFile])
        XCTAssertTrue(plan.requiresLogout, "an override is only read when the window server starts")
        XCTAssertTrue(plan.isInstallable)
        XCTAssertNil(plan.manifest.entries[0].sha256Before)
        XCTAssertFalse(plan.manifest.entries[0].existedBefore)
        XCTAssertTrue(plan.recoveryCommand.contains("sudo rm"),
                      "undoing a newly added file means removing it")
    }

    func testPlanDoesNotWriteAnything() throws {
        _ = try makeInstaller().plan(generated: makeGenerated(), display: makeDisplay())
        let contents = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(contents.isEmpty, "planning must be side-effect free")
    }

    func testPlanForAnExistingFileRecordsAReplacement() throws {
        let generated = makeGenerated()
        let target = root.appendingPathComponent(generated.relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: target)

        let plan = try makeInstaller().plan(generated: generated, display: makeDisplay())
        XCTAssertEqual(plan.actions.map(\.kind), [.replaceFile])
        XCTAssertEqual(plan.manifest.entries[0].sha256Before, SHA256Hash.hex(of: Data("existing".utf8)))
        XCTAssertTrue(plan.manifest.entries[0].existedBefore)
        XCTAssertTrue(plan.recoveryCommand.contains("sudo cp"))
    }

    func testRejectsAnOversizedOverride() {
        var document = DisplayOverrideDocument(
            vendorID: 0x10AC, productID: 0xD0A1,
            scaleResolutions: [ScaledResolution(logicalWidth: 1920, logicalHeight: 1080)])
        document.patchedEDID = Data(repeating: 0, count: OverrideInstaller.maximumOverrideBytes + 1)
        let generated = OverrideGenerator.generate(document)

        XCTAssertThrowsError(try makeInstaller().plan(generated: generated, display: makeDisplay())) { error in
            guard case .fileTooLarge = error as? InstallerError else {
                return XCTFail("expected fileTooLarge, got \(error)")
            }
        }
    }

    // MARK: - Backup staging

    func testStageBackupsCopiesTheExistingFile() throws {
        let generated = makeGenerated()
        let target = root.appendingPathComponent(generated.relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("original contents".utf8)
        try original.write(to: target)

        let plan = try makeInstaller().plan(generated: generated, display: makeDisplay())
        try makeInstaller().stageBackups(for: plan.manifest, into: backups)

        let staged = try Data(contentsOf: backups.appendingPathComponent(generated.relativePath))
        XCTAssertEqual(staged, original)
    }

    /// The user can sit on the confirmation alert indefinitely between plan and backup. A file that
    /// changed in that window must fail staging — otherwise the recovery package ships a backup that
    /// its own restore script (which verifies `sha256Before`) will refuse.
    func testStageBackupsRefusesAFileThatChangedSincePlanning() throws {
        let generated = makeGenerated()
        let target = root.appendingPathComponent(generated.relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("planned against this".utf8).write(to: target)

        let plan = try makeInstaller().plan(generated: generated, display: makeDisplay())
        try Data("changed while the alert was up".utf8).write(to: target)

        XCTAssertThrowsError(
            try makeInstaller().stageBackups(for: plan.manifest, into: backups)
        ) { error in
            guard case .manifestMismatch = error as? InstallerError else {
                return XCTFail("expected manifestMismatch, got \(error)")
            }
        }
    }

    func testStageBackupsDoesNothingForAFreshInstall() throws {
        let plan = try makeInstaller().plan(generated: makeGenerated(), display: makeDisplay())
        try makeInstaller().stageBackups(for: plan.manifest, into: backups)
        let contents = try FileManager.default.contentsOfDirectory(atPath: backups.path)
        XCTAssertTrue(contents.isEmpty, "no file existed, so nothing must be staged")
    }

    // MARK: - Apply

    func testApplyWritesTheFileAndReturnsTheManifest() throws {
        let installer = makeInstaller()
        let generated = makeGenerated()
        let plan = try installer.plan(generated: generated, display: makeDisplay())

        let manifest = try installer.apply(
            plan, payload: [generated.relativePath: generated.data], backupDirectory: backups)

        let written = try Data(contentsOf: root.appendingPathComponent(generated.relativePath))
        XCTAssertEqual(written, generated.data)
        XCTAssertEqual(manifest.entries[0].sha256After, SHA256Hash.hex(of: generated.data))
        XCTAssertEqual(manifest.overrideRoot, root.path)
        XCTAssertEqual(manifest.displayKey, makeDisplay().id)
    }

    /// The preview the user approved and the bytes written must be provably the same.
    func testApplyRefusesAPayloadThatDoesNotMatchThePlan() throws {
        let installer = makeInstaller()
        let generated = makeGenerated()
        let plan = try installer.plan(generated: generated, display: makeDisplay())

        XCTAssertThrowsError(
            try installer.apply(plan, payload: [generated.relativePath: Data("tampered".utf8)],
                                backupDirectory: backups)
        ) { error in
            guard case .manifestMismatch = error as? InstallerError else {
                return XCTFail("expected manifestMismatch, got \(error)")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent(generated.relativePath).path),
            "nothing may be written when verification fails")
    }

    func testApplyBacksUpBeforeReplacing() throws {
        let installer = makeInstaller()
        let generated = makeGenerated()
        let target = root.appendingPathComponent(generated.relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("original contents".utf8)
        try original.write(to: target)

        let plan = try installer.plan(generated: generated, display: makeDisplay())
        _ = try installer.apply(plan, payload: [generated.relativePath: generated.data],
                                backupDirectory: backups)

        let backedUp = try Data(contentsOf: backups.appendingPathComponent(generated.relativePath))
        XCTAssertEqual(backedUp, original, "the previous contents must be recoverable")
    }

    func testApplyRollsBackWhenAWriteFailsPartWayThrough() throws {
        let installer = makeInstaller()
        let generated = makeGenerated()
        var plan = try installer.plan(generated: generated, display: makeDisplay())

        // Append a second action that cannot succeed, so the first one has to be undone.
        plan.actions.append(PlannedAction(
            kind: .createFile,
            absolutePath: root.appendingPathComponent("DisplayVendorID-10ac/second").path,
            relativePath: "DisplayVendorID-10ac/second",
            sha256Before: nil,
            sha256After: SHA256Hash.hex(of: Data("second".utf8)),
            byteCount: 6))

        XCTAssertThrowsError(
            // The payload deliberately omits the second file, which makes the apply fail after the
            // first file is already on disk.
            try installer.apply(plan, payload: [generated.relativePath: generated.data],
                                backupDirectory: backups))

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent(generated.relativePath).path),
            "a failed install must leave nothing behind")
    }

    // MARK: - Restore and remove

    func testRestorePutsBackTheOriginalFile() throws {
        let installer = makeInstaller()
        let generated = makeGenerated()
        let target = root.appendingPathComponent(generated.relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("original".utf8)
        try original.write(to: target)

        let plan = try installer.plan(generated: generated, display: makeDisplay())
        let manifest = try installer.apply(
            plan, payload: [generated.relativePath: generated.data], backupDirectory: backups)

        try installer.restore(manifest: manifest, backupDirectory: backups)
        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    func testRestoreRemovesAFileThatDidNotExistBefore() throws {
        let installer = makeInstaller()
        let generated = makeGenerated()
        let plan = try installer.plan(generated: generated, display: makeDisplay())
        let manifest = try installer.apply(
            plan, payload: [generated.relativePath: generated.data], backupDirectory: backups)

        try installer.restore(manifest: manifest, backupDirectory: backups)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent(generated.relativePath).path))
    }

    /// Undo must not delete what it did not write: a file rewritten by another tool since our
    /// install is their work now, and restore refuses it the same way `removeAppOwned` does.
    func testRestoreRefusesToRemoveAFileAnotherToolRewrote() throws {
        let installer = makeInstaller()
        let generated = makeGenerated()
        let plan = try installer.plan(generated: generated, display: makeDisplay())
        let manifest = try installer.apply(
            plan, payload: [generated.relativePath: generated.data], backupDirectory: backups)

        let target = root.appendingPathComponent(generated.relativePath)
        try Data("another tool's contents".utf8).write(to: target)

        XCTAssertThrowsError(try installer.restore(manifest: manifest, backupDirectory: backups)) { error in
            guard case .notAppOwned = error as? InstallerError else {
                return XCTFail("expected notAppOwned, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path),
                      "the other tool's file must survive the refused restore")
    }

    func testRestoreRefusesACorruptedBackup() throws {
        let installer = makeInstaller()
        let generated = makeGenerated()
        let target = root.appendingPathComponent(generated.relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("original".utf8).write(to: target)

        let plan = try installer.plan(generated: generated, display: makeDisplay())
        let manifest = try installer.apply(
            plan, payload: [generated.relativePath: generated.data], backupDirectory: backups)

        // Tamper with the backup after the fact.
        try Data("not the original".utf8)
            .write(to: backups.appendingPathComponent(generated.relativePath))

        XCTAssertThrowsError(try installer.restore(manifest: manifest, backupDirectory: backups)) { error in
            guard case .manifestMismatch = error as? InstallerError else {
                return XCTFail("expected manifestMismatch, got \(error)")
            }
        }
    }

    func testRemoveAppOwnedDeletesOnlyOurFileAndTheEmptyDirectory() throws {
        let installer = makeInstaller()
        let generated = makeGenerated()
        let plan = try installer.plan(generated: generated, display: makeDisplay())
        let manifest = try installer.apply(
            plan, payload: [generated.relativePath: generated.data], backupDirectory: backups)

        try installer.removeAppOwned(manifest: manifest)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(generated.relativePath).path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("DisplayVendorID-10ac").path),
            "an empty vendor directory is cleaned up")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path),
                      "the override root itself is never removed")
    }

    func testRemoveAppOwnedRefusesAFileEditedBySomeoneElse() throws {
        let installer = makeInstaller()
        let generated = makeGenerated()
        let plan = try installer.plan(generated: generated, display: makeDisplay())
        let manifest = try installer.apply(
            plan, payload: [generated.relativePath: generated.data], backupDirectory: backups)

        // Someone — another tool, or the user — changed the file after we wrote it.
        try Data("hand edited".utf8).write(to: root.appendingPathComponent(generated.relativePath))

        XCTAssertThrowsError(try installer.removeAppOwned(manifest: manifest)) { error in
            guard case .notAppOwned = error as? InstallerError else {
                return XCTFail("expected notAppOwned, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(generated.relativePath).path),
            "someone else's edit must not be destroyed")
    }

    func testDoesNotLeaveTheVendorDirectoryWhenItStillHasOtherFiles() throws {
        let installer = makeInstaller()
        let generated = makeGenerated()
        let plan = try installer.plan(generated: generated, display: makeDisplay())
        let manifest = try installer.apply(
            plan, payload: [generated.relativePath: generated.data], backupDirectory: backups)

        // A second display's override in the same vendor directory.
        let sibling = root.appendingPathComponent("DisplayVendorID-10ac/DisplayProductID-beef")
        try Data("sibling".utf8).write(to: sibling)

        try installer.removeAppOwned(manifest: manifest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path),
                      "another display's override must survive")
    }
}

final class BackupManifestTests: XCTestCase {

    func testManifestRoundTripsThroughJSON() throws {
        let manifest = BackupManifest(
            appVersion: "test-1.0",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            overrideRoot: "/tmp/root",
            displayKey: "v10ac-pd0a1-s0000abcd",
            displayName: "TEST",
            vendorID: 0x10AC,
            productID: 0xD0A1,
            entries: [
                BackupEntry(relativePath: "DisplayVendorID-10ac/DisplayProductID-d0a1",
                            backupRelativePath: nil, sha256Before: nil,
                            sha256After: "abc123", existedBefore: false, byteCount: 42),
            ])

        let decoded = try BackupManifest.decode(from: try manifest.jsonData())
        XCTAssertEqual(decoded, manifest)
    }

    func testManifestJSONIsStableForSnapshotting() throws {
        let manifest = BackupManifest(
            appVersion: "test-1.0",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            overrideRoot: "/tmp/root",
            displayKey: "key", displayName: "TEST",
            vendorID: 1, productID: 2, entries: [])
        let first = try manifest.jsonData()
        let second = try manifest.jsonData()
        XCTAssertEqual(first, second)
        let text = try XCTUnwrap(String(data: first, encoding: .utf8))
        // Sorted keys and unescaped slashes, so a human reading it in a recovery situation is not
        // fighting the formatting.
        XCTAssertTrue(text.contains("\"appVersion\""))
        XCTAssertTrue(text.contains("/tmp/root"))
        XCTAssertLessThan(
            try XCTUnwrap(text.range(of: "\"appVersion\"")).lowerBound,
            try XCTUnwrap(text.range(of: "\"displayKey\"")).lowerBound)
    }
}

/// Merge-versus-replace. The distinction surfaced from real use: an override written by another tool
/// held 258 entries, and "regenerate" must not mean the same thing as "wipe and replace".
final class ExistingContentPolicyTests: XCTestCase {

    private var base: URL!
    private var root: URL!

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hidisplay-policy-\(UUID().uuidString)")
        root = base.appendingPathComponent("Overrides")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func makeDisplay() -> DisplayDevice {
        DisplayDevice(
            identity: DisplayIdentity(cgDisplayID: 1, vendorID: 0x10AC, productID: 0xD0A1),
            name: "TEST", isBuiltIn: false, isOnline: true, isMain: true)
    }

    private func makeGenerated() -> GeneratedOverride {
        OverrideGenerator.generate(
            DisplayOverrideDocument(
                vendorID: 0x10AC, productID: 0xD0A1,
                scaleResolutions: [ScaledResolution(logicalWidth: 1920, logicalHeight: 1080)]),
            nativePixelSize: (3840, 2160))
    }

    /// Seeds the target with a file full of entries in the 12-byte Apple form, which this app never
    /// emits and therefore treats as foreign.
    private func seedForeignOverride(relativePath: String) throws -> Int {
        let url = try Data(contentsOf: try Fixtures.overrideURL(named: "apple-610-9cc3.plist"))
        let (document, _) = try OverrideGenerator.parseExisting(url)
        var foreign = document
        foreign.vendorID = 0x10AC
        foreign.productID = 0xD0A1
        let data = OverrideGenerator.generate(foreign).data

        let target = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
        return foreign.preservedEntries.count
    }

    func testMergeKeepsForeignEntries() throws {
        let generated = makeGenerated()
        let foreignCount = try seedForeignOverride(relativePath: generated.relativePath)
        XCTAssertGreaterThan(foreignCount, 0, "fixture should contain entries this app does not emit")

        let installer = OverrideInstaller(root: root, appVersion: "test")
        let plan = try installer.plan(generated: generated, display: makeDisplay(), policy: .merge)

        // The planned size must exceed the bare generated file, i.e. the foreign entries survive.
        XCTAssertGreaterThan(plan.actions.last!.byteCount, generated.data.count)
    }

    /// Seeds the target with an override made entirely of entries this app *does* emit — the shape
    /// another HiDPI tool writes, and the case the merge policy used to skip entirely.
    private func seedNativeShapedOverride(relativePath: String, count: Int) throws -> [ScaledResolution] {
        let resolutions = (1...count).map {
            ScaledResolution(logicalWidth: 1000 + $0 * 16, logicalHeight: 600 + $0 * 9)
        }
        let data = OverrideGenerator.generate(
            DisplayOverrideDocument(
                vendorID: 0x10AC, productID: 0xD0A1, scaleResolutions: resolutions)).data

        let target = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
        return resolutions
    }

    /// The VX2780-2K regression: installing three sizes over a 242-entry override written by another
    /// tool wiped every one of them. `preservedEntries` was empty — the other tool's entries decoded
    /// perfectly — so the merge branch never ran and the file was replaced wholesale.
    func testMergeKeepsEntriesItCanDecode() throws {
        let generated = makeGenerated()
        let existing = try seedNativeShapedOverride(relativePath: generated.relativePath, count: 12)

        let installer = OverrideInstaller(root: root, appVersion: "test")
        let plan = try installer.plan(generated: generated, display: makeDisplay(), policy: .merge)

        // Entries, not resolutions: each HiDPI size is stored alongside an 8-byte backing companion,
        // so a 12-size file holds 24 entries. The confirmation counts what is in the file.
        let seeded = try OverrideGenerator.parseExisting(
            Data(contentsOf: root.appendingPathComponent(generated.relativePath))).document
        XCTAssertEqual(seeded.scaleResolutions.count, existing.count * 2)
        XCTAssertEqual(plan.carriedOverEntryCount, seeded.scaleResolutions.count,
                       "the confirmation must be able to state how many modes are already installed")

        // Decode the planned bytes rather than trusting a size comparison: the point is that every
        // pre-existing size is still addressable, not merely that the file grew.
        let (result, _) = try OverrideGenerator.parseExisting(plan.payload)

        let ids = Set(result.scaleResolutions.map(\.id))
        for resolution in existing {
            XCTAssertTrue(ids.contains(resolution.id), "merge dropped \(resolution.id)")
        }
        XCTAssertTrue(ids.contains(ScaledResolution(logicalWidth: 1920, logicalHeight: 1080).id),
                      "the newly selected size must be there too")
    }

    /// Seeds the target with an override holding top-level keys this app does not understand.
    private func seedOverrideWithForeignTopLevelKeys(relativePath: String) throws {
        let plist: [String: Any] = [
            "DisplayVendorID": 0x10AC,
            "DisplayProductID": 0xD0A1,
            "DisplayGammaTable": Data([0x01, 0x02, 0x03]),
            "DisplayWhitePointX": 0.3127,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let target = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
    }

    /// "Merge" has to mean the whole file, not just the entries this app understands — a merge that
    /// deletes a gamma table is a replace wearing a merge's name.
    func testMergeCarriesForeignTopLevelKeys() throws {
        let generated = makeGenerated()
        try seedOverrideWithForeignTopLevelKeys(relativePath: generated.relativePath)

        let installer = OverrideInstaller(root: root, appVersion: "test")
        let plan = try installer.plan(generated: generated, display: makeDisplay(), policy: .merge)

        XCTAssertTrue(plan.droppedUnknownKeys.isEmpty, "a merge that carries everything drops nothing")
        let payload = try PropertyListSerialization.propertyList(
            from: plan.payload, options: [], format: nil) as? [String: Any]
        XCTAssertEqual(payload?["DisplayGammaTable"] as? Data, Data([0x01, 0x02, 0x03]))
        XCTAssertEqual(payload?["DisplayWhitePointX"] as? Double, 0.3127)
        XCTAssertNotNil(payload?["scale-resolutions"] as? [Data], "the selection still lands too")
    }

    func testReplaceStillReportsForeignTopLevelKeysAsDropped() throws {
        let generated = makeGenerated()
        try seedOverrideWithForeignTopLevelKeys(relativePath: generated.relativePath)

        let installer = OverrideInstaller(root: root, appVersion: "test")
        let plan = try installer.plan(generated: generated, display: makeDisplay(), policy: .replace)

        XCTAssertTrue(plan.droppedUnknownKeys.contains("DisplayGammaTable"))
        XCTAssertTrue(plan.droppedUnknownKeys.contains("DisplayWhitePointX"))
        let payload = try PropertyListSerialization.propertyList(
            from: plan.payload, options: [], format: nil) as? [String: Any]
        XCTAssertNil(payload?["DisplayGammaTable"], "replace means what it says")
    }

    /// The resolution cap has to gate the *union*, not the selection: one new size over a full file
    /// breaches it just as surely as 129 new sizes over an empty one.
    func testAMergeThatBreachesTheResolutionCapIsNotInstallable() throws {
        let generated = makeGenerated()
        XCTAssertTrue(generated.validation.isInstallable, "the selection alone must be fine")
        _ = try seedNativeShapedOverride(
            relativePath: generated.relativePath, count: OverrideValidator.maximumResolutionCount)

        let installer = OverrideInstaller(root: root, appVersion: "test")
        let plan = try installer.plan(generated: generated, display: makeDisplay(), policy: .merge)

        XCTAssertFalse(plan.isInstallable, "the merged file breaches the cap even though the selection did not")
        XCTAssertTrue(plan.validation.errors.contains { $0.message.contains("limit") })
    }

    /// Same for the byte limit: a small selection merged over a huge existing file must be refused,
    /// not waved through because the selection alone was under the limit.
    func testAMergeThatGrowsPastTheSizeLimitIsRefused() throws {
        let generated = makeGenerated()
        let plist: [String: Any] = [
            "DisplayVendorID": 0x10AC,
            "DisplayProductID": 0xD0A1,
            "IODisplayEDID": Data(repeating: 0, count: OverrideInstaller.maximumOverrideBytes),
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let target = root.appendingPathComponent(generated.relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)

        let installer = OverrideInstaller(root: root, appVersion: "test")
        XCTAssertThrowsError(
            try installer.plan(generated: generated, display: makeDisplay(), policy: .merge)
        ) { error in
            guard case .fileTooLarge = error as? InstallerError else {
                return XCTFail("expected fileTooLarge, got \(error)")
            }
        }
    }

    /// No existing file means nothing to carry over, and the confirmation must not claim otherwise.
    func testCarriedOverCountIsZeroForAFreshInstall() throws {
        let installer = OverrideInstaller(root: root, appVersion: "test")
        let plan = try installer.plan(generated: makeGenerated(), display: makeDisplay(), policy: .merge)
        XCTAssertEqual(plan.carriedOverEntryCount, 0)
        XCTAssertEqual(plan.payload, makeGenerated().data, "nothing to merge means nothing to change")
    }

    /// The plan's own hash must describe its own payload. It did not: `plan()` hashed the merged file
    /// and callers wrote the unmerged one, with nothing comparing them.
    func testThePlanHashDescribesThePlanPayload() throws {
        let generated = makeGenerated()
        _ = try seedNativeShapedOverride(relativePath: generated.relativePath, count: 5)

        let installer = OverrideInstaller(root: root, appVersion: "test")
        let plan = try installer.plan(generated: generated, display: makeDisplay(), policy: .merge)
        let action = plan.actions.last { $0.kind != .createDirectory }

        XCTAssertEqual(action?.sha256After, SHA256Hash.hex(of: plan.payload))
        XCTAssertEqual(action?.byteCount, plan.payload.count)
        XCTAssertNotEqual(plan.payload, generated.data,
                          "a merge that changes nothing would make this test vacuous")
    }

    func testReplaceDiscardsForeignEntriesAndSaysSo() throws {
        let generated = makeGenerated()
        let foreignCount = try seedForeignOverride(relativePath: generated.relativePath)
        XCTAssertGreaterThan(foreignCount, 0)

        let installer = OverrideInstaller(root: root, appVersion: "test")
        let plan = try installer.plan(generated: generated, display: makeDisplay(), policy: .replace)

        XCTAssertEqual(plan.actions.last!.byteCount, generated.data.count,
                       "replace writes exactly the generated file")
        // Aggregated into one countable sentence rather than one line per entry: this text goes
        // straight into the confirmation, and a warning made of 258 identical lines is not read.
        let counted = plan.droppedUnknownKeys.filter { $0.contains("resolution entr") }
        XCTAssertEqual(counted.count, 1,
                       "the preview must state what is being discarded, not drop it quietly")
        XCTAssertTrue(counted[0].hasPrefix("\(foreignCount) resolution "),
                      "the count must be the real one; got '\(counted[0])'")
    }

    /// A patched EDID is the hardest thing in an override to reproduce by hand, so losing one silently
    /// is the worst case of the replace policy. Under merge it survives; under replace it is named.
    func testPatchedEDIDIsCarriedByMergeAndReportedByReplace() throws {
        let generated = makeGenerated()
        let edid = Data(repeating: 0xAB, count: 128)
        let existing = OverrideGenerator.generate(
            DisplayOverrideDocument(
                vendorID: 0x10AC, productID: 0xD0A1,
                scaleResolutions: [ScaledResolution(logicalWidth: 1280, logicalHeight: 720)],
                patchedEDID: edid)).data
        let target = root.appendingPathComponent(generated.relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try existing.write(to: target)

        let installer = OverrideInstaller(root: root, appVersion: "test")

        let merged = try installer.plan(generated: generated, display: makeDisplay(), policy: .merge)
        XCTAssertGreaterThan(merged.actions.last!.byteCount, generated.data.count,
                             "merge must keep an EDID patch it did not write")

        let replaced = try installer.plan(generated: generated, display: makeDisplay(), policy: .replace)
        XCTAssertTrue(replaced.droppedUnknownKeys.contains { $0.contains("IODisplayEDID") },
                      "replace must say the EDID patch is going away")
    }

    func testMergeIsTheDefault() throws {
        let generated = makeGenerated()
        _ = try seedForeignOverride(relativePath: generated.relativePath)
        let installer = OverrideInstaller(root: root, appVersion: "test")

        let explicit = try installer.plan(generated: generated, display: makeDisplay(), policy: .merge)
        let implicit = try installer.plan(generated: generated, display: makeDisplay())
        XCTAssertEqual(implicit.actions.last!.byteCount, explicit.actions.last!.byteCount,
                       "the destructive option must never be the default")
    }
}
