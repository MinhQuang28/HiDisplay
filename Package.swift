// swift-tools-version: 6.0
import PackageDescription

// SwiftPM is the source of truth — there is no committed .xcodeproj. `swift build` / `swift test`
// run from CLI and CI without Xcode project state, and opening Package.swift in Xcode still gives
// full IDE support. The runnable .app bundle is assembled by build-app.sh.
let package = Package(
    name: "HiDisplay",
    platforms: [.macOS(.v13)], // macOS 13 Ventura+: SMAppService exists, SMJobBless not needed
    targets: [
        // All logic lives in the library so it is testable without launching an app.
        .target(
            name: "HiDisplayKit",
            path: "Sources/HiDisplayKit",
            swiftSettings: [
                // Swift 5 language mode: the IOKit registry walks, CGDisplayReconfiguration
                // C callback, and NSWindow overlay work are all simpler without Swift 6 strict
                // concurrency ceremony. Tighten to .v6 once the hardware paths are stable.
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "HiDisplay",
            dependencies: ["HiDisplayKit"],
            path: "Sources/HiDisplay",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Diagnostic CLI: prints the whole discovery → identity → transport → probe chain in one pass.
        // Hardware behaviour is much easier to observe here than through a menu-bar UI.
        .executableTarget(
            name: "hidisplay-probe",
            dependencies: ["HiDisplayKit"],
            path: "Sources/hidisplay-probe",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "HiDisplayTests",
            dependencies: ["HiDisplayKit"],
            path: "Tests/HiDisplayTests",
            exclude: ["Fixtures"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
