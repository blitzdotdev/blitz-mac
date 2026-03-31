import Foundation
import Testing
@testable import Blitz

@Test func testHydratorDiscoversBundleIdentifierFromXcodeProject() throws {
    let fileManager = FileManager.default
    let projectRoot = fileManager.temporaryDirectory
        .appendingPathComponent("project-hydrator-\(UUID().uuidString)", isDirectory: true)

    try fileManager.createDirectory(at: projectRoot, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: projectRoot) }

    try writeTestXcodeProject(
        at: projectRoot,
        bundleIdentifier: "com.blitz.blitzkreig"
    )

    let metadata = BlitzProjectMetadata(
        name: "blitzkreig",
        type: .swift,
        platform: .iOS
    )

    let hydrated = ProjectMetadataHydrator().hydrate(metadata, projectDirectory: projectRoot).metadata

    #expect(hydrated.bundleIdentifier == "com.blitz.blitzkreig")
}

@Test func testRepositoryBackfillsMissingBundleIdentifierOnListProjects() async throws {
    let fileManager = FileManager.default
    let baseDirectory = fileManager.temporaryDirectory
        .appendingPathComponent("project-repository-\(UUID().uuidString)", isDirectory: true)
    let projectDirectory = baseDirectory.appendingPathComponent("blitzkreig", isDirectory: true)

    try fileManager.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: baseDirectory) }

    let repository = ProjectRepository(baseDirectory: baseDirectory)
    let metadata = BlitzProjectMetadata(
        name: "blitzkreig",
        type: .swift,
        platform: .iOS,
        createdAt: Date(),
        lastOpenedAt: Date()
    )

    try repository.writeMetadataToDirectory(projectDirectory, metadata: metadata)
    try writeTestXcodeProject(
        at: projectDirectory,
        bundleIdentifier: "com.blitz.blitzkreig"
    )

    let projects = await repository.listProjects()

    #expect(projects.count == 1)
    #expect(projects.first?.metadata.bundleIdentifier == "com.blitz.blitzkreig")
    #expect(repository.readMetadata(projectId: "blitzkreig")?.bundleIdentifier == "com.blitz.blitzkreig")
}

private func writeTestXcodeProject(at projectRoot: URL, bundleIdentifier: String) throws {
    let fileManager = FileManager.default
    let xcodeproj = projectRoot.appendingPathComponent("Example.xcodeproj", isDirectory: true)
    try fileManager.createDirectory(at: xcodeproj, withIntermediateDirectories: true)

    let pbxproj = """
    // !$*UTF8*$!
    {
        objects = {
            TEST = {
                buildSettings = {
                    PRODUCT_BUNDLE_IDENTIFIER = \(bundleIdentifier);
                };
            };
        };
    }
    """

    try pbxproj.write(
        to: xcodeproj.appendingPathComponent("project.pbxproj"),
        atomically: true,
        encoding: .utf8
    )
}
