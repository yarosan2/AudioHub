// swift-tools-version:5.10
// For editors and `swift build` of the command-line mode only.
// The menu-bar app (bundle, translations, signing) is built with ./build.sh.
import PackageDescription

let package = Package(
    name: "AudioHub",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "audiohub",
            path: "Sources/audiohub",
            linkerSettings: ["CoreAudio", "AudioToolbox", "AppKit", "Network", "AVFoundation", "SwiftUI"]
                .map { .linkedFramework($0) }
        )
    ]
)
