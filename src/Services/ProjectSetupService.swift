import Foundation

/// Scaffolds a new Blitz project from the warm template.
/// Handles the full lifecycle: copy template → write .dev.vars → install deps
struct ProjectSetupService {

    enum SetupStep: String {
        case copying = "Copying template..."
        case installingDependencies = "Installing dependencies..."
        case ready = "Ready"
    }

    struct SetupError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let warmTemplatePath: String = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".blitz/warm-template").path
    }()

    private static let sampleDevVars = """
    JWT_SECRET_MAIN=this_is_the_main_secret_used_for_all_tables_and_admin
    JWT_SECRET_USERS=secret_used_for_users_table_appended_to_the_main_secret
    ADMIN_SERVICE_TOKEN=password_for_accessing_the_backend_as_admin
    ADMIN_JWT_SECRET=this_will_be_used_for_jwt_token_for_admin_operations
    POCKET_UI_VIEWER_PASSWORD=admin_db_password_for_readonly_mode
    POCKET_UI_EDITOR_PASSWORD=admin_db_password_for_readwrite_mode
    MAILGUN_API_KEY=api-key-from-mailgun
    API_ROUTE=NA
    """

    /// Whether a warm template is available on disk.
    static var warmTemplateAvailable: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: warmTemplatePath + "/package.json")
    }

    /// Set up a new project from the warm template.
    /// Calls `onStep` on the main actor as each phase begins.
    static func setup(
        projectId: String,
        projectName: String,
        projectPath: String,
        onStep: @MainActor (SetupStep) -> Void
    ) async throws {

        let fm = FileManager.default

        // --- Step 1: Copy warm template ---
        await onStep(.copying)
        print("[setup] Step 1: Copying warm template")
        print("[setup] Warm template path: \(warmTemplatePath)")
        print("[setup] Project path: \(projectPath)")

        guard warmTemplateAvailable else {
            throw SetupError(message: "No warm template found at \(warmTemplatePath)")
        }

        // Back up project metadata before overwriting dir
        let metadataBackup = projectPath + "/.blitz/project.json"
        let metadataData = try? Data(contentsOf: URL(fileURLWithPath: metadataBackup))
        print("[setup] Metadata backed up: \(metadataData != nil)")

        // Remove existing (near-empty) project dir
        if fm.fileExists(atPath: projectPath) {
            try fm.removeItem(atPath: projectPath)
            print("[setup] Removed existing project dir")
        }

        // cp -R warm template → project
        print("[setup] Running: cp -R \(warmTemplatePath) \(projectPath)")
        try await ProcessRunner.run(
            "/bin/cp",
            arguments: ["-R", warmTemplatePath, projectPath],
            timeout: 60
        )
        print("[setup] Template copied")

        // Remove any stale local database state from the template copy
        let localPersist = projectPath + "/.local-persist"
        if fm.fileExists(atPath: localPersist) {
            try? fm.removeItem(atPath: localPersist)
            print("[setup] Removed stale .local-persist")
        }

        // Restore project metadata
        let blitzDir = projectPath + "/.blitz"
        if !fm.fileExists(atPath: blitzDir) {
            try fm.createDirectory(atPath: blitzDir, withIntermediateDirectories: true)
        }
        if let data = metadataData {
            try data.write(to: URL(fileURLWithPath: metadataBackup))
            print("[setup] Metadata restored")
        }

        // Replace __WARM_TEMPLATE__ with project name in package.json and app.json
        replaceInFile(projectPath + "/package.json", "__WARM_TEMPLATE__", projectName)
        replaceInFile(projectPath + "/app.json", "__WARM_TEMPLATE__", projectName)
        print("[setup] Placeholders replaced")

        // Ensure .dev.vars exists
        let devVarsPath = projectPath + "/.dev.vars"
        if !fm.fileExists(atPath: devVarsPath) {
            let sampleVarsPath = projectPath + "/sample.vars"
            if fm.fileExists(atPath: sampleVarsPath) {
                try fm.copyItem(atPath: sampleVarsPath, toPath: devVarsPath)
                print("[setup] .dev.vars copied from sample.vars")
            } else {
                try sampleDevVars.write(toFile: devVarsPath, atomically: true, encoding: .utf8)
                print("[setup] .dev.vars written from default")
            }
        } else {
            print("[setup] .dev.vars already exists")
        }

        // --- Step 2: Install dependencies ---
        await onStep(.installingDependencies)

        let npmPath = try await findNpm()
        print("[setup] Step 2: Installing dependencies (npm: \(npmPath))")
        let env = buildEnv(projectPath: projectPath)

        try await ProcessRunner.run(
            npmPath,
            arguments: ["install", "--prefer-offline"],
            environment: env,
            currentDirectory: projectPath,
            timeout: 120
        )
        print("[setup] npm install done")

        // Migrations are handled by TeenybaseProcessService.start() when the
        // Database tab opens. Running them here is fragile (port conflicts,
        // stale .local-persist state) and redundant.

        // --- Done ---
        await onStep(.ready)
        print("[setup] Project setup complete!")
    }

    // MARK: - Helpers

    private static func findNpm() async throws -> String {
        let candidates = [
            "/opt/homebrew/bin/npm",
            "/usr/local/bin/npm",
            "/usr/bin/npm"
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        do {
            let result = try await ProcessRunner.run("/usr/bin/which", arguments: ["npm"])
            let path = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { return path }
        } catch {}
        throw SetupError(message: "npm not found. Install Node.js.")
    }

    private static func buildEnv(projectPath: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let localBin = projectPath + "/node_modules/.bin"
        if let existing = env["PATH"] {
            env["PATH"] = localBin + ":" + existing
        }
        env["WRANGLER_SEND_METRICS"] = "false"
        return env
    }

    private static func replaceInFile(_ path: String, _ target: String, _ replacement: String) {
        guard var content = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        content = content.replacingOccurrences(of: target, with: replacement)
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
