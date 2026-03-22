import AVKit
import ScreenCaptureKit
import SwiftUI

/// Terminal app options for onboarding configuration
enum TerminalApp: Hashable {
    case terminal
    case ghostty
    case iterm
    case custom(String)

    var id: String {
        switch self {
        case .terminal: return "terminal"
        case .ghostty: return "ghostty"
        case .iterm: return "iterm"
        case .custom(let path): return path
        }
    }

    var displayName: String {
        switch self {
        case .terminal: return "Terminal"
        case .ghostty: return "Ghostty"
        case .iterm: return "iTerm"
        case .custom(let path):
            return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }
    }

    var iconName: String {
        switch self {
        case .terminal: return "terminal"
        case .ghostty: return "terminal"
        case .iterm: return "terminal"
        case .custom: return "terminal"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .terminal: return "com.apple.Terminal"
        case .ghostty: return "com.mitchellh.ghostty"
        case .iterm: return "com.googlecode.iterm2"
        case .custom(let path): return path
        }
    }

    /// Persist to settings as a string
    var settingsValue: String { id }

    /// Restore from settings string
    static func from(_ value: String) -> TerminalApp {
        switch value {
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
    @State private var selectedTerminal: TerminalApp = .terminal
    @State private var selectedAgent: AIAgent = .claudeCode
    @State private var detectedTerminals: [TerminalApp] = []
    @State private var showCustomPicker = false
    @State private var skipAgentPermissions = false

    // Permissions state
    @State private var screenRecordingGranted = false
    @State private var screenRecordingChecking = false

    // 0 = config, 1 = import slide, 2 = ask ai slide, 3 = permissions (if needed)
    private var totalSteps: Int {
        screenRecordingGranted ? 3 : 4
    }

    var body: some View {
        VStack(spacing: 0) {
            // Content area
            Group {
                switch currentStep {
                case 0:
                    configurationStep
                case 1:
                    slideImportProject
                case 2:
                    slideAskAI
                case 3:
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
                // Terminal selection
                VStack(alignment: .leading, spacing: 6) {
                    Label("Default Terminal", systemImage: "terminal")
                        .font(.headline)

                    VStack(spacing: 2) {
                        ForEach(detectedTerminals, id: \.self) { terminal in
                            terminalRow(terminal)
                        }

                        // Custom picker button
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

                Divider()

                // Agent CLI selection
                VStack(alignment: .leading, spacing: 6) {
                    Label("Default AI Agent", systemImage: "cpu")
                        .font(.headline)

                    VStack(spacing: 2) {
                        ForEach(AIAgent.allCases, id: \.rawValue) { agent in
                            agentRow(agent)
                        }
                    }
                }

                // Skip permissions toggle (only if agent supports it)
                if selectedAgent.skipPermissionsFlag != nil {
                    Divider()

                    Toggle(isOn: $skipAgentPermissions) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Skip agent permissions")
                                .font(.callout)
                            Text("Launch with \(selectedAgent.skipPermissionsFlag ?? "")")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
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

    private func terminalRow(_ terminal: TerminalApp) -> some View {
        let isSelected = selectedTerminal == terminal
        return Button {
            selectedTerminal = terminal
        } label: {
            HStack(spacing: 10) {
                terminalIcon(for: terminal)
                    .frame(width: 20, height: 20)
                Text(terminal.displayName)
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
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminal.bundleIdentifier) {
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

    // MARK: - Slide 1: Import Project

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

    // MARK: - Slide 2: Ask AI

    private var slideAskAI: some View {
        VStack(spacing: 6) {
            slideHeader(
                title: "Ask AI from Any Tab",
                subtitle: "Click \"Ask AI\" to launch \(selectedAgent.displayName) in \(selectedTerminal.displayName)."
            )

            // Demo video — transparent background, aspect fit
            OnboardingVideoPlayer()
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
        }
    }

    // MARK: - Slide 3: Permissions (Screen Recording)

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
        var found: [TerminalApp] = []
        let ws = NSWorkspace.shared

        // Always include macOS Terminal
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
        settings.hasCompletedOnboarding = true
        settings.save()

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
