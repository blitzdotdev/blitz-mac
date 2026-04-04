import Foundation
import Testing
@testable import Blitz

@Test func captureEnvironmentLoadsLoginAndInteractiveZshStartupFiles() throws {
    let fileManager = FileManager.default
    let tempDirectory = fileManager.temporaryDirectory
        .appendingPathComponent("blitz-login-shell-env-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDirectory) }

    try "export BLITZ_FROM_ZPROFILE=1\n".write(
        to: tempDirectory.appendingPathComponent(".zprofile"),
        atomically: true,
        encoding: .utf8
    )
    try "export BLITZ_FROM_ZSHRC=1\n".write(
        to: tempDirectory.appendingPathComponent(".zshrc"),
        atomically: true,
        encoding: .utf8
    )

    let environment = try #require(LoginShellEnvironment.captureEnvironment(
        shellPath: "/bin/zsh",
        baseEnvironment: [
            "HOME": tempDirectory.path,
            "ZDOTDIR": tempDirectory.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
    ))

    #expect(environment["BLITZ_FROM_ZPROFILE"] == "1")
    #expect(environment["BLITZ_FROM_ZSHRC"] == "1")
}
