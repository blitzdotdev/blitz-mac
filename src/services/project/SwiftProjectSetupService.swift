import Foundation

/// Scaffolds a new Swift/SwiftUI project from the bundled template.
/// Mirrors the logic in blitz-cn's create-swift-project.ts.
struct SwiftProjectSetupService {

    /// Convert a project ID like "my-cool-app" → "MyCoolApp".
    static func toSwiftAppName(_ projectId: String) -> String {
        let parts = projectId.components(separatedBy: CharacterSet.alphanumerics.inverted)
        let camel = parts
            .filter { !$0.isEmpty }
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined()

        // Ensure starts with a letter
        var result = camel
        while let first = result.first, !first.isLetter {
            result = String(result.dropFirst())
        }
        return result.isEmpty ? "App" : result
    }

    /// Derive a bundle ID: "MyCoolApp" → "dev.blitz.MyCoolApp".
    static func toBundleId(_ appName: String) -> String {
        let safe = appName.filter { $0.isLetter || $0.isNumber }
        return "dev.blitz.\(safe.isEmpty ? "App" : safe)"
    }

    /// Set up a new Swift project from the bundled template.
    /// Calls `onStep` on the main actor as each phase begins.
    static func setup(
        projectId: String,
        projectName: String,
        projectPath: String,
        onStep: @MainActor (ProjectSetupService.SetupStep) -> Void
    ) async throws {
        let appName = toSwiftAppName(projectId)
        let bundleId = toBundleId(appName)
        let spec = ProjectTemplateSpec(
            templateName: "swift-hello-template",
            missingTemplateMessage: "Bundled Swift template not found",
            replacements: [
                "__APP_NAME__": appName,
                "__BUNDLE_ID__": bundleId
            ],
            cleanupPaths: [],
            logPrefix: "swift-setup"
        )
        try await ProjectTemplateScaffolder.scaffold(
            spec: spec,
            projectPath: projectPath,
            onStep: onStep
        )
    }
}
