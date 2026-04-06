import AVKit
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

/// Terminal app options for onboarding configuration
enum TerminalApp: Hashable {
    case builtIn
    case terminal
    case ghostty
    case iterm
    case custom(String)

    var id: String {
        switch self {
        case .builtIn: return "builtIn"
        case .terminal: return "terminal"
        case .ghostty: return "ghostty"
        case .iterm: return "iterm"
        case .custom(let path): return path
        }
    }

    var displayName: String {
        switch self {
        case .builtIn: return "Terminal (built-in)"
        case .terminal: return "Terminal (external)"
        case .ghostty: return "Ghostty (external)"
        case .iterm: return "iTerm (external)"
        case .custom(let path):
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            return "\(name) (external)"
        }
    }

    /// Name without the "(external)" suffix — used in onboarding disclosure.
    var shortDisplayName: String {
        switch self {
        case .builtIn: return "Built-in Terminal"
        case .terminal: return "Terminal"
        case .ghostty: return "Ghostty"
        case .iterm: return "iTerm"
        case .custom(let path):
            return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }
    }

    var iconName: String {
        switch self {
        case .builtIn: return "terminal"
        case .terminal: return "terminal"
        case .ghostty: return "terminal"
        case .iterm: return "terminal"
        case .custom: return "terminal"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .builtIn: return ""
        case .terminal: return "com.apple.Terminal"
        case .ghostty: return "com.mitchellh.ghostty"
        case .iterm: return "com.googlecode.iterm2"
        case .custom(let path): return path
        }
    }

    var isBuiltIn: Bool {
        if case .builtIn = self { return true }
        return false
    }

    var isAvailable: Bool {
        switch self {
        case .builtIn: return true
        case .custom(let path):
            return FileManager.default.fileExists(atPath: path)
        default:
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
        }
    }

    /// Missing saved terminals fall back to built-in so launches still work.
    var resolvedFallback: TerminalApp {
        isAvailable ? self : .builtIn
    }

    /// Persist to settings as a string
    var settingsValue: String { id }

    /// Restore from settings string
    static func from(_ value: String) -> TerminalApp {
        switch value {
        case "builtIn": return .builtIn
        case "terminal": return .terminal
        case "ghostty": return .ghostty
        case "iterm": return .iterm
        default: return .custom(value)
        }
    }
}

struct OnboardingView: View {
    @Bindable var appState: AppState
    var onComplete: () -> Void

    @State private var currentStep = 0
    @State private var selectedTerminal: TerminalApp = .builtIn
    @State private var selectedAgent: AIAgent = .claudeCode
    @State private var detectedTerminals: [TerminalApp] = []
    @State private var showCustomPicker = false
    @State private var showExternalTerminals = false
    // These default to true and are no longer shown in onboarding UI
    @State private var skipAgentPermissions: Bool = true
    @State private var whitelistBlitzMCPTools: Bool = true
    @State private var allowASCCLICalls: Bool = true

    init(appState: AppState, onComplete: @escaping () -> Void) {
        self.appState = appState
        self.onComplete = onComplete
    }

    // ASC setup state
    @State private var ascIssuerId = ""
    @State private var ascKeyId = ""
    @State private var ascPrivateKey = ""
    @State private var ascPrivateKeyFileName: String?
    @State private var ascShowFilePicker = false
    @State private var ascIsSaving = false
    @State private var ascSaveError: String?
    @State private var ascSaveSuccess = false
    @State private var ascShowInstructions = false

    private var ascIsValid: Bool {
        !ascIssuerId.trimmingCharacters(in: .whitespaces).isEmpty &&
        !ascKeyId.trimmingCharacters(in: .whitespaces).isEmpty &&
        !ascPrivateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // Permissions state
    @State private var screenRecordingGranted = false
    @State private var screenRecordingChecking = false

    /// Skip the ASC slide if credentials are already configured (or just saved during onboarding)
    private var skipASCSlide: Bool {
        ascSaveSuccess || ASCCredentials.load() != nil
    }

    // Steps: config, [asc setup], import, ask ai, [permissions]
    // ASC slide is skipped if credentials already exist; permissions skipped if already granted
    private var totalSteps: Int {
        var count = 3 // config + import + ask ai
        if !skipASCSlide { count += 1 }
        if !screenRecordingGranted { count += 1 }
        return count
    }

    /// Map a logical step index to the actual slide, accounting for skipped slides
    private func slideForStep(_ step: Int) -> Int {
        var slide = step
        // slide 0 = config (always)
        // slide 1 = asc setup (maybe skipped)
        if skipASCSlide && slide >= 1 {
            slide += 1 // skip over ASC
        }
        return slide
    }

    var body: some View {
        VStack(spacing: 0) {
            // Content area
            Group {
                switch slideForStep(currentStep) {
                case 0:
                    configurationStep
                case 1:
                    slideASCSetup
                case 2:
                    slideImportProject
                case 3:
                    slideAskAI
                case 4:
                    slidePermissions
                default:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Bottom bar with dots and buttons
            bottomBar
        }
        .frame(width: 700, height: 440)
        .background(.ultraThickMaterial)
        .task {
            detectedTerminals = detectTerminals()
            if let first = detectedTerminals.first {
                selectedTerminal = first
            }
            screenRecordingGranted = CGPreflightScreenCaptureAccess()
        }
        .onChange(of: appState.ascManager.pendingCredentialValues) { _, pending in
            if let pending {
                ascIssuerId = pending["issuerId"] ?? ""
                ascKeyId = pending["keyId"] ?? ""
                ascPrivateKey = pending["privateKey"] ?? ""
                ascPrivateKeyFileName = pending["privateKeyFileName"]
                appState.ascManager.pendingCredentialValues = nil
                // Jump to ASC slide so user can verify
                if currentStep != 1 {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        currentStep = 1
                    }
                }
            }
        }
    }

    // MARK: - Step 0: Configuration

    private var configurationStep: some View {
        HStack(spacing: 0) {
            // Left: icon + title
            VStack(spacing: 20) {
                Spacer()

                if let icon = Bundle.appResources.image(forResource: "blitz-icon") {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 80, height: 80)
                } else if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 80, height: 80)
                }

                VStack(spacing: 4) {
                    Text("Welcome to Blitz")
                        .font(.system(size: 24, weight: .bold))
                    Text("Let's get you set up")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .frame(width: 700 * 0.38)
            .background(.regularMaterial)

            // Right: configuration options
            ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                // Agent CLI selection (first — most users care about this)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Default AI Agent")
                        .font(.headline)

                    VStack(spacing: 2) {
                        ForEach(AIAgent.allCases, id: \.rawValue) { agent in
                            agentRow(agent)
                        }
                    }
                }

                // Skip permissions toggle (only if agent supports it)
                if selectedAgent.skipPermissionsFlag != nil {
                    Toggle(isOn: $skipAgentPermissions) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Skip agent permissions")
                                .font(.callout)
                            Text("Launch with \(selectedAgent.skipPermissionsFlag ?? "")")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                Divider()

                // Terminal selection
                VStack(alignment: .leading, spacing: 6) {
                    Text("Terminal")
                        .font(.headline)

                    // Built-in (recommended) — always shown
                    terminalRow(.builtIn, label: "Built-in Terminal (recommended)")

                    // External terminals — collapsed under clickable header
                    VStack(alignment: .leading, spacing: 2) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showExternalTerminals.toggle()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .rotationEffect(.degrees(showExternalTerminals ? 90 : 0))
                                Text("Use external terminal")
                                    .font(.callout)
                            }
                            .foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 10)
                        .padding(.vertical, 4)

                        if showExternalTerminals {
                            ForEach(externalTerminals, id: \.self) { terminal in
                                terminalRow(terminal, label: terminal.shortDisplayName)
                            }

                            Button {
                                showCustomPicker = true
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "folder")
                                        .frame(width: 20)
                                    Text("Choose Custom...")
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            }
            .frame(maxWidth: .infinity)
        }
        .fileImporter(
            isPresented: $showCustomPicker,
            allowedContentTypes: [.application]
        ) { result in
            if case .success(let url) = result {
                let custom = TerminalApp.custom(url.path)
                if !detectedTerminals.contains(where: { $0.id == custom.id }) {
                    detectedTerminals.append(custom)
                }
                selectedTerminal = custom
            }
        }
    }

    private var externalTerminals: [TerminalApp] {
        detectedTerminals.filter { !$0.isBuiltIn }
    }

    private func terminalRow(_ terminal: TerminalApp, label: String? = nil) -> some View {
        let isSelected = selectedTerminal == terminal
        return Button {
            selectedTerminal = terminal
        } label: {
            HStack(spacing: 10) {
                terminalIcon(for: terminal)
                    .frame(width: 20, height: 20)
                Text(label ?? terminal.displayName)
                    .font(.body)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func terminalIcon(for terminal: TerminalApp) -> some View {
        if terminal.isBuiltIn {
            Image(systemName: "terminal.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminal.bundleIdentifier) {
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else if case .custom(let path) = terminal {
            let icon = NSWorkspace.shared.icon(forFile: path)
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "terminal")
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
    }

    private func agentRow(_ agent: AIAgent) -> some View {
        let isSelected = selectedAgent == agent
        return Button {
            selectedAgent = agent
        } label: {
            HStack(spacing: 10) {
                Image(nsImage: agent.icon(size: 20))
                    .frame(width: 20, height: 20)
                Text(agent.displayName)
                    .font(.body)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Slide header (shared between slides 1 & 2)

    private func slideHeader(title: String, subtitle: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 20, weight: .bold))

            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 500)
        }
        .padding(.top, 2)
    }

    // MARK: - Slide 1: App Store Connect Setup

    @ViewBuilder
    private var slideASCSetup: some View {
        if ascSaveSuccess {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)
                Text("Credentials saved")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        } else {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 14) {
                // Header
                VStack(spacing: 4) {
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.blue)

                    Text("App Store Connect")
                        .font(.system(size: 20, weight: .bold))

                    Text("Connect your API key to manage submissions, screenshots, and more.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }

                // Form fields
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Issuer ID")
                            .font(.callout.weight(.medium))
                        TextField("xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx", text: $ascIssuerId)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Key ID")
                            .font(.callout.weight(.medium))
                        TextField("10-character alphanumeric", text: $ascKeyId)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Private Key (.p8)")
                            .font(.callout.weight(.medium))
                        HStack(spacing: 8) {
                            Button {
                                ascShowFilePicker = true
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "doc.badge.plus")
                                    Text(ascPrivateKeyFileName ?? "Choose .p8 File…")
                                }
                            }
                            .font(.callout)

                            if ascPrivateKeyFileName != nil {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.body)
                            }

                            Spacer()

                            Button {
                                saveASCCredentials()
                            } label: {
                                if ascIsSaving {
                                    ProgressView()
                                        .controlSize(.small)
                                        .padding(.horizontal, 8)
                                } else {
                                    Text("Save Credentials")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!ascIsValid || ascIsSaving)
                        }
                    }

                    if let error = ascSaveError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: 440)

                // Action links
                VStack(spacing: 4) {
                    Button {
                        launchASCSetupWithAI()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                            Text("Setup with AI")
                            Image(systemName: "arrow.right")
                                .font(.caption)
                        }
                        .font(.callout.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)

                    Link(destination: URL(string: "https://appstoreconnect.apple.com/access/integrations/api")!) {
                        HStack(spacing: 6) {
                            Image(systemName: "key")
                            Text("Setup manually")
                            Image(systemName: "arrow.right")
                                .font(.caption)
                        }
                        .font(.callout.weight(.medium))
                    }

                    // Collapsible instructions
                    VStack(alignment: .leading, spacing: 0) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                ascShowInstructions.toggle()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .rotationEffect(.degrees(ascShowInstructions ? 90 : 0))
                                Text("How to generate your API key")
                                    .font(.caption.weight(.medium))
                            }
                            .foregroundStyle(.blue)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if ascShowInstructions {
                            VStack(alignment: .leading, spacing: 6) {
                                ascInstructionStep(1, "Go to **App Store Connect > Users and Access > Integrations > App Store Connect API**")
                                ascInstructionStep(2, "Select the **Team Keys** tab (not Individual Keys)")
                                ascInstructionStep(3, "Click the **+** button to generate a new key")
                                ascInstructionStep(4, "Set Access to **Admin** and give the key a name")
                                ascInstructionStep(5, "Click **Generate**")
                                ascInstructionStep(6, "Copy the **Issuer ID** (shown at the top) and the **Key ID** from the key row")
                                ascInstructionStep(7, "Click **Download** to save the .p8 file")
                                Text("The .p8 file can only be downloaded once. Store it securely.")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .padding(.leading, 20)
                            }
                            .padding(.top, 6)
                        }
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(
            isPresented: $ascShowFilePicker,
            allowedContentTypes: [UTType(filenameExtension: "p8") ?? .data]
        ) { result in
            if case .success(let url) = result {
                if url.startAccessingSecurityScopedResource() {
                    defer { url.stopAccessingSecurityScopedResource() }
                    ascPrivateKey = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                    ascPrivateKeyFileName = url.lastPathComponent
                }
            }
        }
        } // else
    }

    @ViewBuilder
    private func ascInstructionStep(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(number).")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .trailing)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func saveASCCredentials() {
        ascIsSaving = true
        ascSaveError = nil
        let creds = ASCCredentials(
            issuerId: ascIssuerId.trimmingCharacters(in: .whitespaces),
            keyId: ascKeyId.trimmingCharacters(in: .whitespaces),
            privateKey: ascPrivateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        Task {
            do {
                try creds.save()
                withAnimation(.easeInOut(duration: 0.3)) {
                    ascSaveSuccess = true
                }
            } catch {
                ascSaveError = error.localizedDescription
            }
            ascIsSaving = false
        }
    }

    /// Resolve the terminal for onboarding context where the built-in split pane
    /// is unavailable due to the small window size.
    private var onboardingTerminal: TerminalApp {
        let resolved = selectedTerminal.resolvedFallback
        guard resolved.isBuiltIn else { return resolved }
        // Built-in can't render in the onboarding window — fall back to Terminal.app
        return .terminal
    }

    private func launchASCSetupWithAI() {
        let agent = selectedAgent
        let terminal = onboardingTerminal
        let prompt = "Use the /asc-team-key-create skill to create a new App Store Connect API key, then call the asc_set_credentials MCP tool to fill the form so I can verify and save."
        TerminalLauncher.launch(
            projectPath: BlitzPaths.mcps.path,
            agent: agent,
            terminal: terminal,
            prompt: prompt,
            skipPermissions: skipAgentPermissions
        )
    }

    // MARK: - Slide 2: Import Project (was Slide 1)

    private var slideImportProject: some View {
        VStack(spacing: 6) {
            slideHeader(
                title: "Import Your Project",
                subtitle: "Use an existing Flutter, Swift, or React Native project. Or create a new project."
            )

            OnboardingVideoPlayer(resourceName: "ImportDemo")
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
        }
    }

    // MARK: - Slide 3: Ask AI

    private var slideAskAI: some View {
        VStack(spacing: 6) {
            slideHeader(
                title: "Open \(selectedAgent.displayName) in Blitz",
                subtitle: "Click the terminal icon anywhere to launch \(selectedAgent.displayName). Select your project in the dashboard and ask it to submit your app to the App Store."
            )

            // Demo video — transparent background, aspect fit
            OnboardingVideoPlayer(resourceName: "OpenTerminal")
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
        }
    }

    // MARK: - Slide 4: Permissions (Screen Recording)

    private var slidePermissions: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "rectangle.dashed.badge.record")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 8) {
                Text("Screen Recording")
                    .font(.system(size: 22, weight: .bold))

                Text("Blitz needs Screen Recording permission to capture\nyour simulator for AI-assisted development.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            // Screen recording permission row
            HStack(spacing: 12) {
                Image(systemName: "record.circle")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Screen Recording")
                        .font(.body.weight(.medium))
                    Text("Required to capture the iOS Simulator window")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if screenRecordingChecking {
                    ProgressView()
                        .controlSize(.small)
                } else if screenRecordingGranted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                } else {
                    Button("Grant Access") {
                        requestScreenRecording()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(12)
            .frame(maxWidth: 440)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(screenRecordingGranted ? Color.green.opacity(0.3) : Color.primary.opacity(0.08), lineWidth: 1)
            )

            Button("Open System Settings") {
                AppRelaunchService.shared.prepareForScreenRecordingPermissionRestart()
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Shared Components

    private func onboardingCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }

    private var bottomBar: some View {
        HStack {
            if currentStep > 0 {
                Button("Back") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        currentStep -= 1
                    }
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // Page dots
            HStack(spacing: 6) {
                ForEach(0..<totalSteps, id: \.self) { i in
                    Circle()
                        .fill(i == currentStep ? Color.accentColor : Color.primary.opacity(0.2))
                        .frame(width: 6, height: 6)
                }
            }

            Spacer()

            if currentStep < totalSteps - 1 {
                // Show "Skip" on the ASC setup slide (step 1)
                if slideForStep(currentStep) == 1 {
                    Button("Skip") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            currentStep += 1
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                Button("Next") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        currentStep += 1
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            } else {
                Button("Get Started") {
                    finishOnboarding()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Logic

    private func detectTerminals() -> [TerminalApp] {
        var found: [TerminalApp] = [.builtIn]
        let ws = NSWorkspace.shared

        // macOS Terminal
        if ws.urlForApplication(withBundleIdentifier: "com.apple.Terminal") != nil {
            found.append(.terminal)
        }

        // Check Ghostty
        if ws.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") != nil {
            found.append(.ghostty)
        }

        // Check iTerm
        if ws.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil {
            found.append(.iterm)
        }

        // Also scan ~/Applications for terminal-like apps
        let homeApps = URL(fileURLWithPath: NSHomeDirectory() + "/Applications")
        if let contents = try? FileManager.default.contentsOfDirectory(at: homeApps, includingPropertiesForKeys: nil) {
            for url in contents where url.pathExtension == "app" {
                let name = url.deletingPathExtension().lastPathComponent.lowercased()
                // Skip already-detected ones
                if name == "terminal" || name == "ghostty" || name == "iterm" || name == "iterm2" { continue }
                // Include apps that look like terminals
                let terminalNames = ["warp", "kitty", "alacritty", "hyper", "wezterm", "rio", "tabby"]
                if terminalNames.contains(name) {
                    found.append(.custom(url.path))
                }
            }
        }

        return found
    }

    private func requestScreenRecording() {
        screenRecordingChecking = true
        Task {
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                screenRecordingGranted = true
            } catch {
                screenRecordingGranted = false
            }
            screenRecordingChecking = false
        }
    }

    private func finishOnboarding() {
        let settings = appState.settingsStore
        settings.defaultTerminal = selectedTerminal.settingsValue
        settings.defaultAgentCLI = selectedAgent.rawValue
        settings.skipAgentPermissions = skipAgentPermissions
        settings.whitelistBlitzMCPTools = whitelistBlitzMCPTools
        settings.allowASCCLICalls = allowASCCLICalls
        settings.hasCompletedOnboarding = true
        settings.save()

        let whitelistBlitzMCP = whitelistBlitzMCPTools
        let allowASCCLI = allowASCCLICalls
        Task.detached(priority: .utility) {
            ProjectStorage().ensureGlobalMCPConfigs(
                whitelistBlitzMCP: whitelistBlitzMCP,
                allowASCCLICalls: allowASCCLI
            )
        }

        // Also persist agent selection to AppStorage for ConnectAIPopover
        UserDefaults.standard.set(selectedAgent.rawValue, forKey: "selectedAIAgent")

        onComplete()
    }
}

/// Looping video player using AVPlayerLayer on a plain NSView — fully transparent background.
private struct OnboardingVideoPlayer: NSViewRepresentable {
    var resourceName: String = "AIUseDemo"

    func makeNSView(context: Context) -> NSView {
        let view = TransparentPlayerView()

        if let url = Bundle.appResources.url(forResource: resourceName, withExtension: "mp4") {
            let player = AVPlayer(url: url)
            player.isMuted = true
            view.playerLayer.player = player
            view.playerLayer.videoGravity = .resizeAspect

            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { _ in
                player.seek(to: .zero)
                player.play()
            }

            player.play()
        }

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// NSView backed by an AVPlayerLayer with a transparent background.
private final class TransparentPlayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
        playerLayer.backgroundColor = .clear
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
