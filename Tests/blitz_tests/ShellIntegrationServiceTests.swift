import Foundation
import Testing
@testable import Blitz

@Test func testShellIntegrationInstallsAndRemovesManagedZshBlock() throws {
    let fileManager = FileManager.default
    let home = fileManager.temporaryDirectory
        .appendingPathComponent("shell-integration-home-\(UUID().uuidString)", isDirectory: true)
    let blitzRoot = home.appendingPathComponent(".blitz", isDirectory: true)

    try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: home) }

    let bundledASCD = home.appendingPathComponent("Blitz.app/Contents/Helpers/ascd")
    try fileManager.createDirectory(
        at: bundledASCD.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try "#!/bin/sh\nexit 0\n".write(to: bundledASCD, atomically: true, encoding: .utf8)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledASCD.path)

    let shellService = ShellIntegrationService(
        homeDirectory: home,
        blitzRoot: blitzRoot,
        fileManager: fileManager,
        bundledASCDPathProvider: { bundledASCD.path },
        loginShellPathProvider: { "/bin/zsh" }
    )

    try shellService.sync(enabled: true)

    let zshrc = home.appendingPathComponent(".zshrc")
    let zshrcContents = try String(contentsOf: zshrc, encoding: .utf8)
    #expect(zshrcContents.contains("Blitz shell integration"))
    #expect(zshrcContents.contains(". \"$HOME/.blitz/shell/init.sh\""))

    let initScript = try String(contentsOf: shellService.initScriptURL, encoding: .utf8)
    #expect(initScript.contains("BLITZ_BIN"))
    #expect(initScript.contains(".blitz/bin"))
    #expect(FileManager.default.isExecutableFile(atPath: blitzRoot.appendingPathComponent("bin/ascd").path))
    #expect(FileManager.default.isExecutableFile(atPath: blitzRoot.appendingPathComponent("bin/asc").path))

    try shellService.sync(enabled: false)

    let cleanedZshrc = try String(contentsOf: zshrc, encoding: .utf8)
    #expect(!cleanedZshrc.contains("Blitz shell integration"))
    #expect(!fileManager.fileExists(atPath: shellService.initScriptURL.path))
}
