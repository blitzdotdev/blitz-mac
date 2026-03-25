import Foundation
import os

/// Reads/writes ~/.blitz/settings.json
@MainActor
@Observable
final class SettingsService {
    struct ResolvedTerminalSelection {
        let terminal: TerminalApp
        let replacedMissingTerminal: TerminalApp?
    }

    /// Shared singleton for permission checks from non-UI code (e.g. ApprovalRequest)
    static let shared = SettingsService()
    private static let logger = Logger(subsystem: "com.blitz.macos", category: "Settings")

    private let settingsURL: URL

    var showCursor: Bool = true
    var cursorSize: Double = 20
    var defaultSimulatorUDID: String?

    // Permission toggles: category rawValue → requires approval (default true)
    var permissionToggles: [String: Bool] = [:]

    // Auto-navigate to tab on MCP tool call
    var autoNavEnabled: Bool = true

    // Onboarding
    var hasCompletedOnboarding: Bool = false
    var defaultTerminal: String = "builtIn"   // "builtIn", "terminal", "ghostty", "iterm", or custom path
    var defaultAgentCLI: String = AIAgent.claudeCode.rawValue
    var sendDefaultPrompt: Bool = true
    var skipAgentPermissions: Bool = false
    var whitelistBlitzMCPTools: Bool = true
    var allowASCCLICalls: Bool = false
    var enableASCShellIntegration: Bool = false
    var terminalPosition: String = "bottom"  // "bottom" or "right"

    init() {
        self.settingsURL = BlitzPaths.settings
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let cursor = json["showCursor"] as? Bool { showCursor = cursor }
        if let size = json["cursorSize"] as? Double { cursorSize = size }
        if let udid = json["defaultSimulatorUDID"] as? String { defaultSimulatorUDID = udid }
        if let toggles = json["permissionToggles"] as? [String: Bool] { permissionToggles = toggles }
        if let autoNav = json["autoNavEnabled"] as? Bool { autoNavEnabled = autoNav }
        if let onboarded = json["hasCompletedOnboarding"] as? Bool { hasCompletedOnboarding = onboarded }
        if let term = json["defaultTerminal"] as? String { defaultTerminal = term }
        if let agent = json["defaultAgentCLI"] as? String { defaultAgentCLI = agent }
        if let sendPrompt = json["sendDefaultPrompt"] as? Bool { sendDefaultPrompt = sendPrompt }
        if let skipPerms = json["skipAgentPermissions"] as? Bool { skipAgentPermissions = skipPerms }
        if let whitelist = json["whitelistBlitzMCPTools"] as? Bool { whitelistBlitzMCPTools = whitelist }
        if let allowASCCLI = json["allowASCCLICalls"] as? Bool { allowASCCLICalls = allowASCCLI }
        if let shellIntegration = json["enableASCShellIntegration"] as? Bool { enableASCShellIntegration = shellIntegration }
        if let termPos = json["terminalPosition"] as? String { terminalPosition = termPos }
    }

    func save() {
        var json: [String: Any] = [
            "showCursor": showCursor,
            "cursorSize": cursorSize,
            "autoNavEnabled": autoNavEnabled,
            "hasCompletedOnboarding": hasCompletedOnboarding,
            "defaultTerminal": defaultTerminal,
            "defaultAgentCLI": defaultAgentCLI,
            "sendDefaultPrompt": sendDefaultPrompt,
            "skipAgentPermissions": skipAgentPermissions,
            "whitelistBlitzMCPTools": whitelistBlitzMCPTools,
            "allowASCCLICalls": allowASCCLICalls,
            "enableASCShellIntegration": enableASCShellIntegration,
            "terminalPosition": terminalPosition,
        ]
        if let udid = defaultSimulatorUDID {
            json["defaultSimulatorUDID"] = udid
        }
        if !permissionToggles.isEmpty {
            json["permissionToggles"] = permissionToggles
        }

        guard let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) else { return }

        // Ensure directory exists
        let dir = settingsURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try data.write(to: settingsURL)
        } catch {
            Self.logger.error("Failed to save settings: \(error.localizedDescription)")
        }
    }

    /// Resets stale terminal choices when the selected app is no longer installed.
    @discardableResult
    func resolveDefaultTerminal() -> ResolvedTerminalSelection {
        let configured = TerminalApp.from(defaultTerminal)
        let resolved = configured.resolvedFallback

        guard resolved != configured else {
            return ResolvedTerminalSelection(terminal: resolved, replacedMissingTerminal: nil)
        }

        defaultTerminal = resolved.settingsValue
        save()
        return ResolvedTerminalSelection(terminal: resolved, replacedMissingTerminal: configured)
    }

    func setASCShellIntegrationEnabled(_ enabled: Bool) throws {
        let previousValue = enableASCShellIntegration
        enableASCShellIntegration = enabled
        save()

        do {
            try ShellIntegrationService().sync(enabled: enabled)
        } catch {
            enableASCShellIntegration = previousValue
            save()
            throw error
        }
    }
}
