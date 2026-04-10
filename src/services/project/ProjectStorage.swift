import Foundation

/// High-level facade for project storage, agent config, and scaffolding.
/// Call sites keep using `ProjectStorage`, but responsibilities now live in
/// focused collaborators under `src/services/project`.
struct ProjectStorage {
    let baseDirectory: URL

    private var repository: ProjectRepository {
        ProjectRepository(baseDirectory: baseDirectory)
    }

    private var agentConfigService: ProjectAgentConfigService {
        ProjectAgentConfigService(baseDirectory: baseDirectory)
    }

    init(baseDirectory: URL = BlitzPaths.projects) {
        self.baseDirectory = baseDirectory
    }

    func listProjects() async -> [Project] {
        await repository.listProjects()
    }

    func readMetadata(projectId: String) -> BlitzProjectMetadata? {
        repository.readMetadata(projectId: projectId)
    }

    func writeMetadata(projectId: String, metadata: BlitzProjectMetadata) throws {
        try repository.writeMetadata(projectId: projectId, metadata: metadata)
    }

    func writeMetadataToDirectory(_ dir: URL, metadata: BlitzProjectMetadata) throws {
        try repository.writeMetadataToDirectory(dir, metadata: metadata)
    }

    func deleteProject(projectId: String) throws {
        try repository.deleteProject(projectId: projectId)
    }

    func openProject(at url: URL) throws -> String {
        try repository.openProject(at: url)
    }

    func updateLastOpened(projectId: String) {
        repository.updateLastOpened(projectId: projectId)
    }

    func clearRecentProjects() {
        repository.clearRecentProjects()
    }

    func ensureGlobalMCPConfigs(whitelistBlitzMCP: Bool = true, allowASCCLICalls: Bool = false) {
        agentConfigService.ensureGlobalMCPConfigs(
            whitelistBlitzMCP: whitelistBlitzMCP,
            allowASCCLICalls: allowASCCLICalls
        )
    }

    func ensureAllProjectMCPConfigs(whitelistBlitzMCP: Bool = true, allowASCCLICalls: Bool = false) {
        agentConfigService.ensureAllProjectMCPConfigs(
            whitelistBlitzMCP: whitelistBlitzMCP,
            allowASCCLICalls: allowASCCLICalls
        )
    }

    func ensureMCPConfig(
        projectId: String,
        whitelistBlitzMCP: Bool = true,
        allowASCCLICalls: Bool = false
    ) {
        agentConfigService.ensureMCPConfig(
            projectId: projectId,
            whitelistBlitzMCP: whitelistBlitzMCP,
            allowASCCLICalls: allowASCCLICalls
        )
    }

    func ensureMCPConfig(
        in directory: URL,
        whitelistBlitzMCP: Bool = true,
        allowASCCLICalls: Bool = false,
        includeProjectDocFallback: Bool = true
    ) {
        agentConfigService.ensureMCPConfig(
            in: directory,
            whitelistBlitzMCP: whitelistBlitzMCP,
            allowASCCLICalls: allowASCCLICalls,
            includeProjectDocFallback: includeProjectDocFallback
        )
    }

    func ensureClaudeFiles(
        projectId: String,
        projectType: ProjectType,
        whitelistBlitzMCP: Bool = true,
        allowASCCLICalls: Bool = false
    ) {
        agentConfigService.ensureClaudeFiles(
            projectId: projectId,
            projectType: projectType,
            whitelistBlitzMCP: whitelistBlitzMCP,
            allowASCCLICalls: allowASCCLICalls
        )
    }
}
