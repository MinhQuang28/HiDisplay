import CoreGraphics
import Foundation
import HiDisplayKit

/// Command-line diagnostic harness.
///
/// Exists because the interesting failures are hardware-dependent and a menu-bar app is an awkward place
/// to observe them: this prints the whole chain — CoreGraphics enumeration, IORegistry metadata, identity
/// resolution, transport binding, and an optional live DDC read — in one pass, with no UI.
///
///     swift run hidisplay-probe            # read-only: enumerate, resolve, bind, read brightness
///     swift run hidisplay-probe --set 50   # additionally write a brightness value (asks first)
///     swift run hidisplay-probe --ddc-dump # hex-dump raw DDC replies, decoding nothing
///
/// Read-only by default. Writing is opt-in because a probe that changes what is on screen is a probe
/// people stop trusting.

let arguments = CommandLine.arguments
let setIndex = arguments.firstIndex(of: "--set")
let requestedPercent = setIndex.flatMap { index -> Int? in
    guard index + 1 < arguments.count else { return nil }
    return Int(arguments[index + 1])
}
let wantsDDCDump = arguments.contains("--ddc-dump")
let blindWritePercent = arguments.firstIndex(of: "--ddc-write").flatMap { index -> Int? in
    guard index + 1 < arguments.count else { return nil }
    return Int(arguments[index + 1])
}

func heading(_ text: String) {
    print("\n\u{001B}[1m\(text)\u{001B}[0m")
    print(String(repeating: "─", count: text.count))
}

// MARK: - Platform shims

heading("Private API shims")
print("IOAVService      : \(IOAVServiceShim.shared.isAvailable ? "available" : "UNAVAILABLE — \(IOAVServiceShim.shared.unavailableReason ?? "?")")")
print("DisplayServices  : \(DisplayServicesShim.shared.isAvailable ? "available" : "UNAVAILABLE — \(DisplayServicesShim.shared.unavailableReason ?? "?")")")

// MARK: - Raw metadata backends

heading("Metadata backends")
for backend in [
    AppleSiliconDisplayMetadataBackend() as DisplayMetadataBackend,
] {
    let records = backend.enumerate()
    print("\(backend.name): \(records.count) record(s)")
    for record in records {
        let vendor = record.vendorID.map { String(format: "0x%04x", $0) } ?? "—"
        let product = record.productID.map { String(format: "0x%04x", $0) } ?? "—"
        print("""
              • vendor \(vendor)  product \(product)  serial \(record.serialNumber.map(String.init) ?? "—")
                name \"\(record.productName ?? "")\"  external \(record.isExternal)  \
              native \(record.nativePixelWidth.map(String.init) ?? "?")x\(record.nativePixelHeight.map(String.init) ?? "?")
                registryEntryID \(record.registryEntryID.map { String(format: "0x%llx", $0) } ?? "—")
              """)
    }
}

// MARK: - Discovery + identity

heading("Displays")
let snapshots = DisplayDiscoveryService.snapshot(
    metadataBackend: CompositeDisplayMetadataBackend(), userAssignments: [:])

for snapshot in snapshots {
    let device = snapshot.device
    print("""

    \(device.name)\(device.isMain ? "  [main]" : "")\(device.isBuiltIn ? "  [built-in]" : "")
      key        \(device.id)
      tier       \(device.identity.keyTier)  (\(snapshot.pairing))
      ids        vendor 0x\(String(device.identity.vendorID, radix: 16)) / product 0x\(String(device.identity.productID, radix: 16))
      serial     \(device.identity.serialNumber.map { $0 == 0 ? "0 (absent)" : String($0) } ?? "—")
      edid hash  \(device.identity.edidHash ?? "—")
      mode       \(device.currentMode?.displayLabel ?? "?") @ \(device.currentMode.map { String(format: "%.0f", $0.refreshRate) } ?? "?")Hz
      modes      \(device.availableModes.count) total, \(device.hiDPIModeCount) HiDPI
      native     \(device.nativePixelSize.map { "\($0.width)x\($0.height)" } ?? "?")
      override   \(OverridePaths.relativePath(vendorID: device.identity.vendorID, productID: device.identity.productID))
    """)
}

// MARK: - Brightness

@MainActor
func probeBrightness() async {
    let native = NativeBrightnessController()
    let ddc = DDCBrightnessController()
    let gamma = GammaBrightnessController()

    for snapshot in snapshots {
        let device = snapshot.device
        heading("Brightness — \(device.name)")

        let nativeResult = await native.probe(display: device)
        print("native : \(nativeResult.isSupported ? "YES" : "no ") — \(nativeResult.detail)")

        if !device.isBuiltIn {
            // Report the raw transport bind separately from the probe: "no transport" and "transport
            // bound but the monitor did not answer" are completely different problems.
            let transport = AppleSiliconAVServiceTransport(identity: device.identity)
            print("transport: \(transport.isUsable ? "BOUND" : "not bound — \(transport.bindFailureReason ?? "?")")")
        }

        let ddcResult = await ddc.probe(display: device)
        print("ddc    : \(ddcResult.isSupported ? "YES" : "no ") — \(ddcResult.detail)")

        let gammaResult = await gamma.probe(display: device)
        print("gamma  : \(gammaResult.isSupported ? "YES" : "no ") — \(gammaResult.detail)")

        let availability = ControllerAvailability(
            native: nativeResult.isSupported, ddc: ddcResult.isSupported,
            gamma: gammaResult.isSupported, shade: true)
        let decision = BrightnessControllerResolver.resolve(display: device, availability: availability)
        print("chosen : \(decision.kind?.label ?? "none")")

        if let percent = requestedPercent, ddcResult.isSupported {
            print("\nwriting \(percent)% over DDC …")
            let before = ddcResult.currentValue ?? -1
            try? await ddc.setBrightness(Float(percent) / 100, display: device)
            // The queue is fire-and-forget; give the drain loop and the monitor time to settle before
            // reading back, otherwise the read races the write.
            try? await Task.sleep(for: .milliseconds(600))
            if let after = try? await ddc.getBrightness(display: device) {
                print("read back: \(String(format: "%.0f%%", after * 100)) (was \(String(format: "%.0f%%", before * 100)))")
            } else {
                print("read back failed")
            }
        }
    }
}

// MARK: - Raw DDC dump

/// Writes a Get VCP Feature request and prints whatever comes back, with no interpretation.
///
/// Separate from `probeBrightness` because the decoder's error messages describe the frame it
/// *expected*, which is useless when the real problem is that the frame starts somewhere else, is a
/// different length, or needs a longer delay. This prints bytes and leaves the reading to a human.
///
/// Sweeps reply delay and read length because both are monitor-specific: MCCS specifies 40 ms as a
/// minimum, not a value, and some panels prepend a byte to the frame.
@MainActor
func dumpDDC() async {
    func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// Where in `bytes` a Get VCP Feature Reply appears to start, if anywhere.
    ///
    /// A well-formed reply is `6E 88 02 …`. Reporting the offset rather than asserting offset 0 is
    /// the whole point of this dump.
    func frameOffset(_ bytes: [UInt8]) -> Int? {
        (0..<max(0, bytes.count - 2)).first { bytes[$0] == 0x6E && bytes[$0 + 1] == 0x88 }
    }

    for snapshot in snapshots where !snapshot.device.isBuiltIn {
        let device = snapshot.device
        heading("Raw DDC — \(device.name)")

        let transport = AppleSiliconAVServiceTransport(identity: device.identity)
        guard transport.isUsable else {
            print("not bound — \(transport.bindFailureReason ?? "?")")
            continue
        }

        let request = VCPCodec.getRequest(code: .brightness)
        print("request  : \(hex(request))")

        /// `6E 80 BE` — a well-formed DDC/CI null message. The display is on the bus and answering,
        /// it just has nothing queued. Worth naming, because it looks like garbage but is not.
        func annotate(_ bytes: [UInt8]) -> String {
            if let offset = frameOffset(bytes) { return "frame at +\(offset)" }
            if bytes.starts(with: [0x6E, 0x80, 0xBE]) { return "null message" }
            return "unrecognised"
        }

        for delayMS in [50, 100, 200] {
            do {
                try await transport.write(request)
                try await Task.sleep(for: .milliseconds(delayMS))
                // Several reads per write: a monitor that needs longer than the delay answers null
                // first and the real frame on a later read. One read per write cannot tell that apart
                // from a monitor that never answers.
                for attempt in 1...4 {
                    let reply = try await transport.read(length: 12)
                    print("\(delayMS)ms read #\(attempt): \(hex(reply))   \(annotate(reply))")
                    try await Task.sleep(for: .milliseconds(50))
                }
            } catch {
                print("\(delayMS)ms: error — \(error)")
            }
            // Never hammer the bus: back-to-back DDC traffic is what makes monitors stop answering.
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
}

/// Sends `Set VCP Feature` for brightness and reports only whether the bus accepted the write.
///
/// Deliberately does not read anything back. A monitor that never answers a Get can still obey a Set,
/// and the app would be able to drive brightness for real — blind, but real. Nothing here can prove
/// that; only a human looking at the panel can, which is why this prints an instruction rather than a
/// verdict.
///
/// Assumes a 0…100 range, since the range normally comes from the reply this display will not send.
@MainActor
func blindWrite(percent: Int) async {
    for snapshot in snapshots where !snapshot.device.isBuiltIn {
        let device = snapshot.device
        heading("Blind DDC write — \(device.name)")

        let transport = AppleSiliconAVServiceTransport(identity: device.identity)
        guard transport.isUsable else {
            print("not bound — \(transport.bindFailureReason ?? "?")")
            continue
        }

        let value = UInt16(max(0, min(100, percent)))
        let frame = VCPCodec.setRequest(code: .brightness, value: value)
        print("writing brightness = \(value) (assuming a 0…100 range)")
        print("frame  : \(frame.map { String(format: "%02X", $0) }.joined(separator: " "))")
        do {
            try await transport.write(frame)
            print("bus    : write accepted (this says nothing about whether the panel obeyed it)")
            print("→ look at the screen. Did the backlight change?")
        } catch {
            print("bus    : write rejected — \(error)")
        }
    }
}

/// Sweeps the ambiguous parts of the DDC wire contract against a real display.
///
/// `IOAVServiceWriteI2C` takes both a sub-address (`offset`) and a data buffer, and DDC/CI frames
/// *begin* with the same 0x51 byte that is conventionally passed as that offset. Whether the hardware
/// prepends the offset itself — making the conventional frame a duplicated, malformed one — is not
/// documented anywhere, and a display answering a malformed request with a null message looks
/// identical to a display with DDC/CI switched off.
///
/// So: try both frame shapes at several chip addresses and offsets, and let the display decide. A
/// reply beginning `6E 88 02` is the only outcome that means anything.
@MainActor
func sweepDDCWireFormat() async {
    let shim = IOAVServiceShim.shared
    guard shim.isAvailable else { return print("IOAVService unavailable") }

    for snapshot in snapshots where !snapshot.device.isBuiltIn {
        heading("DDC wire-format sweep — \(snapshot.device.name)")

        var target: CFTypeRef?
        IORegistryAccess.forEachService(matchingClass: "DCPAVServiceProxy") { service, _ in
            guard target == nil,
                  IORegistryAccess.stringProperty(service, "Location")?
                    .caseInsensitiveCompare("External") == .orderedSame
            else { return }
            target = shim.makeService(for: service)
        }
        guard let service = target else { return print("no external AV service") }

        let full = VCPCodec.getRequest(code: .brightness)          // 51 82 01 10 AC
        let headless = Array(full.dropFirst())                     //    82 01 10 AC
        let shapes = [("with 0x51", full), ("without 0x51", headless)]
        // 0x37 is the DDC/CI address; 0x51 the conventional sub-address. 0x00 covers controllers that
        // treat the whole frame as the payload, and 0x6E the raw unshifted display address.
        let routes: [(chip: UInt32, offset: UInt32)] = [(0x37, 0x51), (0x37, 0x00), (0x6E, 0x51)]

        for (label, frame) in shapes {
            for route in routes {
                var reply = [UInt8](repeating: 0, count: 12)
                let wrote = frame.withUnsafeBytes { raw in
                    shim.write(service: service, chipAddress: route.chip, offset: route.offset,
                               from: raw.baseAddress!, length: UInt32(raw.count))
                }
                try? await Task.sleep(for: .milliseconds(80))
                let read = reply.withUnsafeMutableBytes { raw in
                    shim.read(service: service, chipAddress: route.chip, offset: route.offset,
                              into: raw.baseAddress!, length: UInt32(raw.count))
                }
                let hex = reply.map { String(format: "%02X", $0) }.joined(separator: " ")
                let verdict = reply.starts(with: [0x6E, 0x88, 0x02]) ? "  ★ REAL REPLY" : ""
                print(String(format: "chip %02X off %02X %-13@ w=%d r=%d  %@%@",
                             route.chip, route.offset, label as NSString, wrote, read, hex, verdict))
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
    }
}

if arguments.contains("--ddc-sweep") {
    await sweepDDCWireFormat()
} else if let percent = blindWritePercent {
    await blindWrite(percent: percent)
} else if wantsDDCDump {
    await dumpDDC()
} else {
    await probeBrightness()
}
print("")
