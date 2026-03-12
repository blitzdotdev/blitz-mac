import Foundation

/// Central source of truth for all ~/.blitz/ paths used across the app.
/// Every file that needs a .blitz path should use these instead of hardcoding.
enum BlitzPaths {
    /// Root: ~/.blitz/
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".blitz")
    }

    /// Projects directory: ~/.blitz/projects/
    static var projects: URL { root.appendingPathComponent("projects") }

    /// Settings file: ~/.blitz/settings.json
    static var settings: URL { root.appendingPathComponent("settings.json") }

    /// MCP port file: ~/.blitz/mcp-port
    static var mcpPort: URL { root.appendingPathComponent("mcp-port") }

    /// MCP bridge script: ~/.blitz/blitz-mcp-bridge.sh
    static var mcpBridge: URL { root.appendingPathComponent("blitz-mcp-bridge.sh") }

    /// Signing base directory: ~/.blitz/signing/
    static var signing: URL { root.appendingPathComponent("signing") }

    /// Signing directory for a specific bundle ID
    static func signing(bundleId: String) -> URL {
        signing.appendingPathComponent(bundleId)
    }

    /// Python idb path: ~/.blitz/python/bin/idb
    static var idbPath: URL { root.appendingPathComponent("python/bin/idb") }

    /// idb companion path: ~/.blitz/idb-companion/bin/idb_companion
    static var idbCompanionPath: URL {
        root.appendingPathComponent("idb-companion/bin/idb_companion")
    }

    /// Node runtime: ~/.blitz/node-runtime/bin/node
    static var nodeRuntime: URL {
        root.appendingPathComponent("node-runtime/bin/node")
    }
}
