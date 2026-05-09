import Foundation

// MARK: - App Shots Manager
// Wraps `asc app-shots` CLI commands for screenshot generation via templates and themes.

extension ASCManager {

    // MARK: - Models

    struct AppShotTemplate: Codable, Identifiable, Sendable {
        let id: String
        let name: String
        let category: String
        let description: String
        let deviceCount: Int
        let palette: Palette?

        struct Palette: Codable, Sendable {
            let id: String
            let name: String
            let background: String?
        }
    }

    struct AppShotTheme: Codable, Identifiable, Sendable {
        let id: String
        let name: String
        let icon: String
        let description: String
        let accent: String?
        let previewGradient: String?
    }

    // MARK: - Templates

    /// List available screenshot templates from `asc app-shots templates list`.
    nonisolated static func appShotsTemplatesList() async throws -> [AppShotTemplate] {
        let output = try await ProcessRunner.run(
            "asc",
            arguments: ["app-shots", "templates", "list", "--output", "json"]
        )
        let json = extractJSON(from: output)
        let data = Data(json.utf8)
        let wrapper = try JSONDecoder().decode(DataWrapper<[AppShotTemplate]>.self, from: data)
        return wrapper.data
    }

    /// Apply a template to a screenshot, producing a PNG.
    /// Returns the path to the generated image.
    nonisolated static func appShotsTemplatesApply(
        templateId: String,
        screenshot: String,
        headline: String,
        subtitle: String? = nil,
        tagline: String? = nil,
        appName: String? = nil,
        imageOutput: String? = nil
    ) async throws -> String {
        var args = [
            "app-shots", "templates", "apply",
            "--id", templateId,
            "--screenshot", screenshot,
            "--headline", headline,
            "--preview", "image",
        ]
        if let subtitle { args += ["--subtitle", subtitle] }
        if let tagline { args += ["--tagline", tagline] }
        if let appName { args += ["--app-name", appName] }
        if let imageOutput { args += ["--image-output", imageOutput] }

        let output = try await ProcessRunner.run("asc", arguments: args, timeout: 60)
        // The CLI prints the output path or JSON with the path
        return parseImageOutputPath(from: output, fallback: imageOutput)
    }

    /// Get a single template's preview HTML via `asc app-shots templates get --id <id> --preview`.
    nonisolated static func appShotsTemplatePreviewHTML(templateId: String) async throws -> String {
        try await ProcessRunner.run(
            "asc",
            arguments: ["app-shots", "templates", "get", "--id", templateId, "--preview"],
            timeout: 30
        )
    }

    /// Apply a template to a screenshot, returning composed HTML (not PNG).
    nonisolated static func appShotsTemplatesApplyHTML(
        templateId: String,
        screenshot: String,
        headline: String,
        subtitle: String? = nil,
        tagline: String? = nil,
        appName: String? = nil
    ) async throws -> String {
        var args = [
            "app-shots", "templates", "apply",
            "--id", templateId,
            "--screenshot", screenshot,
            "--headline", headline,
            "--preview", "html",
        ]
        if let subtitle { args += ["--subtitle", subtitle] }
        if let tagline { args += ["--tagline", tagline] }
        if let appName { args += ["--app-name", appName] }

        return try await ProcessRunner.run("asc", arguments: args, timeout: 60)
    }

    // MARK: - Themes

    /// List available visual themes from `asc app-shots themes list`.
    nonisolated static func appShotsThemesList() async throws -> [AppShotTheme] {
        let output = try await ProcessRunner.run(
            "asc",
            arguments: ["app-shots", "themes", "list", "--output", "json"]
        )
        let json = extractJSON(from: output)
        let data = Data(json.utf8)
        let wrapper = try JSONDecoder().decode(DataWrapper<[AppShotTheme]>.self, from: data)
        return wrapper.data
    }

    /// Apply a theme to a template with a screenshot, producing a PNG.
    /// Returns the path to the generated image.
    nonisolated static func appShotsThemesApply(
        themeId: String,
        templateId: String,
        screenshot: String,
        headline: String? = nil,
        subtitle: String? = nil,
        tagline: String? = nil,
        canvasWidth: Int? = nil,
        canvasHeight: Int? = nil,
        imageOutput: String? = nil
    ) async throws -> String {
        var args = [
            "app-shots", "themes", "apply",
            "--theme", themeId,
            "--template", templateId,
            "--screenshot", screenshot,
            "--preview", "image",
        ]
        if let headline { args += ["--headline", headline] }
        if let subtitle { args += ["--subtitle", subtitle] }
        if let tagline { args += ["--tagline", tagline] }
        if let canvasWidth { args += ["--canvas-width", "\(canvasWidth)"] }
        if let canvasHeight { args += ["--canvas-height", "\(canvasHeight)"] }
        if let imageOutput { args += ["--image-output", imageOutput] }

        let output = try await ProcessRunner.run("asc", arguments: args, timeout: 300)
        return parseImageOutputPath(from: output, fallback: imageOutput)
    }

    // MARK: - Generate (Gemini AI Enhance)

    /// Enhance a screenshot using Gemini AI via `asc app-shots generate`.
    /// Returns the path to the enhanced image.
    nonisolated static func appShotsGenerate(
        file: String,
        outputDir: String? = nil,
        styleReference: String? = nil,
        deviceType: String? = nil,
        prompt: String? = nil,
        model: String? = nil
    ) async throws -> String {
        var args = ["app-shots", "generate", "--file", file, "--output", "json"]
        if let outputDir { args += ["--output-dir", outputDir] }
        if let styleReference { args += ["--style-reference", styleReference] }
        if let deviceType { args += ["--device-type", deviceType] }
        if let prompt { args += ["--prompt", prompt] }
        if let model { args += ["--model", model] }

        let output = try await ProcessRunner.run("asc", arguments: args, timeout: 180)
        return parseGenerateOutput(from: output)
    }

    // MARK: - Export (HTML → PNG)

    /// Render an HTML file to PNG via `asc app-shots export`.
    /// Returns the path to the exported PNG.
    nonisolated static func appShotsExport(
        html: String,
        output: String? = nil,
        width: Int? = nil,
        height: Int? = nil
    ) async throws -> String {
        var args = ["app-shots", "export", "--html", html]
        if let output { args += ["--output", output] }
        if let width { args += ["--width", "\(width)"] }
        if let height { args += ["--height", "\(height)"] }

        let result = try await ProcessRunner.run("asc", arguments: args, timeout: 60)
        return parseImageOutputPath(from: result, fallback: output)
    }

    // MARK: - Helpers

    private struct DataWrapper<T: Decodable>: Decodable {
        let data: T
    }

    /// Extract JSON from CLI output that may contain plugin loading stderr lines.
    nonisolated private static func extractJSON(from output: String) -> String {
        // The JSON is the last line that starts with `{`
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("{") {
                return trimmed
            }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parse the image output path from CLI output.
    nonisolated private static func parseImageOutputPath(from output: String, fallback: String?) -> String {
        // Extract JSON from output (may have plugin loading lines before it)
        let jsonStr = extractJSON(from: output)
        if let data = jsonStr.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let path = json["outputPath"] as? String { return resolvePath(path) }
            if let path = json["exported"] as? String { return resolvePath(path) }
            if let path = json["path"] as? String { return resolvePath(path) }
            if let path = json["output"] as? String { return resolvePath(path) }
        }
        // Check each line for a file path
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        for line in trimmed.split(separator: "\n").reversed() {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasSuffix(".png") && (l.hasPrefix("/") || l.hasPrefix(".")) {
                return resolvePath(l)
            }
        }
        return fallback ?? trimmed
    }

    /// Resolve a potentially relative path to absolute.
    nonisolated private static func resolvePath(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        if path.hasPrefix("~") { return (path as NSString).expandingTildeInPath }
        // Relative path — resolve from home directory
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(path).path
    }

    /// Parse the generate command output for the enhanced image path.
    nonisolated private static func parseGenerateOutput(from output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let path = json["outputPath"] as? String { return path }
            if let files = json["files"] as? [String], let first = files.first { return first }
        }
        return parseImageOutputPath(from: trimmed, fallback: nil)
    }
}
