import Foundation

/// Async wrapper around Process for running shell commands
struct ProcessRunner: Sendable {

    init() {}

    struct ProcessError: Error, LocalizedError {
        let command: String
        let exitCode: Int32
        let stderr: String

        init(command: String, exitCode: Int32, stderr: String) {
            self.command = command
            self.exitCode = exitCode
            self.stderr = stderr
        }

        var errorDescription: String? {
            "Command '\(command)' failed with exit code \(exitCode): \(stderr)"
        }
    }

    /// Run a command and return stdout
    ///
    /// - Note: Pipe reads happen on background threads concurrently with the process
    ///   to avoid deadlocks when the pipe buffer (64KB) fills up.
    @discardableResult
    static func run(
        _ executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: String? = nil,
        // TODO: timeout is accepted for API compatibility but is not enforced
        timeout: TimeInterval = 30
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            if let env = environment {
                var processEnv = ProcessInfo.processInfo.environment
                for (key, value) in env {
                    processEnv[key] = value
                }
                process.environment = processEnv
            }

            if let dir = currentDirectory {
                process.currentDirectoryURL = URL(fileURLWithPath: dir)
            }

            // Use a DispatchGroup to wait for both pipe reads AND process termination.
            // Pipes must be drained on background threads BEFORE the process exits,
            // otherwise the process can block waiting for the pipe buffer to drain
            // while we only start reading after termination — a classic deadlock.
            let group = DispatchGroup()

            var stdoutResult = ""
            var stderrResult = ""

            // Read stdout on a background thread
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                stdoutResult = String(data: data, encoding: .utf8) ?? ""
                group.leave()
            }

            // Read stderr on a background thread
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                stderrResult = String(data: data, encoding: .utf8) ?? ""
                group.leave()
            }

            // Wait for process termination
            group.enter()
            process.terminationHandler = { _ in
                group.leave()
            }

            do {
                try process.run()
            } catch {
                // Process failed to launch. The pipes will return empty data
                // immediately since nothing is writing to them, so the background
                // reads will complete on their own. We still need to wait for
                // the group to avoid resuming the continuation twice.
                group.notify(queue: .global(qos: .userInitiated)) {
                    continuation.resume(throwing: error)
                }
                return
            }

            // Once all three (stdout read, stderr read, termination) are done, resume
            group.notify(queue: .global(qos: .userInitiated)) {
                if process.terminationStatus == 0 {
                    continuation.resume(returning: stdoutResult)
                } else {
                    continuation.resume(throwing: ProcessError(
                        command: "\(executable) \(arguments.joined(separator: " "))",
                        exitCode: process.terminationStatus,
                        stderr: stderrResult.isEmpty ? stdoutResult : stderrResult
                    ))
                }
            }
        }
    }

    /// Run a command and stream stdout/stderr line by line.
    /// Check `ManagedProcess.launchError` after calling to detect launch failures.
    static func stream(
        _ executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: String? = nil,
        onStdout: @escaping @Sendable (String) -> Void,
        onStderr: @escaping @Sendable (String) -> Void
    ) -> ManagedProcess {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if let env = environment {
            var processEnv = ProcessInfo.processInfo.environment
            for (key, value) in env {
                processEnv[key] = value
            }
            process.environment = processEnv
        }

        if let dir = currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: dir)
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            onStdout(line)
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            onStderr(line)
        }

        var launchErr: Error?
        do {
            try process.run()
        } catch {
            launchErr = error
        }

        return ManagedProcess(process: process, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe, launchError: launchErr)
    }
}

/// A running process that can be terminated
final class ManagedProcess: @unchecked Sendable {
    let process: Process
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe

    /// Non-nil if the process failed to launch
    let launchError: Error?

    init(process: Process, stdoutPipe: Pipe, stderrPipe: Pipe, launchError: Error? = nil) {
        self.process = process
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        self.launchError = launchError
    }

    var isRunning: Bool { process.isRunning }

    /// Whether the process was successfully started
    var didLaunch: Bool { launchError == nil && process.processIdentifier != 0 }

    func terminate() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
        }
    }

    /// Wait for the process to exit. Returns immediately if the process never launched.
    func waitUntilExit() async {
        // If the process never started, return immediately
        guard didLaunch else { return }

        // Use Process.waitUntilExit() on a background queue to avoid race conditions
        // with terminationHandler + isRunning check
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { [process] in
                process.waitUntilExit()
                continuation.resume()
            }
        }
    }

    deinit {
        terminate()
    }
}
