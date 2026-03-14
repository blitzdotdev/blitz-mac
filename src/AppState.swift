import Foundation
import SwiftUI

/// All navigation tabs in the app
enum AppTab: String, CaseIterable, Identifiable {
    // Build group
    case simulator
    case database
    case tests
    case assets

    // Release group (ASC)
    case ascOverview
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
        case .ascOverview, .storeListing, .screenshots, .appDetails, .monetization, .review,
             .analytics, .reviews, .builds, .groups, .betaInfo, .feedback:
            return true
        default:
            return false
        }
    }

    var label: String {
        switch self {
        case .simulator: "Simulator"
        case .database: "Database"
        case .tests: "Tests"
        case .assets: "Assets"
        case .ascOverview: "Overview"
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
        case .simulator: "iphone"
        case .database: "cylinder"
        case .tests: "checkmark.circle"
        case .assets: "photo.badge.plus"
        case .ascOverview: "chart.bar"
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
        case build = "Build"
        case release = "Release"
        case insights = "Insights"
        case testFlight = "TestFlight"

        var tabs: [AppTab] {
            switch self {
            case .build: [.simulator, .database, .tests, .assets]
            case .release: [.ascOverview, .storeListing, .screenshots, .appDetails, .monetization, .review]
            case .insights: [.analytics, .reviews]
            case .testFlight: [.builds, .groups, .betaInfo, .feedback]
            }
        }
    }
}

/// Root observable state for the entire app
@MainActor
@Observable
final class AppState {
    // Navigation
    var activeProjectId: String?
    var activeTab: AppTab = .simulator

    // Child observable managers
    var projectManager = ProjectManager()
    var simulatorManager = SimulatorManager()
    var simulatorStream = SimulatorStreamManager()
var settingsStore = SettingsService.shared
    var databaseManager = DatabaseManager()
    var projectSetup = ProjectSetupManager()
    var ascManager = ASCManager()
    var autoUpdate = AutoUpdateManager()

    // Sheet control (toggled by menu bar, observed by ContentView)
    var showNewProjectSheet = false
    var showImportProjectSheet = false

// MCP approval flow
    var pendingApproval: ApprovalRequest?
    var showApprovalAlert: Bool = false
    var toolExecutor: MCPToolExecutor?
    var mcpServer: MCPServerService?

    init() {
        // Boot MCP server eagerly — this runs before any SwiftUI view callback
        MCPBootstrap.shared.boot(appState: self)
    }

    var activeProject: Project? {
        guard let id = activeProjectId else { return nil }
        return projectManager.projects.first { $0.id == id }
    }
}

// MARK: - Observable Managers

@MainActor
@Observable
final class ProjectManager {
    var projects: [Project] = []
    var isLoading = false

    func loadProjects() async {
        isLoading = true
        defer { isLoading = false }

        let storage = ProjectStorage()
        projects = await storage.listProjects()
    }
}

@MainActor
@Observable
final class SimulatorManager {
    var simulators: [SimulatorInfo] = []
    var bootedDeviceId: String?
    var isStreaming = false
    var isBooting = false
    var bootingDeviceName: String?

    func loadSimulators() async {
        let client = SimctlClient()
        do {
            let devices = try await client.listDevices()
            simulators = devices.map { device in
                SimulatorInfo(
                    udid: device.udid,
                    name: device.name,
                    state: device.state,
                    deviceTypeIdentifier: device.deviceTypeIdentifier,
                    lastBootedAt: device.lastBootedAt
                )
            }
            // Only auto-select a booted device if it's supported
            bootedDeviceId = simulators.first(where: {
                $0.isBooted && SimulatorConfigDatabase.isSupported($0.name)
            })?.udid
        } catch {
            print("Failed to load simulators: \(error)")
        }
    }

    /// Boot a simulator if none is currently running. Called when a project opens.
    /// Prefers supported devices (iPhone 16/17); falls back to any iPhone.
    func bootIfNeeded() async {
        await loadSimulators()

        // If a supported device is already booted, keep it
        if let bootedId = bootedDeviceId,
           let booted = simulators.first(where: { $0.udid == bootedId }),
           SimulatorConfigDatabase.isSupported(booted.name) { return }

        // Otherwise pick a supported device to boot (prefer shutdown ones to avoid conflicts)
        guard let target = simulators.first(where: {
            SimulatorConfigDatabase.isSupported($0.name) && !$0.isBooted
        }) ?? simulators.first(where: {
            SimulatorConfigDatabase.isSupported($0.name)
        }) else { return }

        isBooting = true
        defer { isBooting = false }

        let service = SimulatorService()
        do {
            try await service.boot(udid: target.udid)
            bootedDeviceId = target.udid
            await loadSimulators()
        } catch {
            print("Failed to auto-boot simulator: \(error)")
        }
    }

    /// Shutdown the booted simulator. Called on app quit.
    func shutdownBooted() {
        guard let udid = bootedDeviceId else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "shutdown", udid]
        try? process.run()
        process.waitUntilExit()
    }
}

@MainActor
@Observable
final class SimulatorStreamManager {
    let captureService = SimulatorCaptureService()
    var renderer: MetalRenderer?
    var isCapturing = false
    var errorMessage: String?
    var statusMessage: String?
    /// True when the stream was paused by a tab switch (not manually stopped)
    var isPaused = false

    private var rendererInitialized = false

    func ensureRenderer() {
        guard !rendererInitialized else { return }
        rendererInitialized = true
        do {
            renderer = try MetalRenderer()
        } catch {
            errorMessage = "Metal init failed: \(error.localizedDescription)"
        }
    }

    /// Full start: ensure renderer, open Simulator.app, connect SCStream.
    func startStreaming(bootedDeviceId: String?) async {
        guard !isCapturing else { return }
        guard bootedDeviceId != nil else {
            statusMessage = "No simulator booted"
            return
        }

        errorMessage = nil
        isPaused = false
        ensureRenderer()

        statusMessage = "Opening Simulator.app..."
        let service = SimulatorService()
        try? await service.openSimulatorApp()

        statusMessage = "Connecting to simulator..."
        do {
            try await captureService.startCapture(retryForWindow: true)
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
            return
        }

        if captureService.isCapturing {
            isCapturing = true
            statusMessage = nil
        }
    }

    /// Full stop: stop SCStream, clear state.
    func stopStreaming() async {
        await captureService.stopCapture()
        isCapturing = false
        isPaused = false
    }

    /// Pause: stop SCStream but keep simulator booted. Lightweight for tab switches.
    func pauseStream() async {
        guard isCapturing else { return }
        isPaused = true
        await captureService.stopCapture()
        isCapturing = false
    }

    /// Resume: restart SCStream after a pause. No window retry needed since sim is already running.
    func resumeStream() async {
        guard isPaused else { return }
        isPaused = false
        ensureRenderer()

        do {
            try await captureService.startCapture(retryForWindow: false)
            if captureService.isCapturing {
                isCapturing = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}



@MainActor
@Observable
final class ProjectSetupManager {
    var isSettingUp = false
    var setupProjectId: String?
    var currentStep: ProjectSetupService.SetupStep?
    var errorMessage: String?

    /// Set by NewProjectSheet; consumed by ContentView to trigger setup.
    var pendingSetupProjectId: String?

    /// Scaffold a project using the appropriate template for its type.
    func setup(projectId: String, projectName: String, projectPath: String, projectType: ProjectType = .reactNative) async {
        isSettingUp = true
        setupProjectId = projectId
        currentStep = nil
        errorMessage = nil

        do {
            switch projectType {
            case .swift:
                try await SwiftProjectSetupService.setup(
                    projectId: projectId,
                    projectName: projectName,
                    projectPath: projectPath,
                    onStep: { step in self.currentStep = step }
                )
            case .reactNative:
                try await ProjectSetupService.setup(
                    projectId: projectId,
                    projectName: projectName,
                    projectPath: projectPath,
                    onStep: { step in self.currentStep = step }
                )
            case .flutter:
                throw ProjectSetupService.SetupError(message: "Flutter projects are not yet supported")
            }
            // Ensure .mcp.json, CLAUDE.md, .claude/settings.local.json exist
            // (setup recreates the project dir, so these must be written after)
            let storage = ProjectStorage()
            storage.ensureMCPConfig(projectId: projectId)
            storage.ensureClaudeFiles(projectId: projectId, projectType: projectType)
            isSettingUp = false
        } catch {
            errorMessage = error.localizedDescription
            isSettingUp = false
        }
    }

    var stepMessage: String {
        if let error = errorMessage { return "Error: \(error)" }
        return currentStep?.rawValue ?? "Preparing..."
    }
}

@MainActor
@Observable
final class DatabaseManager {
    // Connection & data state
    var connectionStatus: ConnectionStatus = .disconnected
    var schema: TeenybaseSettingsResponse?
    var selectedTable: TeenybaseTable?
    var rows: [TableRow] = []
    var totalRows: Int = 0
    var currentPage: Int = 0
    var pageSize: Int = 50
    var sortField: String?
    var sortAscending: Bool = true
    var searchText: String = ""
    var errorMessage: String?

    // Tracks which project we're connected to
    private(set) var connectedProjectId: String?

    // Backend process
    let backendProcess = TeenybaseProcessService()
    let client = TeenybaseClient()

    /// Start the backend server for a project and connect to it.
    func startAndConnect(projectId: String, projectPath: String) async {
        // Already connected to this project
        if connectedProjectId == projectId && connectionStatus == .connected { return }
        // Already in progress for this project
        if connectedProjectId == projectId && connectionStatus == .connecting { return }

        // Switching projects — tear down old connection
        if connectedProjectId != nil && connectedProjectId != projectId {
            disconnect()
        }

        connectedProjectId = projectId
        connectionStatus = .connecting
        errorMessage = nil

        // Read admin token from .dev.vars
        let token = readDevVar("ADMIN_SERVICE_TOKEN", projectPath: projectPath)
        guard let token, !token.isEmpty else {
            connectionStatus = .error
            errorMessage = "No ADMIN_SERVICE_TOKEN in .dev.vars"
            return
        }

        // Start the backend process
        await backendProcess.start(projectPath: projectPath)

        // Wait for it to be running
        guard backendProcess.status == .running else {
            connectionStatus = .error
            errorMessage = backendProcess.errorMessage ?? "Backend failed to start"
            return
        }

        // Connect the API client
        let baseURL = backendProcess.baseURL
        await client.configure(baseURL: baseURL, token: token)

        do {
            let settings = try await client.fetchSchema()
            self.schema = settings
            self.connectionStatus = .connected
            self.errorMessage = nil
            if self.selectedTable == nil, let first = settings.tables.first {
                self.selectedTable = first
            }
        } catch {
            self.connectionStatus = .error
            self.errorMessage = "Connected but schema fetch failed: \(error.localizedDescription)"
        }
    }

    func loadRows() async {
        guard let table = selectedTable else { return }
        do {
            var whereClause: String? = nil
            if !searchText.isEmpty {
                let textFields = table.fields.filter { ($0.type ?? "text") == "text" || ($0.sqlType ?? "") == "text" }
                if !textFields.isEmpty {
                    let escaped = searchText
                        .replacingOccurrences(of: "'", with: "''")
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "%", with: "\\%")
                        .replacingOccurrences(of: "_", with: "\\_")
                    let clauses = textFields.map { "\($0.name) LIKE '%\(escaped)%'" }
                    whereClause = clauses.joined(separator: " OR ")
                }
            }

            let result = try await client.listRecords(
                table: table.name,
                limit: pageSize,
                offset: currentPage * pageSize,
                orderBy: sortField,
                ascending: sortAscending,
                where: whereClause
            )
            self.rows = result.items
            self.totalRows = result.total
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    func insertRecord(values: [String: Any]) async {
        guard let table = selectedTable else { return }
        do {
            _ = try await client.insertRecord(table: table.name, values: values)
            await loadRows()
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    func updateRecord(id: String, values: [String: Any]) async {
        guard let table = selectedTable else { return }
        do {
            _ = try await client.updateRecord(table: table.name, id: id, values: values)
            await loadRows()
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    func deleteRecord(id: String) async {
        guard let table = selectedTable else { return }
        do {
            _ = try await client.deleteRecord(table: table.name, id: id)
            await loadRows()
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    func disconnect() {
        backendProcess.stop()
        connectedProjectId = nil
        connectionStatus = .disconnected
        schema = nil
        selectedTable = nil
        rows = []
        totalRows = 0
        currentPage = 0
        errorMessage = nil
    }

    private func readDevVar(_ key: String, projectPath: String) -> String? {
        let path = projectPath + "/.dev.vars"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            if trimmed.hasPrefix(key + "=") || trimmed.hasPrefix(key + " ") {
                let parts = trimmed.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    return String(parts[1]).trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                }
            }
        }
        return nil
    }
}

// SettingsStore is SettingsService (defined in Services/SettingsService.swift)
typealias SettingsStore = SettingsService
