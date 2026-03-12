import Foundation

/// Manages the Node.js sidecar process and communicates via Unix domain socket
actor NodeSidecarService {
    private var process: ManagedProcess?
    private var httpClient: UnixSocketHTTP?
    private let socketPath: String

    var isRunning: Bool { process?.isRunning ?? false }

    init() {
        self.socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("blitz-\(ProcessInfo.processInfo.processIdentifier).sock").path
    }

    /// Start the Node.js sidecar process
    func start(sidecarPath: String) async throws {
        guard !isRunning else { return }

        // Clean up old socket file
        try? FileManager.default.removeItem(atPath: socketPath)

        // Find node binary
        let nodePath = try await findNode()

        // Start the sidecar with Unix socket
        let proc = ProcessRunner.stream(
            nodePath,
            arguments: [sidecarPath],
            environment: [
                "BLITZ_SOCKET": socketPath,
                "NODE_ENV": "production"
            ],
            onStdout: { line in
                print("[sidecar] \(line)", terminator: "")
            },
            onStderr: { line in
                print("[sidecar:err] \(line)", terminator: "")
            }
        )

        self.process = proc
        self.httpClient = UnixSocketHTTP(socketPath: socketPath)

        // Wait for socket to become available
        try await waitForSocket()
    }

    /// Stop the sidecar process
    func stop() {
        process?.terminate()
        process = nil
        httpClient = nil
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    /// Wait for the Unix socket to become available
    private func waitForSocket() async throws {
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(500))
            if FileManager.default.fileExists(atPath: socketPath) {
                // Try a health check
                do {
                    let response = try await httpClient?.request(method: "GET", path: "/health")
                    if response?.statusCode == 200 { return }
                } catch {
                    continue
                }
            }
        }
        throw SidecarError.startupTimeout
    }

    /// Find the node binary
    private func findNode() async throws -> String {
        // Try common locations — includes ~/.blitz/node-runtime installed by postinstall
        let candidates = [
            BlitzPaths.nodeRuntime.path,
            "/usr/local/bin/node",
            "/opt/homebrew/bin/node",
            "/usr/bin/node"
        ]

        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // Try `which node`
        do {
            let result = try await ProcessRunner.run("/usr/bin/which", arguments: ["node"])
            let path = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { return path }
        } catch {}

        throw SidecarError.nodeNotFound
    }

    // MARK: - Sidecar API

    func createProject(_ request: CreateProjectRequest) async throws -> CreateProjectResponse {
        guard let client = httpClient else { throw SidecarError.notRunning }
        return try await client.post("/projects", body: request)
    }

    func importProject(_ request: ImportProjectRequest) async throws -> CreateProjectResponse {
        guard let client = httpClient else { throw SidecarError.notRunning }
        return try await client.post("/projects/import", body: request)
    }

    func startRuntime(projectId: String, simulatorUDID: String?) async throws {
        guard let client = httpClient else { throw SidecarError.notRunning }
        let request = StartRuntimeRequest(projectId: projectId, simulatorUDID: simulatorUDID)
        try await client.post("/projects/\(projectId)/runtime", body: request)
    }

    func getRuntimeStatus(projectId: String) async throws -> RuntimeStatusResponse {
        guard let client = httpClient else { throw SidecarError.notRunning }
        return try await client.get("/projects/\(projectId)/runtime-status")
    }

    func stopRuntime(projectId: String) async throws {
        guard let client = httpClient else { throw SidecarError.notRunning }
        let empty: [String: String] = [:]
        try await client.post("/projects/\(projectId)/runtime/stop", body: empty)
    }

    func reloadMetro() async throws {
        guard let client = httpClient else { throw SidecarError.notRunning }
        let empty: [String: String] = [:]
        try await client.post("/simulator/reload", body: empty)
    }

    enum SidecarError: Error, LocalizedError {
        case nodeNotFound
        case startupTimeout
        case notRunning

        var errorDescription: String? {
            switch self {
            case .nodeNotFound: return "Node.js not found. Install Node.js to use Blitz."
            case .startupTimeout: return "Sidecar failed to start within timeout"
            case .notRunning: return "Sidecar is not running"
            }
        }
    }
}
