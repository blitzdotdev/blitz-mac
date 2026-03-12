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

        installBridgeScript()

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

    private func installBridgeScript() {
        let destDir = BlitzPaths.root
        let destFile = BlitzPaths.mcpBridge

        if let bundlePath = Bundle.main.path(forResource: "blitz-mcp-bridge", ofType: "sh") {
            try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destFile)
            try? FileManager.default.copyItem(atPath: bundlePath, toPath: destFile.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destFile.path)
        } else {
            let script = """
            #!/bin/bash
            PORT_FILE="$HOME/.blitz/mcp-port"
            if [ ! -f "$PORT_FILE" ]; then
                echo '{"jsonrpc":"2.0","id":1,"error":{"code":-1,"message":"Blitz is not running."}}' >&2
                exit 1
            fi
            PORT=$(cat "$PORT_FILE")
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                response=$(curl -s -X POST "http://127.0.0.1:${PORT}/mcp" \\
                    -H "Content-Type: application/json" -d "$line" 2>/dev/null)
                if [ $? -ne 0 ]; then
                    echo '{"jsonrpc":"2.0","id":null,"error":{"code":-1,"message":"Cannot connect to Blitz."}}' >&2
                    exit 1
                fi
                echo "$response"
            done
            """
            try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            try? script.write(to: destFile, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destFile.path)
        }
    }
}

final class BlitzAppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let fileMenu = NSApp.mainMenu?.item(withTitle: "File") {
            fileMenu.title = "Project"
        }
        // Set dock icon from bundled resource (needed for swift run / non-.app launches)
        if let icon = Bundle.module.image(forResource: "blitz-icon") {
            NSApp.applicationIconImage = icon
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        MCPBootstrap.shared.shutdown()
        appState?.simulatorManager.shutdownBooted()
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
                    appState.settingsStore.load()
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
        .windowToolbarStyle(.unified(showsTitle: false))
    }
}
