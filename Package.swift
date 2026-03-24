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
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "Blitz",
            dependencies: ["SwiftTerm"],
            path: "src",
            exclude: ["metal"],
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
        .testTarget(
            name: "BlitzTests",
            dependencies: ["Blitz"],
            path: "Tests/blitz_tests"
        ),
    ]
)
