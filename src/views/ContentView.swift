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
    @Environment(\.openWindow) private var openWindow
    @State private var mainWindow: NSWindow?
    @State private var tabSwitchTask: Task<Void, Never>?
    @State private var showConnectAI = false

    private var appleIDLoginBinding: Binding<Bool> {
        Binding(
            get: { appState.ascManager.showAppleIDLogin },
            set: { appState.ascManager.showAppleIDLogin = $0 }
        )
    }

    /// Consume pendingSetupProjectId and run project scaffolding if needed.
    private func startPendingSetupIfNeeded() async {
        guard let pendingId = appState.projectSetup.pendingSetupProjectId,
              pendingId == appState.activeProjectId,
              let project = appState.activeProject else { return }
        appState.projectSetup.pendingSetupProjectId = nil
        await appState.projectSetup.setup(
            projectId: project.id,
            projectName: project.name,
            projectPath: project.path,
            projectType: project.type,
            platform: project.platform
        )
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(appState: appState)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 250)
        } detail: {
            DetailView(appState: appState)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: {
                    // Try to auto-launch terminal with agent CLI
                    let launched = TerminalLauncher.launchFromSettings(
                        projectPath: appState.activeProject?.path,
                        activeTab: appState.activeTab
                    )
                    if !launched {
                        // Fallback: show the popover
                        showConnectAI = true
                    }
                }) {
                    Label("Connect AI", systemImage: "sparkles")
                }
                .help("Connect AI agent")
                .popover(isPresented: $showConnectAI, arrowEdge: .bottom) {
                    ConnectAIPopover(projectPath: appState.activeProject?.path, activeTab: appState.activeTab)
                }
                .contextMenu {
                    Button("Show Connect AI Panel") {
                        showConnectAI = true
                    }
                }
            }
        }
        .background(HostingWindowFinder { window in
            mainWindow = window
        })
        .task {
            await appState.projectManager.loadProjects()

            // If a project was just created (e.g. from WelcomeWindow), run setup
            await startPendingSetupIfNeeded()

            // Auto-boot simulator when project opens
            await appState.simulatorManager.bootIfNeeded()
            // Auto-start stream if landing on simulator tab
            if appState.activeTab == .simulator {
                await appState.simulatorStream.startStreaming(
                    bootedDeviceId: appState.simulatorManager.bootedDeviceId
                )
            }
            // Load ASC credentials for the initial project
            if let projectId = appState.activeProjectId,
               let project = appState.activeProject {
                await appState.ascManager.loadCredentials(
                    for: projectId,
                    bundleId: project.metadata.bundleIdentifier
                )
                if appState.activeTab.isASCTab {
                    await appState.ascManager.fetchTabData(appState.activeTab)
                }
            }
        }
        .onChange(of: appState.activeProjectId) { _, newValue in
            if newValue == nil {
                // Project closed → stop stream, reopen welcome, close this window
                Task { await appState.simulatorStream.stopStreaming() }
                openWindow(id: "welcome")
                mainWindow?.close()
            } else {
                // Project switched → ensure config files, run pending setup, reload ASC credentials
                Task {
                    if let newId = newValue, let project = appState.activeProject {
                        // Ensure config files are up to date on every open.
                        // Handles Tauri migration, first-open of imported projects,
                        // and ensures Teenybase backend files are scaffolded.
                        let storage = ProjectStorage()
                        storage.ensureMCPConfig(projectId: newId)
                        storage.ensureTeenybaseBackend(projectId: newId, projectType: project.type)
                        storage.ensureClaudeFiles(projectId: newId, projectType: project.type)
                    }
                    await startPendingSetupIfNeeded()
                    appState.ascManager.clearForProjectSwitch()
                    if let newId = newValue, let project = appState.activeProject {
                        await appState.ascManager.loadCredentials(
                            for: newId,
                            bundleId: project.metadata.bundleIdentifier
                        )
                        if appState.activeTab.isASCTab {
                            await appState.ascManager.fetchTabData(appState.activeTab)
                        }
                    }
                }
            }
        }
        .onChange(of: appState.activeTab) { oldTab, newTab in
            tabSwitchTask?.cancel()
            tabSwitchTask = Task {
                // Pause stream when leaving simulator tab
                if oldTab == .simulator && newTab != .simulator {
                    await appState.simulatorStream.pauseStream()
                }
                // Resume/start stream when entering simulator tab
                if newTab == .simulator {
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
                    await appState.ascManager.fetchTabData(newTab)
                }
            }
        }
        .sheet(isPresented: $appState.showNewProjectSheet) {
            NewProjectSheet(appState: appState, isPresented: $appState.showNewProjectSheet)
        }
        .sheet(isPresented: $appState.showImportProjectSheet) {
            ImportProjectSheet(appState: appState, isPresented: $appState.showImportProjectSheet)
        }
        .sheet(isPresented: appleIDLoginBinding, onDismiss: {
            appState.ascManager.cancelPendingWebAuth()
        }) {
            AppleIDLoginSheet { session in
                appState.ascManager.setIrisSession(session)
                Task { await appState.ascManager.fetchRejectionFeedback() }
            }
        }
        .approvalAlert(appState: appState)
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
        case .simulator:
            SimulatorView(appState: appState)
        case .database:
            DatabaseView(appState: appState)
        case .tests:
            TestsView(appState: appState)
        case .assets:
            AssetsView(appState: appState)
        case .ascOverview:
            ASCOverview(appState: appState)
        case .storeListing:
            StoreListingView(appState: appState)
        case .screenshots:
            ScreenshotsView(appState: appState)
        case .appDetails:
            AppDetailsView(appState: appState)
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
