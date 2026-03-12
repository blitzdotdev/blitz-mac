import Foundation

/// Filesystem operations for ~/.blitz/projects/
struct ProjectStorage {
    let baseDirectory: URL

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
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }

            // Skip warm template directories
            if entry.lastPathComponent.hasPrefix(".blitz-template-warm-") { continue }

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

    /// Write project metadata
    func writeMetadata(projectId: String, metadata: BlitzProjectMetadata) throws {
        let projectDir = baseDirectory.appendingPathComponent(projectId)
        let blitzDir = projectDir.appendingPathComponent(".blitz")
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

    /// Ensure .mcp.json contains blitz-macos and blitz-iphone MCP server entries.
    /// If the file exists, merges into the existing mcpServers key without overwriting other entries.
    /// If it doesn't exist, creates it.
    func ensureMCPConfig(projectId: String) {
        let projectDir = baseDirectory.appendingPathComponent(projectId)
        let mcpFile = projectDir.appendingPathComponent(".mcp.json")
        let bridgePath = BlitzPaths.mcpBridge.path

        let blitzMacosEntry: [String: Any] = [
            "command": "bash",
            "args": [bridgePath]
        ]
        let blitzIphoneEntry: [String: Any] = [
            "command": "npx",
            "args": ["-y", "@blitzdev/iphone-mcp"]
        ]

        var root: [String: Any]
        if let data = try? Data(contentsOf: mcpFile),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
            var servers = root["mcpServers"] as? [String: Any] ?? [:]
            servers["blitz-macos"] = blitzMacosEntry
            servers["blitz-iphone"] = blitzIphoneEntry
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
    }

    /// Ensure CLAUDE.md and .claude/settings.local.json exist for a project.
    /// Mirrors the server-side ensureClaudeFiles() logic.
    func ensureClaudeFiles(projectId: String, projectType: ProjectType) {
        let fm = FileManager.default
        let projectDir = baseDirectory.appendingPathComponent(projectId)

        // 1. .claude/settings.local.json
        let claudeDir = projectDir.appendingPathComponent(".claude")
        let settingsFile = claudeDir.appendingPathComponent("settings.local.json")
        if !fm.fileExists(atPath: settingsFile.path) {
            try? fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
            let settings: [String: Any] = [
                "permissions": [
                    "allow": [
                        "Bash(curl:*)",
                        "Bash(xcrun simctl terminate:*)",
                        "Bash(xcrun simctl launch:*)",
                        "mcp__blitz-macos__get_project_state",
                    ]
                ],
                "enabledMcpjsonServers": ["blitz-macos", "blitz-iphone"],
            ]
            if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: settingsFile)
            }
        }

        // 2. CLAUDE.md — load from bundled template
        let claudeMdFile = projectDir.appendingPathComponent("CLAUDE.md")
        if !fm.fileExists(atPath: claudeMdFile.path) {
            let content = Self.claudeMdContent(projectType: projectType)
            try? content.write(to: claudeMdFile, atomically: true, encoding: .utf8)
        }
    }

    private static func claudeMdContent(projectType: ProjectType) -> String {
        guard let templateURL = Bundle.module.url(forResource: "CLAUDE.md", withExtension: "template"),
              var template = try? String(contentsOf: templateURL, encoding: .utf8) else {
            return "# Blitz AI Agent Guide\n"
        }

        let header = projectType == .swift
            ? "Swift Project — Blitz AI Agent Guide"
            : "React Native Project — Blitz AI Agent Guide"
        template = template.replacingOccurrences(of: "{{PROJECT_TYPE_HEADER}}", with: header)

        let rnWarnings = projectType == .reactNative
            ? "- **Do not run `xcodebuild` or `react-native run-ios`** — Blitz handles builds\n- **Do not start Metro** (`npx react-native start`) — Blitz runs Metro automatically\n"
            : ""
        template = template.replacingOccurrences(of: "{{REACT_NATIVE_BUILD_WARNINGS}}\n", with: rnWarnings)

        let metroSection = projectType == .reactNative
            ? """

            ### Metro Bundler

            Metro is managed automatically by Blitz. **DO NOT start your own Metro server** — it will conflict.
            - `.blitz/metro.json` contains the active Metro port and bundle URL
            - `.blitz/metro.log` contains Metro/app logs (including console.log from your app)
            """
            : ""
        template = template.replacingOccurrences(of: "{{METRO_SECTION}}", with: metroSection)

        return template
    }

    /// Clear lastOpenedAt on all projects
    func clearRecentProjects() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            if entry.lastPathComponent.hasPrefix(".blitz-template-warm-") { continue }

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
