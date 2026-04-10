import Foundation

struct ProjectTemplateSpec {
    let templateName: String
    let missingTemplateMessage: String
    let replacements: [String: String]
    let cleanupPaths: [String]
    let logPrefix: String
}

/// Shared template copier used by React Native, Swift, and macOS Swift setup services.
enum ProjectTemplateScaffolder {
    static func scaffold(
        spec: ProjectTemplateSpec,
        projectPath: String,
        onStep: @MainActor (ProjectSetupService.SetupStep) -> Void
    ) async throws {
        let fm = FileManager.default

        await onStep(.copying)
        print("[\(spec.logPrefix)] Copying bundled template")

        guard let templateURL = Bundle.appResources.url(
            forResource: spec.templateName,
            withExtension: nil,
            subdirectory: "templates"
        ) else {
            throw ProjectSetupService.SetupError(message: spec.missingTemplateMessage)
        }

        let metadataPath = projectPath + "/.blitz/project.json"
        let metadataData = try? Data(contentsOf: URL(fileURLWithPath: metadataPath))

        if fm.fileExists(atPath: projectPath) {
            try fm.removeItem(atPath: projectPath)
        }
        try fm.createDirectory(atPath: projectPath, withIntermediateDirectories: true)

        try copyTemplateDir(
            src: templateURL,
            dest: URL(fileURLWithPath: projectPath),
            replacements: spec.replacements
        )

        for cleanupPath in spec.cleanupPaths {
            let absolutePath = URL(fileURLWithPath: projectPath).appendingPathComponent(cleanupPath).path
            if fm.fileExists(atPath: absolutePath) {
                try? fm.removeItem(atPath: absolutePath)
            }
        }

        let blitzDir = projectPath + "/.blitz"
        if !fm.fileExists(atPath: blitzDir) {
            try fm.createDirectory(atPath: blitzDir, withIntermediateDirectories: true)
        }
        if let data = metadataData {
            try data.write(to: URL(fileURLWithPath: metadataPath))
        }

        await onStep(.ready)
        print("[\(spec.logPrefix)] Project setup complete")
    }

    private static func copyTemplateDir(src: URL, dest: URL, replacements: [String: String]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)

        let entries = try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: [.isDirectoryKey])
        for entry in entries {
            let resolvedName = applyReplacements(to: entry.lastPathComponent, replacements: replacements)
            let destPath = dest.appendingPathComponent(resolvedName)

            var isDir: ObjCBool = false
            fm.fileExists(atPath: entry.path, isDirectory: &isDir)

            if isDir.boolValue {
                try copyTemplateDir(src: entry, dest: destPath, replacements: replacements)
            } else {
                var content = try String(contentsOf: entry, encoding: .utf8)
                content = applyReplacements(to: content, replacements: replacements)
                try content.write(to: destPath, atomically: true, encoding: .utf8)
            }
        }
    }

    private static func applyReplacements(to value: String, replacements: [String: String]) -> String {
        replacements.reduce(value) { partialResult, replacement in
            partialResult.replacingOccurrences(of: replacement.key, with: replacement.value)
        }
    }
}
