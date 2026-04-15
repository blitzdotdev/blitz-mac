// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Blitz",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "BlitzMCPCommon", targets: ["BlitzMCPCommon"]),
        .executable(name: "Blitz", targets: ["Blitz"]),
        .executable(name: "blitz-macos-mcp", targets: ["BlitzMCPHelper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
    targets: [
        .target(
            name: "BlitzMCPCommon",
            path: "Sources/BlitzMCPCommon"
        ),
        .executableTarget(
            name: "Blitz",
            dependencies: ["SwiftTerm", "BlitzMCPCommon"],
            path: "src",
            exclude: ["metal", "resources/skills"],
            resources: [.process("resources"), .copy("templates")],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreMediaIO"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
            ]
        ),
        .executableTarget(
            name: "BlitzMCPHelper",
            dependencies: ["BlitzMCPCommon"],
            path: "Sources/BlitzMCPHelper"
        ),
        .testTarget(
            name: "BlitzTests",
            dependencies: ["Blitz"],
            path: "Tests/blitz_tests"
        ),
    ]
)
