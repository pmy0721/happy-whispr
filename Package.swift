// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HappyWhispr",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "HappyWhispr",
            path: "Sources/HappyWhispr",
            exclude: ["happy-whispr-icon"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Security"),
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("Combine"),
            ]
        )
    ]
)
