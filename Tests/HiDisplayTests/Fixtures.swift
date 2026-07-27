import Foundation
import XCTest

/// Locates the bundled fixture files.
///
/// The `Fixtures` directory is excluded from the target's sources in Package.swift rather than declared
/// as a resource, so it is read from the source tree by path. That keeps the raw override files exactly
/// as they were copied off a real system — a resource bundle would be fine too, but this way the bytes
/// under test are unambiguously the bytes on disk.
enum Fixtures {

    static var directory: URL {
        // #filePath points at this source file; the fixtures sit beside it.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    static var overridesDirectory: URL {
        directory.appendingPathComponent("overrides", isDirectory: true)
    }

    static func overrideFileURLs() throws -> [URL] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: overridesDirectory, includingPropertiesForKeys: nil)
        return contents.filter { $0.pathExtension == "plist" }.sorted { $0.path < $1.path }
    }

    static func overrideURL(named name: String) throws -> URL {
        let url = overridesDirectory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("fixture \(name) is missing")
        }
        return url
    }

    /// Builds a syntactically valid EDID block 0 so the parser can be tested without real hardware.
    ///
    /// Hand-assembled rather than captured because a captured EDID contains a real monitor's serial
    /// number, and committing that to a repository is exactly what the diagnostics rules forbid.
    static func makeEDID(
        manufacturer: String = "DEL",
        productID: UInt16 = 0xD0A1,
        serial: UInt32 = 0x1234_5678,
        week: UInt8 = 34,
        year: Int = 2022,
        monitorName: String? = "TEST U2723QE",
        nativeWidth: Int = 3840,
        nativeHeight: Int = 2160
    ) -> Data {
        var bytes = [UInt8](repeating: 0, count: 128)
        bytes[0...7] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]

        // Manufacturer: three 5-bit letters packed big-endian.
        var word: UInt16 = 0
        for scalar in manufacturer.uppercased().unicodeScalars {
            word = (word << 5) | UInt16(scalar.value - 64)
        }
        bytes[8] = UInt8(word >> 8)
        bytes[9] = UInt8(word & 0xFF)

        bytes[10] = UInt8(productID & 0xFF)      // product code is little-endian
        bytes[11] = UInt8(productID >> 8)
        bytes[12] = UInt8(serial & 0xFF)         // serial is little-endian
        bytes[13] = UInt8((serial >> 8) & 0xFF)
        bytes[14] = UInt8((serial >> 16) & 0xFF)
        bytes[15] = UInt8((serial >> 24) & 0xFF)
        bytes[16] = week
        bytes[17] = UInt8(year - 1990)
        bytes[18] = 1                            // EDID 1.4
        bytes[19] = 4

        // First descriptor: a detailed timing carrying the native resolution.
        let timing = 54
        bytes[timing] = 0x01                     // non-zero pixel clock marks this as a timing
        bytes[timing + 1] = 0x02
        bytes[timing + 2] = UInt8(nativeWidth & 0xFF)
        bytes[timing + 4] = UInt8((nativeWidth >> 8) << 4)
        bytes[timing + 5] = UInt8(nativeHeight & 0xFF)
        bytes[timing + 7] = UInt8((nativeHeight >> 8) << 4)

        // Second descriptor: display product name, tagged 0xFC and LF-terminated.
        if let monitorName {
            let name = 54 + 18
            bytes[name + 3] = 0xFC
            var index = name + 5
            for character in monitorName.unicodeScalars where index < name + 18 {
                bytes[index] = UInt8(character.value)
                index += 1
            }
            if index < name + 18 { bytes[index] = 0x0A }
        }

        // Checksum byte makes the whole block sum to 0 mod 256.
        let sum = bytes[0..<127].reduce(into: UInt8(0)) { $0 = $0 &+ $1 }
        bytes[127] = UInt8((256 - Int(sum)) % 256)
        return Data(bytes)
    }
}
