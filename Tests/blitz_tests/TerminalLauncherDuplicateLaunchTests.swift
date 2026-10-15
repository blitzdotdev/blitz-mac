import Foundation
import Testing
@testable import Blitz

// One test so the shared launch record isn't touched by parallel tests.
@Test func testDuplicateAgentLaunchGuard() {
    let command = "claude 'dup-guard \(UUID().uuidString)'"

    #expect(TerminalLauncher.claimLaunch(of: command, now: Date()))
    TerminalLauncher.finishLaunch(of: command, succeeded: true)

    // A queued second click replayed right after the launch returns is skipped.
    #expect(!TerminalLauncher.claimLaunch(of: command, now: Date()))

    // The same command is allowed again once the window has passed.
    #expect(TerminalLauncher.claimLaunch(of: command, now: Date().addingTimeInterval(4)))

    // A failed launch is forgotten, so an immediate retry goes through.
    TerminalLauncher.finishLaunch(of: command, succeeded: false)
    #expect(TerminalLauncher.claimLaunch(of: command, now: Date()))
    TerminalLauncher.finishLaunch(of: command, succeeded: true)

    // A different command is never blocked by the last one.
    #expect(TerminalLauncher.claimLaunch(of: command + " other", now: Date()))
}
