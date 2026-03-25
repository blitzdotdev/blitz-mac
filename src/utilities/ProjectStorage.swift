import Foundation

/// Filesystem operations for ~/.blitz/projects/
struct ProjectStorage {
    let baseDirectory: URL

    private enum ProjectSkillRoot: String, CaseIterable {
        case claude = ".claude"
        case agents = ".agents"
    }

    init() {
        self.baseDirectory = BlitzPaths.projects
    }

    /// List all projects in ~/.blitz/projects/
    func listProjects() async -> [Project] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }

        var projects: [Project] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for entry in entries {
            // fileExists(atPath:isDirectory:) follows symlinks;
            // isDirectoryKey does NOT, so symlinked project dirs would be skipped.
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }

            let metadataFile = entry.appendingPathComponent(".blitz/project.json")
            guard let data = try? Data(contentsOf: metadataFile),
                  let metadata = try? decoder.decode(BlitzProjectMetadata.self, from: data) else {
                continue
            }

            let project = Project(
                id: entry.lastPathComponent,
                metadata: metadata,
                path: entry.path
            )
            projects.append(project)
        }

        return projects.sorted { ($0.metadata.lastOpenedAt ?? .distantPast) > ($1.metadata.lastOpenedAt ?? .distantPast) }
    }

    /// Read a specific project's metadata
    func readMetadata(projectId: String) -> BlitzProjectMetadata? {
        let metadataFile = baseDirectory
            .appendingPathComponent(projectId)
            .appendingPathComponent(".blitz/project.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: metadataFile) else { return nil }
        return try? decoder.decode(BlitzProjectMetadata.self, from: data)
    }

    /// Write project metadata into ~/.blitz/projects/{id}/.blitz/project.json
    func writeMetadata(projectId: String, metadata: BlitzProjectMetadata) throws {
        let projectDir = baseDirectory.appendingPathComponent(projectId)
        try writeMetadataToDirectory(projectDir, metadata: metadata)
    }

    /// Write project metadata into an arbitrary directory (e.g. the original project path before symlinking).
    func writeMetadataToDirectory(_ dir: URL, metadata: BlitzProjectMetadata) throws {
        let blitzDir = dir.appendingPathComponent(".blitz")
        try FileManager.default.createDirectory(at: blitzDir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: blitzDir.appendingPathComponent("project.json"))
    }

    /// Delete a project directory
    func deleteProject(projectId: String) throws {
        let projectDir = baseDirectory.appendingPathComponent(projectId)
        let path = projectDir.path
        // Check if this is a symlink — if so, only remove the symlink itself, not the target
        var isSymlink = false
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           attrs[.type] as? FileAttributeType == .typeSymbolicLink {
            isSymlink = true
        }
        if isSymlink {
            // unlink only removes the symlink, not the target directory
            unlink(path)
        } else {
            try FileManager.default.removeItem(at: projectDir)
        }
    }

    /// Open a project at the given URL. Validates .blitz/project.json exists,
    /// registers it in ~/.blitz/projects/ if needed, and returns the projectId.
    func openProject(at url: URL) throws -> String {
        let metadataFile = url.appendingPathComponent(".blitz/project.json")
        guard FileManager.default.fileExists(atPath: metadataFile.path) else {
            throw ProjectOpenError.notABlitzProject
        }

        var folderName = url.lastPathComponent
        let existingDir = baseDirectory.appendingPathComponent(folderName)

        if FileManager.default.fileExists(atPath: existingDir.path) {
            // Check if it resolves to the same location
            let resolvedExisting = existingDir.resolvingSymlinksInPath().path
            let resolvedNew = url.resolvingSymlinksInPath().path
            if resolvedExisting == resolvedNew {
                updateLastOpened(projectId: folderName)
                return folderName
            }
            // Name collision with different project — disambiguate
            var counter = 2
            while FileManager.default.fileExists(
                atPath: baseDirectory.appendingPathComponent("\(folderName)-\(counter)").path
            ) { counter += 1 }
            folderName = "\(folderName)-\(counter)"
        }

        // Create symlink: ~/.blitz/projects/{folderName} → selectedPath
        let symlinkDir = baseDirectory.appendingPathComponent(folderName)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlinkDir, withDestinationURL: url)

        updateLastOpened(projectId: folderName)
        return folderName
    }

    /// Update lastOpenedAt timestamp for a project
    func updateLastOpened(projectId: String) {
        guard var metadata = readMetadata(projectId: projectId) else { return }
        metadata.lastOpenedAt = Date()
        do {
            try writeMetadata(projectId: projectId, metadata: metadata)
        } catch {
            print("[ProjectStorage] Failed to update lastOpenedAt for \(projectId): \(error)")
        }
    }

    /// Ensure ~/.blitz/mcps/ has MCP configs, CLAUDE.md, and skills so that
    /// agent sessions launched outside a project (e.g. onboarding ASC setup) can
    /// access Blitz MCP tools. Idempotent — safe to call on every launch.
    func ensureGlobalMCPConfigs(whitelistBlitzMCP: Bool = true, allowASCCLICalls: Bool = false) {
        let fm = FileManager.default
        let mcpsDir = BlitzPaths.mcps

        try? fm.createDirectory(at: mcpsDir, withIntermediateDirectories: true)

        // 1. .mcp.json + .codex/config.toml + opencode.json (reuse project-level logic)
        ensureMCPConfig(
            in: mcpsDir,
            whitelistBlitzMCP: whitelistBlitzMCP,
            allowASCCLICalls: allowASCCLICalls,
            includeProjectDocFallback: false
        )

        // 2. .claude/settings.local.json
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
            "permissions": [
                "allow": allowList
            ]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: settingsFile)
        }

        // 3. CLAUDE.md
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

        // 4. Skills — copy bundled skills (e.g. asc-team-key-create)
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

    /// Ensure agent MCP configs for every existing project under ~/.blitz/projects/.
    /// This backfills new config fields for users with older project files.
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

    /// Ensure .mcp.json contains blitz-macos and blitz-iphone MCP server entries.
    /// If the file exists, merges into the existing mcpServers key without overwriting other entries.
    /// If it doesn't exist, creates it.
    /// Also removes the deprecated blitz-ios entry if present.
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

    /// Shared implementation: writes .mcp.json, .codex/config.toml, and opencode.json into `directory`.
    func ensureMCPConfig(
        in directory: URL,
        whitelistBlitzMCP: Bool = true,
        allowASCCLICalls: Bool = false,
        includeProjectDocFallback: Bool = true
    ) {
        let mcpFile = directory.appendingPathComponent(".mcp.json")
        let helperPath = BlitzPaths.mcpHelper.path

        let blitzMacosEntry: [String: Any] = [
            "command": helperPath
        ]
        // Use full path to npx from Blitz's bundled Node.js runtime.
        // Also set PATH env so that #!/usr/bin/env node resolves correctly —
        // npx and the packages it runs use env shebang lookups.
        let nodeRuntimeBin = BlitzPaths.nodeDir.path
        let blitzIphoneEntry: [String: Any] = [
            "command": nodeRuntimeBin + "/npx",
            "args": ["-y", "@blitzdev/iphone-mcp"],
            "env": [
                "PATH": "\(nodeRuntimeBin):/usr/bin:/bin:/usr/sbin:/sbin"
            ]
        ]

        var root: [String: Any]
        if let data = try? Data(contentsOf: mcpFile),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
            var servers = root["mcpServers"] as? [String: Any] ?? [:]
            servers["blitz-macos"] = blitzMacosEntry
            servers["blitz-iphone"] = blitzIphoneEntry
            servers.removeValue(forKey: "blitz-ios") // deprecated
            root["mcpServers"] = servers
        } else {
            root = ["mcpServers": [
                "blitz-macos": blitzMacosEntry,
                "blitz-iphone": blitzIphoneEntry
            ]]
        }

        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else { return }
        do {
            try data.write(to: mcpFile)
        } catch {
            print("[ProjectStorage] Failed to write .mcp.json: \(error)")
        }

        // Codex config — explicit Blitz MCP servers and tool allowlists.
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
        let codexIphonePathEnv = "\(nodeRuntimeBin):/usr/bin:/bin:/usr/sbin:/sbin"
        let codexProjectDocFallbackLine: String
        let codexProjectDocMaxBytesLine: String
        if includeProjectDocFallback {
            codexProjectDocFallbackLine = """
            project_doc_fallback_filenames = [".claude/rules/blitz.md", ".claude/rules/teenybase.md"]
            """
            codexProjectDocMaxBytesLine = "project_doc_max_bytes = 65536"
        } else {
            codexProjectDocFallbackLine = ""
            codexProjectDocMaxBytesLine = ""
        }
        let toml = """
        \(codexProjectDocFallbackLine)
        \(codexProjectDocMaxBytesLine)

        [mcp_servers.blitz_macos]
        command = "\(Self.escapeTOMLString(helperPath))"
        cwd = "\(Self.escapeTOMLString(directory.path))"
        enabled_tools = [\(codexMacEnabledToolsToml)]

        [mcp_servers."blitz-iphone"]
        command = "\(Self.escapeTOMLString(nodeRuntimeBin + "/npx"))"
        args = ["-y", "@blitzdev/iphone-mcp"]
        cwd = "\(Self.escapeTOMLString(directory.path))"
        enabled_tools = [\(codexIphoneEnabledToolsToml)]

        [mcp_servers."blitz-iphone".env]
        PATH = "\(Self.escapeTOMLString(codexIphonePathEnv))"
        """
        do {
            try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
            try toml.write(to: codexConfig, atomically: true, encoding: .utf8)
        } catch {
            print("[ProjectStorage] Failed to write .codex/config.toml: \(error)")
        }

        // Codex ASC bash allowlist — managed as a dedicated Blitz-owned rules file.
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
                print("[ProjectStorage] Failed to write .codex/rules/blitz.rules: \(error)")
            }
        } else if FileManager.default.fileExists(atPath: codexBlitzRulesFile.path) {
            try? FileManager.default.removeItem(at: codexBlitzRulesFile)
        }

        // OpenCode config
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
            "command": [nodeRuntimeBin + "/npx", "-y", "@blitzdev/iphone-mcp"],
            "enabled": true,
            "environment": [
                "PATH": "\(nodeRuntimeBin):/usr/bin:/bin:/usr/sbin:/sbin",
            ],
        ]
        opencodeMcp.removeValue(forKey: "blitz-ios") // deprecated
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
                print("[ProjectStorage] Failed to write opencode.json: \(error)")
            }
        }
    }

    /// All Blitz MCP tool permission strings for both blitz-macos and blitz-iphone servers.
    static func allBlitzMCPToolPermissions() -> [String] {
        // blitz-macos tools — from MCPToolRegistry
        let macTools = blitzMacosToolNames().map { "mcp__blitz-macos__\($0)" }
        // blitz-iphone tools — from @blitzdev/iphone-mcp
        let iphoneTools = blitzIphoneToolNames().map { "mcp__blitz-iphone__\($0)" }
        return macTools + iphoneTools
    }

    private static func blitzMacosToolNames() -> [String] {
        MCPToolRegistry.allToolNames()
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

    /// Ensure CLAUDE.md, .claude/settings.local.json, and .claude/rules/ exist for a project.
    func ensureClaudeFiles(
        projectId: String,
        projectType: ProjectType,
        whitelistBlitzMCP: Bool = true,
        allowASCCLICalls: Bool = false
    ) {
        let fm = FileManager.default
        let projectDir = baseDirectory.appendingPathComponent(projectId)
        let claudeDir = projectDir.appendingPathComponent(".claude")

        // 1. .claude/settings.local.json
        // Always update enabledMcpjsonServers (Blitz-owned structural setting).
        let settingsFile = claudeDir.appendingPathComponent("settings.local.json")
        try? fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let correctServers = ["blitz-macos", "blitz-iphone"]
        var settings: [String: Any]
        if fm.fileExists(atPath: settingsFile.path),
           let data = try? Data(contentsOf: settingsFile),
           var existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Preserve user customisations; only force-update the server list
            existing["enabledMcpjsonServers"] = correctServers
            // Remove deprecated blitz-ios permission entries
            if var perms = existing["permissions"] as? [String: Any],
               var allow = perms["allow"] as? [String] {
                allow.removeAll { $0.contains("blitz-ios") }
                // Inject whitelist if enabled
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
                "permissions": [
                    "allow": defaultAllow
                ],
                "enabledMcpjsonServers": correctServers,
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: settingsFile)
        }

        // 2. CLAUDE.md — write only if absent; user may have their own
        let claudeMdFile = projectDir.appendingPathComponent("CLAUDE.md")
        if !fm.fileExists(atPath: claudeMdFile.path) {
            let content = Self.claudeMdContent(projectType: projectType)
            try? content.write(to: claudeMdFile, atomically: true, encoding: .utf8)
        }

        // 3. .claude/rules/ — Blitz-owned files, always overwrite.
        // These auto-load in every Claude Code session alongside any existing CLAUDE.md,
        // so agents get Blitz/Teenybase context even on projects with pre-existing docs.
        let rulesDir = claudeDir.appendingPathComponent("rules")
        try? fm.createDirectory(at: rulesDir, withIntermediateDirectories: true)

        let blitzRules = rulesDir.appendingPathComponent("blitz.md")
        try? Self.blitzRulesContent().write(to: blitzRules, atomically: true, encoding: .utf8)

        let teenybaseRules = rulesDir.appendingPathComponent("teenybase.md")
        try? Self.teenybaseRulesContent(projectDir: projectDir, projectType: projectType)
            .write(to: teenybaseRules, atomically: true, encoding: .utf8)

        // 4. App Store Review Agent — clone from public repo, symlink into .claude/agents/
        ensureReviewerAgent(projectDir: projectDir)

        // 5. Project skills — copy bundled Blitz skills and sync ASC CLI skills
        // into supported local agent skill directories.
        ensureProjectSkills(projectDir: projectDir)

    }

    /// Clone or update the app-store-review-agent repo and symlink the agent
    /// into .claude/agents/ where Claude Code can discover it.
    /// Runs git operations on a background queue so it never blocks the UI.
    func ensureReviewerAgent(projectDir: URL) {
        let fm = FileManager.default
        let claudeDir = projectDir.appendingPathComponent(".claude")
        let agentRepoDir = claudeDir.appendingPathComponent("app-store-review-agent")
        let agentsDir = claudeDir.appendingPathComponent("agents")
        let symlinkPath = agentsDir.appendingPathComponent("reviewer.md")

        // If symlink already exists and resolves to a real file, nothing to do.
        // (Still dispatch a background pull to pick up rule updates.)
        let symlinkExists = fm.fileExists(atPath: symlinkPath.path)

        DispatchQueue.global(qos: .utility).async {
            let repoURL = BlitzPaths.reviewerAgentRepo

            if fm.fileExists(atPath: agentRepoDir.appendingPathComponent(".git").path) {
                // Already cloned — pull latest in background
                let pull = Process()
                pull.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                pull.arguments = ["-C", agentRepoDir.path, "pull", "--quiet", "--ff-only"]
                pull.standardOutput = FileHandle.nullDevice
                pull.standardError = FileHandle.nullDevice
                try? pull.run()
                pull.waitUntilExit()
            } else {
                // First time — clone
                let clone = Process()
                clone.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                clone.arguments = ["clone", "--quiet", "--depth", "1", repoURL, agentRepoDir.path]
                clone.standardOutput = FileHandle.nullDevice
                clone.standardError = FileHandle.nullDevice
                try? clone.run()
                clone.waitUntilExit()
                guard clone.terminationStatus == 0 else {
                    print("[ProjectStorage] Failed to clone app-store-review-agent")
                    return
                }
            }

            // Create .claude/agents/ and symlink reviewer.md
            if !symlinkExists {
                try? fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)
                // Relative symlink so it works regardless of absolute project path
                try? fm.createSymbolicLink(
                    atPath: symlinkPath.path,
                    withDestinationPath: "../app-store-review-agent/agents/reviewer.md"
                )
                print("[ProjectStorage] Reviewer agent installed")
            }
        }
    }

    /// Copy bundled Blitz project skills and sync the ASC CLI skills repo into
    /// each supported local agent skills directory.
    /// Overwrites asc-app-create-ui/SKILL.md with the pre-cached-session version.
    /// Runs git operations on a background queue so it never blocks the UI.
    func ensureProjectSkills(projectDir: URL) {
        let fm = FileManager.default
        let claudeDir = projectDir.appendingPathComponent(".claude")
        let repoDir = claudeDir.appendingPathComponent("asc-skills")
        let skillDirectories = projectSkillDirectories(projectDir: projectDir)

        for skillsDir in skillDirectories {
            try? fm.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        }

        if let bundledSkillsDir = Self.bundledProjectSkillsDirectory() {
            Self.syncSkillDirectories(
                from: bundledSkillsDir,
                into: skillDirectories,
                using: fm
            )
        }

        DispatchQueue.global(qos: .utility).async {
            let repoURL = BlitzPaths.ascSkillsRepo

            if fm.fileExists(atPath: repoDir.appendingPathComponent(".git").path) {
                // Already cloned — pull latest
                let pull = Process()
                pull.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                pull.arguments = ["-C", repoDir.path, "pull", "--quiet", "--ff-only"]
                pull.standardOutput = FileHandle.nullDevice
                pull.standardError = FileHandle.nullDevice
                try? pull.run()
                pull.waitUntilExit()
            } else {
                // First time — clone
                let clone = Process()
                clone.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                clone.arguments = ["clone", "--quiet", "--depth", "1", repoURL, repoDir.path]
                clone.standardOutput = FileHandle.nullDevice
                clone.standardError = FileHandle.nullDevice
                try? clone.run()
                clone.waitUntilExit()
                guard clone.terminationStatus == 0 else {
                    print("[ProjectStorage] Failed to clone asc-skills")
                    return
                }
            }

            let repoSkillsDir = repoDir.appendingPathComponent("skills")
            Self.syncSkillDirectories(from: repoSkillsDir, into: skillDirectories, using: fm)

            // Ensure bundled Blitz skills always win over upstream repo copies.
            if let bundledSkillsDir = Self.bundledProjectSkillsDirectory() {
                Self.syncSkillDirectories(from: bundledSkillsDir, into: skillDirectories, using: fm)
            }

            // Overwrite asc-app-create-ui/SKILL.md with Blitz's pre-cached-session version
            for skillsDir in skillDirectories {
                let ascCreateSkillFile = skillsDir
                    .appendingPathComponent("asc-app-create-ui")
                    .appendingPathComponent("SKILL.md")
                try? Self.ascAppCreateSkillContent()
                    .write(to: ascCreateSkillFile, atomically: true, encoding: .utf8)
            }

            let installedRoots = skillDirectories
                .map(\.path)
                .joined(separator: ", ")
            print("[ProjectStorage] Project skills installed in \(installedRoots)")
        }
    }

    private func projectSkillDirectories(projectDir: URL) -> [URL] {
        ProjectSkillRoot.allCases.map {
            projectDir
                .appendingPathComponent($0.rawValue)
                .appendingPathComponent("skills")
        }
    }

    private static func bundledProjectSkillsDirectory() -> URL? {
        let fm = FileManager.default

        if let bundleSkills = Bundle.main.resourceURL?
            .appendingPathComponent("claude-skills"),
           fm.fileExists(atPath: bundleSkills.path) {
            return bundleSkills
        }

        #if DEBUG
        let repoSkills = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".claude/skills")
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

    /// Content for the Blitz-specific asc-app-create-ui skill that uses
    /// iris APIs via the web session file managed by Blitz.
    private static func ascAppCreateSkillContent() -> String {
        return ##"""
        ---
        name: asc-app-create-ui
        description: Create an App Store Connect app via iris API using web session from Blitz
        ---

        Create an App Store Connect app using Apple's iris API. Authentication is handled via a web session file at `~/.blitz/asc-agent/web-session.json` managed by Blitz.

        Extract from the conversation context:
        - `bundleId` — the bundle identifier (e.g. `com.blitz.myapp`)
        - `sku` — the SKU string (may be provided; if missing, generate one from the app name)

        ## Workflow

        ### 1. Check for an existing web session

        ```bash
        test -f ~/.blitz/asc-agent/web-session.json && echo "SESSION_EXISTS" || echo "NO_SESSION"
        ```

        - If `NO_SESSION`: call the `asc_web_auth` MCP tool first. Wait for it to complete before proceeding.
        - If `SESSION_EXISTS`: proceed.

        ### 2. Ask the user for the primary language

        Ask what primary language/locale the app should use. Common choices: `en-US` (English US), `en-GB` (English UK), `ja` (Japanese), `zh-Hans` (Simplified Chinese), `ko` (Korean), `fr-FR` (French), `de-DE` (German).

        ### 3. Derive the app name

        Take the last component of the bundle ID after the final `.`, capitalize the first letter. Confirm with the user.

        ### 4. Create the app via iris API

        Use the following self-contained script. Replace `BUNDLE_ID`, `SKU`, `APP_NAME`, and `LOCALE` with the resolved values. **Do not print or log cookies.**

        Key differences from the public REST API:
        - Uses `appstoreconnect.apple.com/iris/v1/` (not `api.appstoreconnect.apple.com`)
        - Authenticated via web session cookies (not JWT)
        - Uses `appInfos` relationship (not `bundleId` relationship)
        - App name goes on `appInfoLocalizations` (not `appStoreVersionLocalizations`)
        - Uses `${new-...}` placeholder IDs for inline-created resources

        ```bash
        python3 -c "
        import json, os, urllib.request, sys

        BUNDLE_ID = 'BUNDLE_ID_HERE'
        SKU = 'SKU_HERE'
        APP_NAME = 'APP_NAME_HERE'
        LOCALE = 'LOCALE_HERE'

        # Read web session from file (synced by Blitz auth bridge)
        session_path = os.path.expanduser('~/.blitz/asc-agent/web-session.json')
        if not os.path.isfile(session_path):
            print('ERROR: No web session found. Call asc_web_auth MCP tool first.')
            sys.exit(1)
        with open(session_path) as f:
            raw = f.read()

        store = json.loads(raw)
        session = store['sessions'][store['last_key']]
        cookie_str = '; '.join(
            (f'{c[\"name\"]}=\"{c[\"value\"]}\"' if c['name'].startswith('DES') else f'{c[\"name\"]}={c[\"value\"]}')
            for cl in session['cookies'].values() for c in cl
            if c.get('name') and c.get('value')
        )

        headers = {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            'X-Requested-With': 'XMLHttpRequest',
            'Origin': 'https://appstoreconnect.apple.com',
            'Referer': 'https://appstoreconnect.apple.com/',
            'Cookie': cookie_str
        }

        create_body = json.dumps({
            'data': {
                'type': 'apps',
                'attributes': {
                    'bundleId': BUNDLE_ID,
                    'sku': SKU,
                    'primaryLocale': LOCALE,
                },
                'relationships': {
                    'appStoreVersions': {
                        'data': [{'type': 'appStoreVersions', 'id': '\${new-appStoreVersion-1}'}]
                    },
                    'appInfos': {
                        'data': [{'type': 'appInfos', 'id': '\${new-appInfo-1}'}]
                    }
                }
            },
            'included': [
                {
                    'type': 'appStoreVersions',
                    'id': '\${new-appStoreVersion-1}',
                    'attributes': {'platform': 'IOS', 'versionString': '1.0'},
                    'relationships': {
                        'appStoreVersionLocalizations': {
                            'data': [{'type': 'appStoreVersionLocalizations', 'id': '\${new-appStoreVersionLocalization-1}'}]
                        }
                    }
                },
                {
                    'type': 'appStoreVersionLocalizations',
                    'id': '\${new-appStoreVersionLocalization-1}',
                    'attributes': {'locale': LOCALE}
                },
                {
                    'type': 'appInfos',
                    'id': '\${new-appInfo-1}',
                    'relationships': {
                        'appInfoLocalizations': {
                            'data': [{'type': 'appInfoLocalizations', 'id': '\${new-appInfoLocalization-1}'}]
                        }
                    }
                },
                {
                    'type': 'appInfoLocalizations',
                    'id': '\${new-appInfoLocalization-1}',
                    'attributes': {'locale': LOCALE, 'name': APP_NAME}
                }
            ]
        }).encode()

        req = urllib.request.Request(
            'https://appstoreconnect.apple.com/iris/v1/apps',
            data=create_body, method='POST', headers=headers)
        try:
            resp = urllib.request.urlopen(req)
            result = json.loads(resp.read().decode())
            app_id = result['data']['id']
            print(f'App created successfully!')
            print(f'App ID: {app_id}')
            print(f'Bundle ID: {BUNDLE_ID}')
            print(f'Name: {APP_NAME}')
            print(f'SKU: {SKU}')
        except urllib.error.HTTPError as e:
            body = e.read().decode()
            if e.code == 401:
                print('ERROR: Session expired. Call asc_web_auth MCP tool to re-authenticate.')
            elif e.code == 409:
                print(f'ERROR: App may already exist or conflict. Details: {body[:500]}')
            else:
                print(f'ERROR creating app: HTTP {e.code} — {body[:500]}')
            sys.exit(1)
        "
        ```

        ### 5. Report results

        After success, report the App ID, bundle ID, name, and SKU to the user.

        ## Common Errors

        ### 401 Not Authorized
        Call the `asc_web_auth` MCP tool to open the Apple ID login window in Blitz. Then retry.

        ### 409 Conflict
        An app with the same bundle ID or SKU may already exist. Try a different SKU.

        ## Agent Behavior

        - **Do NOT ask for Apple ID email** — authentication is handled via cached web session file, not email.
        - **NEVER print, log, or echo session cookies.**
        - Use the self-contained python script — do NOT extract cookies separately.
        - If iris API returns 401, call `asc_web_auth` MCP tool and retry.
        """##
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

    private static func teenybaseRulesContent(projectDir: URL, projectType: ProjectType) -> String {
        let fm = FileManager.default

        let backendDir: URL
        let schemaPath: String
        let commandPrefix: String
        switch projectType {
        case .reactNative:
            backendDir = projectDir
            schemaPath = "teenybase.ts"
            commandPrefix = ""
        case .swift, .flutter:
            backendDir = projectDir.appendingPathComponent("backend")
            schemaPath = "backend/teenybase.ts"
            commandPrefix = "cd backend && "
        }

        let hasBackend = fm.fileExists(atPath: backendDir.appendingPathComponent("teenybase.ts").path)
        let templateName = hasBackend ? "teenybase-rules-backend" : "teenybase-rules-no-backend"

        guard let url = Bundle.appResources.url(forResource: templateName, withExtension: "md"),
              var content = try? String(contentsOf: url, encoding: .utf8) else {
            return "# Teenybase Backend\n"
        }

        content = content.replacingOccurrences(of: "{{DEVVARS_PATH}}", with: backendDir.appendingPathComponent(".dev.vars").path)
        content = content.replacingOccurrences(of: "{{SCHEMA_PATH}}", with: schemaPath)
        content = content.replacingOccurrences(of: "{{COMMAND_PREFIX}}", with: commandPrefix)
        return content
    }

    // MARK: - Teenybase backend scaffolding

    /// Copy Teenybase backend files into a project if not already present.
    /// RN projects get files at the project root; Swift/Flutter get a backend/ subdirectory.
    func ensureTeenybaseBackend(projectId: String, projectType: ProjectType) {
        let fm = FileManager.default
        let projectDir = baseDirectory.appendingPathComponent(projectId)

        guard let templateURL = Bundle.appResources.url(
            forResource: "rn-notes-template", withExtension: nil, subdirectory: "templates"
        ) else {
            print("[ProjectStorage] Teenybase template not found in bundle")
            return
        }

        switch projectType {
        case .reactNative:
            copyTeenybaseFiles(from: templateURL, to: projectDir, fm: fm)
            mergeTeenybaseScripts(into: projectDir.appendingPathComponent("package.json"), fm: fm)
        case .swift, .flutter:
            let backendDir = projectDir.appendingPathComponent("backend")
            try? fm.createDirectory(at: backendDir, withIntermediateDirectories: true)
            copyTeenybaseFiles(from: templateURL, to: backendDir, fm: fm)
            ensureStandalonePackageJson(at: backendDir.appendingPathComponent("package.json"),
                                        projectId: projectId, fm: fm)
        }
    }

    /// Copy teenybase.ts, wrangler.toml, src-backend/worker.ts, and .dev.vars into dest.
    /// Skips each file if it already exists so existing configs are never overwritten.
    private func copyTeenybaseFiles(from templateURL: URL, to dest: URL, fm: FileManager) {
        // teenybase.ts — skip if present (indicates backend already set up)
        let teenybaseDest = dest.appendingPathComponent("teenybase.ts")
        guard !fm.fileExists(atPath: teenybaseDest.path) else { return }

        try? fm.copyItem(at: templateURL.appendingPathComponent("teenybase.ts"), to: teenybaseDest)

        // wrangler.toml
        let wranglerDest = dest.appendingPathComponent("wrangler.toml")
        if !fm.fileExists(atPath: wranglerDest.path) {
            let src = templateURL.appendingPathComponent("wrangler.toml")
            if var content = try? String(contentsOf: src, encoding: .utf8) {
                content = content.replacingOccurrences(of: "sample-app", with: dest.deletingLastPathComponent().lastPathComponent)
                try? content.write(to: wranglerDest, atomically: true, encoding: .utf8)
            }
        }

        // src-backend/worker.ts
        let srcBackendDest = dest.appendingPathComponent("src-backend")
        try? fm.createDirectory(at: srcBackendDest, withIntermediateDirectories: true)
        let workerDest = srcBackendDest.appendingPathComponent("worker.ts")
        if !fm.fileExists(atPath: workerDest.path) {
            try? fm.copyItem(
                at: templateURL.appendingPathComponent("src-backend/worker.ts"),
                to: workerDest
            )
        }

        // .dev.vars — from sample.vars
        let devVarsDest = dest.appendingPathComponent(".dev.vars")
        if !fm.fileExists(atPath: devVarsDest.path) {
            let sampleVars = templateURL.appendingPathComponent("sample.vars")
            if fm.fileExists(atPath: sampleVars.path) {
                try? fm.copyItem(at: sampleVars, to: devVarsDest)
            }
        }
    }

    /// For RN projects: merge teenybase scripts + devDependency into existing package.json.
    /// No-op if teenybase is already in devDependencies.
    private func mergeTeenybaseScripts(into packageJsonURL: URL, fm: FileManager) {
        guard fm.fileExists(atPath: packageJsonURL.path),
              let data = try? Data(contentsOf: packageJsonURL),
              var pkg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        var devDeps = pkg["devDependencies"] as? [String: Any] ?? [:]
        guard devDeps["teenybase"] == nil else { return } // already set up

        devDeps["teenybase"] = "0.0.10"
        pkg["devDependencies"] = devDeps

        var scripts = pkg["scripts"] as? [String: Any] ?? [:]
        let backendScripts: [String: String] = [
            "generate:backend": "teeny generate --local",
            "migrate:backend": "teeny migrate --local",
            "dev:backend": "teeny dev --local",
            "build:backend": "teeny build --local",
            "exec:backend": "teeny exec --local",
            "deploy:backend:remote": "teeny deploy --migrate --remote",
        ]
        for (key, value) in backendScripts where scripts[key] == nil {
            scripts[key] = value
        }
        pkg["scripts"] = scripts

        if let updated = try? JSONSerialization.data(withJSONObject: pkg, options: [.prettyPrinted, .sortedKeys]) {
            try? updated.write(to: packageJsonURL)
        }
    }

    /// For Swift/Flutter: write a standalone package.json for the backend/ subdirectory.
    private func ensureStandalonePackageJson(at url: URL, projectId: String, fm: FileManager) {
        guard !fm.fileExists(atPath: url.path) else { return }
        let content = """
        {
          "name": "\(projectId)-backend",
          "version": "1.0.0",
          "scripts": {
            "generate": "teeny generate --local",
            "migrate": "teeny migrate --local",
            "dev": "teeny dev --local",
            "build": "teeny build --local",
            "exec": "teeny exec --local",
            "deploy": "teeny deploy --migrate --remote"
          },
          "devDependencies": {
            "teenybase": "0.0.10"
          }
        }
        """
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Clear lastOpenedAt on all projects
    func clearRecentProjects() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for entry in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let projectId = entry.lastPathComponent
            guard var metadata = readMetadata(projectId: projectId) else { continue }
            metadata.lastOpenedAt = nil
            try? writeMetadata(projectId: projectId, metadata: metadata)
        }
    }
}

enum ProjectOpenError: LocalizedError {
    case notABlitzProject

    var errorDescription: String? {
        switch self {
        case .notABlitzProject:
            return "Not a Blitz project. The selected folder does not contain .blitz/project.json. Use Import to add an external project."
        }
    }
}
