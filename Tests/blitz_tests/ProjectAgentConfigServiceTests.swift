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

@Test func detachedLauncherStopsServerWhenClientExits() throws {
    let tempDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("blitz-detached-launcher-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    ProjectAgentConfigService(baseDirectory: tempDirectory).ensureMCPConfig(in: tempDirectory)
    let launcherPath = BlitzPaths.bin.appendingPathComponent("blitz-detached-mcp").path
    let pidFile = tempDirectory.appendingPathComponent("server.pid")

    // The shell stands in for the MCP client: it starts the launcher with a stand-in server,
    // then exits without signalling it, as a killed or crashed agent does.
    let client = Process()
    client.executableURL = URL(fileURLWithPath: "/bin/sh")
    client.arguments = [
        "-c",
        "\"$0\" /bin/sh -c 'echo $$ > \"$0\"; exec /bin/sleep 60' \"$1\" & sleep 1",
        launcherPath,
        pidFile.path,
    ]
    client.standardOutput = FileHandle.nullDevice
    client.standardError = FileHandle.nullDevice
    try client.run()
    client.waitUntilExit()

    let pidText = try String(contentsOf: pidFile, encoding: .utf8)
    let serverPID = try #require(pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
    defer { kill(serverPID, SIGKILL) }

    let deadline = Date().addingTimeInterval(10)
    while kill(serverPID, 0) == 0 && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.2)
    }
    #expect(kill(serverPID, 0) != 0, "server outlived its MCP client")
}
