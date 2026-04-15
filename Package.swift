// swift-tools-version: 5.10

import Foundation
import PackageDescription

let skipUnstableASCTests = ProcessInfo.processInfo.environment["BLITZ_SKIP_UNSTABLE_ASC_TESTS"] == "1"
let excludedBlitzTests = skipUnstableASCTests ? [
    "ASCProjectLifecycleTests.swift",
    "ASCScreenshotsLocaleRegressionTests.swift",
    "ASCVersionSelectionTests.swift",
] : []

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
            path: "Tests/blitz_tests",
            exclude: excludedBlitzTests
        ),
    ]
)
