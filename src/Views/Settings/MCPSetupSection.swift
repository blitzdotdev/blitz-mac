import SwiftUI

/// Settings section showing MCP server status and Claude Code config
struct MCPSetupSection: View {
    let mcpServer: MCPServerService?

    @State private var serverPort: Int = 0
    @State private var serverRunning: Bool = false
    @State private var copied = false

    var body: some View {
        Section("Claude Code (MCP)") {
            HStack {
                Text("MCP Server")
                Spacer()
                if serverRunning {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                        Text("Running on port \(serverPort)")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                        Text("Not running")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Button {
                copyConfigToClipboard()
            } label: {
                HStack {
                    Text(copied ? "Copied!" : "Copy Config to Clipboard")
                    Spacer()
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            Text("Add the copied JSON to ~/.claude.json under \"mcpServers\" to connect Claude Code to Blitz.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .task {
            await refreshStatus()
        }
    }

    private func refreshStatus() async {
        guard let server = mcpServer else { return }
        serverPort = await server.port
        serverRunning = await server.isRunning
    }

    private func copyConfigToClipboard() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let config = """
        {
          "blitz-macos": {
            "command": "bash",
            "args": ["\(home)/.blitz/blitz-mcp-bridge.sh"]
          }
        }
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(config, forType: .string)

        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copied = false
        }
    }
}
