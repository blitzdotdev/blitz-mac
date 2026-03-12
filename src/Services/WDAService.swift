import Foundation

/// Manages WebDriverAgent lifecycle for physical device interaction
actor WDAService {
    private var wdaProcess: ManagedProcess?
    private(set) var sessionId: String?
    private(set) var isRunning = false

    let port: Int

    init(port: Int = 8100) {
        self.port = port
    }

    /// Build and install WDA on a physical device
    func start(deviceUDID: String) async throws {
        guard !isRunning else { return }

        // Build WDA
        let wdaProject = findWDAProject()
        guard let projectPath = wdaProject else {
            throw WDAServiceError.wdaProjectNotFound
        }

        let proc = ProcessRunner.stream(
            "xcodebuild",
            arguments: [
                "build-for-testing",
                "-project", projectPath,
                "-scheme", "WebDriverAgentRunner",
                "-destination", "id=\(deviceUDID)",
                "-derivedDataPath", "/tmp/blitz-wda-build",
                "USE_PORT=\(port)"
            ],
            onStdout: { line in
                print("[WDA:build] \(line)", terminator: "")
            },
            onStderr: { line in
                print("[WDA:build:err] \(line)", terminator: "")
            }
        )

        await proc.waitUntilExit()

        // Launch WDA test runner
        let runner = ProcessRunner.stream(
            "xcodebuild",
            arguments: [
                "test-without-building",
                "-project", projectPath,
                "-scheme", "WebDriverAgentRunner",
                "-destination", "id=\(deviceUDID)",
                "-derivedDataPath", "/tmp/blitz-wda-build"
            ],
            onStdout: { line in
                print("[WDA:run] \(line)", terminator: "")
            },
            onStderr: { line in
                print("[WDA:run:err] \(line)", terminator: "")
            }
        )

        self.wdaProcess = runner
        self.isRunning = true

        // Wait for WDA to become responsive
        try await waitForWDA()

        // Create a session
        let client = WDAClient(port: port)
        self.sessionId = try await client.createSession()
    }

    /// Stop WDA
    func stop() {
        wdaProcess?.terminate()
        wdaProcess = nil
        sessionId = nil
        isRunning = false
    }

    /// Health check
    func healthCheck() async -> Bool {
        let client = WDAClient(port: port)
        return (try? await client.healthCheck()) ?? false
    }

    private func waitForWDA() async throws {
        let client = WDAClient(port: port)
        for _ in 0..<60 { // 30 seconds
            try await Task.sleep(for: .milliseconds(500))
            if (try? await client.healthCheck()) == true {
                return
            }
        }
        throw WDAServiceError.startupTimeout
    }

    private func findWDAProject() -> String? {
        // Look in common locations
        let candidates = [
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.blitz/WebDriverAgent/WebDriverAgent.xcodeproj",
            "/usr/local/lib/node_modules/appium/node_modules/appium-webdriveragent/WebDriverAgent.xcodeproj",
        ]

        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        return nil
    }

    enum WDAServiceError: Error, LocalizedError {
        case wdaProjectNotFound
        case startupTimeout

        var errorDescription: String? {
            switch self {
            case .wdaProjectNotFound: return "WebDriverAgent project not found"
            case .startupTimeout: return "WDA failed to start within timeout"
            }
        }
    }
}
