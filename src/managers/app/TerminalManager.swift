import Foundation
import AppKit

struct TerminalStartupProcess {
    let executable: String
    let args: [String]
    let execName: String?
}

/// A single terminal session backed by a pseudo-terminal process.
/// The `terminalView` is created once and reused across show/hide cycles.
@MainActor
final class TerminalSession: Identifiable {
    let id = UUID()
    var title: String
    let terminalView: BlitzTerminalView
    private(set) var isTerminated = false

    init(
        title: String,
        projectPath: String?,
        startupProcess: TerminalStartupProcess? = nil,
        onTerminated: @escaping (UUID) -> Void,
        onTitleChanged: @escaping (UUID, String) -> Void
    ) {
        self.title = title

        let termView = BlitzTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        termView.nativeBackgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        termView.nativeForegroundColor = NSColor.white
        termView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        self.terminalView = termView

        let sessionId = id
        termView.onProcessTerminated = { _ in onTerminated(sessionId) }
        termView.onTitleChanged = { newTitle in onTitleChanged(sessionId, newTitle) }

        let cwd: String
        if let path = projectPath, FileManager.default.fileExists(atPath: path) {
            cwd = path
        } else {
            cwd = FileManager.default.homeDirectoryForCurrentUser.path
        }

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var env = ProcessInfo.processInfo.environment
        if startupProcess != nil {
            env = LoginShellEnvironment.mergedEnvironment(
                baseEnvironment: env,
                shellPath: shell
            )
        }
        env["TERM"] = "xterm-256color"
        let authEnvironment = ASCAuthBridge().environmentOverrides(forLaunchPath: projectPath)
        for (key, value) in authEnvironment {
            env[key] = value
        }
        if startupProcess != nil {
            for (key, value) in AnalyticsService.agentSessionEnvironment() {
                env[key] = value
            }
        }
        let envPairs = env.map { "\($0.key)=\($0.value)" }

        if let startupProcess {
            // Launch built-in AI sessions directly under the PTY instead of typing into a shell.
            // This removes shell startup noise and avoids parent-shell job-control interference.
            termView.startProcess(
                executable: startupProcess.executable,
                args: startupProcess.args,
                environment: envPairs,
                execName: startupProcess.execName,
                currentDirectory: cwd
            )
        } else {
            let shellName = (shell as NSString).lastPathComponent
            termView.startProcess(
                executable: shell,
                args: ["-l"],
                environment: envPairs,
                execName: "-\(shellName)",
                currentDirectory: cwd
            )
        }
    }

    func terminate() {
        guard !isTerminated else { return }
        isTerminated = true
        terminalView.terminate()
    }

    func markTerminated() {
        isTerminated = true
    }

    /// Send a command string to the shell (types it and presses Enter).
    func sendCommand(_ command: String) {
        guard !isTerminated else { return }
        let data = Array((command + "\n").utf8)
        terminalView.send(source: terminalView, data: data[...])
    }
}

/// Manages terminal session lifecycle. Lives on AppState to persist across all views.
@MainActor
@Observable
final class TerminalManager {
    var sessions: [TerminalSession] = []
    var activeSessionId: UUID?

    private var sessionCounter = 0

    nonisolated static func agentStartupProcess(
        agent: AIAgent,
        prompt: String? = nil,
        skipPermissions: Bool = false
    ) -> TerminalStartupProcess {
        var commandParts = [shellQuote(agent.cliCommand)]
        if skipPermissions, let flag = agent.skipPermissionsFlag {
            commandParts.append(shellQuote(flag))
        }
        if let prompt, !prompt.isEmpty {
            commandParts.append(shellQuote(prompt))
        }

        let script = guardedStartupScript(command: commandParts.joined(separator: " "))

        return TerminalStartupProcess(
            executable: "/bin/sh",
            args: ["-c", script],
            execName: "/bin/sh"
        )
    }

    nonisolated static func guardedStartupScript(command: String) -> String {
        """
        cleanup() {
            status=$?
            trap - EXIT HUP INT TERM
            kill -HUP 0 >/dev/null 2>&1 || true
            kill -TERM 0 >/dev/null 2>&1 || true
            wait >/dev/null 2>&1 || true
            exit "$status"
        }
        trap cleanup EXIT HUP INT TERM
        /usr/bin/python3 - <<'PY' &
        import os
        import signal
        import time

        stop = False
        parent_pid = os.getppid()
        leader = os.getpgrp()

        def end(*_):
            global stop
            stop = True

        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(sig, end)

        while not stop:
            if os.getppid() != parent_pid:
                break
            try:
                current = os.tcgetpgrp(0)
                if current != leader:
                    os.tcsetpgrp(0, leader)
            except Exception:
                pass
            time.sleep(0.05)
        PY
        \(command)
        """
    }

    nonisolated private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    var activeSession: TerminalSession? {
        guard let id = activeSessionId else { return nil }
        return sessions.first { $0.id == id }
    }

    @discardableResult
    func createSession(projectPath: String?) -> TerminalSession {
        sessionCounter += 1
        let session = TerminalSession(
            title: "Terminal \(sessionCounter)",
            projectPath: projectPath,
            onTerminated: { [weak self] id in
                self?.sessions.first { $0.id == id }?.markTerminated()
            },
            onTitleChanged: { [weak self] id, newTitle in
                self?.sessions.first { $0.id == id }?.title = newTitle
            }
        )
        sessions.append(session)
        activeSessionId = session.id
        return session
    }

    @discardableResult
    func createAgentSession(
        projectPath: String?,
        agent: AIAgent,
        prompt: String? = nil,
        skipPermissions: Bool = false
    ) -> TerminalSession {
        sessionCounter += 1

        let session = TerminalSession(
            title: "\(agent.displayName) \(sessionCounter)",
            projectPath: projectPath,
            startupProcess: Self.agentStartupProcess(
                agent: agent,
                prompt: prompt,
                skipPermissions: skipPermissions
            ),
            onTerminated: { [weak self] id in
                self?.sessions.first { $0.id == id }?.markTerminated()
            },
            onTitleChanged: { [weak self] id, newTitle in
                self?.sessions.first { $0.id == id }?.title = newTitle
            }
        )
        sessions.append(session)
        activeSessionId = session.id
        return session
    }

    func closeSession(_ id: UUID) {
        sessions.first { $0.id == id }?.terminate()
        sessions.removeAll { $0.id == id }
        if activeSessionId == id {
            activeSessionId = sessions.last?.id
        }
    }

    func closeAllSessions() {
        sessions.forEach { $0.terminate() }
        sessions.removeAll()
        activeSessionId = nil
        sessionCounter = 0
    }
}
