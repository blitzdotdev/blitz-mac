import SwiftUI

/// Manages MCP server lifecycle independently of SwiftUI view callbacks.
@MainActor
final class MCPBootstrap {
    static let shared = MCPBootstrap()
    private(set) var server: MCPServerService?
    private var started = false

    func boot(appState: AppState) {
        guard !started else { return }
        started = true

        installMCPHelper()
        installASCEnvironment(settings: appState.settingsStore)
        installClaudeSkills()
        updateIphoneMCP()
        ProjectStorage().ensureGlobalMCPConfigs(
            whitelistBlitzMCP: appState.settingsStore.whitelistBlitzMCPTools,
            allowASCCLICalls: appState.settingsStore.allowASCCLICalls
        )

        let server = MCPServerService(appState: appState)
        self.server = server
        appState.mcpServer = server

        Task.detached {
            do {
                try await server.start()
            } catch {
                print("[MCP] Failed to start server: \(error)")
            }
        }
    }

    func shutdown() {
        guard let server else { return }
        // Fire-and-forget — app is terminating
        Task.detached { await server.stop() }
        // Brief wait to allow cleanup
        Thread.sleep(forTimeInterval: 0.1)
    }

    /// Copies bundled Claude skills to ~/.claude/skills/ so they're globally available.
    /// Overwrites on every launch to keep skills in sync with the app version.
    private func installClaudeSkills() {
        let fm = FileManager.default
        let destRoot = BlitzPaths.claudeSkills

        // Look for embedded skills in the app bundle
        guard let bundleSkills = Bundle.main.resourceURL?
                .appendingPathComponent("claude-skills") else { return }
        guard fm.fileExists(atPath: bundleSkills.path) else { return }

        do {
            try fm.createDirectory(at: destRoot, withIntermediateDirectories: true)
            let skills = try fm.contentsOfDirectory(atPath: bundleSkills.path)
            for skill in skills {
                let src = bundleSkills.appendingPathComponent(skill)
                let dst = destRoot.appendingPathComponent(skill)
                // Remove old version and copy fresh
                try? fm.removeItem(at: dst)
                try fm.copyItem(at: src, to: dst)
            }
        } catch {
            print("[MCP] Failed to install Claude skills: \(error)")
        }
    }

    /// Background-update @blitzdev/iphone-mcp in the bundled Node runtime.
    /// Runs `npm install -g @blitzdev/iphone-mcp@latest` so the binary at
    /// ~/.blitz/node-runtime/bin/iphone-mcp stays current with each app launch.
    private func updateIphoneMCP() {
        let npm = BlitzPaths.nodeDir.appendingPathComponent("npm").path
        guard FileManager.default.isExecutableFile(atPath: npm) else { return }

        Task.detached(priority: .utility) {
            do {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: npm)
                process.arguments = ["install", "-g", "--prefix", BlitzPaths.root.appendingPathComponent("node-runtime").path, "@blitzdev/iphone-mcp@latest"]
                process.environment = [
                    "PATH": "\(BlitzPaths.nodeDir.path):/usr/bin:/bin",
                    "HOME": FileManager.default.homeDirectoryForCurrentUser.path
                ]
                process.standardOutput = nil
                process.standardError = nil
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    print("[MCP] iphone-mcp updated successfully")
                } else {
                    print("[MCP] iphone-mcp update failed (exit \(process.terminationStatus))")
                }
            } catch {
                print("[MCP] iphone-mcp update error: \(error)")
            }
        }
    }

    private func installMCPHelper() {
        let fm = FileManager.default
        let destDir = BlitzPaths.root

        try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        if let sourceURL = bundledMCPHelperURL() {
            try? fm.removeItem(at: BlitzPaths.mcpHelper)
            try? fm.copyItem(at: sourceURL, to: BlitzPaths.mcpHelper)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: BlitzPaths.mcpHelper.path)
        } else {
            print("[MCP] Failed to locate bundled blitz-macos-mcp helper")
        }

        // Keep the old script path working for manually created configs while
        // new project configs point directly at the helper executable.
        let bridgeScript = """
        #!/bin/bash
        HELPER="$HOME/.blitz/blitz-macos-mcp"
        if [ ! -x "$HELPER" ]; then
            echo '{"jsonrpc":"2.0","id":null,"error":{"code":-1,"message":"Blitz MCP helper is not installed. Start Blitz first."}}' >&2
            exit 1
        fi
        exec "$HELPER" "$@"
        """
        try? bridgeScript.write(to: BlitzPaths.mcpBridge, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: BlitzPaths.mcpBridge.path)
    }

    private func installASCEnvironment(settings: SettingsService) {
        try? ASCAuthBridge().installCLIShims()
        try? ShellIntegrationService().sync(enabled: settings.enableASCShellIntegration)
    }

    private func bundledMCPHelperURL() -> URL? {
        let fm = FileManager.default

        let bundledHelper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/blitz-macos-mcp")
        if fm.isExecutableFile(atPath: bundledHelper.path) {
            return bundledHelper
        }

        if let executableURL = Bundle.main.executableURL {
            let siblingHelper = executableURL
                .deletingLastPathComponent()
                .appendingPathComponent("blitz-macos-mcp")
            if fm.isExecutableFile(atPath: siblingHelper.path) {
                return siblingHelper
            }
        }

        return nil
    }
}

final class BlitzAppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let fileMenu = NSApp.mainMenu?.item(withTitle: "File") {
            fileMenu.title = "Project"
        }
        // Set dock icon from bundled resource (needed for swift run / non-.app launches)
        if let icon = Bundle.appResources.image(forResource: "blitz-icon") {
            NSApp.applicationIconImage = icon
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        MCPBootstrap.shared.shutdown()
        // Don't block termination with synchronous simctl shutdown —
        // this prevents macOS TCC "Quit & Reopen" from relaunching the app.
        // Fire-and-forget: let simctl handle cleanup in the background.
        if let udid = appState?.simulatorManager.bootedDeviceId {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["simctl", "shutdown", udid]
            try? process.run()
            // Do NOT call waitUntilExit() — let the app terminate immediately
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if appState?.activeProjectId != nil {
                for window in NSApp.windows where window.canBecomeMain {
                    window.makeKeyAndOrderFront(nil)
                    return false
                }
            }
            for window in NSApp.windows {
                window.makeKeyAndOrderFront(nil)
                return false
            }
        }
        return true
    }
}

@main
struct BlitzApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: BlitzAppDelegate
    @State private var appState = AppState()

    var body: some Scene {
        Window("Welcome to Blitz", id: "welcome") {
            WelcomeWindow(appState: appState)
                .frame(width: 700, height: 440)
                .onAppear {
                    appDelegate.appState = appState
                }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 700, height: 440)
        .commands {
            AppCommands(appState: appState)
        }

        WindowGroup(id: "main", for: String.self) { _ in
            ContentView(appState: appState)
                .frame(minWidth: 800, minHeight: 600)
        }
        .defaultSize(width: 1200, height: 900)
        .windowToolbarStyle(.unified(showsTitle: false))
    }
}
