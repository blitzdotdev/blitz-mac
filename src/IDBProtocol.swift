import Foundation

/// Protocol for interacting with idb (iOS Development Bridge)
/// Uses a persistent `idb shell` process for low-latency command execution
actor IDBClient {
    private var shellProcess: Process?
    private var stdinPipe: Pipe?
    private var udid: String?

    init() {}

    /// Resolve the idb binary path — prefer ~/.blitz/python/bin/idb
    private static func resolveIdbPath() -> String {
        if FileManager.default.fileExists(atPath: BlitzPaths.idbPath.path) {
            return BlitzPaths.idbPath.path
        }
        for path in ["/opt/homebrew/bin/idb", "/usr/local/bin/idb"] {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return "/opt/homebrew/bin/idb"
    }

    /// Resolve idb_companion path
    private static func resolveCompanionPath() -> String? {
        if FileManager.default.fileExists(atPath: BlitzPaths.idbCompanionPath.path) {
            return BlitzPaths.idbCompanionPath.path
        }
        // Check homebrew
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/idb_companion") {
            return "/opt/homebrew/bin/idb_companion"
        }
        return nil
    }

    private static let idbPath = resolveIdbPath()
    private static let companionPath = resolveCompanionPath()

    /// Ensure we have a running shell process for the given UDID
    private func ensureShell(udid: String) async throws {
        if self.udid == udid, shellProcess != nil, shellProcess?.isRunning == true {
            return
        }

        // Kill existing shell
        shellProcess?.terminate()
        shellProcess = nil
        stdinPipe = nil

        var args: [String] = []
        if let companionPath = Self.companionPath {
            args.append(contentsOf: ["--companion-path", companionPath])
        }
        args.append(contentsOf: ["shell", "--no-prompt", "--udid", udid])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.idbPath)
        process.arguments = args

        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()

        // Give the shell a moment to initialize
        try await Task.sleep(for: .milliseconds(500))

        self.shellProcess = process
        self.stdinPipe = stdin
        self.udid = udid
    }

    /// Send a command through the shell's stdin
    private func runInShell(udid: String, command: String) async throws {
        try await ensureShell(udid: udid)

        guard let stdin = stdinPipe else {
            throw IDBError.shellNotAvailable
        }

        let data = (command + "\n").data(using: .utf8)!
        stdin.fileHandleForWriting.write(data)
    }

    /// Run a direct idb command (not through shell) and return output
    private func runDirect(_ arguments: [String]) async throws -> String {
        var args: [String] = []
        if let companionPath = Self.companionPath {
            args.append(contentsOf: ["--companion-path", companionPath])
        }
        args.append(contentsOf: arguments)
        return try await ProcessRunner.run(Self.idbPath, arguments: args)
    }

    // MARK: - Device Actions (via persistent shell for speed)

    /// Tap at coordinates
    func tap(udid: String, x: Double, y: Double, duration: Double? = nil) async throws {
        var cmd = "ui tap \(Int(x)) \(Int(y))"
        if let duration {
            cmd += " --duration \(duration)"
        }
        cmd += " --json"
        try await runInShell(udid: udid, command: cmd)
    }

    /// Swipe between points
    func swipe(udid: String, fromX: Double, fromY: Double, toX: Double, toY: Double, duration: Double? = nil, delta: Int? = nil) async throws {
        var cmd = "ui swipe \(Int(fromX)) \(Int(fromY)) \(Int(toX)) \(Int(toY))"
        if let duration {
            cmd += " --duration \(duration)"
        }
        if let delta {
            cmd += " --delta \(delta)"
        }
        cmd += " --json"
        try await runInShell(udid: udid, command: cmd)
    }

    /// Input text
    func inputText(udid: String, text: String) async throws {
        // Manually JSON-encode the string — JSONSerialization rejects bare strings
        // without .fragmentsAllowed, which isn't available on all targets.
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        try await runInShell(udid: udid, command: "ui text \"\(escaped)\" --json")
    }

    /// Press a button (HOME, LOCK, etc.)
    func pressButton(udid: String, button: String) async throws {
        try await runInShell(udid: udid, command: "ui button \(button) --json")
    }

    /// Press a key by HID keycode
    func pressKey(udid: String, keycode: Int, duration: Double? = nil) async throws {
        var cmd = "ui key \(keycode)"
        if let duration {
            cmd += " --duration \(duration)"
        }
        cmd += " --json"
        try await runInShell(udid: udid, command: cmd)
    }

    /// Press a sequence of keys
    func pressKeySequence(udid: String, keys: [Int]) async throws {
        let keyStr = keys.map { String($0) }.joined(separator: " ")
        try await runInShell(udid: udid, command: "ui key-sequence \(keyStr) --json")
    }

    // MARK: - Direct commands (less latency-sensitive)

    /// Describe the full UI hierarchy
    func describeAll(udid: String) async throws -> String {
        try await runDirect(["ui", "describe-all", "--udid", udid])
    }

    /// Describe the element at a specific point
    func describePoint(udid: String, x: Int, y: Int) async throws -> String {
        try await runDirect(["ui", "describe-point", "\(x)", "\(y)", "--udid", udid])
    }

    /// Take a screenshot
    func screenshot(udid: String, path: String) async throws {
        _ = try await runDirect(["screenshot", "--udid", udid, path])
    }

    /// Shutdown the shell when done
    func shutdown() {
        shellProcess?.terminate()
        shellProcess = nil
        stdinPipe = nil
        udid = nil
    }

    enum IDBError: Error, LocalizedError {
        case shellNotAvailable

        var errorDescription: String? {
            switch self {
            case .shellNotAvailable: return "IDB shell process is not available"
            }
        }
    }
}
