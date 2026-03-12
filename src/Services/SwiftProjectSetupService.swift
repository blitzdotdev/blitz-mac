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

        let fm = FileManager.default
        let appName = toSwiftAppName(projectId)
        let bundleId = toBundleId(appName)

        // --- Step 1: Copy & patch template ---
        await onStep(.copying)
        print("[swift-setup] Scaffolding: appName=\(appName) bundleId=\(bundleId)")

        guard let templateURL = Bundle.module.url(forResource: "swift-hello-template", withExtension: nil, subdirectory: "Templates") else {
            throw ProjectSetupService.SetupError(message: "Bundled Swift template not found")
        }

        // Back up project metadata before overwriting dir
        let metadataPath = projectPath + "/.blitz/project.json"
        let metadataData = try? Data(contentsOf: URL(fileURLWithPath: metadataPath))

        // Remove existing (near-empty) project dir
        if fm.fileExists(atPath: projectPath) {
            try fm.removeItem(atPath: projectPath)
        }
        try fm.createDirectory(atPath: projectPath, withIntermediateDirectories: true)

        // Recursively copy template, replacing placeholders in names & contents
        try copyTemplateDir(
            src: templateURL.path,
            dest: projectPath,
            appName: appName,
            bundleId: bundleId
        )

        // Restore project metadata
        let blitzDir = projectPath + "/.blitz"
        if !fm.fileExists(atPath: blitzDir) {
            try fm.createDirectory(atPath: blitzDir, withIntermediateDirectories: true)
        }
        if let data = metadataData {
            try data.write(to: URL(fileURLWithPath: metadataPath))
        }

        print("[swift-setup] Template copied and patched")

        // No npm install needed for Swift projects — go straight to ready
        await onStep(.ready)
        print("[swift-setup] Project setup complete!")
    }

    // MARK: - Helpers

    private static let appNamePlaceholder = "__APP_NAME__"
    private static let bundleIdPlaceholder = "__BUNDLE_ID__"

    /// Recursively copy a template directory, replacing placeholders in
    /// filenames/directory names and file contents.
    private static func copyTemplateDir(
        src: String,
        dest: String,
        appName: String,
        bundleId: String
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: dest, withIntermediateDirectories: true)

        let entries = try fm.contentsOfDirectory(atPath: src)
        for entry in entries {
            let resolvedName = entry.replacingOccurrences(of: appNamePlaceholder, with: appName)
            let srcPath = src + "/" + entry
            let destPath = dest + "/" + resolvedName

            var isDir: ObjCBool = false
            fm.fileExists(atPath: srcPath, isDirectory: &isDir)

            if isDir.boolValue {
                try copyTemplateDir(src: srcPath, dest: destPath, appName: appName, bundleId: bundleId)
            } else {
                var content = try String(contentsOfFile: srcPath, encoding: .utf8)
                content = content
                    .replacingOccurrences(of: appNamePlaceholder, with: appName)
                    .replacingOccurrences(of: bundleIdPlaceholder, with: bundleId)
                try content.write(toFile: destPath, atomically: true, encoding: .utf8)
            }
        }
    }
}
