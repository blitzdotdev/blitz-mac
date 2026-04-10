import Foundation

/// Scaffolds a new macOS Swift/SwiftUI project from the bundled template.
/// Sandboxed by default for Mac App Store submission.
struct MacSwiftProjectSetupService {

    /// Set up a new macOS Swift project from the bundled template.
    static func setup(
        projectId: String,
        projectName: String,
        projectPath: String,
        onStep: @MainActor (ProjectSetupService.SetupStep) -> Void
    ) async throws {
        let appName = SwiftProjectSetupService.toSwiftAppName(projectId)
        let bundleId = SwiftProjectSetupService.toBundleId(appName)
        let spec = ProjectTemplateSpec(
            templateName: "swift-mac-template",
            missingTemplateMessage: "Bundled macOS Swift template not found",
            replacements: [
                "__APP_NAME__": appName,
                "__BUNDLE_ID__": bundleId
            ],
            cleanupPaths: [],
            logPrefix: "mac-swift-setup"
        )
        try await ProjectTemplateScaffolder.scaffold(
            spec: spec,
            projectPath: projectPath,
            onStep: onStep
        )
    }
}
