import AppKit
import Foundation
import Testing
@testable import Blitz

@Test func testProjectAppIconLoaderResolvesSymlinkedProjectPaths() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("project-app-icon-loader-\(UUID().uuidString)", isDirectory: true)
    let realProject = root.appendingPathComponent("real-project", isDirectory: true)
    let symlinkProject = root.appendingPathComponent("linked-project", isDirectory: false)

    try fileManager.createDirectory(at: realProject, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }

    try writeTestAppIcon(to: realProject)
    try fileManager.createSymbolicLink(at: symlinkProject, withDestinationURL: realProject)

    let image = await ProjectAppIconLoader.loadImage(
        for: "symlinked-project-\(UUID().uuidString)",
        projectPath: symlinkProject.path
    )

    #expect(image != nil)
}

@Test func testProjectAppIconLoaderRetriesAfterMissingCache() async throws {
    let fileManager = FileManager.default
    let projectRoot = fileManager.temporaryDirectory
        .appendingPathComponent("project-app-icon-retry-\(UUID().uuidString)", isDirectory: true)
    let projectId = "retry-project-\(UUID().uuidString)"

    try fileManager.createDirectory(at: projectRoot, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: projectRoot) }

    let missingImage = await ProjectAppIconLoader.loadImage(
        for: projectId,
        projectPath: projectRoot.path
    )
    #expect(missingImage == nil)

    try writeTestAppIcon(to: projectRoot)

    let image = await ProjectAppIconLoader.loadImage(
        for: projectId,
        projectPath: projectRoot.path
    )

    #expect(image != nil)
}

private func writeTestAppIcon(to projectRoot: URL) throws {
    let fileManager = FileManager.default
    let appIconSet = projectRoot
        .appendingPathComponent("Example", isDirectory: true)
        .appendingPathComponent("Assets.xcassets", isDirectory: true)
        .appendingPathComponent("AppIcon.appiconset", isDirectory: true)

    try fileManager.createDirectory(at: appIconSet, withIntermediateDirectories: true)

    let contents = """
    {
      "images" : [
        {
          "filename" : "AppIcon.png",
          "idiom" : "universal",
          "platform" : "ios",
          "size" : "1024x1024"
        }
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }
    """

    try contents.write(
        to: appIconSet.appendingPathComponent("Contents.json"),
        atomically: true,
        encoding: .utf8
    )

    guard let image = NSImage(
        systemSymbolName: "app.fill",
        accessibilityDescription: nil
    ) else {
        Issue.record("Failed to create test icon image")
        return
    }

    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 1024,
        pixelsHigh: 1024,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )

    guard let bitmap else {
        Issue.record("Failed to allocate bitmap for test icon")
        return
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.systemBlue.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 1024)).fill()
    image.draw(in: NSRect(x: 128, y: 128, width: 768, height: 768))
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        Issue.record("Failed to encode test icon PNG")
        return
    }

    try data.write(to: appIconSet.appendingPathComponent("AppIcon.png"))
}
