// swift-tools-version: 6.0
import PackageDescription

// SwiftPM is the source of truth — there is no committed .xcodeproj. `swift build` / `swift test`
// run from CLI and CI without Xcode project state, and opening Package.swift in Xcode still gives
// full IDE support. The runnable .app bundle is assembled by build-app.sh.
let package = Package(
    name: "HiDisplay",
    // String form: swift-tools 6.0 has no `.v26` constant yet.
    platforms: [.macOS("26.0")], // macOS 26 Tahoe+: Liquid Glass (glassEffect) for the brightness HUD
    targets: [
        // All logic lives in the library so it is testable without launching an app.
        .target(
            name: "HiDisplayKit",
            path: "Sources/HiDisplayKit",
            swiftSettings: [
                // Swift 6 language mode: strict concurrency is enforced, so an isolation mistake
                // in the IOKit, CGDisplayReconfiguration or NSWindow paths is a compile error
                // rather than a data race found on hardware.
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "HiDisplay",
            dependencies: ["HiDisplayKit"],
            path: "Sources/HiDisplay",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Diagnostic CLI: prints the whole discovery → identity → transport → probe chain in one pass.
        // Hardware behaviour is much easier to observe here than through a menu-bar UI.
        .executableTarget(
            name: "hidisplay-probe",
            dependencies: ["HiDisplayKit"],
            path: "Sources/hidisplay-probe",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "HiDisplayTests",
            dependencies: ["HiDisplayKit"],
            path: "Tests/HiDisplayTests",
            exclude: ["Fixtures"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
