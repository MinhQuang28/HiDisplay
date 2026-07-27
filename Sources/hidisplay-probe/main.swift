import CoreGraphics
import Foundation
import HiDisplayKit

/// Command-line diagnostic harness.
///
/// Exists because the interesting failures are hardware-dependent and a menu-bar app is an awkward place
/// to observe them: this prints the whole chain — CoreGraphics enumeration, IORegistry metadata, identity
/// resolution, transport binding, and an optional live DDC read — in one pass, with no UI.
///
///     swift run hidisplay-probe          # read-only: enumerate, resolve, bind, read brightness
///     swift run hidisplay-probe --set 50 # additionally write a brightness value (asks first)
///
/// Read-only by default. Writing is opt-in because a probe that changes what is on screen is a probe
/// people stop trusting.

let arguments = CommandLine.arguments
let setIndex = arguments.firstIndex(of: "--set")
let requestedPercent = setIndex.flatMap { index -> Int? in
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
    IntelDisplayMetadataBackend(),
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

await probeBrightness()
print("")
