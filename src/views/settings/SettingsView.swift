import SwiftUI

struct SettingsView: View {
    @Bindable var settings: SettingsService
    @Bindable var appState: AppState
    var mcpServer: MCPServerService?

    @State private var showClearCredentialsConfirm = false
    @State private var showTerminalPicker = false
    @State private var showSkipPermsDetail = false
    @State private var showAskAIDetail = false

    private let gateableCategories: [(ApprovalRequest.ToolCategory, String)] = [
        (.ascFormMutation, "ASC form editing"),
        (.ascScreenshotMutation, "ASC screenshot upload"),
        (.ascSubmitMutation, "ASC submit for review"),
        (.buildPipeline, "Build pipeline"),
        (.projectMutation, "Project mutations"),
        (.settingsMutation, "Settings mutations"),
        (.simulatorControl, "Simulator control"),
    ]

    private var currentTerminal: TerminalApp {
        TerminalApp.from(settings.defaultTerminal)
    }

    private var currentAgent: AIAgent {
        AIAgent(rawValue: settings.defaultAgentCLI) ?? .claudeCode
    }

    var body: some View {
        Form {
            defaultsSection

            Section("Simulator") {
                Toggle("Show Cursor Overlay", isOn: $settings.showCursor)

                if settings.showCursor {
                    HStack {
                        Text("Cursor Size")
                        Slider(value: $settings.cursorSize, in: 10...40, step: 2)
                        Text("\(Int(settings.cursorSize))px")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }

            Section("Permissions") {
                Toggle("Auto-navigate to tab on tool call", isOn: $settings.autoNavEnabled)
                    .onChange(of: settings.autoNavEnabled) { _, _ in settings.save() }

                Toggle("Approve all", isOn: Binding(
                    get: {
                        gateableCategories.allSatisfy { settings.permissionToggles[$0.0.rawValue] ?? false }
                    },
                    set: { newValue in
                        for (category, _) in gateableCategories {
                            settings.permissionToggles[category.rawValue] = newValue
                        }
                        settings.save()
                    }
                ))
                .fontWeight(.medium)

                ForEach(gateableCategories, id: \.0.rawValue) { category, label in
                    Toggle(label, isOn: Binding(
                        get: { settings.permissionToggles[category.rawValue] ?? false },
                        set: { newValue in
                            settings.permissionToggles[category.rawValue] = newValue
                            settings.save()
                        }
                    ))
                }
            }

            MCPSetupSection(mcpServer: mcpServer)

            Section("Updates") {
                UpdateSettingsRow(autoUpdate: appState.autoUpdate)
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("App Store Connect Credentials")
                        Spacer()
                        if appState.ascManager.credentials != nil {
                            Text("Configured")
                                .font(.callout)
                                .foregroundStyle(.green)
                        } else {
                            Text("Not set")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button("Clear Credentials", role: .destructive) {
                        showClearCredentialsConfirm = true
                    }
                    .disabled(appState.ascManager.credentials == nil)

                    Text("This will remove your saved API key, Key ID, and Issuer ID. You will need to re-enter them to use App Store Connect features.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Danger Zone")
            }
            .confirmationDialog(
                "Clear App Store Connect Credentials?",
                isPresented: $showClearCredentialsConfirm,
                titleVisibility: .visible
            ) {
                Button("Clear Credentials", role: .destructive) {
                    if let projectId = appState.ascManager.loadedProjectId {
                        appState.ascManager.deleteCredentials(projectId: projectId)
                    }
                }
            } message: {
                Text("This action cannot be undone. You will need to re-enter your API credentials to access App Store Connect data.")
            }

            Section("About") {
                HStack {
                    Text("Blitz")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 500)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(
            isPresented: $showTerminalPicker,
            allowedContentTypes: [.application]
        ) { result in
            if case .success(let url) = result {
                settings.defaultTerminal = TerminalApp.custom(url.path).settingsValue
                settings.save()
            }
        }
    }

    // MARK: - Defaults Section

    private var defaultsSection: some View {
        Section("Defaults") {
            // Terminal picker
            HStack {
                Text("Terminal")
                Spacer()
                Menu {
                    terminalMenuItem(.terminal)

                    if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") != nil {
                        terminalMenuItem(.ghostty)
                    }

                    if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil {
                        terminalMenuItem(.iterm)
                    }

                    Divider()

                    Button("Choose Custom...") {
                        showTerminalPicker = true
                    }
                } label: {
                    HStack(spacing: 4) {
                        terminalAppIcon(currentTerminal, size: 16)
                        Text(currentTerminal.displayName)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            // Agent CLI picker
            HStack {
                Text("AI Agent")
                Spacer()
                Menu {
                    ForEach(AIAgent.allCases, id: \.rawValue) { agent in
                        Button {
                            settings.defaultAgentCLI = agent.rawValue
                            UserDefaults.standard.set(agent.rawValue, forKey: "selectedAIAgent")
                            settings.save()
                        } label: {
                            HStack {
                                Image(nsImage: agent.icon(size: 16))
                                Text(agent.displayName)
                                if currentAgent == agent { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(nsImage: currentAgent.icon(size: 16))
                        Text(currentAgent.displayName)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            // Send default prompt toggle
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Send tab-specific prompt on launch", isOn: Binding(
                    get: { settings.sendDefaultPrompt },
                    set: { newValue in
                        settings.sendDefaultPrompt = newValue
                        settings.save()
                    }
                ))

                learnMore(isExpanded: $showAskAIDetail) {
                    Text("When you click \"Ask AI\", Blitz launches \(currentAgent.displayName) in \(currentTerminal.displayName). Right-click the button to open the panel instead.")
                }
            }

            // Skip permissions toggle (only for agents that support it)
            if currentAgent.skipPermissionsFlag != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Skip agent permissions", isOn: Binding(
                        get: { settings.skipAgentPermissions },
                        set: { newValue in
                            settings.skipAgentPermissions = newValue
                            settings.save()
                        }
                    ))

                    learnMore(isExpanded: $showSkipPermsDetail) {
                        Text("Launches \(currentAgent.displayName) with \(currentAgent.skipPermissionsFlag ?? ""). The agent will not ask for confirmation before running tools.")
                    }
                }
            }
        }
    }

    private func learnMore<Content: View>(isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                    Text("Learn more...")
                }
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded.wrappedValue {
                content()
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func terminalMenuItem(_ terminal: TerminalApp) -> some View {
        Button {
            settings.defaultTerminal = terminal.settingsValue
            settings.save()
        } label: {
            HStack {
                terminalAppIcon(terminal, size: 16)
                Text(terminal.displayName)
                if currentTerminal == terminal { Image(systemName: "checkmark") }
            }
        }
    }

    @ViewBuilder
    private func terminalAppIcon(_ terminal: TerminalApp, size: CGFloat) -> some View {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminal.bundleIdentifier) {
            let icon = Self.resizedIcon(NSWorkspace.shared.icon(forFile: appURL.path), size: size)
            Image(nsImage: icon)
        } else if case .custom(let path) = terminal {
            let icon = Self.resizedIcon(NSWorkspace.shared.icon(forFile: path), size: size)
            Image(nsImage: icon)
        } else {
            Image(systemName: "terminal")
                .frame(width: size, height: size)
        }
    }

    /// Resize an NSImage to an exact pixel size so SwiftUI renders it at a consistent size.
    private static func resizedIcon(_ image: NSImage, size: CGFloat) -> NSImage {
        let s = NSSize(width: size, height: size)
        let resized = NSImage(size: s)
        resized.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: s),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy, fraction: 1)
        resized.unlockFocus()
        resized.isTemplate = false
        return resized
    }
}
