import Testing
import Foundation
@testable import Blitz

@Test func testProjectMetadataRoundtrip() throws {
    let metadata = BlitzProjectMetadata(
        name: "My App",
        type: .reactNative,
        bundleIdentifier: "com.example.myapp"
    )

    let encoder = JSONEncoder()
    let data = try encoder.encode(metadata)

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(BlitzProjectMetadata.self, from: data)

    #expect(decoded.name == "My App")
    #expect(decoded.type == .reactNative)
    #expect(decoded.bundleIdentifier == "com.example.myapp")
}

@Test func testProjectTypeRawValues() {
    #expect(ProjectType.blitz.rawValue == "blitz")
    #expect(ProjectType.reactNative.rawValue == "react-native")
    #expect(ProjectType.swift.rawValue == "swift")
    #expect(ProjectType.flutter.rawValue == "flutter")
}
