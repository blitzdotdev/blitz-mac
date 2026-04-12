import Foundation
import Testing
@testable import Blitz

@Test func ensureMCPConfigUsesDetachedLauncherForBlitzIphone() throws {
    let tempDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("blitz-agent-config-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let service = ProjectAgentConfigService(baseDirectory: tempDirectory)
    service.ensureMCPConfig(in: tempDirectory)

    let launcherPath = BlitzPaths.bin.appendingPathComponent("blitz-detached-mcp").path
    #expect(FileManager.default.isExecutableFile(atPath: launcherPath))

    let codexConfigURL = tempDirectory.appendingPathComponent(".codex/config.toml")
    let codexConfig = try String(contentsOf: codexConfigURL, encoding: .utf8)
    #expect(codexConfig.contains("command = \"\(launcherPath)\""))
    #expect(
        codexConfig.contains("dist/cli.js")
        || codexConfig.contains("node-runtime/bin/iphone-mcp")
        || codexConfig.contains("\"-y\", \"@blitzdev/iphone-mcp\"")
    )

    let mcpConfigURL = tempDirectory.appendingPathComponent(".mcp.json")
    let mcpConfigData = try Data(contentsOf: mcpConfigURL)
    let root = try #require(JSONSerialization.jsonObject(with: mcpConfigData) as? [String: Any])
    let servers = try #require(root["mcpServers"] as? [String: Any])
    let blitzIphone = try #require(servers["blitz-iphone"] as? [String: Any])
    #expect(blitzIphone["command"] as? String == launcherPath)
}
