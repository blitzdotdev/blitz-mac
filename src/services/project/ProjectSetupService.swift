import Foundation

/// Scaffolds a new React Native / Blitz project from the bundled template.
/// Handles the full lifecycle: copy template → patch placeholders.
/// Dependency install, runtime setup, and builds are handled by the user's agent.
struct ProjectSetupService {

    enum SetupStep: String {
        case copying = "Copying template..."
        case ready = "Ready"
    }

    struct SetupError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let projectNamePlaceholder = "__PROJECT_NAME__"

    /// Set up a new project from the bundled RN template.
    /// Calls `onStep` on the main actor as each phase begins.
    static func setup(
        projectId: String,
        projectName: String,
        projectPath: String,
        onStep: @MainActor (SetupStep) -> Void
    ) async throws {
        let spec = ProjectTemplateSpec(
            templateName: "rn-notes-template",
            missingTemplateMessage: "Bundled RN template not found",
            replacements: [projectNamePlaceholder: projectName],
            cleanupPaths: [],
            logPrefix: "setup"
        )
        try await ProjectTemplateScaffolder.scaffold(
            spec: spec,
            projectPath: projectPath,
            onStep: onStep
        )
    }
}
