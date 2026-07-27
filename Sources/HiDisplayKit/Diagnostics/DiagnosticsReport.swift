import Foundation

/// The support bundle payload.
///
/// What is *absent* is as deliberate as what is present. No username, no home directory path, no raw
/// serial number and no raw EDID: a diagnostics file gets pasted into public issue trackers, and a
/// monitor serial plus a hostname is more identifying than anyone expects. Serials appear only as the
/// truncated hash already used for the profile key, which is enough to tell two displays apart without
/// revealing either.
public struct DiagnosticsReport: Codable, Sendable {

    public struct Environment: Codable, Sendable {
        public var appVersion: String
        public var systemVersion: String
        public var architecture: String
        /// Whether each private-API shim resolved, and why not if it did not. The single most useful
        /// field when a user reports "brightness does nothing".
        public var shims: [String: String]
    }

    public struct DisplayReport: Codable, Sendable {
        public var stableKey: String
        public var name: String
        public var vendorIDHex: String
        public var productIDHex: String
        public var hasSerial: Bool
        public var edidHashPresent: Bool
        public var keyTier: String
        public var pairingConfidence: String
        public var isBuiltIn: Bool
        public var isMain: Bool
        public var isMirrored: Bool
        public var metadataSource: String?
        public var currentMode: String?
        public var nativePixels: String?
        public var modeCount: Int
        public var hiDPIModeCount: Int
        /// A short sample rather than every mode — a 4K monitor reports over a hundred, which drowns
        /// out everything else in the file.
        public var sampleModes: [String]
        public var overrideRelativePath: String
        public var capabilities: [String: Bool]
    }

    public struct BrightnessReport: Codable, Sendable {
        public var stableKey: String
        public var chosenController: String?
        public var availableControllers: [String]
        public var probeDetails: [String: String]
        public var warning: String?
        public var requestedValue: Float?
    }

    public var generatedAt: Date
    public var environment: Environment
    public var displays: [DisplayReport]
    public var brightness: [BrightnessReport]

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

public enum DiagnosticsBuilder {

    public static func build(
        displays: [DisplayDevice],
        ambiguousKeys: Set<String>,
        brightnessStates: [String: BrightnessState],
        availability: [String: ControllerAvailability],
        probeDetails: [String: [BrightnessControllerKind: String]],
        warnings: [String: String],
        chosenControllers: [String: BrightnessControllerKind],
        appVersion: String,
        now: Date = Date()
    ) -> DiagnosticsReport {
        let environment = DiagnosticsReport.Environment(
            appVersion: appVersion,
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: currentArchitecture(),
            shims: [
                "IOAVService": IOAVServiceShim.shared.isAvailable
                    ? "available"
                    : "unavailable: \(IOAVServiceShim.shared.unavailableReason ?? "unknown")",
                "DisplayServices": DisplayServicesShim.shared.isAvailable
                    ? "available"
                    : "unavailable: \(DisplayServicesShim.shared.unavailableReason ?? "unknown")",
            ])

        let displayReports = displays.map { display -> DiagnosticsReport.DisplayReport in
            let native = display.nativePixelSize
            return DiagnosticsReport.DisplayReport(
                stableKey: display.id,
                name: display.name,
                vendorIDHex: String(format: "0x%04x", display.identity.vendorID),
                productIDHex: String(format: "0x%04x", display.identity.productID),
                // Presence, not value: enough to explain the key tier without leaking the serial.
                hasSerial: (display.identity.serialNumber ?? 0) != 0,
                edidHashPresent: display.identity.edidHash != nil,
                keyTier: String(describing: display.identity.keyTier),
                pairingConfidence: ambiguousKeys.contains(display.id) ? "ambiguous" : "confident",
                isBuiltIn: display.isBuiltIn,
                isMain: display.isMain,
                isMirrored: display.isMirrored,
                metadataSource: nil,
                currentMode: display.currentMode.map(\.id),
                nativePixels: native.map { "\($0.width)x\($0.height)" },
                modeCount: display.availableModes.count,
                hiDPIModeCount: display.hiDPIModeCount,
                sampleModes: Array(display.availableModes.prefix(12).map(\.id)),
                overrideRelativePath: OverridePaths.relativePath(
                    vendorID: display.identity.vendorID, productID: display.identity.productID),
                capabilities: [
                    "nativeBrightness": display.capabilities.supportsNativeBrightness,
                    "ddc": display.capabilities.supportsDDC,
                    "softwareDimming": display.capabilities.supportsSoftwareDimming,
                    "shadeDimming": display.capabilities.supportsShadeDimming,
                    "hiDPIOverride": display.capabilities.supportsHiDPIOverride,
                    "hdr": display.capabilities.supportsHDR,
                ])
        }

        let brightnessReports = displays.map { display -> DiagnosticsReport.BrightnessReport in
            DiagnosticsReport.BrightnessReport(
                stableKey: display.id,
                chosenController: chosenControllers[display.id]?.rawValue,
                availableControllers: availability[display.id]?.supportedKinds.map(\.rawValue) ?? [],
                probeDetails: Dictionary(
                    uniqueKeysWithValues: (probeDetails[display.id] ?? [:]).map { ($0.key.rawValue, $0.value) }),
                warning: warnings[display.id],
                requestedValue: brightnessStates[display.id]?.requestedValue)
        }

        return DiagnosticsReport(
            generatedAt: now,
            environment: environment,
            displays: displayReports,
            brightness: brightnessReports)
    }

    static func currentArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}
