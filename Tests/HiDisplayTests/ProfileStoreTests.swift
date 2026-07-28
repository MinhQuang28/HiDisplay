import XCTest
@testable import HiDisplayKit

/// Profile persistence, always against a temporary file — never the real Application Support path.
final class ProfileStoreTests: XCTestCase {

    private var directory: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hidisplay-profiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("profiles.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeDisplay(
        key serial: UInt32 = 0xABCD, name: String = "TEST U2723QE"
    ) -> DisplayDevice {
        DisplayDevice(
            identity: DisplayIdentity(
                cgDisplayID: 1, vendorID: 0x10AC, productID: 0xD0A1,
                serialNumber: serial, keyTier: .strong),
            name: name, isBuiltIn: false, isOnline: true, isMain: true)
    }

    func testWritesAndReadsBackAProfile() async throws {
        let display = makeDisplay()
        let store = ProfileStore(fileURL: fileURL, saveDebounce: .milliseconds(1))
        await store.setBrightness(0.42, for: display)
        await store.setController(.ddc, for: display)
        await store.flush()

        let reloaded = ProfileStore(fileURL: fileURL)
        await reloaded.load()
        let loaded = await reloaded.profile(for: display.id)
        let profile = try XCTUnwrap(loaded)
        XCTAssertEqual(profile.brightness, 0.42)
        XCTAssertEqual(profile.brightnessController, .ddc)
        XCTAssertEqual(profile.displayName, "TEST U2723QE")
        XCTAssertEqual(profile.keyTier, .strong)
    }

    /// The bug this guards: a reconnect creating a second profile for the same monitor.
    func testUpsertDoesNotDuplicateOnReconnect() async {
        let store = ProfileStore(fileURL: fileURL, saveDebounce: .milliseconds(1))
        let display = makeDisplay()
        await store.setBrightness(0.3, for: display)
        // Same monitor, new CoreGraphics ID — exactly what a replug looks like.
        var reconnected = display
        reconnected.identity.cgDisplayID = 99
        await store.setBrightness(0.7, for: reconnected)

        let all = await store.allProfiles()
        XCTAssertEqual(all.count, 1, "the display ID changed but the stable key did not")
        XCTAssertEqual(all[0].brightness, 0.7)
    }

    func testTwoDisplaysWithDifferentSerialsGetSeparateProfiles() async {
        let store = ProfileStore(fileURL: fileURL, saveDebounce: .milliseconds(1))
        await store.setBrightness(0.2, for: makeDisplay(key: 0x111, name: "Left"))
        await store.setBrightness(0.8, for: makeDisplay(key: 0x222, name: "Right"))

        let all = await store.allProfiles()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(Set(all.map(\.brightness)), [0.2, 0.8])
    }

    func testRenamingADisplayUpdatesTheProfileRatherThanCreatingOne() async throws {
        let store = ProfileStore(fileURL: fileURL, saveDebounce: .milliseconds(1))
        await store.setBrightness(0.5, for: makeDisplay(name: "Old Name"))
        await store.setBrightness(0.5, for: makeDisplay(name: "New Name"))

        let all = await store.allProfiles()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].displayName, "New Name")
    }

    func testMissingFileStartsEmptyWithoutError() async {
        let store = ProfileStore(fileURL: fileURL)
        await store.load()
        let profiles = await store.allProfiles()
        XCTAssertTrue(profiles.isEmpty)
    }

    /// A corrupt file must not be silently overwritten — it is the user's data.
    func testCorruptFileIsPreservedAsACopy() async throws {
        try Data("{ not json".utf8).write(to: fileURL)
        let store = ProfileStore(fileURL: fileURL)
        await store.load()

        let profiles = await store.allProfiles()
        XCTAssertTrue(profiles.isEmpty)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fileURL.appendingPathExtension("corrupt").path),
            "the unreadable original must be kept for manual recovery")
    }

    /// `copyItem` refuses to overwrite, so a second corruption used to silently keep the *old*
    /// salvage while looking like it had preserved the new one.
    func testASecondCorruptionReplacesTheSalvageCopy() async throws {
        let salvage = fileURL.appendingPathExtension("corrupt")

        try Data("{ first corruption".utf8).write(to: fileURL)
        await ProfileStore(fileURL: fileURL).load()

        try Data("{ second corruption".utf8).write(to: fileURL)
        await ProfileStore(fileURL: fileURL).load()

        XCTAssertEqual(try Data(contentsOf: salvage), Data("{ second corruption".utf8),
                       "the salvage must hold the most recent unreadable file")
    }

    func testRejectsAFileFromANewerSchema() throws {
        let future = """
        { "schemaVersion": 999, "profiles": {}, "hiDPIProfiles": {}, "userAssignments": {} }
        """
        XCTAssertThrowsError(try ProfileStore.decode(Data(future.utf8))) { error in
            guard case ProfileStore.StoreError.unsupportedSchema(let found, _) = error else {
                return XCTFail("expected unsupportedSchema, got \(error)")
            }
            XCTAssertEqual(found, 999)
        }
    }

    func testMigrationStampsTheCurrentSchemaVersion() throws {
        let document = ProfileDocument(schemaVersion: 0)
        let migrated = try ProfileStore.migrate(document)
        XCTAssertEqual(migrated.schemaVersion, ProfileDocument.currentSchemaVersion)
    }

    func testUserAssignmentsSurviveARoundTrip() async throws {
        let uuid = UUID()
        let store = ProfileStore(fileURL: fileURL, saveDebounce: .milliseconds(1))
        await store.assignIdentity(uuid, toHeuristicKey: "v10ac-pd0a1")
        await store.flush()

        let reloaded = ProfileStore(fileURL: fileURL)
        await reloaded.load()
        let assignments = await reloaded.userAssignments()
        XCTAssertEqual(assignments["v10ac-pd0a1"], uuid)
    }

    func testHiDPIProfilesAreStoredPerDisplay() async {
        let store = ProfileStore(fileURL: fileURL, saveDebounce: .milliseconds(1))
        let profile = HiDPIProfile(
            displayKey: "v10ac-pd0a1-s0000abcd",
            resolutions: [ScaledResolution(logicalWidth: 1920, logicalHeight: 1080)])
        await store.save(hiDPIProfile: profile)

        let mine = await store.hiDPIProfiles(forDisplay: "v10ac-pd0a1-s0000abcd")
        let theirs = await store.hiDPIProfiles(forDisplay: "someone-else")
        XCTAssertEqual(mine.count, 1)
        XCTAssertTrue(theirs.isEmpty)
    }

    func testResetOneProfileLeavesOthersAlone() async {
        let store = ProfileStore(fileURL: fileURL, saveDebounce: .milliseconds(1))
        let left = makeDisplay(key: 0x111, name: "Left")
        let right = makeDisplay(key: 0x222, name: "Right")
        await store.setBrightness(0.2, for: left)
        await store.setBrightness(0.8, for: right)

        await store.resetProfile(key: left.id)
        let leftProfile = await store.profile(for: left.id)
        let rightProfile = await store.profile(for: right.id)
        XCTAssertNil(leftProfile)
        XCTAssertNotNil(rightProfile)
    }

    func testResetAllClearsEverything() async {
        let store = ProfileStore(fileURL: fileURL, saveDebounce: .milliseconds(1))
        await store.setBrightness(0.2, for: makeDisplay())
        await store.assignIdentity(UUID(), toHeuristicKey: "k")
        await store.resetAll()

        let remaining = await store.allProfiles()
        let assignments = await store.userAssignments()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertTrue(assignments.isEmpty)
    }

    func testExportImportRoundTrip() async throws {
        let store = ProfileStore(fileURL: fileURL, saveDebounce: .milliseconds(1))
        await store.setBrightness(0.33, for: makeDisplay())
        let exported = try await store.exportData()

        let other = ProfileStore(
            fileURL: directory.appendingPathComponent("other.json"), saveDebounce: .milliseconds(1))
        try await other.importData(exported)
        let imported = await other.allProfiles()
        XCTAssertEqual(imported.first?.brightness, 0.33)
    }

    /// A slider drag produces many rapid updates; only the last state needs to reach disk, but it must.
    func testRapidUpdatesCoalesceAndTheFinalValueIsPersisted() async throws {
        let display = makeDisplay()
        let store = ProfileStore(fileURL: fileURL, saveDebounce: .milliseconds(30))
        for value in stride(from: Float(0), through: 1, by: 0.05) {
            await store.setBrightness(value, for: display)
        }
        await store.flush()

        let reloaded = ProfileStore(fileURL: fileURL)
        await reloaded.load()
        let finalProfile = await reloaded.profile(for: display.id)
        XCTAssertEqual(try XCTUnwrap(finalProfile).brightness, 1.0, accuracy: 0.001)
    }
}

final class RecoveryPackageTests: XCTestCase {

    private var parent: URL!

    override func setUpWithError() throws {
        parent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hidisplay-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: parent)
    }

    private func manifest(existedBefore: Bool) -> BackupManifest {
        BackupManifest(
            appVersion: "test-1.0",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            overrideRoot: OverridePaths.systemOverrideRoot,
            displayKey: "v10ac-pd0a1-s0000abcd",
            displayName: "TEST U2723QE",
            vendorID: 0x10AC, productID: 0xD0A1,
            entries: [
                BackupEntry(
                    relativePath: "DisplayVendorID-10ac/DisplayProductID-d0a1",
                    backupRelativePath: existedBefore ? "DisplayVendorID-10ac/DisplayProductID-d0a1" : nil,
                    sha256Before: existedBefore ? "aaaa" : nil,
                    sha256After: "bbbb",
                    existedBefore: existedBefore,
                    byteCount: 100),
            ])
    }

    func testCreatesTheExpectedLayout() throws {
        let package = try RecoveryPackageBuilder.create(manifest: manifest(existedBefore: false), in: parent)

        XCTAssertTrue(package.directory.lastPathComponent.hasPrefix("HiDisplay-Recovery-"))
        for url in [package.readme, package.restoreScript,
                    package.directory.appendingPathComponent("manifest.json")] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "missing \(url.lastPathComponent)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.backupDirectory.path))
    }

    func testRestoreScriptIsExecutable() throws {
        let package = try RecoveryPackageBuilder.create(manifest: manifest(existedBefore: false), in: parent)
        let attributes = try FileManager.default.attributesOfItem(atPath: package.restoreScript.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.int16Value & 0o111, 0o111, "must be double-clickable")
    }

    /// The script has to be safe when run by a stressed user in Recovery, so its safety properties are
    /// asserted on the generated text rather than left to review.
    func testRestoreScriptSafetyProperties() throws {
        for existed in [true, false] {
            let package = try RecoveryPackageBuilder.create(
                manifest: manifest(existedBefore: existed), in: parent,
                timestamp: Date(timeIntervalSince1970: existed ? 1 : 2))
            let script = try String(contentsOf: package.restoreScript, encoding: .utf8)

            XCTAssertTrue(script.contains("set -euo pipefail"), "must abort on the first failure")
            XCTAssertFalse(script.contains("rm -rf"), "never recursive deletion")
            XCTAssertTrue(script.contains("is outside"), "must verify the target is inside the override root")
            XCTAssertTrue(script.contains("/System/*"), "must refuse to touch the system volume")
            XCTAssertTrue(script.contains(OverridePaths.systemOverrideRoot))
            if existed {
                XCTAssertTrue(script.contains("shasum -a 256"), "a restored backup must be verified first")
            } else {
                XCTAssertTrue(script.contains("rmdir"), "an emptied vendor directory is removed non-recursively")
            }
        }
    }

    /// The display name is the one script ingredient the monitor's hardware controls (via EDID), so a
    /// hostile name must not be able to smuggle shell syntax into restore.command — which runs sudo.
    func testHostileDisplayNameCannotReachTheRestoreScript() throws {
        let hostileNames = [
            "Evil\"; rm -r /tmp; echo \"Monitor",
            "Evil$(touch /tmp/pwned)Monitor",
            "Evil`touch /tmp/pwned`Monitor",
            "Evil\\\"$(id)\\\"Monitor",
            "Evil\nsudo rm /etc/hosts\n# Monitor",
        ]
        for (index, name) in hostileNames.enumerated() {
            var hostile = manifest(existedBefore: true)
            hostile.displayName = name
            let package = try RecoveryPackageBuilder.create(
                manifest: hostile, in: parent, timestamp: Date(timeIntervalSince1970: Double(index)))
            let script = try String(contentsOf: package.restoreScript, encoding: .utf8)

            // The name lands on exactly two lines. Whatever survives sanitizing must be inert there:
            // no expansion, no quote-escape, no line break smuggled through.
            let nameLines = script.components(separatedBy: "\n")
                .filter { $0.contains("installed for:") || $0.contains("display :") }
            XCTAssertEqual(nameLines.count, 2, "expected the name on two lines for '\(name)'")
            for line in nameLines {
                for character in ["$", "`", "\\"] {
                    XCTAssertFalse(line.contains(character), "'\(character)' survived for '\(name)'")
                }
            }
            // The echo line stays a single double-quoted string: exactly the two delimiting quotes.
            let echoLine = try XCTUnwrap(nameLines.first { $0.contains("display :") })
            XCTAssertEqual(echoLine.filter { $0 == "\"" }.count, 2, "quote survived for '\(name)'")
            // Fragments of the injected text may survive as inert characters, but never as their own
            // line — that would mean the newline itself got through.
            XCTAssertFalse(script.contains("\nsudo rm /etc"), "injected line break survived for '\(name)'")
            // bash -n parses without executing: the script must still be syntactically valid.
            let bash = Process()
            bash.executableURL = URL(fileURLWithPath: "/bin/bash")
            bash.arguments = ["-n", package.restoreScript.path]
            try bash.run()
            bash.waitUntilExit()
            XCTAssertEqual(bash.terminationStatus, 0, "script no longer parses for '\(name)'")
        }
    }

    func testReadmeExplainsBothTheNormalAndRecoveryTerminalRoutes() throws {
        let package = try RecoveryPackageBuilder.create(manifest: manifest(existedBefore: true), in: parent)
        let readme = try String(contentsOf: package.readme, encoding: .utf8)

        XCTAssertTrue(readme.contains("restore.command"))
        XCTAssertTrue(readme.contains("macOS Recovery"))
        XCTAssertTrue(readme.contains("/Volumes"), "Recovery mounts the normal disk under /Volumes")
        XCTAssertTrue(readme.contains("TEST U2723QE"))
        XCTAssertTrue(readme.contains("no personal data"))
    }

    func testManifestInsideThePackageIsReadable() throws {
        let original = manifest(existedBefore: true)
        let package = try RecoveryPackageBuilder.create(manifest: original, in: parent)
        let data = try Data(contentsOf: package.directory.appendingPathComponent("manifest.json"))
        XCTAssertEqual(try BackupManifest.decode(from: data), original)
    }
}

final class DiagnosticsTests: XCTestCase {

    private func makeDisplay() -> DisplayDevice {
        DisplayDevice(
            identity: DisplayIdentity(
                cgDisplayID: 1, vendorID: 0x10AC, productID: 0xD0A1,
                serialNumber: 0xDEAD_BEEF, edidHash: "1122334455667788", keyTier: .strong),
            name: "TEST U2723QE", isBuiltIn: false, isOnline: true, isMain: true,
            currentMode: DisplayMode(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, refreshRate: 60),
            availableModes: [
                DisplayMode(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, refreshRate: 60),
                DisplayMode(width: 3840, height: 2160, pixelWidth: 3840, pixelHeight: 2160, refreshRate: 60),
            ])
    }

    private func makeReport() -> DiagnosticsReport {
        DiagnosticsBuilder.build(
            displays: [makeDisplay()],
            ambiguousKeys: [],
            brightnessStates: [:],
            availability: [:],
            probeDetails: [:],
            warnings: [:],
            chosenControllers: [:],
            appVersion: "test-1.0",
            now: Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// The privacy contract, asserted rather than trusted: diagnostics get pasted into public issue
    /// trackers, and a monitor serial plus a hostname is more identifying than users expect.
    func testReportContainsNoSerialNumberOrHomePath() throws {
        let text = try XCTUnwrap(String(data: try makeReport().jsonData(), encoding: .utf8))

        XCTAssertFalse(text.contains("deadbeef"), "the raw serial must never appear")
        XCTAssertFalse(text.contains("3735928559"), "nor its decimal form")
        XCTAssertFalse(text.lowercased().contains(NSUserName().lowercased()))
        XCTAssertFalse(text.contains(NSHomeDirectory()))
        // Presence flags are what the file carries instead.
        XCTAssertTrue(text.contains("\"hasSerial\" : true"))
        XCTAssertTrue(text.contains("\"edidHashPresent\" : true"))
    }

    func testReportCarriesWhatSupportActuallyNeeds() throws {
        let report = makeReport()
        let display = try XCTUnwrap(report.displays.first)

        XCTAssertEqual(display.vendorIDHex, "0x10ac")
        XCTAssertEqual(display.productIDHex, "0xd0a1")
        XCTAssertEqual(display.overrideRelativePath, "DisplayVendorID-10ac/DisplayProductID-d0a1")
        XCTAssertEqual(display.keyTier, "strong")
        XCTAssertEqual(display.hiDPIModeCount, 1)
        XCTAssertEqual(display.modeCount, 2)
        // Shim status is the single most useful field when brightness silently does nothing.
        XCTAssertNotNil(report.environment.shims["IOAVService"])
        XCTAssertNotNil(report.environment.shims["DisplayServices"])
    }

    func testModeListIsSampledNotDumped() {
        var display = makeDisplay()
        display.availableModes = (1...200).map {
            DisplayMode(width: $0 * 2, height: $0, pixelWidth: $0 * 2, pixelHeight: $0, refreshRate: 60)
        }
        let report = DiagnosticsBuilder.build(
            displays: [display], ambiguousKeys: [], brightnessStates: [:], availability: [:],
            probeDetails: [:], warnings: [:], chosenControllers: [:], appVersion: "test")
        XCTAssertEqual(report.displays[0].modeCount, 200)
        XCTAssertLessThanOrEqual(report.displays[0].sampleModes.count, 12,
                                 "a full mode dump would drown out everything else in the file")
    }

    func testAmbiguousPairingIsReported() {
        let display = makeDisplay()
        let report = DiagnosticsBuilder.build(
            displays: [display], ambiguousKeys: [display.id], brightnessStates: [:], availability: [:],
            probeDetails: [:], warnings: [:], chosenControllers: [:], appVersion: "test")
        XCTAssertEqual(report.displays[0].pairingConfidence, "ambiguous")
    }
}
