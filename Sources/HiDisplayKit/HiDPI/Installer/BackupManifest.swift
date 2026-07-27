import CryptoKit
import Foundation

/// Record of one file the installer touched, and of what was there before.
///
/// The hash of the previous contents is what makes a restore verifiable: `restore.command` can check
/// that what it is putting back is what was actually taken away, rather than trusting a filename.
public struct BackupEntry: Codable, Equatable, Sendable {
    /// Path relative to the override root — the same form the generator produces.
    public var relativePath: String
    /// Where the backup copy lives, relative to the recovery package's `backup/` directory.
    public var backupRelativePath: String?
    /// SHA-256 of the file before the install, or `nil` if there was no file.
    public var sha256Before: String?
    /// SHA-256 of the file the installer wrote.
    public var sha256After: String
    public var existedBefore: Bool
    public var byteCount: Int

    public init(
        relativePath: String,
        backupRelativePath: String?,
        sha256Before: String?,
        sha256After: String,
        existedBefore: Bool,
        byteCount: Int
    ) {
        self.relativePath = relativePath
        self.backupRelativePath = backupRelativePath
        self.sha256Before = sha256Before
        self.sha256After = sha256After
        self.existedBefore = existedBefore
        self.byteCount = byteCount
    }
}

public struct BackupManifest: Codable, Equatable, Sendable {
    /// Bumped whenever the shape changes, so an old manifest is still restorable by a newer app.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var appVersion: String
    public var createdAt: Date
    /// The override root these paths are relative to. Recorded so a restore cannot be pointed at a
    /// different root than the install used.
    public var overrideRoot: String
    /// Stable display key, so a manifest can be matched back to a monitor.
    public var displayKey: String
    public var displayName: String
    public var vendorID: UInt32
    public var productID: UInt32
    public var entries: [BackupEntry]

    public init(
        schemaVersion: Int = BackupManifest.currentSchemaVersion,
        appVersion: String,
        createdAt: Date,
        overrideRoot: String,
        displayKey: String,
        displayName: String,
        vendorID: UInt32,
        productID: UInt32,
        entries: [BackupEntry]
    ) {
        self.schemaVersion = schemaVersion
        self.appVersion = appVersion
        self.createdAt = createdAt
        self.overrideRoot = overrideRoot
        self.displayKey = displayKey
        self.displayName = displayName
        self.vendorID = vendorID
        self.productID = productID
        self.entries = entries
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        // Sorted keys + ISO-8601 dates: the manifest is snapshot-tested and read by humans in a
        // recovery situation, so stable, readable output matters more than compactness.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(from data: Data) throws -> BackupManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackupManifest.self, from: data)
    }
}

public enum SHA256Hash {
    public static func hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func hex(ofFileAt url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return hex(of: data)
    }
}
