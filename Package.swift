// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OpenThock",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CMixer", path: "Sources/CMixer"),
        .executableTarget(
            name: "OpenThock",
            dependencies: ["CMixer"],
            path: "Sources/OpenThock",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
    ]
)
