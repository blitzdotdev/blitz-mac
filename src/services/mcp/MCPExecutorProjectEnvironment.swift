import Foundation

extension MCPExecutor {
    // MARK: - Project Tools

    func executeProjectList() async -> [String: Any] {
        await appState.projectManager.loadProjects()
        let projects = await MainActor.run {
            appState.projectManager.projects.map { project -> [String: Any] in
                ["id": project.id, "name": project.name, "path": project.path, "type": project.type.rawValue]
            }
        }
        return mcpJSON(["projects": projects])
    }

    func executeProjectGetActive() async -> [String: Any] {
        let result = await MainActor.run { () -> [String: Any]? in
            guard let project = appState.activeProject else { return nil }
            return ["id": project.id, "name": project.name, "path": project.path, "type": project.type.rawValue]
        }
        if let result {
            return mcpJSON(result)
        }
        return mcpText("No active project")
    }

    func executeProjectOpen(_ args: [String: Any]) async throws -> [String: Any] {
        guard let projectId = args["projectId"] as? String else {
            throw MCPServerService.MCPError.invalidToolArgs
        }
        let storage = ProjectStorage()
        storage.updateLastOpened(projectId: projectId)
        await MainActor.run { appState.activeProjectId = projectId }
        await appState.projectManager.loadProjects()
        return mcpText("Opened project: \(projectId)")
    }

    func executeProjectCreate(_ args: [String: Any]) async throws -> [String: Any] {
        guard let name = args["name"] as? String,
              let typeStr = args["type"] as? String else {
            throw MCPServerService.MCPError.invalidToolArgs
        }

        let storage = ProjectStorage()
        let projectId = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let projectDir = storage.baseDirectory.appendingPathComponent(projectId)

        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let projectType = ProjectType(rawValue: typeStr) ?? .reactNative
        let platformStr = args["platform"] as? String
        let platform = ProjectPlatform(rawValue: platformStr ?? "iOS") ?? .iOS
        let metadata = BlitzProjectMetadata(
            name: name,
            type: projectType,
            platform: platform,
            createdAt: Date(),
            lastOpenedAt: Date()
        )
        try storage.writeMetadata(projectId: projectId, metadata: metadata)
        let (whitelistBlitzMCP, allowASCCLICalls) = await MainActor.run {
            (
                SettingsService.shared.whitelistBlitzMCPTools,
                SettingsService.shared.allowASCCLICalls
            )
        }
        storage.ensureMCPConfig(
            projectId: projectId,
            whitelistBlitzMCP: whitelistBlitzMCP,
            allowASCCLICalls: allowASCCLICalls
        )
        await appState.projectManager.loadProjects()

        await MainActor.run {
            appState.projectSetup.pendingSetupProjectId = projectId
            appState.activeProjectId = projectId
        }

        try? await Task.sleep(for: .seconds(2))
        let setupStarted = await MainActor.run { appState.projectSetup.isSettingUp }
        if !setupStarted {
            guard let project = await MainActor.run(body: { appState.activeProject }) else {
                return mcpText("Created project '\(name)' but could not start setup (project not found)")
            }
            await appState.projectSetup.setup(
                projectId: project.id,
                projectName: project.name,
                projectPath: project.path,
                projectType: project.type,
                platform: project.platform
            )
        } else {
            for _ in 0..<180 {
                let done = await MainActor.run { !appState.projectSetup.isSettingUp }
                if done { break }
                try? await Task.sleep(for: .seconds(1))
            }
        }

        let errorMsg = await MainActor.run { appState.projectSetup.errorMessage }
        if let errorMsg {
            return mcpText("Created project '\(name)' but setup failed: \(errorMsg)")
        }
        return mcpText("Created project '\(name)' (type: \(typeStr), id: \(projectId)) — setup complete")
    }

    func executeProjectImport(_ args: [String: Any]) async throws -> [String: Any] {
        guard let path = args["path"] as? String else {
            throw MCPServerService.MCPError.invalidToolArgs
        }

        let url = URL(fileURLWithPath: path)
        let storage = ProjectStorage()
        let projectId = try storage.openProject(at: url)
        let (whitelistBlitzMCP, allowASCCLICalls) = await MainActor.run {
            (
                SettingsService.shared.whitelistBlitzMCPTools,
                SettingsService.shared.allowASCCLICalls
            )
        }
        storage.ensureMCPConfig(
            projectId: projectId,
            whitelistBlitzMCP: whitelistBlitzMCP,
            allowASCCLICalls: allowASCCLICalls
        )
        await appState.projectManager.loadProjects()
        await MainActor.run { appState.activeProjectId = projectId }

        return mcpText("Imported project from '\(path)' (id: \(projectId))")
    }

    func executeProjectClose() async -> [String: Any] {
        await MainActor.run {
            appState.activeProjectId = nil
            appState.activeTab = .dashboard
        }
        return mcpText("Project closed")
    }

    // MARK: - Simulator Tools

    func executeSimulatorListDevices() async -> [String: Any] {
        await appState.simulatorManager.loadSimulators()
        let devices = await MainActor.run {
            appState.simulatorManager.simulators.map { sim -> [String: Any] in
                [
                    "udid": sim.udid,
                    "name": sim.name,
                    "state": sim.state,
                    "isBooted": sim.isBooted
                ]
            }
        }
        return mcpJSON(["devices": devices])
    }

    func executeSimulatorSelectDevice(_ args: [String: Any]) async throws -> [String: Any] {
        guard let udid = args["udid"] as? String else {
            throw MCPServerService.MCPError.invalidToolArgs
        }

        let service = SimulatorService()
        try await service.boot(udid: udid)
        await MainActor.run { appState.simulatorManager.bootedDeviceId = udid }
        await appState.simulatorManager.loadSimulators()

        return mcpText("Booted simulator: \(udid)")
    }

    // MARK: - Settings Tools

    func executeSettingsGet() async -> [String: Any] {
        let settings = await MainActor.run { () -> [String: Any] in
            [
                "showCursor": appState.settingsStore.showCursor,
                "cursorSize": appState.settingsStore.cursorSize,
                "defaultSimulatorUDID": appState.settingsStore.defaultSimulatorUDID ?? ""
            ]
        }
        return mcpJSON(settings)
    }

    func executeSettingsUpdate(_ args: [String: Any]) async -> [String: Any] {
        await MainActor.run {
            if let cursor = args["showCursor"] as? Bool { appState.settingsStore.showCursor = cursor }
            if let size = args["cursorSize"] as? Double { appState.settingsStore.cursorSize = size }
        }
        return mcpText("Settings updated")
    }

    func executeSettingsSave() async -> [String: Any] {
        await MainActor.run { appState.settingsStore.save() }
        return mcpText("Settings saved to disk")
    }
}
