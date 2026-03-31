import Foundation
import SwiftUI

/// All navigation tabs in the app
enum AppTab: String, CaseIterable, Identifiable {
    // Top-level standalone tabs
    case dashboard
    case app

    // Release group (ASC)
    case storeListing
    case screenshots
    case appDetails
    case monetization
    case review

    // Insights group
    case analytics
    case reviews

    // TestFlight group
    case builds
    case groups
    case betaInfo
    case feedback

    // Settings
    case settings

    var id: String { rawValue }

    var isASCTab: Bool {
        switch self {
        case .storeListing, .screenshots, .appDetails, .monetization, .review,
             .analytics, .reviews, .builds, .groups, .betaInfo, .feedback:
            return true
        default:
            return false
        }
    }

    var label: String {
        switch self {
        case .dashboard: "Dashboard"
        case .app: "App"
        case .storeListing: "Store Listing"
        case .screenshots: "Screenshots"
        case .appDetails: "App Details"
        case .monetization: "Monetization"
        case .review: "Review"
        case .analytics: "Analytics"
        case .reviews: "Reviews"
        case .builds: "Builds"
        case .groups: "Groups"
        case .betaInfo: "Beta Info"
        case .feedback: "Feedback"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .app: "app"
        case .storeListing: "text.page"
        case .screenshots: "photo.on.rectangle"
        case .appDetails: "info.circle"
        case .monetization: "dollarsign.circle"
        case .review: "star"
        case .analytics: "chart.line.uptrend.xyaxis"
        case .reviews: "bubble.left.and.bubble.right"
        case .builds: "hammer"
        case .groups: "person.3"
        case .betaInfo: "doc.text"
        case .feedback: "exclamationmark.bubble"
        case .settings: "gear"
        }
    }

    enum Group: String, CaseIterable {
        case release = "Release"
        case insights = "Insights"
        case testFlight = "TestFlight"

        var tabs: [AppTab] {
            switch self {
            case .release: [.storeListing, .screenshots, .appDetails, .monetization, .review]
            case .insights: [.analytics, .reviews]
            case .testFlight: [.builds, .groups, .betaInfo, .feedback]
            }
        }
    }
}

/// Sub-tabs within the Dashboard tab (top navbar)
enum DashboardSubTab: String, CaseIterable, Identifiable {
    case myApps
    case allApps

    var id: String { rawValue }

    var label: String {
        switch self {
        case .myApps: "My Apps"
        case .allApps: "All Apps"
        }
    }

    var systemImage: String {
        switch self {
        case .myApps: "folder"
        case .allApps: "globe"
        }
    }
}

/// Sub-tabs within the App tab (top navbar)
enum AppSubTab: String, CaseIterable, Identifiable {
    case overview
    case simulator
    case database
    case tests
    case icon

    var id: String { rawValue }

    var label: String {
        switch self {
        case .overview: "Overview"
        case .simulator: "Simulator"
        case .database: "Database"
        case .tests: "Tests"
        case .icon: "Icon"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "chart.bar"
        case .simulator: "iphone"
        case .database: "cylinder"
        case .tests: "checkmark.circle"
        case .icon: "photo.badge.plus"
        }
    }
}

/// Root observable state for the entire app
@MainActor
@Observable
final class AppState {
    // Navigation
    var activeProjectId: String?
    var activeTab: AppTab = .dashboard
    var activeAppSubTab: AppSubTab = .overview
    var activeDashboardSubTab: DashboardSubTab = .myApps

    // Child observable managers
    var projectManager = ProjectManager()
    var simulatorManager = SimulatorManager()
    var simulatorStream = SimulatorStreamManager()
    let simulatorCats = SimulatorCatSceneModel()
    var settingsStore = SettingsService.shared
    var databaseManager = DatabaseManager()
    var projectSetup = ProjectSetupManager()
    var ascManager = ASCManager()
    var autoUpdate = AutoUpdateManager()
    var terminalManager = TerminalManager()

    // Terminal panel visibility (toggle only — does not affect session lifecycle)
    var showTerminal = false
    var terminalPanelSize: CGFloat = 250

    // Sheet control (toggled by menu bar, observed by ContentView)
    var showNewProjectSheet = false
    var showImportProjectSheet = false

// MCP approval flow
    var pendingApproval: ApprovalRequest?
    var showApprovalAlert: Bool = false
    var toolExecutor: MCPExecutor?
    var mcpServer: MCPServerService?
    var hasAttemptedLaunchAppWallSync = false

    init() {
        ascManager.appState = self
        // Boot MCP server eagerly — this runs before any SwiftUI view callback
        MCPBootstrap.shared.boot(appState: self)
        ascManager.loadStoredCredentialsIfNeeded()
    }

    var activeProject: Project? {
        guard let id = activeProjectId else { return nil }
        return projectManager.projects.first { $0.id == id }
    }

    func performLaunchAppWallSyncIfNeeded() async {
        guard !hasAttemptedLaunchAppWallSync else { return }
        hasAttemptedLaunchAppWallSync = true

        guard UserDefaults.standard.bool(forKey: "appWallSyncConsented") else {
            Log("[AppWall] launch auto-sync skipped: sync toggle is off")
            return
        }

        let projects = projectManager.projects
        guard !projects.isEmpty else {
            Log("[AppWall] launch auto-sync skipped: no local projects loaded")
            return
        }

        guard let credentials = ascManager.credentials ?? ASCCredentials.load() else {
            Log("[AppWall] launch auto-sync skipped: missing ASC credentials")
            return
        }

        do {
            let result = try await AppWallSyncRunner.syncLocalLiveApps(
                projects: projects,
                credentials: credentials
            )
            if let warning = result.warning {
                Log("[AppWall] launch auto-sync completed with warnings: success=\(result.successCount) warning=\(warning)")
            } else {
                Log("[AppWall] launch auto-sync completed: success=\(result.successCount)")
            }
        } catch {
            Log("[AppWall] launch auto-sync failed: \(error.localizedDescription)")
        }
    }
}

// SettingsStore is SettingsService (defined in Services/SettingsService.swift)
typealias SettingsStore = SettingsService
