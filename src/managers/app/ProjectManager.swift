import Foundation

@MainActor
@Observable
final class ProjectManager {
    var projects: [Project] = []
    var isLoading = false
    private var hasTrackedInventory = false

    func loadProjects() async {
        isLoading = true
        defer { isLoading = false }

        let storage = ProjectStorage()
        projects = await storage.listProjects()

        guard !hasTrackedInventory, !projects.isEmpty else { return }
        hasTrackedInventory = true
        for project in projects {
            AnalyticsService.trackProjectInventory(projectType: project.type)
        }
    }
}

@MainActor
@Observable
final class ProjectSetupManager {
    var isSettingUp = false
    var setupProjectId: String?
    var currentStep: ProjectSetupService.SetupStep?
    var errorMessage: String?

    /// Set by NewProjectSheet; consumed by ContentView to trigger setup.
    var pendingSetupProjectId: String?

    /// Scaffold a project using the appropriate template for its type.
    func setup(projectId: String, projectName: String, projectPath: String, projectType: ProjectType = .reactNative, platform: ProjectPlatform = .iOS) async {
        isSettingUp = true
        setupProjectId = projectId
        currentStep = nil
        errorMessage = nil

        do {
            switch (projectType, platform) {
            case (.swift, .macOS):
                try await MacSwiftProjectSetupService.setup(
                    projectId: projectId,
                    projectName: projectName,
                    projectPath: projectPath,
                    onStep: { step in self.currentStep = step }
                )
            case (.swift, .iOS):
                try await SwiftProjectSetupService.setup(
                    projectId: projectId,
                    projectName: projectName,
                    projectPath: projectPath,
                    onStep: { step in self.currentStep = step }
                )
            case (.reactNative, _):
                try await ProjectSetupService.setup(
                    projectId: projectId,
                    projectName: projectName,
                    projectPath: projectPath,
                    onStep: { step in self.currentStep = step }
                )
            case (.flutter, _):
                throw ProjectSetupService.SetupError(message: "Flutter projects are not yet supported")
            }
            // Ensure .mcp.json, CLAUDE.md, .claude/settings.local.json exist
            // (setup recreates the project dir, so these must be written after)
            let storage = ProjectStorage()
            storage.ensureMCPConfig(
                projectId: projectId,
                whitelistBlitzMCP: SettingsService.shared.whitelistBlitzMCPTools,
                allowASCCLICalls: SettingsService.shared.allowASCCLICalls
            )
            storage.ensureClaudeFiles(
                projectId: projectId,
                projectType: projectType,
                whitelistBlitzMCP: SettingsService.shared.whitelistBlitzMCPTools,
                allowASCCLICalls: SettingsService.shared.allowASCCLICalls
            )
            isSettingUp = false
        } catch {
            errorMessage = error.localizedDescription
            isSettingUp = false
        }
    }

    var stepMessage: String {
        if let error = errorMessage { return "Error: \(error)" }
        return currentStep?.rawValue ?? "Preparing..."
    }
}
