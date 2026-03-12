import Foundation

/// Manages the Teenybase backend process lifecycle: migrate, start, monitor, stop.
@Observable
final class TeenybaseProcessService {
    private(set) var status: TeenybaseStatus = .stopped
    private(set) var port: Int = 8787
    private(set) var errorMessage: String?
    private(set) var logs: [String] = []

    private var process: ManagedProcess?

    enum TeenybaseStatus: String {
        case stopped
        case migrating
        case starting
        case running
        case error
    }

    /// Start the Teenybase backend for a project.
    /// Runs migrations first, then starts the dev server.
    func start(projectPath: String, port: Int = 8787) async {
        guard status == .stopped || status == .error else { return }

        self.port = port
        self.errorMessage = nil
        self.logs = []

        // Validate project has backend
        let packageJsonPath = projectPath + "/package.json"
        guard FileManager.default.fileExists(atPath: packageJsonPath) else {
            status = .error
            errorMessage = "No package.json found. Project may not be fully set up."
            return
        }

        let npmPath: String
        do {
            npmPath = try await findExecutable("npm")
        } catch {
            status = .error
            errorMessage = "npm not found. Install Node.js to use the database."
            return
        }

        let env = buildEnvironment(projectPath: projectPath)

        // Kill anything already on the port
        await killPort(port)

        // Step 1: Run migrations
        status = .migrating
        do {
            try await runMigrations(npmPath: npmPath, projectPath: projectPath, env: env)
        } catch {
            status = .error
            errorMessage = "Migration failed: \(error.localizedDescription)"
            return
        }

        // Step 2: Start dev server
        status = .starting
        let proc = ProcessRunner.stream(
            npmPath,
            arguments: ["run", "dev:backend"],
            environment: env,
            currentDirectory: projectPath,
            onStdout: { [weak self] line in
                DispatchQueue.main.async {
                    self?.appendLog(line)
                }
            },
            onStderr: { [weak self] line in
                DispatchQueue.main.async {
                    self?.appendLog(line)
                }
            }
        )
        self.process = proc

        // Step 3: Wait for server to be healthy
        let healthy = await waitForHealth(port: port, timeout: 30)
        if healthy {
            status = .running
        } else if status == .starting {
            status = .error
            errorMessage = "Backend did not become healthy within 30s"
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        status = .stopped
        errorMessage = nil
    }

    var isRunning: Bool { status == .running }

    var baseURL: String { "http://localhost:\(port)" }

    // MARK: - Private

    private func appendLog(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if logs.count > 500 { logs.removeFirst() }
        logs.append(trimmed)
    }

    private func runMigrations(npmPath: String, projectPath: String, env: [String: String]) async throws {
        try await ProcessRunner.run(
            npmPath,
            arguments: ["run", "migrate:backend", "--", "-y"],
            environment: env,
            currentDirectory: projectPath,
            timeout: 60
        )
    }

    private func buildEnvironment(projectPath: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // Ensure project's local binaries are first in PATH
        let localBin = projectPath + "/node_modules/.bin"
        if let existing = env["PATH"] {
            env["PATH"] = localBin + ":" + existing
        } else {
            env["PATH"] = localBin
        }
        // Standard overrides
        env["TEENY_DEV_PORT"] = String(port)
        env["WRANGLER_SEND_METRICS"] = "false"
        // Load .dev.vars into environment
        loadDevVars(projectPath: projectPath, into: &env)
        return env
    }

    private func loadDevVars(projectPath: String, into env: inout [String: String]) {
        let path = projectPath + "/.dev.vars"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            env[key] = value
        }
    }

    private func waitForHealth(port: Int, timeout: Int) async -> Bool {
        let url = URL(string: "http://localhost:\(port)/api/v1/health")!
        for _ in 0..<(timeout * 2) {
            guard !Task.isCancelled else { return false }
            do {
                try await Task.sleep(for: .milliseconds(500))
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    // Verify it's actually teenybase
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       json["status"] as? String == "ok" {
                        return true
                    }
                }
            } catch {
                continue
            }
        }
        return false
    }

    private func killPort(_ port: Int) async {
        // Use lsof to find PIDs listening on the port, then kill them
        do {
            let result = try await ProcessRunner.run(
                "/usr/sbin/lsof",
                arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"],
                timeout: 5
            )
            let pids = result.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines)
                .filter { !$0.isEmpty }
            for pid in pids {
                _ = try? await ProcessRunner.run("/bin/kill", arguments: ["-9", pid], timeout: 5)
            }
            if !pids.isEmpty {
                try? await Task.sleep(for: .milliseconds(500))
            }
        } catch {
            // No process on port — fine
        }
    }

    private func findExecutable(_ name: String) async throws -> String {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        // Try `which`
        do {
            let result = try await ProcessRunner.run("/usr/bin/which", arguments: [name])
            let path = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty && FileManager.default.fileExists(atPath: path) {
                return path
            }
        } catch {}

        throw TeenybaseProcessError.executableNotFound(name)
    }

    deinit {
        process?.terminate()
    }
}

enum TeenybaseProcessError: LocalizedError {
    case executableNotFound(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let name):
            return "\(name) not found. Install Node.js to use the database."
        }
    }
}
