import SwiftUI

// MARK: - Window accessor

private struct HostingWindowFinder: NSViewRepresentable {
    var callback: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { self.callback(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { self.callback(nsView.window) }
    }
}

// MARK: - ContentView

struct ContentView: View {
    @Bindable var appState: AppState
    @State private var mainWindow: NSWindow?
    @State private var tabSwitchTask: Task<Void, Never>?
    @State private var showOnboarding: Bool
    @State private var credentialOnlyOnboarding: Bool

    init(appState: AppState) {
        self.appState = appState
        // First-run users see the full onboarding. Users who've already completed
        // onboarding but don't have credentials (wiped keychain, expired key, etc.)
        // get a credential-only onboarding that jumps directly to the ASC slide
        // and dismisses as soon as credentials are saved. Nobody ever sees the
        // legacy picker again.
        let hasCompletedOnboarding = appState.settingsStore.hasCompletedOnboarding
        let hasCredentials = ASCCredentials.load() != nil
        let onboardingNeeded = !hasCompletedOnboarding || !hasCredentials
        _showOnboarding = State(initialValue: onboardingNeeded)
        _credentialOnlyOnboarding = State(
            initialValue: hasCompletedOnboarding && !hasCredentials
        )
    }

    private var terminalSplitMinContentSize: CGFloat {
        let baseMinContentSize: CGFloat = 200
        guard appState.settingsStore.terminalPosition == "right" else {
            return baseMinContentSize
        }
        return max(baseMinContentSize, AppTabView.minimumSingleLineWidth)
    }

    private var appleIDLoginBinding: Binding<Bool> {
        Binding(
            get: { appState.ascManager.showAppleIDLogin },
            set: { appState.ascManager.showAppleIDLogin = $0 }
        )
    }

    private var createUpdateBinding: Binding<Bool> {
        Binding(
            get: { appState.ascManager.showCreateUpdateSheet },
            set: { appState.ascManager.showCreateUpdateSheet = $0 }
        )
    }

    /// Consume pendingSetupProjectId and run project scaffolding if needed.
    private func launchTerminal() {
        let settings = appState.settingsStore
        let terminal = settings.resolveDefaultTerminal().terminal

        if terminal.isBuiltIn {
            // Show built-in terminal panel
            appState.showTerminal = true

            let agent = AIAgent(rawValue: settings.defaultAgentCLI) ?? .claudeCode
            let prompt = settings.sendDefaultPrompt ? ConnectAIPopover.prompt(for: appState.activeTab) : nil
            appState.terminalManager.createAgentSession(
                projectPath: appState.activeProject?.path,
                agent: agent,
                prompt: prompt,
                skipPermissions: settings.skipAgentPermissions
            )
        } else {
            // Launch external terminal
            TerminalLauncher.launchFromSettings(
                projectPath: appState.activeProject?.path,
                activeTab: appState.activeTab
            )
        }
    }

    private func startPendingSetupIfNeeded() async -> Bool {
        guard let pendingId = appState.projectSetup.pendingSetupProjectId,
              pendingId == appState.activeProjectId,
              let project = appState.activeProject else { return false }
        appState.projectSetup.pendingSetupProjectId = nil
        await appState.projectSetup.setup(
            projectId: project.id,
            projectName: project.name,
            projectPath: project.path,
            projectType: project.type,
            platform: project.platform
        )
        return true
    }

    private func refreshProjectFiles(projectId: String, projectType: ProjectType) {
        let whitelistBlitzMCP = appState.settingsStore.whitelistBlitzMCPTools
        let allowASCCLICalls = appState.settingsStore.allowASCCLICalls
        Task.detached(priority: .utility) {
            let storage = ProjectStorage()
            storage.ensureMCPConfig(
                projectId: projectId,
                whitelistBlitzMCP: whitelistBlitzMCP,
                allowASCCLICalls: allowASCCLICalls
            )
            storage.ensureClaudeFiles(
                projectId: projectId,
                projectType: projectType,
                whitelistBlitzMCP: whitelistBlitzMCP,
                allowASCCLICalls: allowASCCLICalls
            )
        }
    }

    var body: some View {
        ZStack {
            // Keep the dashboard view tree alive behind onboarding so its
            // hydration tasks can run before the overlay is dismissed.
            mainContent
                .frame(
                    minWidth: showOnboarding ? nil : 800,
                    minHeight: showOnboarding ? nil : 600
                )
                .opacity(showOnboarding ? 0 : 1)
                .allowsHitTesting(!showOnboarding)

            if showOnboarding {
                onboardingOverlay
            }

            if appState.autoUpdate.showsFullScreenOverlay {
                UpdateOverlay(autoUpdate: appState.autoUpdate)
            }
        }
        .background(HostingWindowFinder { window in
            mainWindow = window
        })
        .onChange(of: mainWindow) { _, _ in
            configureWindow(forOnboarding: showOnboarding)
        }
        .onChange(of: showOnboarding) { _, isOnboarding in
            configureWindow(forOnboarding: isOnboarding)
        }
        .task {
            await appState.projectManager.loadProjects()
            await appState.performLaunchAppWallSyncIfNeeded()
            await appState.autoUpdate.checkForUpdate()

            // Load any stored ASC credentials up front so the Dashboard can render
            // all ASC apps instantly on the first main-window paint, even when
            // there is no active local project.
            appState.ascManager.loadStoredCredentialsIfNeeded()

            if let projectId = appState.activeProjectId,
               let projectType = appState.activeProject?.type {
                refreshProjectFiles(projectId: projectId, projectType: projectType)
            }

            // If a project was just created, run setup
            if await startPendingSetupIfNeeded() {
                await appState.projectManager.loadProjects()
            }

            // Auto-boot simulator when project opens
            await appState.simulatorManager.bootIfNeeded()
            // Auto-start stream if landing on simulator sub-tab
            if appState.activeTab == .app && appState.activeAppSubTab == .simulator {
                await appState.simulatorStream.startStreaming(
                    bootedDeviceId: appState.simulatorManager.bootedDeviceId
                )
            }
            // Per-project credential hydration still runs when we have an active project.
            if let projectId = appState.activeProjectId,
               let project = appState.activeProject {
                await appState.ascManager.loadCredentials(
                    for: projectId,
                    bundleId: project.metadata.bundleIdentifier
                )
                if appState.activeTab.isASCTab {
                    await appState.ascManager.ensureTabData(appState.activeTab)
                } else if appState.activeTab == .app && appState.activeAppSubTab == .overview {
                    await appState.ascManager.ensureTabData(.app)
                }
            }
        }
        .onChange(of: appState.activeProjectId) { _, newValue in
            if newValue == nil {
                // Project closed → stop stream. We never reopen a separate welcome/picker
                // window. The caller is responsible for setting `activeTab` to whatever
                // makes sense (Dashboard for an explicit "Close Project", App for picking
                // an ASC-only app, etc.).
                Task { await appState.simulatorStream.stopStreaming() }
            } else {
                // Project switched → ensure config files, run pending setup, reload ASC credentials
                if let newId = newValue {
                    appState.ascManager.prepareForProjectSwitch(
                        to: newId,
                        bundleId: appState.activeProject?.metadata.bundleIdentifier
                    )
                }

                if let newId = newValue, let projectType = appState.activeProject?.type {
                    refreshProjectFiles(projectId: newId, projectType: projectType)
                }

                Task {
                    if await startPendingSetupIfNeeded() {
                        await appState.projectManager.loadProjects()
                    }
                    if let newId = newValue, let project = appState.activeProject {
                        await appState.ascManager.loadCredentials(
                            for: newId,
                            bundleId: project.metadata.bundleIdentifier
                        )
                        if appState.activeTab.isASCTab {
                            await appState.ascManager.ensureTabData(appState.activeTab)
                        } else if appState.activeTab == .app && appState.activeAppSubTab == .overview {
                            await appState.ascManager.ensureTabData(.app)
                        }
                    }
                }
            }
        }
        .onChange(of: appState.activeTab) { oldTab, newTab in
            tabSwitchTask?.cancel()
            tabSwitchTask = Task {
                let isLeavingSimulator = oldTab == .app && appState.activeAppSubTab == .simulator
                let isEnteringSimulator = newTab == .app && appState.activeAppSubTab == .simulator

                // Pause stream when leaving simulator
                if isLeavingSimulator && newTab != .app {
                    await appState.simulatorStream.pauseStream()
                }
                // Resume/start stream when entering simulator
                if isEnteringSimulator {
                    if appState.simulatorStream.isPaused {
                        await appState.simulatorStream.resumeStream()
                    } else if !appState.simulatorStream.isCapturing {
                        await appState.simulatorStream.startStreaming(
                            bootedDeviceId: appState.simulatorManager.bootedDeviceId
                        )
                    }
                }
                // Fetch ASC data when entering any ASC tab
                if newTab.isASCTab {
                    await appState.ascManager.ensureTabData(newTab)
                }
            }
        }
        .onChange(of: appState.activeAppSubTab) { oldSub, newSub in
            guard appState.activeTab == .app else { return }
            tabSwitchTask?.cancel()
            tabSwitchTask = Task {
                // Pause stream when leaving simulator sub-tab
                if oldSub == .simulator && newSub != .simulator {
                    await appState.simulatorStream.pauseStream()
                }
                // Resume/start stream when entering simulator sub-tab
                if newSub == .simulator {
                    if appState.simulatorStream.isPaused {
                        await appState.simulatorStream.resumeStream()
                    } else if !appState.simulatorStream.isCapturing {
                        await appState.simulatorStream.startStreaming(
                            bootedDeviceId: appState.simulatorManager.bootedDeviceId
                        )
                    }
                }
                // Fetch ASC overview data when entering overview sub-tab
                if newSub == .overview {
                    await appState.ascManager.ensureTabData(.app)
                }
            }
        }
        .sheet(isPresented: $appState.showNewProjectSheet) {
            NewProjectSheet(appState: appState, isPresented: $appState.showNewProjectSheet)
        }
        .sheet(isPresented: $appState.showImportProjectSheet) {
            ImportProjectSheet(appState: appState, isPresented: $appState.showImportProjectSheet)
        }
        .sheet(isPresented: createUpdateBinding) {
            CreateUpdateSheet(appState: appState)
        }
        .sheet(isPresented: appleIDLoginBinding, onDismiss: {
            appState.ascManager.cancelPendingWebAuth()
        }) {
            AppleIDLoginSheet { session in
                appState.ascManager.setIrisSession(session)
                Task { await appState.ascManager.fetchRejectionFeedback(force: true) }
            }
        }
        .approvalAlert(appState: appState)
    }

    // MARK: - Window configuration

    private func configureWindow(forOnboarding isOnboarding: Bool) {
        guard let window = mainWindow else { return }
        if isOnboarding {
            window.toolbar?.isVisible = false
            window.styleMask.remove(.resizable)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.setContentSize(NSSize(width: 700, height: 440))
            window.center()
        } else {
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .hidden
            window.styleMask.insert(.resizable)
            window.contentMinSize = NSSize(width: 800, height: 600)
            window.toolbar?.isVisible = true
            window.setContentSize(NSSize(width: 1200, height: 900))
            window.center()
        }
    }

    // MARK: - Main NavigationSplitView content

    @ViewBuilder
    private var mainContent: some View {
        NavigationSplitView {
            SidebarView(appState: appState)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 250)
        } detail: {
            TerminalSplitView(
                isHorizontal: appState.settingsStore.terminalPosition == "right",
                showPanel: appState.showTerminal,
                panelSize: $appState.terminalPanelSize,
                minPanelSize: 120,
                minContentSize: terminalSplitMinContentSize
            ) {
                DetailView(appState: appState)
            } panel: {
                TerminalPanelView(appState: appState)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    launchTerminal()
                } label: {
                    Label("Terminal", systemImage: "terminal")
                }
                .help("Launch terminal with AI agent")
            }
        }
    }

    // MARK: - Onboarding overlay

    @ViewBuilder
    private var onboardingOverlay: some View {
        OnboardingView(
            appState: appState,
            credentialOnlyMode: credentialOnlyOnboarding
        ) {
            showOnboarding = false
            credentialOnlyOnboarding = false
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.windowBackground)
    }
}

// MARK: - DetailView

struct DetailView: View {
    @Bindable var appState: AppState

    private var setup: ProjectSetupManager { appState.projectSetup }

    private var isSettingUpActiveProject: Bool {
        (setup.isSettingUp || setup.errorMessage != nil) && setup.setupProjectId == appState.activeProjectId
    }

    var body: some View {
        ZStack {
            tabContent
                .opacity(isSettingUpActiveProject ? 0.15 : 1)
                .allowsHitTesting(!isSettingUpActiveProject)

            if isSettingUpActiveProject {
                projectSetupOverlay
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var tabContent: some View {
        ZStack {
            // Keep MonetizationView alive so creation progress survives tab switches
            MonetizationView(appState: appState)
                .opacity(appState.activeTab == .monetization ? 1 : 0)
                .allowsHitTesting(appState.activeTab == .monetization)

            if appState.activeTab != .monetization {
                activeTabView
            }
        }
    }

    @ViewBuilder
    private var activeTabView: some View {
        switch appState.activeTab {
        case .dashboard:
            DashboardView(appState: appState)
        case .app:
            AppTabView(appState: appState)
        case .appInformation:
            AppInformationView(appState: appState)
        case .screenshots:
            ScreenshotsView(appState: appState)
        case .monetization:
            EmptyView() // handled above
        case .review:
            ReviewView(appState: appState)
        case .analytics:
            AnalyticsView(appState: appState)
        case .reviews:
            ReviewsView(appState: appState)
        case .builds:
            BuildsView(appState: appState)
        case .groups:
            GroupsView(appState: appState)
        case .betaInfo:
            BetaInfoView(appState: appState)
        case .feedback:
            FeedbackView(appState: appState)
        case .settings:
            SettingsView(settings: appState.settingsStore, appState: appState, mcpServer: appState.mcpServer)
        }
    }

    private var projectSetupOverlay: some View {
        VStack(spacing: 20) {
            ProgressView()
                .controlSize(.large)

            Text("Setting up project")
                .font(.title3.weight(.medium))

            Text(setup.stepMessage)
                .font(.body)
                .foregroundStyle(.secondary)

            if setup.errorMessage != nil {
                Button("Retry") {
                    guard let project = appState.activeProject else { return }
                    Task {
                        await setup.setup(
                            projectId: project.id,
                            projectName: project.name,
                            projectPath: project.path,
                            projectType: project.type
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
    }
}
