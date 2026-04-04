import BlitzMCPCommon
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

    /// Global MCP configs directory: ~/.blitz/mcps/
    static var mcps: URL { root.appendingPathComponent("mcps") }

    /// Settings file: ~/.blitz/settings.json
    static var settings: URL { root.appendingPathComponent("settings.json") }

    /// User-facing Blitz bin directory: ~/.blitz/bin/
    static var bin: URL { root.appendingPathComponent("bin") }

    /// Shared logs directory: ~/.blitz/logs/
    static var logs: URL { root.appendingPathComponent("logs") }

    /// Analytics state directory: ~/.blitz/analytics/
    static var analytics: URL { root.appendingPathComponent("analytics") }
    static var analyticsDeviceID: URL { analytics.appendingPathComponent("device-id") }

    /// One timestamped directory per app launch, used by the shared debug log.
    static let launchLogSessionName: String = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(formatter.string(from: Date()))-\(ProcessInfo.processInfo.processIdentifier)"
    }()

    static var launchLogDirectory: URL { logs.appendingPathComponent(launchLogSessionName) }
    static var launchLogFile: URL { launchLogDirectory.appendingPathComponent("blitz.log") }

    /// Shell integration directory: ~/.blitz/shell/
    static var shell: URL { root.appendingPathComponent("shell") }

    /// Shell integration entrypoint: ~/.blitz/shell/init.sh
    static var shellInit: URL { shell.appendingPathComponent("init.sh") }

    /// MCP helper executable: ~/.blitz/blitz-macos-mcp
    static var mcpHelper: URL { BlitzMCPTransportPaths.helper }

    /// Compatibility bridge script: ~/.blitz/blitz-mcp-bridge.sh
    static var mcpBridge: URL { BlitzMCPTransportPaths.bridgeScript }

    /// Local Unix socket used by the app-owned MCP executor.
    static var mcpSocket: URL { BlitzMCPTransportPaths.socket }

    /// Local Unix datagram socket for live gesture visualization events.
    static var gestureEventsSocket: URL { root.appendingPathComponent("gesture-events.sock") }

    /// Optional append-only mirror for gesture visualization events.
    static var gestureEventsJSONL: URL { root.appendingPathComponent("gesture-events.jsonl") }

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

    /// Node.js runtime: ~/.blitz/node-runtime/bin/
    static var nodeDir: URL { root.appendingPathComponent("node-runtime/bin") }

    /// Screenshots directory for a project: ~/.blitz/projects/{projectId}/.blitz/screenshots/
    static func screenshots(projectId: String) -> URL {
        projects.appendingPathComponent(projectId).appendingPathComponent(".blitz/screenshots")
    }

    /// Claude skills directory: ~/.claude/skills/
    static var claudeSkills: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/skills")
    }

    /// App Store Review Agent repo URL
    static let reviewerAgentRepo = "https://github.com/blitzdotdev/app-store-review-agent.git"

    /// App Store Connect CLI Skills repo URL
    static let ascSkillsRepo = "https://github.com/rudrankriyam/app-store-connect-cli-skills.git"
}
