import AppKit
import CoreServices

/// Launches the user's configured terminal with an AI agent CLI command.
enum TerminalLauncher {
    static func buildAgentCommand(
        projectPath: String?,
        agent: AIAgent,
        prompt: String? = nil,
        skipPermissions: Bool = false
    ) -> String {
        var segments = shellExportCommands(for: projectPath)

        if let path = projectPath {
            segments.append("cd \(shellQuote(path))")
        }

        var agentCommand = agent.cliCommand
        if skipPermissions, let flag = agent.skipPermissionsFlag {
            agentCommand += " \(flag)"
        }
        if let prompt, !prompt.isEmpty {
            agentCommand += " \(shellQuote(prompt))"
        }
        segments.append(agentCommand)

        return segments.joined(separator: " && ")
    }

    /// Launch the default terminal with the default agent CLI, optionally with a prompt.
    /// Returns true if the launch was attempted, false if the terminal couldn't be resolved.
    @discardableResult
    static func launch(
        projectPath: String?,
        agent: AIAgent,
        terminal: TerminalApp,
        prompt: String? = nil,
        skipPermissions: Bool = false
    ) -> Bool {
        let shellCommand = buildAgentCommand(
            projectPath: projectPath,
            agent: agent,
            prompt: prompt,
            skipPermissions: skipPermissions
        )

        switch terminal.resolvedFallback {
        case .builtIn:
            return false // Handled by ContentView directly
        case .terminal:
            return launchTerminalApp(command: shellCommand)
        case .ghostty:
            return launchGhostty(command: shellCommand)
        case .iterm:
            return launchITerm(command: shellCommand)
        case .custom(let path):
            return launchCustom(appPath: path, command: shellCommand)
        }
    }

    /// Launch using the settings from SettingsService
    @MainActor
    @discardableResult
    static func launchFromSettings(
        projectPath: String?,
        activeTab: AppTab
    ) -> Bool {
        let settings = SettingsService.shared
        let agent = AIAgent(rawValue: settings.defaultAgentCLI) ?? .claudeCode
        let terminal = settings.resolveDefaultTerminal().terminal

        var prompt: String? = nil
        if settings.sendDefaultPrompt {
            prompt = ConnectAIPopover.prompt(for: activeTab)
        }

        return launch(projectPath: projectPath, agent: agent, terminal: terminal, prompt: prompt, skipPermissions: settings.skipAgentPermissions)
    }

    // MARK: - Terminal.app

    private static func launchTerminalApp(command: String) -> Bool {
        let escaped = escapeForAppleScript(command)
        let script = """
        tell application "Terminal"
            do script "\(escaped)"
            activate
        end tell
        """
        return runOsascript(script)
    }

    // MARK: - Ghostty

    private static func launchGhostty(command: String) -> Bool {
        // Ghostty doesn't support AppleScript. Use the binary directly with -e flag
        // which avoids needing Automation permission entirely.
        if let ghosttyURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") {
            let binary = ghosttyURL.appendingPathComponent("Contents/MacOS/ghostty")
            let process = Process()
            process.executableURL = binary
            // -e consumes remaining args as the command to run.
            // Wrap in /bin/bash -c so shell syntax (cd && ...) works.
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            process.arguments = ["-e", shell, "-l", "-c", command]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                return true
            } catch {
                // fall through
            }
        }

        // Fallback: open Ghostty and copy command to clipboard
        if let ghosttyURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            NSWorkspace.shared.openApplication(at: ghosttyURL, configuration: NSWorkspace.OpenConfiguration())
        }
        return false
    }

    // MARK: - iTerm

    private static func launchITerm(command: String) -> Bool {
        let escaped = escapeForAppleScript(command)
        // iTerm2 AppleScript: create a new window, then write text to its session
        let script = """
        tell application "iTerm"
            activate
            set newWindow to (create window with default profile)
            tell current session of newWindow
                write text "\(escaped)"
            end tell
        end tell
        """
        return runOsascript(script)
    }

    // MARK: - Custom

    private static func launchCustom(appPath: String, command: String) -> Bool {
        let appName = URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
        let escaped = escapeForAppleScript(command)
        // Try Terminal.app-style AppleScript (works for many terminal emulators)
        let script = """
        tell application "\(appName)"
            do script "\(escaped)"
            activate
        end tell
        """
        if runOsascript(script) {
            return true
        }

        // Fallback: open the app and copy command to clipboard
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: appPath),
            configuration: NSWorkspace.OpenConfiguration()
        )
        return false
    }

    // MARK: - Helpers

    private static func escapeForAppleScript(_ command: String) -> String {
        command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func shellExportCommands(for projectPath: String?) -> [String] {
        ASCAuthBridge().shellExportCommands(forLaunchPath: projectPath)
    }

    private static func runOsascript(_ script: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Permission Checks

    /// Whether the given terminal requires Automation (Apple Events) permission.
    /// Ghostty uses direct process execution and doesn't need it.
    static func needsAutomationPermission(_ terminal: TerminalApp) -> Bool {
        switch terminal {
        case .builtIn, .ghostty: return false
        default: return true
        }
    }

    /// Check Automation permission status without prompting.
    /// Returns: noErr (granted), errAEEventWouldRequireUserConsent (not yet asked),
    /// errAEEventNotPermitted (denied), or procNotFound (app not installed).
    static func automationPermissionStatus(bundleIdentifier: String) -> OSStatus {
        let descriptor = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        guard let aeDesc = descriptor.aeDesc else { return OSStatus(procNotFound) }
        return AEDeterminePermissionToAutomateTarget(aeDesc, typeWildCard, typeWildCard, false)
    }

    /// Request Automation permission (shows system consent dialog if not yet decided).
    /// Returns true if permission was granted.
    static func requestAutomationPermission(bundleIdentifier: String) -> Bool {
        let descriptor = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        guard let aeDesc = descriptor.aeDesc else { return false }
        let status = AEDeterminePermissionToAutomateTarget(aeDesc, typeWildCard, typeWildCard, true)
        return status == noErr
    }
}
