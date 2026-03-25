import SwiftUI

enum AIAgent: String, CaseIterable {
    case claudeCode = "claude-code"
    case codex = "codex"
    case opencode = "opencode"

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        }
    }

    var cliCommand: String {
        switch self {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        case .opencode: return "opencode"
        }
    }

    /// Flag to skip interactive permission prompts, or nil if not supported.
    var skipPermissionsFlag: String? {
        switch self {
        case .claudeCode: return "--dangerously-skip-permissions"
        case .codex: return "--dangerously-bypass-approvals-and-sandbox"
        case .opencode: return nil
        }
    }

    /// Resource name for the agent's icon PNG (bundled in src/resources/).
    var iconResourceName: String {
        switch self {
        case .claudeCode: return "claude-code-icon"
        case .codex: return "codex-icon"
        case .opencode: return "opencode-icon"
        }
    }

    /// Load the agent's icon from the app bundle resources, with iOS-style rounded corners.
    /// Corner radius uses the standard iOS ratio (~0.158 of the icon size).
    func icon(size: CGFloat) -> NSImage {
        guard let src = Bundle.appResources.image(forResource: iconResourceName) else {
            return NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
                ?? NSImage()
        }
        let s = NSSize(width: size, height: size)
        let radius = size * (9.0 / 57.0) // iOS icon corner radius ratio
        let result = NSImage(size: s)
        result.lockFocus()
        let path = NSBezierPath(roundedRect: NSRect(origin: .zero, size: s), xRadius: radius, yRadius: radius)
        path.addClip()
        src.draw(in: NSRect(origin: .zero, size: s),
                 from: NSRect(origin: .zero, size: src.size),
                 operation: .copy, fraction: 1)
        result.unlockFocus()
        result.isTemplate = false
        return result
    }
}

struct ConnectAIPopover: View {
    let projectPath: String?
    let activeTab: AppTab

    @AppStorage("selectedAIAgent") private var selectedAgent: String = AIAgent.claudeCode.rawValue
    @State private var copiedCommand = false
    @State private var copiedPrompt = false

    private var agent: AIAgent {
        AIAgent(rawValue: selectedAgent) ?? .claudeCode
    }

    private var command: String {
        TerminalLauncher.buildAgentCommand(
            projectPath: projectPath,
            agent: agent
        )
    }

    private var tabPrompt: String? {
        Self.prompt(for: activeTab)
    }

    /// Tab-specific default prompt, shared with TerminalLauncher.
    static func prompt(for tab: AppTab) -> String? {
        switch tab {
        case .dashboard:
            return nil
        case .app:
            return "Help me complete all the steps needed to submit my app to the App Store."
        case .storeListing:
            return "Help me write a compelling App Store listing — name, subtitle, description, and keywords."
        case .screenshots:
            return "Help me take and upload App Store screenshots for my app."
        case .appDetails:
            return "Help me fill in my app's details — category, copyright, and content rights."
        case .monetization:
            return "Help me set up monetization — pricing, subscriptions, or in-app purchases."
        case .review:
            return "Help me complete the age rating and review contact info for App Store review."
        case .analytics:
            return "Help me understand my app's analytics and performance."
        case .reviews:
            return "Help me review and respond to customer reviews."
        case .builds:
            return "Help me build and upload my app to TestFlight."
        case .groups:
            return "Help me set up TestFlight beta groups and add testers."
        case .betaInfo:
            return "Help me write the TestFlight beta description and contact info."
        case .feedback:
            return "Help me review TestFlight beta feedback."
        case .settings:
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect AI")
                .font(.headline)

            // Agent type selector
            Picker("Agent", selection: $selectedAgent) {
                ForEach(AIAgent.allCases, id: \.rawValue) { agent in
                    Text(agent.displayName).tag(agent.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            // Generic command
            HStack(spacing: 8) {
                Text(command)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))

                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copiedCommand = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedCommand = false }
                }) {
                    Image(systemName: copiedCommand ? "checkmark" : "doc.on.doc")
                }
                .help("Copy to clipboard")
            }

            Text("Run this in your terminal to connect \(agent.displayName) to this project.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Tab-specific prompt
            if let prompt = tabPrompt {
                Divider()

                Text("Suggested prompt")
                    .font(.subheadline.weight(.medium))

                HStack(spacing: 8) {
                    Text(prompt)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))

                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(prompt, forType: .string)
                        copiedPrompt = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedPrompt = false }
                    }) {
                        Image(systemName: copiedPrompt ? "checkmark" : "doc.on.doc")
                    }
                    .help("Copy prompt to clipboard")
                }
            }
        }
        .padding()
        .frame(width: 360)
    }
}
