// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Blitz",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Blitz", targets: ["Blitz"]),
    ],
    targets: [
        .executableTarget(
            name: "Blitz",
            path: "src",
            exclude: ["Metal"],
            resources: [.process("Resources"), .copy("Templates")],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreMediaIO"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(
            name: "BlitzTests",
            dependencies: ["Blitz"],
            path: "Tests/BlitzTests"
        ),
    ]
)
