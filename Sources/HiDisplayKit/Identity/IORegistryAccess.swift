import Foundation
import IOKit

/// Thin, leak-free helpers over the IORegistry.
///
/// Every raw `io_object_t` obtained here is released on every path, including error paths — an
/// `IOObjectRelease` missed inside a hot-plug callback leaks a kernel object per replug, which shows
/// up much later as a mysterious failure to open new services.
public enum IORegistryAccess {

    /// Iterates services matching a class name, releasing each object after `body` returns.
    ///
    /// `body` receives the service and its registry entry ID. Returning a value from `body` is not
    /// supported on purpose: holding onto an `io_object_t` past the callback is exactly the leak
    /// this wrapper exists to prevent.
    public static func forEachService(
        matchingClass className: String,
        _ body: (io_service_t, UInt64) -> Void
    ) {
        guard let matching = IOServiceMatching(className) else { return }
        var iterator: io_iterator_t = 0
        // IOServiceGetMatchingServices consumes a reference to `matching`, so it must not be
        // released here.
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == KERN_SUCCESS, iterator != 0 else { return }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            var entryID: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(service, &entryID) != KERN_SUCCESS {
                entryID = 0
            }
            body(service, entryID)
            IOObjectRelease(service)
        }
    }

    /// Reads one property off a service, taking ownership of the returned CF object exactly once.
    public static func property(_ service: io_service_t, _ key: String) -> Any? {
        guard let unmanaged = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)
        else { return nil }
        return unmanaged.takeRetainedValue()
    }

    /// Reads a property, searching the service's children as well.
    ///
    /// Needed because the interesting dictionaries are not always on the matched node: on some macOS
    /// versions `DisplayAttributes` sits on the `DCPAVServiceProxy` itself, on others on a child.
    public static func searchProperty(_ service: io_service_t, _ key: String) -> Any? {
        let options = IOOptionBits(kIORegistryIterateRecursively)
        guard let unmanaged = IORegistryEntrySearchCFProperty(
            service, kIOServicePlane, key as CFString, kCFAllocatorDefault, options)
        else { return nil }
        // IORegistryEntrySearchCFProperty returns +1 already, and is typed as an unretained
        // `CFTypeRef?` rather than Unmanaged, so bridging it directly is correct here.
        return unmanaged
    }

    public static func dictionaryProperty(_ service: io_service_t, _ key: String) -> [String: Any]? {
        property(service, key) as? [String: Any] ?? searchProperty(service, key) as? [String: Any]
    }

    public static func stringProperty(_ service: io_service_t, _ key: String) -> String? {
        if let value = property(service, key) as? String { return value }
        if let data = property(service, key) as? Data {
            // Some registry strings arrive as NUL-terminated data.
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        }
        return nil
    }

    public static func dataProperty(_ service: io_service_t, _ key: String) -> Data? {
        property(service, key) as? Data
    }

    public static func name(_ service: io_service_t) -> String? {
        // io_name_t is a fixed 128-byte C buffer.
        var buffer = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(service, &buffer) == KERN_SUCCESS else { return nil }
        return String(cString: buffer)
    }

    /// Walks up the IOService plane looking for the display unit this node belongs to, and returns its
    /// token — `disp0`, `dispext0`, …
    ///
    /// This is the link between the two registry branches that describe one physical display. On
    /// macOS 26 the metadata (`DisplayAttributes`) lives on `AppleCLCD2` while the DDC channel comes
    /// from `DCPAVServiceProxy`, and there is no property joining them. But their ancestors are named
    /// consistently:
    ///
    /// ```
    /// dispext0@8000000            → AppleCLCD2          (has DisplayAttributes)
    /// dispext0:dcpav-service-epic:0 → DCPAVServiceProxy (is the IOAVService source)
    /// ```
    ///
    /// So the token before `@` or `:` identifies the display, and matching on it is what stops the app
    /// binding a DDC channel to the wrong monitor.
    public static func displayUnitToken(_ service: io_service_t, maxDepth: Int = 10) -> String? {
        var current = service
        var retained = false
        defer { if retained { IOObjectRelease(current) } }

        for _ in 0..<maxDepth {
            if let name = name(current), let token = parseDisplayUnitToken(name) {
                return token
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS,
                  parent != 0
            else { return nil }
            if retained { IOObjectRelease(current) }
            current = parent
            retained = true
        }
        return nil
    }

    /// `dispext0@8000000` → `dispext0`; `disp0:dcpav-service-epic:0` → `disp0`.
    ///
    /// Returns `nil` for anything not shaped like a display unit, so an unrelated ancestor such as
    /// `dcp@7EC00000` does not produce a false match.
    public static func parseDisplayUnitToken(_ name: String) -> String? {
        let token = name.prefix { $0 != "@" && $0 != ":" }
        guard token.hasPrefix("disp") else { return nil }
        // Require a trailing index, so the bare `display-crossbar0` style names are not mistaken for
        // a display unit.
        let suffix = token.dropFirst(4)
        let index = suffix.hasPrefix("ext") ? suffix.dropFirst(3) : suffix
        guard !index.isEmpty, index.allSatisfy(\.isNumber) else { return nil }
        return String(token)
    }
}

/// Reads a plist-ish registry value that may arrive as `NSNumber`, `NSString`, or `Data`, without
/// force-unwrapping or trapping on an unexpected type.
///
/// Registry layouts are observed rather than documented (see docs/private-apis.md), so tolerating a
/// changed representation is a correctness requirement, not defensiveness for its own sake.
public func registryUInt32(_ value: Any?) -> UInt32? {
    switch value {
    case let number as NSNumber:
        let wide = number.uint64Value
        // Overflow means this is not the field we think it is. The built-in panel on macOS 26 reports
        // ProductID = 62896309613633, and truncating that produced a plausible-looking 0x30313441 that
        // then failed to match CoreGraphics' product ID and silently blocked pairing. Reporting "absent"
        // lets the matcher fall back to the fields it can trust.
        return wide > UInt64(UInt32.max) ? nil : UInt32(wide)
    case let string as String:
        if let decimal = UInt32(string) { return decimal }
        return UInt32(string.replacingOccurrences(of: "0x", with: ""), radix: 16)
    case let data as Data:
        // Little-endian is what IOKit hands back for integer-shaped data properties.
        guard !data.isEmpty else { return nil }
        var result: UInt32 = 0
        for (offset, byte) in data.prefix(4).enumerated() {
            result |= UInt32(byte) << (8 * offset)
        }
        return result
    default:
        return nil
    }
}
