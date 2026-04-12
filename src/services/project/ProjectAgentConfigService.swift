import Foundation

/// Writes Blitz-owned agent config and installs Blitz-managed helper content.
struct ProjectAgentConfigService {
    let baseDirectory: URL

    private enum ProjectSkillRoot: String, CaseIterable {
        case claude = ".claude"
        case agents = ".agents"
    }

    private func blitzIphoneCommand(nodeRuntimeBin: String) -> (command: String, args: [String], env: [String: String]) {
        let pathEnv = "\(nodeRuntimeBin):/usr/bin:/bin:/usr/sbin:/sbin"
        let command: String
        let args: [String]

        if let localCLI = Self.localBlitzIphoneCLIPath() {
            let localNode = Self.localNodePath() ?? "/opt/homebrew/bin/node"
            command = localNode
            args = [localCLI]
        } else if FileManager.default.isExecutableFile(atPath: nodeRuntimeBin + "/node"),
                  FileManager.default.isExecutableFile(atPath: nodeRuntimeBin + "/iphone-mcp") {
            command = nodeRuntimeBin + "/node"
            args = [nodeRuntimeBin + "/iphone-mcp"]
        } else {
            command = nodeRuntimeBin + "/npx"
            args = ["-y", "@blitzdev/iphone-mcp"]
        }

        let env = ["PATH": "\(pathEnv):/opt/homebrew/bin:/usr/local/bin"]
        if let launcher = Self.ensureDetachedMCPLauncher() {
            return (
                command: launcher,
                args: [command] + args,
                env: env
            )
        }

        return (
            command: command,
            args: args,
            env: env
        )
    }

    private static func ensureDetachedMCPLauncher() -> String? {
        let fm = FileManager.default
        let launcherURL = BlitzPaths.bin.appendingPathComponent("blitz-detached-mcp")
        let script = """
        #!/usr/bin/env python3
        import os
        import signal
        import sys

        def main() -> int:
            if len(sys.argv) < 2:
                print("usage: blitz-detached-mcp <command> [args...]", file=sys.stderr)
                return 64

            child_pid = os.fork()
            if child_pid == 0:
                os.setsid()
                os.execvpe(sys.argv[1], sys.argv[1:], os.environ)

            def forward(sig, _frame):
                try:
                    os.kill(child_pid, sig)
                except ProcessLookupError:
                    pass

            for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
                signal.signal(sig, forward)

            while True:
                try:
                    _, status = os.waitpid(child_pid, 0)
                    break
                except InterruptedError:
                    continue

            if os.WIFEXITED(status):
                return os.WEXITSTATUS(status)
            if os.WIFSIGNALED(status):
                return 128 + os.WTERMSIG(status)
            return 1

        if __name__ == "__main__":
            raise SystemExit(main())
        """

        do {
            try fm.createDirectory(at: BlitzPaths.bin, withIntermediateDirectories: true)
            try script.write(to: launcherURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcherURL.path)
            return launcherURL.path
        } catch {
            print("[ProjectAgentConfigService] Failed to write detached MCP launcher: \(error)")
            return nil
        }
    }

    private static func localBlitzIphoneCLIPath() -> String? {
        let candidate = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("superapp/blitz-ios-mcp/dist/cli.js")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            return nil
        }
        return candidate.path
    }

    private static func localNodePath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func ensureGlobalMCPConfigs(whitelistBlitzMCP: Bool = true, allowASCCLICalls: Bool = false) {
        let fm = FileManager.default
        let mcpsDir = BlitzPaths.mcps

        try? fm.createDirectory(at: mcpsDir, withIntermediateDirectories: true)

        ensureMCPConfig(
            in: mcpsDir,
            whitelistBlitzMCP: whitelistBlitzMCP,
            allowASCCLICalls: allowASCCLICalls,
            includeProjectDocFallback: false
        )

        let claudeDir = mcpsDir.appendingPathComponent(".claude")
        let settingsFile = claudeDir.appendingPathComponent("settings.local.json")
        try? fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        var allowList: [String] = [
            "mcp__blitz-macos__asc_set_credentials",
            "mcp__blitz-macos__asc_web_auth",
            "Bash(python3:*)",
        ]
        if whitelistBlitzMCP {
            allowList = Self.allBlitzMCPToolPermissions()
        }
        if allowASCCLICalls {
            Self.ensureAllowPermission("Bash(asc:*)", in: &allowList)
        }
        let settings: [String: Any] = [
            "enabledMcpjsonServers": ["blitz-macos", "blitz-iphone"],
            "permissions": ["allow": allowList]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: settingsFile)
        }

        let claudeMd = mcpsDir.appendingPathComponent("CLAUDE.md")
        let claudeMdContent = """
        # Blitz — Global Agent Context

        This directory is used by Blitz to run agent sessions outside of a project context
        (e.g. App Store Connect API key setup during onboarding).

        ## Available MCP Tools

        The `blitz-macos` MCP server is connected. Key tools for ASC setup:

        - `asc_web_auth` — Opens the Apple ID login window in Blitz to authenticate a web session.
          Call this first if you get a 401 from iris APIs or if no web session exists.
        - `asc_set_credentials` — Pre-fills the ASC credential form in Blitz with issuer ID, key ID,
          and a path to the .p8 private key file. The user must click "Save Credentials" to confirm.
          Parameters: `issuerId` (string), `keyId` (string), `privateKeyPath` (string, absolute path to .p8 file).
        """
        try? claudeMdContent.write(to: claudeMd, atomically: true, encoding: .utf8)

        let skillDirectories = ProjectSkillRoot.allCases.map {
            mcpsDir.appendingPathComponent($0.rawValue).appendingPathComponent("skills")
        }

        DispatchQueue.global(qos: .utility).async {
            for skillsDir in skillDirectories {
                try? fm.createDirectory(at: skillsDir, withIntermediateDirectories: true)
            }

            if let bundledSkillsDir = Self.bundledProjectSkillsDirectory() {
                Self.syncSkillDirectories(from: bundledSkillsDir, into: skillDirectories, using: fm)
            }
        }
    }

    func ensureAllProjectMCPConfigs(whitelistBlitzMCP: Bool = true, allowASCCLICalls: Bool = false) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return
        }

        for entry in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }
            ensureMCPConfig(
                in: entry,
                whitelistBlitzMCP: whitelistBlitzMCP,
                allowASCCLICalls: allowASCCLICalls,
                includeProjectDocFallback: true
            )
        }
    }

    func ensureMCPConfig(
        projectId: String,
        whitelistBlitzMCP: Bool = true,
        allowASCCLICalls: Bool = false
    ) {
        let projectDir = baseDirectory.appendingPathComponent(projectId)
        ensureMCPConfig(
            in: projectDir,
            whitelistBlitzMCP: whitelistBlitzMCP,
            allowASCCLICalls: allowASCCLICalls,
            includeProjectDocFallback: true
        )
    }

    /// Writes `.mcp.json`, `.codex/config.toml`, and `opencode.json` into `directory`.
    func ensureMCPConfig(
        in directory: URL,
        whitelistBlitzMCP: Bool = true,
        allowASCCLICalls: Bool = false,
        includeProjectDocFallback: Bool = true
    ) {
        let mcpFile = directory.appendingPathComponent(".mcp.json")
        let helperPath = BlitzPaths.mcpHelper.path

        let blitzMacosEntry: [String: Any] = ["command": helperPath]
        let nodeRuntimeBin = BlitzPaths.nodeDir.path
        let blitzIphoneCommand = blitzIphoneCommand(nodeRuntimeBin: nodeRuntimeBin)
        let blitzIphoneEntry: [String: Any] = [
            "command": blitzIphoneCommand.command,
            "args": blitzIphoneCommand.args,
            "env": blitzIphoneCommand.env
        ]

        var root: [String: Any]
        if let data = try? Data(contentsOf: mcpFile),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
            var servers = root["mcpServers"] as? [String: Any] ?? [:]
            servers["blitz-macos"] = blitzMacosEntry
            servers["blitz-iphone"] = blitzIphoneEntry
            servers.removeValue(forKey: "blitz-ios")
            root["mcpServers"] = servers
        } else {
            root = ["mcpServers": [
                "blitz-macos": blitzMacosEntry,
                "blitz-iphone": blitzIphoneEntry
            ]]
        }

        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        do {
            try data.write(to: mcpFile)
        } catch {
            print("[ProjectAgentConfigService] Failed to write .mcp.json: \(error)")
        }

        let codexDir = directory.appendingPathComponent(".codex")
        let codexConfig = codexDir.appendingPathComponent("config.toml")
        let codexMacEnabledTools = whitelistBlitzMCP ? Self.blitzMacosToolNames() : Self.minimalBlitzMacosToolNames()
        let codexIphoneEnabledTools = whitelistBlitzMCP ? Self.blitzIphoneToolNames() : []
        let codexMacEnabledToolsToml = codexMacEnabledTools
            .map { "\"\(Self.escapeTOMLString($0))\"" }
            .joined(separator: ", ")
        let codexIphoneEnabledToolsToml = codexIphoneEnabledTools
            .map { "\"\(Self.escapeTOMLString($0))\"" }
            .joined(separator: ", ")
        let codexIphonePathEnv = blitzIphoneCommand.env["PATH"] ?? "\(nodeRuntimeBin):/usr/bin:/bin:/usr/sbin:/sbin"
        let codexIphoneArgsToml = blitzIphoneCommand.args
            .map { "\"\(Self.escapeTOMLString($0))\"" }
            .joined(separator: ", ")
        let codexProjectDocFallbackLine = includeProjectDocFallback
            ? "project_doc_fallback_filenames = [\".claude/rules/blitz.md\", \".claude/rules/teenybase.md\"]"
            : ""
        let codexProjectDocMaxBytesLine = includeProjectDocFallback ? "project_doc_max_bytes = 65536" : ""
        let toml = """
        \(codexProjectDocFallbackLine)
        \(codexProjectDocMaxBytesLine)

        [mcp_servers.blitz_macos]
        command = "\(Self.escapeTOMLString(helperPath))"
        cwd = "\(Self.escapeTOMLString(directory.path))"
        enabled_tools = [\(codexMacEnabledToolsToml)]

        [mcp_servers."blitz-iphone"]
        command = "\(Self.escapeTOMLString(blitzIphoneCommand.command))"
        args = [\(codexIphoneArgsToml)]
        cwd = "\(Self.escapeTOMLString(directory.path))"
        enabled_tools = [\(codexIphoneEnabledToolsToml)]

        [mcp_servers."blitz-iphone".env]
        PATH = "\(Self.escapeTOMLString(codexIphonePathEnv))"
        """
        do {
            try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
            try toml.write(to: codexConfig, atomically: true, encoding: .utf8)
        } catch {
            print("[ProjectAgentConfigService] Failed to write .codex/config.toml: \(error)")
        }

        let codexRulesDir = codexDir.appendingPathComponent("rules")
        let codexBlitzRulesFile = codexRulesDir.appendingPathComponent("blitz.rules")
        if allowASCCLICalls {
            let ascPath = BlitzPaths.bin.appendingPathComponent("asc").path
            let rules = """
            # Managed by Blitz. Allows ASC CLI commands without approval prompts.
            prefix_rule(pattern=["asc"], decision="allow")
            prefix_rule(pattern=["\(Self.escapeStarlarkString(ascPath))"], decision="allow")
            """
            do {
                try FileManager.default.createDirectory(at: codexRulesDir, withIntermediateDirectories: true)
                try rules.write(to: codexBlitzRulesFile, atomically: true, encoding: .utf8)
            } catch {
                print("[ProjectAgentConfigService] Failed to write .codex/rules/blitz.rules: \(error)")
            }
        } else if FileManager.default.fileExists(atPath: codexBlitzRulesFile.path) {
            try? FileManager.default.removeItem(at: codexBlitzRulesFile)
        }

        let opencodeConfig = directory.appendingPathComponent("opencode.json")
        var opencodeRoot: [String: Any] = [:]
        if let data = try? Data(contentsOf: opencodeConfig),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            opencodeRoot = existing
        }
        if opencodeRoot["$schema"] == nil {
            opencodeRoot["$schema"] = "https://opencode.ai/config.json"
        }

        var opencodeMcp = opencodeRoot["mcp"] as? [String: Any] ?? [:]
        opencodeMcp["blitz-macos"] = [
            "type": "local",
            "command": [helperPath],
            "enabled": true,
        ]
        opencodeMcp["blitz-iphone"] = [
            "type": "local",
            "command": [blitzIphoneCommand.command] + blitzIphoneCommand.args,
            "enabled": true,
            "environment": [
                "PATH": codexIphonePathEnv,
            ],
        ]
        opencodeMcp.removeValue(forKey: "blitz-ios")
        opencodeRoot["mcp"] = opencodeMcp

        var opencodePermission: [String: Any] = [:]
        if let existingPermission = opencodeRoot["permission"] as? [String: Any] {
            opencodePermission = existingPermission
        } else if let existingPermissionString = opencodeRoot["permission"] as? String {
            opencodePermission["*"] = existingPermissionString
        }

        let opencodeMCPPermissionKeys = Self.allOpenCodeBlitzMCPPermissionKeys()
        if whitelistBlitzMCP {
            for key in opencodeMCPPermissionKeys {
                opencodePermission[key] = "allow"
            }
        } else {
            for key in opencodeMCPPermissionKeys {
                opencodePermission[key] = "ask"
            }
            opencodePermission["blitz-macos_asc_set_credentials"] = "allow"
            opencodePermission["blitz-macos_asc_web_auth"] = "allow"
        }

        var opencodeBash: [String: Any] = [:]
        if let existingBash = opencodePermission["bash"] as? [String: Any] {
            opencodeBash = existingBash
        } else if let existingBashString = opencodePermission["bash"] as? String {
            opencodeBash["*"] = existingBashString
        }
        let ascPath = BlitzPaths.bin.appendingPathComponent("asc").path
        let ascPatterns = [
            "asc",
            "asc *",
            ascPath,
            "\(ascPath) *",
        ]
        if allowASCCLICalls {
            for pattern in ascPatterns {
                opencodeBash[pattern] = "allow"
            }
        } else {
            for pattern in ascPatterns {
                opencodeBash.removeValue(forKey: pattern)
            }
        }
        if opencodeBash.isEmpty {
            opencodePermission.removeValue(forKey: "bash")
        } else {
            opencodePermission["bash"] = opencodeBash
        }
        opencodeRoot["permission"] = opencodePermission

        if let data = try? JSONSerialization.data(withJSONObject: opencodeRoot, options: [.prettyPrinted, .sortedKeys]) {
            do {
                try data.write(to: opencodeConfig)
            } catch {
                print("[ProjectAgentConfigService] Failed to write opencode.json: \(error)")
            }
        }
    }

    func ensureClaudeFiles(
        projectId: String,
        projectType: ProjectType,
        whitelistBlitzMCP: Bool = true,
        allowASCCLICalls: Bool = false
    ) {
        let fm = FileManager.default
        let projectDir = baseDirectory.appendingPathComponent(projectId)
        let claudeDir = projectDir.appendingPathComponent(".claude")

        let settingsFile = claudeDir.appendingPathComponent("settings.local.json")
        try? fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let correctServers = ["blitz-macos", "blitz-iphone"]
        var settings: [String: Any]
        if fm.fileExists(atPath: settingsFile.path),
           let data = try? Data(contentsOf: settingsFile),
           var existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            existing["enabledMcpjsonServers"] = correctServers
            if var perms = existing["permissions"] as? [String: Any],
               var allow = perms["allow"] as? [String] {
                allow.removeAll { $0.contains("blitz-ios") }
                if whitelistBlitzMCP {
                    let blitzTools = Self.allBlitzMCPToolPermissions()
                    for tool in blitzTools where !allow.contains(tool) {
                        allow.append(tool)
                    }
                }
                if allowASCCLICalls {
                    Self.ensureAllowPermission("Bash(asc:*)", in: &allow)
                } else {
                    allow.removeAll { $0 == "Bash(asc:*)" }
                }
                perms["allow"] = allow
                existing["permissions"] = perms
            }
            settings = existing
        } else {
            var defaultAllow: [String] = [
                "Bash(curl:*)",
                "Bash(xcrun simctl terminate:*)",
                "Bash(xcrun simctl launch:*)",
                "mcp__blitz-macos__app_get_state",
            ]
            if whitelistBlitzMCP {
                defaultAllow = Self.allBlitzMCPToolPermissions() + [
                    "Bash(curl:*)",
                    "Bash(xcrun simctl terminate:*)",
                    "Bash(xcrun simctl launch:*)",
                ]
            }
            if allowASCCLICalls {
                Self.ensureAllowPermission("Bash(asc:*)", in: &defaultAllow)
            }
            settings = [
                "permissions": ["allow": defaultAllow],
                "enabledMcpjsonServers": correctServers,
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: settingsFile)
        }

        let claudeMdFile = projectDir.appendingPathComponent("CLAUDE.md")
        if !fm.fileExists(atPath: claudeMdFile.path) {
            try? Self.claudeMdContent(projectType: projectType)
                .write(to: claudeMdFile, atomically: true, encoding: .utf8)
        }

        let rulesDir = claudeDir.appendingPathComponent("rules")
        try? fm.createDirectory(at: rulesDir, withIntermediateDirectories: true)

        let blitzRules = rulesDir.appendingPathComponent("blitz.md")
        try? Self.blitzRulesContent().write(to: blitzRules, atomically: true, encoding: .utf8)

        if let teenybaseRulesContent = Self.teenybaseRulesContent() {
            let teenybaseRules = rulesDir.appendingPathComponent("teenybase.md")
            try? teenybaseRulesContent.write(to: teenybaseRules, atomically: true, encoding: .utf8)
        }

        ensureReviewerAgent(projectDir: projectDir)
        ensureProjectSkills(projectDir: projectDir)
    }

    func ensureReviewerAgent(projectDir: URL) {
        let fm = FileManager.default
        let claudeDir = projectDir.appendingPathComponent(".claude")
        let agentRepoDir = claudeDir.appendingPathComponent("app-store-review-agent")
        let agentsDir = claudeDir.appendingPathComponent("agents")
        let symlinkPath = agentsDir.appendingPathComponent("reviewer.md")
        let symlinkExists = fm.fileExists(atPath: symlinkPath.path)

        DispatchQueue.global(qos: .utility).async {
            let repoURL = BlitzPaths.reviewerAgentRepo

            if fm.fileExists(atPath: agentRepoDir.appendingPathComponent(".git").path) {
                let pull = Process()
                pull.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                pull.arguments = ["-C", agentRepoDir.path, "pull", "--quiet", "--ff-only"]
                pull.standardOutput = FileHandle.nullDevice
                pull.standardError = FileHandle.nullDevice
                try? pull.run()
                pull.waitUntilExit()
            } else {
                let clone = Process()
                clone.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                clone.arguments = ["clone", "--quiet", "--depth", "1", repoURL, agentRepoDir.path]
                clone.standardOutput = FileHandle.nullDevice
                clone.standardError = FileHandle.nullDevice
                try? clone.run()
                clone.waitUntilExit()
                guard clone.terminationStatus == 0 else {
                    print("[ProjectAgentConfigService] Failed to clone app-store-review-agent")
                    return
                }
            }

            if !symlinkExists {
                try? fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)
                try? fm.createSymbolicLink(
                    atPath: symlinkPath.path,
                    withDestinationPath: "../app-store-review-agent/agents/reviewer.md"
                )
                print("[ProjectAgentConfigService] Reviewer agent installed")
            }
        }
    }

    func ensureProjectSkills(projectDir: URL) {
        let fm = FileManager.default
        let claudeDir = projectDir.appendingPathComponent(".claude")
        let repoDir = claudeDir.appendingPathComponent("asc-skills")
        let skillDirectories = projectSkillDirectories(projectDir: projectDir)

        for skillsDir in skillDirectories {
            try? fm.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        }

        if let bundledSkillsDir = Self.bundledProjectSkillsDirectory() {
            Self.syncSkillDirectories(from: bundledSkillsDir, into: skillDirectories, using: fm)
        }

        DispatchQueue.global(qos: .utility).async {
            let repoURL = BlitzPaths.ascSkillsRepo

            if fm.fileExists(atPath: repoDir.appendingPathComponent(".git").path) {
                let pull = Process()
                pull.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                pull.arguments = ["-C", repoDir.path, "pull", "--quiet", "--ff-only"]
                pull.standardOutput = FileHandle.nullDevice
                pull.standardError = FileHandle.nullDevice
                try? pull.run()
                pull.waitUntilExit()
            } else {
                let clone = Process()
                clone.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                clone.arguments = ["clone", "--quiet", "--depth", "1", repoURL, repoDir.path]
                clone.standardOutput = FileHandle.nullDevice
                clone.standardError = FileHandle.nullDevice
                try? clone.run()
                clone.waitUntilExit()
                guard clone.terminationStatus == 0 else {
                    print("[ProjectAgentConfigService] Failed to clone asc-skills")
                    return
                }
            }

            let repoSkillsDir = repoDir.appendingPathComponent("skills")
            Self.syncSkillDirectories(from: repoSkillsDir, into: skillDirectories, using: fm)

            if let bundledSkillsDir = Self.bundledProjectSkillsDirectory() {
                Self.syncSkillDirectories(from: bundledSkillsDir, into: skillDirectories, using: fm)
            }

            let installedRoots = skillDirectories.map(\.path).joined(separator: ", ")
            print("[ProjectAgentConfigService] Project skills installed in \(installedRoots)")
        }
    }

    private func projectSkillDirectories(projectDir: URL) -> [URL] {
        ProjectSkillRoot.allCases.map {
            projectDir
                .appendingPathComponent($0.rawValue)
                .appendingPathComponent("skills")
        }
    }

    static func allBlitzMCPToolPermissions() -> [String] {
        let macTools = blitzMacosToolNames().map { "mcp__blitz-macos__\($0)" }
        let iphoneTools = blitzIphoneToolNames().map { "mcp__blitz-iphone__\($0)" }
        return macTools + iphoneTools
    }

    private static func blitzMacosToolNames() -> [String] {
        MCPRegistry.allToolNames()
    }

    private static func minimalBlitzMacosToolNames() -> [String] {
        ["asc_set_credentials", "asc_web_auth"]
    }

    private static func blitzIphoneToolNames() -> [String] {
        [
            "list_devices", "setup_device", "launch_app", "list_apps",
            "get_screenshot", "scan_ui", "describe_screen", "device_action",
            "device_actions", "get_execution_context",
        ]
    }

    private static func allOpenCodeBlitzMCPPermissionKeys() -> [String] {
        let macTools = blitzMacosToolNames().map { "blitz-macos_\($0)" }
        let iphoneTools = blitzIphoneToolNames().map { "blitz-iphone_\($0)" }
        return macTools + iphoneTools
    }

    private static func escapeTOMLString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func escapeStarlarkString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func bundledProjectSkillsDirectory() -> URL? {
        let fm = FileManager.default

        if let bundleSkills = Bundle.main.resourceURL?.appendingPathComponent("claude-skills"),
           fm.fileExists(atPath: bundleSkills.path) {
            return bundleSkills
        }

        #if DEBUG
        let repoSkills = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("resources/skills")
        if fm.fileExists(atPath: repoSkills.path) {
            return repoSkills
        }
        #endif

        return nil
    }

    private static func syncSkillDirectories(from sourceSkillsDir: URL, into destinations: [URL], using fm: FileManager) {
        guard let skillDirs = try? fm.contentsOfDirectory(
            at: sourceSkillsDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }

        for destination in destinations {
            for srcSkillDir in skillDirs {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: srcSkillDir.path, isDirectory: &isDir),
                      isDir.boolValue else { continue }

                let destSkillDir = destination.appendingPathComponent(srcSkillDir.lastPathComponent)
                if fm.fileExists(atPath: destSkillDir.path) {
                    try? fm.removeItem(at: destSkillDir)
                }
                try? fm.copyItem(at: srcSkillDir, to: destSkillDir)
            }
        }
    }

    private static func ensureAllowPermission(_ permission: String, in allowList: inout [String]) {
        guard !allowList.contains(permission) else { return }
        allowList.append(permission)
    }

    private static func claudeMdContent(projectType: ProjectType) -> String {
        guard let templateURL = Bundle.appResources.url(forResource: "CLAUDE.md", withExtension: "template"),
              var template = try? String(contentsOf: templateURL, encoding: .utf8) else {
            return "# Blitz AI Agent Guide\n"
        }

        let header: String
        switch projectType {
        case .swift:
            header = "Swift Project — Blitz AI Agent Guide"
        case .reactNative:
            header = "React Native Project — Blitz AI Agent Guide"
        case .flutter:
            header = "Flutter Project — Blitz AI Agent Guide"
        }
        template = template.replacingOccurrences(of: "{{PROJECT_TYPE_HEADER}}", with: header)

        return template
    }

    private static func blitzRulesContent() -> String {
        guard let url = Bundle.appResources.url(forResource: "blitz-rules", withExtension: "md"),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return "# Blitz MCP Integration\n"
        }
        return content
    }

    private static func teenybaseRulesContent() -> String? {
        guard let url = Bundle.appResources.url(forResource: "teenybase-rules", withExtension: "md"),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        return content
    }
}
