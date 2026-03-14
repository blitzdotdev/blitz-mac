import Foundation
import AppKit

/// Runs an async operation with a timeout. Throws CancellationError if the deadline is exceeded.
private func withThrowingTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw CancellationError()
        }
        guard let result = try await group.next() else {
            throw CancellationError()
        }
        group.cancelAll()
        return result
    }
}

/// Executes MCP tool calls against AppState.
/// Holds pending approval continuations for destructive operations.
actor MCPToolExecutor {
    private let appState: AppState
    private var pendingContinuations: [String: CheckedContinuation<Bool, Never>] = [:]

    init(appState: AppState) {
        self.appState = appState
    }

    /// Execute a tool call, requesting approval if needed
    func execute(name: String, arguments: [String: Any]) async throws -> [String: Any] {
        let category = MCPToolRegistry.category(for: name)

        // Pre-navigate for ASC form tools so the user sees the target tab before approving
        var previousTab: AppTab?
        if name == "asc_fill_form" || name == "asc_upload_screenshots" || name == "asc_open_submit_preview"
            || name == "asc_create_iap" || name == "asc_create_subscription" || name == "asc_set_app_price" {
            previousTab = await preNavigateASCTool(name: name, arguments: arguments)
        }

        let request = ApprovalRequest(
            id: UUID().uuidString,
            toolName: name,
            description: "Execute '\(name)'",
            parameters: arguments.mapValues { "\($0)" },
            category: category
        )

        if request.requiresApproval(permissionToggles: await SettingsService.shared.permissionToggles) {
            let approved = await requestApproval(request)
            guard approved else {
                // Navigate back if denied
                if let prev = previousTab {
                    await MainActor.run { appState.activeTab = prev }
                    _ = await MainActor.run { appState.ascManager.pendingFormValues.removeAll() }
                }
                return mcpText("Tool '\(name)' was denied by the user.")
            }
        }

        return try await executeTool(name: name, arguments: arguments)
    }

    /// Navigate to the appropriate tab before approval, and set pending form values.
    /// Returns the previous tab so we can navigate back if denied.
    private func preNavigateASCTool(name: String, arguments: [String: Any]) async -> AppTab? {
        let previousTab = await MainActor.run { appState.activeTab }

        let targetTab: AppTab?
        if name == "asc_fill_form" {
            let tab = arguments["tab"] as? String ?? ""
            switch tab {
            case "storeListing": targetTab = .storeListing
            case "appDetails": targetTab = .appDetails
            case "monetization": targetTab = .monetization
            case "review.ageRating", "review.contact": targetTab = .review
            case "settings.bundleId": targetTab = .settings
            default: targetTab = nil
            }
        } else if name == "asc_open_submit_preview" {
            targetTab = .ascOverview
        } else if name == "asc_upload_screenshots" {
            targetTab = .screenshots
        } else if name == "asc_set_app_price" {
            targetTab = .monetization
        } else if name == "asc_create_iap" || name == "asc_create_subscription" {
            targetTab = .monetization
        } else {
            targetTab = nil
        }

        if let targetTab {
            await MainActor.run { appState.activeTab = targetTab }
            // Ensure tab data is loaded
            if targetTab.isASCTab {
                await appState.ascManager.fetchTabData(targetTab)
            }
        }

        // For asc_fill_form, pre-populate pending values so the form shows intended changes
        if name == "asc_fill_form",
           let tab = arguments["tab"] as? String {
            var fieldMap: [String: String] = [:]
            if let fieldsArray = arguments["fields"] as? [[String: Any]] {
                for item in fieldsArray {
                    if let field = item["field"] as? String, let value = item["value"] as? String {
                        fieldMap[field] = value
                    }
                }
            } else if let fieldsDict = arguments["fields"] as? [String: Any] {
                for (key, value) in fieldsDict {
                    fieldMap[key] = "\(value)"
                }
            } else if let fieldsString = arguments["fields"] as? String,
                      let data = fieldsString.data(using: .utf8),
                      let parsed = try? JSONSerialization.jsonObject(with: data) {
                if let dict = parsed as? [String: Any] {
                    for (key, value) in dict {
                        fieldMap[key] = "\(value)"
                    }
                } else if let array = parsed as? [[String: Any]] {
                    for item in array {
                        if let field = item["field"] as? String, let value = item["value"] as? String {
                            fieldMap[field] = value
                        }
                    }
                }
            }
            if !fieldMap.isEmpty {
                let fieldMapCopy = fieldMap
                await MainActor.run {
                    appState.ascManager.pendingFormValues[tab] = fieldMapCopy
                    appState.ascManager.pendingFormVersion += 1
                }
            }
        }

        return previousTab
    }

    /// Resume a pending approval
    nonisolated func resolveApproval(id: String, approved: Bool) {
        Task { await _resolveApproval(id: id, approved: approved) }
    }

    private func _resolveApproval(id: String, approved: Bool) {
        guard let continuation = pendingContinuations.removeValue(forKey: id) else { return }
        continuation.resume(returning: approved)
    }

    // MARK: - Approval Flow

    private func requestApproval(_ request: ApprovalRequest) async -> Bool {
        // Show alert on main thread and bring Blitz to front so user sees it
        await MainActor.run {
            appState.pendingApproval = request
            appState.showApprovalAlert = true
            NSApp.activate(ignoringOtherApps: true)
        }

        // Suspend until user approves/denies or timeout
        let approved = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            pendingContinuations[request.id] = continuation

            // 5-minute auto-deny timeout
            Task {
                try? await Task.sleep(for: .seconds(300))
                if pendingContinuations[request.id] != nil {
                    _resolveApproval(id: request.id, approved: false)
                }
            }
        }

        // Clear alert
        await MainActor.run {
            appState.pendingApproval = nil
            appState.showApprovalAlert = false
        }

        return approved
    }

    // MARK: - Tool Execution

    private func executeTool(name: String, arguments: [String: Any]) async throws -> [String: Any] {
        switch name {
        // -- App State --
        case "app_get_state":
            return try await executeAppGetState()

        // -- Navigation --
        case "nav_switch_tab":
            return try await executeNavSwitchTab(arguments)
        case "nav_list_tabs":
            return await executeNavListTabs()

        // -- Projects --
        case "project_list":
            return await executeProjectList()
        case "project_get_active":
            return await executeProjectGetActive()
        case "project_open":
            return try await executeProjectOpen(arguments)
        case "project_create":
            return try await executeProjectCreate(arguments)
        case "project_import":
            return try await executeProjectImport(arguments)
        case "project_close":
            return await executeProjectClose()

        // -- Simulator --
        case "simulator_list_devices":
            return await executeSimulatorListDevices()
        case "simulator_select_device":
            return try await executeSimulatorSelectDevice(arguments)

        // -- Settings --
        case "settings_get":
            return await executeSettingsGet()
        case "settings_update":
            return await executeSettingsUpdate(arguments)
        case "settings_save":
            return await executeSettingsSave()



        // -- Tab State --
        case "get_tab_state":
            return try await executeGetTabState(arguments)

        // -- ASC Form Tools --
        case "asc_fill_form":
            return try await executeASCFillForm(arguments)
        case "asc_upload_screenshots":
            return try await executeASCUploadScreenshots(arguments)
        case "asc_open_submit_preview":
            return await executeASCOpenSubmitPreview()
        case "asc_create_iap":
            return try await executeASCCreateIAP(arguments)
        case "asc_create_subscription":
            return try await executeASCCreateSubscription(arguments)
        case "asc_set_app_price":
            return try await executeASCSetAppPrice(arguments)

        // -- Build Pipeline --
        case "app_store_setup_signing":
            return try await executeSetupSigning(arguments)
        case "app_store_build":
            return try await executeBuildIPA(arguments)
        case "app_store_upload":
            return try await executeUploadToTestFlight(arguments)

        case "get_blitz_screenshot":
            let path = "/tmp/blitz-app-screenshot-\(Int(Date().timeIntervalSince1970)).png"
            let saved = await MainActor.run { () -> Bool in
                guard let window = NSApp.windows.first(where: { $0.title != "Welcome to Blitz" && $0.canBecomeMain && $0.isVisible }) ?? NSApp.mainWindow else {
                    return false
                }
                let windowId = CGWindowID(window.windowNumber)
                guard let cgImage = CGWindowListCreateImage(
                    .null,
                    .optionIncludingWindow,
                    windowId,
                    [.boundsIgnoreFraming, .bestResolution]
                ) else {
                    return false
                }
                let bitmap = NSBitmapImageRep(cgImage: cgImage)
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    return false
                }
                return ((try? png.write(to: URL(fileURLWithPath: path))) != nil)
            }
            if saved {
                return mcpText(path)
            } else {
                return mcpText("Error: could not capture Blitz window screenshot")
            }

        default:
            throw MCPServerService.MCPError.unknownTool(name)
        }
    }

    // MARK: - App State Tools

    private func executeAppGetState() async throws -> [String: Any] {
        let state = await MainActor.run { () -> [String: Any] in
            var result: [String: Any] = [
                "activeTab": appState.activeTab.rawValue,
                "isStreaming": appState.simulatorStream.isCapturing
            ]
            if let project = appState.activeProject {
                result["activeProject"] = [
                    "id": project.id,
                    "name": project.name,
                    "path": project.path,
                    "type": project.type.rawValue
                ]
            }
            if let udid = appState.simulatorManager.bootedDeviceId {
                result["bootedSimulator"] = udid
            }
            // Expose Teenybase DB URL so AI agents can curl it directly
            let db = appState.databaseManager
            if db.connectionStatus == .connected || db.backendProcess.isRunning {
                result["database"] = [
                    "url": db.backendProcess.baseURL,
                    "status": db.connectionStatus == .connected ? "connected" : "running"
                ]
            }
            return result
        }
        return mcpJSON(state)
    }

    // MARK: - Navigation Tools

    private func executeNavSwitchTab(_ args: [String: Any]) async throws -> [String: Any] {
        guard let tabStr = args["tab"] as? String,
              let tab = AppTab(rawValue: tabStr) else {
            throw MCPServerService.MCPError.invalidToolArgs
        }
        await MainActor.run { appState.activeTab = tab }

        // Auto-connect database when switching to database tab
        if tab == .database {
            let status = await MainActor.run { appState.databaseManager.connectionStatus }
            if status != .connected, let project = await MainActor.run(body: { appState.activeProject }) {
                await appState.databaseManager.startAndConnect(projectId: project.id, projectPath: project.path)
            }
        }

        return mcpText("Switched to tab: \(tab.label)")
    }

    private func executeNavListTabs() async -> [String: Any] {
        var groups: [[String: Any]] = []
        for group in AppTab.Group.allCases {
            let tabs = group.tabs.map { ["name": $0.rawValue, "label": $0.label, "icon": $0.icon] as [String: Any] }
            groups.append(["group": group.rawValue, "tabs": tabs])
        }
        // Include settings separately
        groups.append(["group": "Other", "tabs": [["name": "settings", "label": "Settings", "icon": "gear"]]])
        return mcpJSON(["groups": groups])
    }

    // MARK: - Project Tools

    private func executeProjectList() async -> [String: Any] {
        await appState.projectManager.loadProjects()
        let projects = await MainActor.run {
            appState.projectManager.projects.map { p -> [String: Any] in
                ["id": p.id, "name": p.name, "path": p.path, "type": p.type.rawValue]
            }
        }
        return mcpJSON(["projects": projects])
    }

    private func executeProjectGetActive() async -> [String: Any] {
        let result = await MainActor.run { () -> [String: Any]? in
            guard let project = appState.activeProject else { return nil }
            return ["id": project.id, "name": project.name, "path": project.path, "type": project.type.rawValue]
        }
        if let result {
            return mcpJSON(result)
        }
        return mcpText("No active project")
    }

    private func executeProjectOpen(_ args: [String: Any]) async throws -> [String: Any] {
        guard let projectId = args["projectId"] as? String else {
            throw MCPServerService.MCPError.invalidToolArgs
        }
        let storage = ProjectStorage()
        storage.updateLastOpened(projectId: projectId)
        await MainActor.run { appState.activeProjectId = projectId }
        await appState.projectManager.loadProjects()
        return mcpText("Opened project: \(projectId)")
    }

    private func executeProjectCreate(_ args: [String: Any]) async throws -> [String: Any] {
        guard let name = args["name"] as? String,
              let typeStr = args["type"] as? String else {
            throw MCPServerService.MCPError.invalidToolArgs
        }

        let storage = ProjectStorage()
        let projectId = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let projectDir = storage.baseDirectory.appendingPathComponent(projectId)

        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let projectType = ProjectType(rawValue: typeStr) ?? .reactNative
        let metadata = BlitzProjectMetadata(
            name: name,
            type: projectType,
            createdAt: Date(),
            lastOpenedAt: Date()
        )
        try storage.writeMetadata(projectId: projectId, metadata: metadata)
        storage.ensureMCPConfig(projectId: projectId)
        await appState.projectManager.loadProjects()

        // Set pending setup so ContentView triggers template scaffolding
        await MainActor.run {
            appState.projectSetup.pendingSetupProjectId = projectId
            appState.activeProjectId = projectId
        }

        // Wait for setup to complete (ContentView picks up pendingSetupProjectId).
        // If the main window isn't open (WelcomeWindow's onChange should open it),
        // fall back to running setup directly.
        try? await Task.sleep(for: .seconds(2))
        let setupStarted = await MainActor.run { appState.projectSetup.isSettingUp }
        if !setupStarted {
            // ContentView didn't pick it up — run setup directly
            guard let project = await MainActor.run(body: { appState.activeProject }) else {
                return mcpText("Created project '\(name)' but could not start setup (project not found)")
            }
            await appState.projectSetup.setup(
                projectId: project.id,
                projectName: project.name,
                projectPath: project.path,
                projectType: project.type
            )
        } else {
            // Wait for setup to finish (up to 3 min)
            for _ in 0..<180 {
                let done = await MainActor.run { !appState.projectSetup.isSettingUp }
                if done { break }
                try? await Task.sleep(for: .seconds(1))
            }
        }

        let errorMsg = await MainActor.run { appState.projectSetup.errorMessage }
        if let errorMsg {
            return mcpText("Created project '\(name)' but setup failed: \(errorMsg)")
        }
        return mcpText("Created project '\(name)' (type: \(typeStr), id: \(projectId)) — setup complete")
    }

    private func executeProjectImport(_ args: [String: Any]) async throws -> [String: Any] {
        guard let path = args["path"] as? String else {
            throw MCPServerService.MCPError.invalidToolArgs
        }

        let url = URL(fileURLWithPath: path)
        let storage = ProjectStorage()
        let projectId = try storage.openProject(at: url)
        storage.ensureMCPConfig(projectId: projectId)
        await appState.projectManager.loadProjects()
        await MainActor.run { appState.activeProjectId = projectId }

        return mcpText("Imported project from '\(path)' (id: \(projectId))")
    }

    private func executeProjectClose() async -> [String: Any] {
        await MainActor.run { appState.activeProjectId = nil }
        return mcpText("Project closed")
    }

    // MARK: - Simulator Tools

    private func executeSimulatorListDevices() async -> [String: Any] {
        await appState.simulatorManager.loadSimulators()
        let devices = await MainActor.run {
            appState.simulatorManager.simulators.map { sim -> [String: Any] in
                [
                    "udid": sim.udid,
                    "name": sim.name,
                    "state": sim.state,
                    "isBooted": sim.isBooted
                ]
            }
        }
        return mcpJSON(["devices": devices])
    }

    private func executeSimulatorSelectDevice(_ args: [String: Any]) async throws -> [String: Any] {
        guard let udid = args["udid"] as? String else {
            throw MCPServerService.MCPError.invalidToolArgs
        }

        let service = SimulatorService()
        try await service.boot(udid: udid)
        await MainActor.run { appState.simulatorManager.bootedDeviceId = udid }
        await appState.simulatorManager.loadSimulators()

        return mcpText("Booted simulator: \(udid)")
    }


    // MARK: - Settings Tools

    private func executeSettingsGet() async -> [String: Any] {
        let settings = await MainActor.run { () -> [String: Any] in
            [
                "showCursor": appState.settingsStore.showCursor,
                "cursorSize": appState.settingsStore.cursorSize,
                "defaultSimulatorUDID": appState.settingsStore.defaultSimulatorUDID ?? ""
            ]
        }
        return mcpJSON(settings)
    }

    private func executeSettingsUpdate(_ args: [String: Any]) async -> [String: Any] {
        await MainActor.run {
            if let cursor = args["showCursor"] as? Bool { appState.settingsStore.showCursor = cursor }
            if let size = args["cursorSize"] as? Double { appState.settingsStore.cursorSize = size }
        }
        return mcpText("Settings updated")
    }

    private func executeSettingsSave() async -> [String: Any] {
        await MainActor.run { appState.settingsStore.save() }
        return mcpText("Settings saved to disk")
    }

    // MARK: - ASC Form Tools

    // Valid field names per tab — rejects unknown fields before API roundtrip
    private static let validFieldsByTab: [String: Set<String>] = [
        "storeListing": ["title", "name", "subtitle", "description", "keywords", "promotionalText",
                         "marketingUrl", "supportUrl", "whatsNew", "privacyPolicyUrl"],
        "appDetails": ["copyright", "primaryCategory", "contentRightsDeclaration"],
        "monetization": ["isFree"],
        "review.ageRating": ["gambling", "messagingAndChat", "unrestrictedWebAccess",
                             "userGeneratedContent", "advertising", "lootBox",
                             "healthOrWellnessTopics", "parentalControls", "ageAssurance",
                             "alcoholTobaccoOrDrugUseOrReferences", "contests", "gamblingSimulated",
                             "gunsOrOtherWeapons", "horrorOrFearThemes", "matureOrSuggestiveThemes",
                             "medicalOrTreatmentInformation", "profanityOrCrudeHumor",
                             "sexualContentGraphicAndNudity", "sexualContentOrNudity",
                             "violenceCartoonOrFantasy", "violenceRealistic",
                             "violenceRealisticProlongedGraphicOrSadistic"],
        "review.contact": ["contactFirstName", "contactLastName", "contactEmail", "contactPhone",
                           "notes", "demoAccountRequired", "demoAccountName", "demoAccountPassword"],
        "settings.bundleId": ["bundleId"],
    ]

    // Common aliases: user-friendly field names → API field names (per tab)
    private static let fieldAliases: [String: String] = [
        "firstName": "contactFirstName",
        "lastName": "contactLastName",
        "email": "contactEmail",
        "phone": "contactPhone",
    ]

    private func executeASCFillForm(_ args: [String: Any]) async throws -> [String: Any] {
        guard let tab = args["tab"] as? String else {
            throw MCPServerService.MCPError.invalidToolArgs
        }

        // Build field map with alias resolution — accept multiple formats:
        // 1. Array of {field, value} objects: [{"field":"k","value":"v"}, ...]
        // 2. Flat dict: {"key": "value", ...}
        // 3. JSON string containing either format above
        var fieldMap: [String: String] = [:]
        if let fieldsArray = args["fields"] as? [[String: Any]] {
            for item in fieldsArray {
                if let field = item["field"] as? String, let value = item["value"] as? String {
                    let resolved = Self.fieldAliases[field] ?? field
                    fieldMap[resolved] = value
                }
            }
        } else if let fieldsDict = args["fields"] as? [String: Any] {
            for (key, value) in fieldsDict {
                let resolved = Self.fieldAliases[key] ?? key
                fieldMap[resolved] = "\(value)"
            }
        } else if let fieldsString = args["fields"] as? String,
                  let data = fieldsString.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) {
            if let dict = parsed as? [String: Any] {
                for (key, value) in dict {
                    let resolved = Self.fieldAliases[key] ?? key
                    fieldMap[resolved] = "\(value)"
                }
            } else if let array = parsed as? [[String: Any]] {
                for item in array {
                    if let field = item["field"] as? String, let value = item["value"] as? String {
                        let resolved = Self.fieldAliases[field] ?? field
                        fieldMap[resolved] = value
                    }
                }
            }
        }

        guard !fieldMap.isEmpty else {
            throw MCPServerService.MCPError.invalidToolArgs
        }

        // Validate field names against allowed set for this tab
        if let validFields = Self.validFieldsByTab[tab] {
            let invalid = fieldMap.keys.filter { !validFields.contains($0) }
            if !invalid.isEmpty {
                // Check if the field belongs to a different tab
                var hints: [String] = []
                for field in invalid {
                    for (otherTab, otherFields) in Self.validFieldsByTab where otherTab != tab {
                        if otherFields.contains(field) {
                            hints.append("'\(field)' belongs on tab '\(otherTab)'")
                        }
                    }
                }
                let hintStr = hints.isEmpty ? "" : " Hint: \(hints.joined(separator: "; "))."
                return mcpText("Error: invalid field(s) for tab '\(tab)': \(invalid.sorted().joined(separator: ", ")). Valid fields: \(validFields.sorted().joined(separator: ", ")).\(hintStr)")
            }
        }

        // Navigation + pending values already set by preNavigateASCTool in execute()

        // Execute the write based on tab
        switch tab {
        case "storeListing":
            // Fields are split across two ASC resources:
            // - appInfoLocalizations: name (title), subtitle, privacyPolicyUrl
            // - appStoreVersionLocalizations: description, keywords, whatsNew, marketingUrl, supportUrl, promotionalText
            let appInfoLocFields: Set<String> = ["name", "title", "subtitle", "privacyPolicyUrl"]
            var versionLocFields: [String: String] = [:]
            var infoLocFields: [String: String] = [:]

            for (field, value) in fieldMap {
                if appInfoLocFields.contains(field) {
                    // Map "title" to "name" for the API
                    let apiField = (field == "title") ? "name" : field
                    infoLocFields[apiField] = value
                } else {
                    versionLocFields[field] = value
                }
            }

            // Save appInfoLocalization fields (name, subtitle, privacyPolicyUrl)
            if !infoLocFields.isEmpty {
                for (field, value) in infoLocFields {
                    await appState.ascManager.updateAppInfoLocalizationField(field, value: value)
                }
                if let err = await checkASCWriteError(tab: tab) { return err }
            }

            // Save version localization fields (description, keywords, etc.)
            if !versionLocFields.isEmpty {
                guard let locId = await MainActor.run(body: { appState.ascManager.localizations.first?.id }) else {
                    return mcpText("Error: no version localizations found.")
                }
                do {
                    guard let service = await MainActor.run(body: { appState.ascManager.service }) else {
                        return mcpText("Error: ASC service not configured")
                    }
                    try await service.patchLocalization(id: locId, fields: versionLocFields)
                    if let versionId = await MainActor.run(body: { appState.ascManager.appStoreVersions.first?.id }) {
                        let locs = try await service.fetchLocalizations(versionId: versionId)
                        await MainActor.run { appState.ascManager.localizations = locs }
                    }
                } catch {
                    _ = await MainActor.run { appState.ascManager.pendingFormValues.removeValue(forKey: tab) }
                    return mcpText("Error: \(error.localizedDescription)")
                }
            }

        case "appDetails":
            for (field, value) in fieldMap {
                await appState.ascManager.updateAppInfoField(field, value: value)
            }
            if let err = await checkASCWriteError(tab: tab) { return err }

        case "monetization":
            guard let isFree = fieldMap["isFree"] else {
                return mcpText("Error: monetization tab requires the 'isFree' field (value: \"true\" or \"false\").")
            }
            if isFree == "true" {
                await appState.ascManager.setPriceFree()
            } else {
                // Paid pricing — use asc_set_app_price tool instead
                return mcpText("To set a paid price, use the asc_set_app_price tool with a price parameter (e.g. price=\"0.99\").")
            }
            if let err = await checkASCWriteError(tab: tab) { return err }

        case "review.ageRating":
            var attrs: [String: Any] = [:]
            let boolFields = Set(["gambling", "messagingAndChat", "unrestrictedWebAccess",
                                  "userGeneratedContent", "advertising", "lootBox",
                                  "healthOrWellnessTopics", "parentalControls", "ageAssurance"])
            for (field, value) in fieldMap {
                if boolFields.contains(field) {
                    attrs[field] = value == "true"
                } else {
                    attrs[field] = value
                }
            }
            await appState.ascManager.updateAgeRating(attrs)
            if let err = await checkASCWriteError(tab: tab) { return err }

        case "review.contact":
            var attrs: [String: Any] = [:]
            for (field, value) in fieldMap {
                if field == "demoAccountRequired" {
                    attrs[field] = value == "true"
                } else {
                    attrs[field] = value
                }
            }
            await appState.ascManager.updateReviewContact(attrs)
            if let err = await checkASCWriteError(tab: tab) { return err }

        case "settings.bundleId":
            if let bundleId = fieldMap["bundleId"] {
                let projectPath = await MainActor.run { appState.activeProject?.path }
                await MainActor.run {
                    guard let projectId = appState.activeProjectId else { return }
                    let storage = ProjectStorage()
                    guard var metadata = storage.readMetadata(projectId: projectId) else { return }
                    metadata.bundleIdentifier = bundleId
                    try? storage.writeMetadata(projectId: projectId, metadata: metadata)
                }
                // Also update PRODUCT_BUNDLE_IDENTIFIER in pbxproj
                if let projectPath {
                    let pipeline = BuildPipelineService()
                    await pipeline.updateBundleIdInPbxproj(projectPath: projectPath, bundleId: bundleId)
                }
                await appState.projectManager.loadProjects()
                let hasCreds = await MainActor.run { appState.ascManager.credentials != nil }
                if hasCreds {
                    await appState.ascManager.fetchApp(bundleId: bundleId)
                }
            }

        default:
            return mcpText("Unknown tab: \(tab)")
        }

        // Clear pending values
        _ = await MainActor.run { appState.ascManager.pendingFormValues.removeValue(forKey: tab) }

        return mcpJSON(["success": true, "tab": tab, "fieldsUpdated": fieldMap.count])
    }

    private func executeASCUploadScreenshots(_ args: [String: Any]) async throws -> [String: Any] {
        guard let rawPaths = args["screenshotPaths"] as? [String],
              let displayType = args["displayType"] as? String else {
            throw MCPServerService.MCPError.invalidToolArgs
        }
        let locale = args["locale"] as? String ?? "en-US"

        // Expand ~ and validate paths exist
        let paths = rawPaths.map { ($0 as NSString).expandingTildeInPath }
        for path in paths {
            guard FileManager.default.fileExists(atPath: path) else {
                return mcpText("Error: file not found at \(path)")
            }
        }

        await appState.ascManager.uploadScreenshots(paths: paths, displayType: displayType, locale: locale)

        if let err = await checkASCWriteError(tab: "screenshots") { return err }
        return mcpJSON(["success": true, "uploaded": paths.count])
    }

    private func executeASCOpenSubmitPreview() async -> [String: Any] {
        // Navigation already done by preNavigateASCTool
        var readiness = await MainActor.run { appState.ascManager.submissionReadiness }

        // If Build is the only (or one of the) missing fields, try to auto-attach
        let buildMissing = readiness.missingRequired.contains { $0.label == "Build" }
        if buildMissing {
            // Refresh builds list from ASC
            let service = await MainActor.run { appState.ascManager.service }
            let appId = await MainActor.run { appState.ascManager.app?.id }
            if let service, let appId {
                // Fetch latest builds
                if let latestBuild = try? await service.fetchLatestBuild(appId: appId),
                   latestBuild.attributes.processingState == "VALID" {
                    // Find the pending version to attach to
                    let versionId = await MainActor.run { () -> String? in
                        appState.ascManager.appStoreVersions.first {
                            let s = $0.attributes.appStoreState ?? ""
                            return s != "READY_FOR_SALE" && s != "REMOVED_FROM_SALE"
                                && s != "DEVELOPER_REMOVED_FROM_SALE" && !s.isEmpty
                        }?.id ?? appState.ascManager.appStoreVersions.first?.id
                    }
                    if let versionId {
                        do {
                            try await service.attachBuild(versionId: versionId, buildId: latestBuild.id)
                            // Refresh data so readiness reflects the attached build
                            await appState.ascManager.fetchTabData(.ascOverview)
                            readiness = await MainActor.run { appState.ascManager.submissionReadiness }
                        } catch {
                            // Non-fatal: report in missing fields
                        }
                    }
                }
            }
        }

        if !readiness.isComplete {
            let missing = readiness.missingRequired.map { $0.label }
            return mcpJSON(["ready": false, "missing": missing])
        }

        await MainActor.run {
            appState.ascManager.showSubmitPreview = true
        }

        return mcpJSON(["ready": true, "opened": true])
    }

    // MARK: - ASC IAP / Subscriptions / Pricing Tools

    /// Fuzzy price match: "0.99" matches "0.990", "0.99", etc.
    private static func priceMatches(_ customerPrice: String?, target: String) -> Bool {
        guard let customerPrice else { return false }
        guard let a = Double(customerPrice), let b = Double(target) else {
            return customerPrice == target
        }
        return abs(a - b) < 0.001
    }

    private func executeASCSetAppPrice(_ args: [String: Any]) async throws -> [String: Any] {
        guard let priceStr = args["price"] as? String else {
            throw MCPServerService.MCPError.invalidToolArgs
        }
        let effectiveDate = args["effectiveDate"] as? String  // optional: ISO date like "2026-06-01"

        guard let service = await MainActor.run(body: { appState.ascManager.service }) else {
            return mcpText("Error: ASC service not configured")
        }
        guard let appId = await MainActor.run(body: { appState.ascManager.app?.id }) else {
            return mcpText("Error: no ASC app loaded. Open a project with a bundle ID first.")
        }

        // If price is "0" or "0.00", use the existing setPriceFree method
        if let priceVal = Double(priceStr), priceVal < 0.001 {
            try await service.setPriceFree(appId: appId)
            return mcpJSON(["success": true, "price": "0.00", "message": "App set to free"])
        }

        // Fetch price points and find matching one
        let pricePoints = try await service.fetchAppPricePoints(appId: appId)
        guard let match = pricePoints.first(where: { Self.priceMatches($0.attributes.customerPrice, target: priceStr) }) else {
            let available = pricePoints.compactMap { $0.attributes.customerPrice }
                .filter { Double($0) ?? 0 > 0 }
                .prefix(20)
            return mcpText("Error: no price point matching $\(priceStr). Available: \(available.joined(separator: ", "))")
        }

        if let effectiveDate {
            // Scheduled price change: keep current price until effectiveDate, then switch
            let freePoint = pricePoints.first(where: {
                let p = $0.attributes.customerPrice ?? "0"
                return p == "0" || p == "0.0" || p == "0.00"
            })
            // Use free point as default current price
            let currentId = freePoint?.id ?? match.id
            try await service.setScheduledAppPrice(
                appId: appId,
                currentPricePointId: currentId,
                futurePricePointId: match.id,
                effectiveDate: effectiveDate
            )
            return mcpJSON(["success": true, "price": priceStr, "effectiveDate": effectiveDate, "message": "Scheduled price change for \(effectiveDate)"])
        }

        try await service.setAppPrice(appId: appId, pricePointId: match.id)
        return mcpJSON(["success": true, "price": priceStr, "pricePointId": match.id])
    }

    private func executeASCCreateIAP(_ args: [String: Any]) async throws -> [String: Any] {
        guard let productId = args["productId"] as? String,
              let name = args["name"] as? String,
              let type = args["type"] as? String,
              let displayName = args["displayName"] as? String,
              let priceStr = args["price"] as? String,
              let screenshotPath = args["screenshotPath"] as? String else {
            throw MCPServerService.MCPError.invalidToolArgs
        }
        let description = args["description"] as? String

        // Validate type
        let validTypes = ["CONSUMABLE", "NON_CONSUMABLE", "NON_RENEWING_SUBSCRIPTION"]
        guard validTypes.contains(type) else {
            return mcpText("Error: invalid type '\(type)'. Must be one of: \(validTypes.joined(separator: ", "))")
        }

        // Pre-fill form values so the UI shows them
        await MainActor.run {
            var values: [String: String] = [
                "kind": "iap",
                "name": name, "productId": productId, "type": type,
                "displayName": displayName, "price": priceStr
            ]
            if let description { values["description"] = description }
            appState.ascManager.pendingCreateValues = values
        }

        // Delegate to ASCManager (same flow as the SwiftUI form)
        await MainActor.run {
            appState.ascManager.createIAP(
                name: name, productId: productId, type: type,
                displayName: displayName, description: description,
                price: priceStr, screenshotPath: screenshotPath
            )
        }

        // Poll until creation completes
        let result = await pollASCCreation()

        if let error = result {
            return mcpText("Error creating IAP: \(error)")
        }

        return mcpJSON([
            "success": true,
            "productId": productId,
            "type": type,
            "displayName": displayName,
            "price": priceStr
        ] as [String: Any])
    }

    private func executeASCCreateSubscription(_ args: [String: Any]) async throws -> [String: Any] {
        guard let groupName = args["groupName"] as? String,
              let productId = args["productId"] as? String,
              let name = args["name"] as? String,
              let displayName = args["displayName"] as? String,
              let duration = args["duration"] as? String,
              let priceStr = args["price"] as? String,
              let screenshotPath = args["screenshotPath"] as? String else {
            throw MCPServerService.MCPError.invalidToolArgs
        }
        let description = args["description"] as? String

        // Validate duration
        let validDurations = ["ONE_WEEK", "ONE_MONTH", "TWO_MONTHS", "THREE_MONTHS", "SIX_MONTHS", "ONE_YEAR"]
        guard validDurations.contains(duration) else {
            return mcpText("Error: invalid duration '\(duration)'. Must be one of: \(validDurations.joined(separator: ", "))")
        }

        // Pre-fill form values so the UI shows them
        await MainActor.run {
            var values: [String: String] = [
                "kind": "subscription",
                "groupName": groupName, "name": name, "productId": productId,
                "displayName": displayName, "duration": duration, "price": priceStr
            ]
            if let description { values["description"] = description }
            appState.ascManager.pendingCreateValues = values
        }

        // Delegate to ASCManager (same flow as the SwiftUI form)
        await MainActor.run {
            appState.ascManager.createSubscription(
                groupName: groupName, name: name, productId: productId,
                displayName: displayName, description: description,
                duration: duration, price: priceStr, screenshotPath: screenshotPath
            )
        }

        // Poll until creation completes
        let result = await pollASCCreation()

        if let error = result {
            return mcpText("Error creating subscription: \(error)")
        }

        return mcpJSON([
            "success": true,
            "groupName": groupName,
            "productId": productId,
            "displayName": displayName,
            "duration": duration,
            "price": priceStr
        ] as [String: Any])
    }

    /// Poll ASCManager.isCreating until it finishes. Returns the error string if failed, nil on success.
    private func pollASCCreation() async -> String? {
        // Wait for isCreating to become true (task starts)
        for _ in 0..<10 {
            let creating = await MainActor.run { appState.ascManager.isCreating }
            if creating { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // Wait for isCreating to become false (task completes)
        while await MainActor.run(body: { appState.ascManager.isCreating }) {
            try? await Task.sleep(for: .milliseconds(500))
        }
        return await MainActor.run { appState.ascManager.writeError }
    }

    // MARK: - Tab State Tool

    private func executeGetTabState(_ args: [String: Any]) async throws -> [String: Any] {
        let tabStr = args["tab"] as? String
        let tab: AppTab
        if let tabStr, let parsed = AppTab(rawValue: tabStr) {
            tab = parsed
        } else {
            tab = await MainActor.run { appState.activeTab }
        }

        // Build base result on main actor
        var result = await MainActor.run { () -> [String: Any] in
            let asc = appState.ascManager
            var r: [String: Any] = [
                "tab": tab.rawValue,
                "isLoading": asc.isLoadingTab[tab] ?? false,
            ]
            if let error = asc.tabError[tab] { r["error"] = error }
            if let writeErr = asc.writeError { r["writeError"] = writeErr }
            if tab.isASCTab, let app = asc.app {
                r["app"] = ["id": app.id, "name": app.name, "bundleId": app.bundleId] as [String: Any]
            }
            return r
        }

        // Build tab-specific data
        let tabData = await MainActor.run { () -> [String: Any] in
            let projectId = appState.activeProjectId
            return tabStateData(for: tab, asc: appState.ascManager, projectId: projectId)
        }
        for (key, value) in tabData {
            result[key] = value
        }

        return mcpJSON(result)
    }

    /// Extract tab-specific state data. Must be called on MainActor.
    @MainActor
    private func tabStateData(for tab: AppTab, asc: ASCManager, projectId: String?) -> [String: Any] {
        switch tab {
        case .ascOverview:
            if let pid = projectId {
                asc.checkAppIcon(projectId: pid)
            }
            return tabStateASCOverview(asc)
        case .storeListing:
            return tabStateStoreListing(asc)
        case .appDetails:
            return tabStateAppDetails(asc)
        case .review:
            return tabStateReview(asc)
        case .screenshots:
            return tabStateScreenshots(asc)
        case .reviews:
            return tabStateReviews(asc)
        case .builds:
            return tabStateBuilds(asc)
        case .groups:
            return tabStateGroups(asc)
        case .betaInfo:
            return tabStateBetaInfo(asc)
        case .feedback:
            return tabStateFeedback(asc)
        default:
            return ["note": "No structured state available for this tab"]
        }
    }

    @MainActor
    private func tabStateASCOverview(_ asc: ASCManager) -> [String: Any] {
        let readiness = asc.submissionReadiness
        var fields: [[String: Any]] = []
        for f in readiness.fields {
            let filled = f.value != nil && !f.value!.isEmpty
            fields.append(["label": f.label, "value": f.value as Any, "required": f.required, "filled": filled])
        }
        var r: [String: Any] = [
            "submissionReadiness": [
                "isComplete": readiness.isComplete,
                "fields": fields,
                "missingRequired": readiness.missingRequired.map { $0.label }
            ] as [String: Any],
            "totalVersions": asc.appStoreVersions.count
        ]
        if let v = asc.appStoreVersions.first {
            r["latestVersion"] = ["id": v.id, "versionString": v.attributes.versionString, "state": v.attributes.appStoreState ?? "unknown"] as [String: Any]
        }
        return r
    }

    @MainActor
    private func tabStateStoreListing(_ asc: ASCManager) -> [String: Any] {
        let loc = asc.localizations.first
        let infoLoc = asc.appInfoLocalization
        return [
            "localization": [
                "locale": loc?.attributes.locale ?? "",
                "name": infoLoc?.attributes.name ?? loc?.attributes.title ?? "",
                "subtitle": infoLoc?.attributes.subtitle ?? loc?.attributes.subtitle ?? "",
                "description": loc?.attributes.description ?? "",
                "keywords": loc?.attributes.keywords ?? "",
                "promotionalText": loc?.attributes.promotionalText ?? "",
                "marketingUrl": loc?.attributes.marketingUrl ?? "",
                "supportUrl": loc?.attributes.supportUrl ?? "",
                "whatsNew": loc?.attributes.whatsNew ?? ""
            ] as [String: Any],
            "privacyPolicyUrl": infoLoc?.attributes.privacyPolicyUrl ?? "",
            "localeCount": asc.localizations.count
        ]
    }

    @MainActor
    private func tabStateAppDetails(_ asc: ASCManager) -> [String: Any] {
        var r: [String: Any] = [
            "appInfo": [
                "primaryCategory": asc.appInfo?.primaryCategoryId ?? "",
                "contentRightsDeclaration": asc.app?.contentRightsDeclaration ?? ""
            ] as [String: Any],
            "versionCount": asc.appStoreVersions.count
        ]
        if let v = asc.appStoreVersions.first {
            r["latestVersion"] = ["versionString": v.attributes.versionString, "state": v.attributes.appStoreState ?? "unknown"] as [String: Any]
        }
        return r
    }

    @MainActor
    private func tabStateReview(_ asc: ASCManager) -> [String: Any] {
        var r: [String: Any] = [:]

        if let ar = asc.ageRatingDeclaration {
            let a = ar.attributes
            var arDict: [String: Any] = ["id": ar.id]
            arDict["gambling"] = a.gambling ?? false
            arDict["messagingAndChat"] = a.messagingAndChat ?? false
            arDict["unrestrictedWebAccess"] = a.unrestrictedWebAccess ?? false
            arDict["userGeneratedContent"] = a.userGeneratedContent ?? false
            arDict["advertising"] = a.advertising ?? false
            arDict["lootBox"] = a.lootBox ?? false
            arDict["healthOrWellnessTopics"] = a.healthOrWellnessTopics ?? false
            arDict["parentalControls"] = a.parentalControls ?? false
            arDict["ageAssurance"] = a.ageAssurance ?? false
            arDict["alcoholTobaccoOrDrugUseOrReferences"] = a.alcoholTobaccoOrDrugUseOrReferences ?? "NONE"
            arDict["contests"] = a.contests ?? "NONE"
            arDict["gamblingSimulated"] = a.gamblingSimulated ?? "NONE"
            arDict["gunsOrOtherWeapons"] = a.gunsOrOtherWeapons ?? "NONE"
            arDict["horrorOrFearThemes"] = a.horrorOrFearThemes ?? "NONE"
            arDict["matureOrSuggestiveThemes"] = a.matureOrSuggestiveThemes ?? "NONE"
            arDict["medicalOrTreatmentInformation"] = a.medicalOrTreatmentInformation ?? "NONE"
            arDict["profanityOrCrudeHumor"] = a.profanityOrCrudeHumor ?? "NONE"
            arDict["sexualContentGraphicAndNudity"] = a.sexualContentGraphicAndNudity ?? "NONE"
            arDict["sexualContentOrNudity"] = a.sexualContentOrNudity ?? "NONE"
            arDict["violenceCartoonOrFantasy"] = a.violenceCartoonOrFantasy ?? "NONE"
            arDict["violenceRealistic"] = a.violenceRealistic ?? "NONE"
            arDict["violenceRealisticProlongedGraphicOrSadistic"] = a.violenceRealisticProlongedGraphicOrSadistic ?? "NONE"
            r["ageRating"] = arDict
        }

        if let rd = asc.reviewDetail {
            let a = rd.attributes
            r["reviewContact"] = [
                "contactFirstName": a.contactFirstName ?? "",
                "contactLastName": a.contactLastName ?? "",
                "contactEmail": a.contactEmail ?? "",
                "contactPhone": a.contactPhone ?? "",
                "notes": a.notes ?? "",
                "demoAccountRequired": a.demoAccountRequired ?? false,
                "demoAccountName": a.demoAccountName ?? "",
                "demoAccountPassword": a.demoAccountPassword ?? ""
            ] as [String: Any]
        }

        r["builds"] = asc.builds.prefix(10).map { b -> [String: Any] in
            ["id": b.id, "version": b.attributes.version, "processingState": b.attributes.processingState ?? "unknown", "uploadedDate": b.attributes.uploadedDate ?? ""]
        }
        return r
    }

    @MainActor
    private func tabStateScreenshots(_ asc: ASCManager) -> [String: Any] {
        let sets = asc.screenshotSets.map { s -> [String: Any] in
            var set: [String: Any] = ["id": s.id, "displayType": s.attributes.screenshotDisplayType]
            if let shots = asc.screenshots[s.id] {
                set["screenshotCount"] = shots.count
                set["screenshots"] = shots.map { ["id": $0.id, "fileName": $0.attributes.fileName ?? ""] as [String: Any] }
            }
            return set
        }
        return ["screenshotSets": sets, "localeCount": asc.localizations.count]
    }

    @MainActor
    private func tabStateReviews(_ asc: ASCManager) -> [String: Any] {
        let reviews = asc.customerReviews.prefix(20).map { r -> [String: Any] in
            ["id": r.id, "title": r.attributes.title ?? "", "body": r.attributes.body ?? "", "rating": r.attributes.rating, "reviewerNickname": r.attributes.reviewerNickname ?? ""]
        }
        return ["reviews": reviews, "totalReviews": asc.customerReviews.count]
    }

    @MainActor
    private func tabStateBuilds(_ asc: ASCManager) -> [String: Any] {
        let builds = asc.builds.prefix(20).map { b -> [String: Any] in
            ["id": b.id, "version": b.attributes.version, "processingState": b.attributes.processingState ?? "unknown", "uploadedDate": b.attributes.uploadedDate ?? ""]
        }
        return ["builds": builds]
    }

    @MainActor
    private func tabStateGroups(_ asc: ASCManager) -> [String: Any] {
        let groups = asc.betaGroups.map { g -> [String: Any] in
            ["id": g.id, "name": g.attributes.name, "isInternalGroup": g.attributes.isInternalGroup ?? false]
        }
        return ["betaGroups": groups]
    }

    @MainActor
    private func tabStateBetaInfo(_ asc: ASCManager) -> [String: Any] {
        let locs = asc.betaLocalizations.map { l -> [String: Any] in
            ["id": l.id, "locale": l.attributes.locale, "description": l.attributes.description ?? ""]
        }
        return ["betaLocalizations": locs]
    }

    @MainActor
    private func tabStateFeedback(_ asc: ASCManager) -> [String: Any] {
        var items: [[String: Any]] = []
        for (buildId, feedbackItems) in asc.betaFeedback {
            for item in feedbackItems {
                items.append(["buildId": buildId, "id": item.id, "comment": item.attributes.comment ?? "", "timestamp": item.attributes.timestamp ?? ""])
            }
        }
        return ["feedback": items, "selectedBuildId": asc.selectedBuildId ?? ""]
    }

    // MARK: - Build Pipeline Tools

    private func executeSetupSigning(_ args: [String: Any]) async throws -> [String: Any] {
        let (optCtx, err) = await requireBuildContext()
        guard let ctx = optCtx else { return err! }
        let project = ctx.project
        let bundleId = ctx.bundleId
        let service = ctx.service
        let teamId = args["teamId"] as? String ?? (ctx.teamId.isEmpty ? nil : ctx.teamId)

        await MainActor.run {
            appState.ascManager.buildPipelinePhase = .signingSetup
            appState.ascManager.buildPipelineMessage = "Setting up signing…"
        }

        let pipeline = BuildPipelineService()
        let appStateRef = appState
        do {
            // Run with 5-minute overall timeout to prevent silent hangs
            let result = try await withThrowingTimeout(seconds: 300) {
                try await pipeline.setupSigning(
                    projectPath: project.path,
                    bundleId: bundleId,
                    teamId: teamId,
                    ascService: service,
                    onProgress: { msg in
                        Task { @MainActor in
                            appStateRef.ascManager.buildPipelineMessage = msg
                        }
                    }
                )
            }

            // Persist teamId to project metadata on success
            if !result.teamId.isEmpty {
                await MainActor.run {
                    let storage = ProjectStorage()
                    guard var metadata = storage.readMetadata(projectId: project.id) else { return }
                    metadata.teamId = result.teamId
                    try? storage.writeMetadata(projectId: project.id, metadata: metadata)
                }
            }

            await MainActor.run {
                appState.ascManager.buildPipelinePhase = .idle
                appState.ascManager.buildPipelineMessage = ""
            }

            return mcpJSON([
                "success": true,
                "bundleIdResourceId": result.bundleIdResourceId,
                "certificateId": result.certificateId,
                "profileUUID": result.profileUUID,
                "teamId": result.teamId,
                "log": result.log
            ] as [String: Any])
        } catch {
            await MainActor.run {
                appState.ascManager.buildPipelinePhase = .idle
                appState.ascManager.buildPipelineMessage = ""
            }
            return mcpText("Error in signing setup: \(error.localizedDescription)")
        }
    }

    private func executeBuildIPA(_ args: [String: Any]) async throws -> [String: Any] {
        let (optCtx, err) = await requireBuildContext(needsTeamId: true)
        guard let ctx = optCtx else { return err! }
        let project = ctx.project
        let bundleId = ctx.bundleId
        let teamId = ctx.teamId

        let scheme = args["scheme"] as? String
        let configuration = args["configuration"] as? String

        await MainActor.run {
            appState.ascManager.buildPipelinePhase = .archiving
            appState.ascManager.buildPipelineMessage = "Starting build…"
        }

        let pipeline = BuildPipelineService()
        let appStateRef = appState
        do {
            let result = try await pipeline.buildIPA(
                projectPath: project.path,
                bundleId: bundleId,
                teamId: teamId,
                scheme: scheme,
                configuration: configuration,
                onProgress: { msg in
                    Task { @MainActor in
                        // Detect phase transitions from build output
                        if msg.contains("ARCHIVE SUCCEEDED") || msg.contains("-exportArchive") {
                            appStateRef.ascManager.buildPipelinePhase = .exporting
                        }
                        appStateRef.ascManager.buildPipelineMessage = String(msg.prefix(120))
                    }
                }
            )

            await MainActor.run {
                appState.ascManager.buildPipelinePhase = .idle
                appState.ascManager.buildPipelineMessage = ""
            }

            return mcpJSON([
                "success": true,
                "ipaPath": result.ipaPath,
                "archivePath": result.archivePath,
                "log": result.log
            ] as [String: Any])
        } catch {
            await MainActor.run {
                appState.ascManager.buildPipelinePhase = .idle
                appState.ascManager.buildPipelineMessage = ""
            }
            return mcpText("Error building IPA: \(error.localizedDescription)")
        }
    }

    private func executeUploadToTestFlight(_ args: [String: Any]) async throws -> [String: Any] {
        guard let credentials = await MainActor.run(body: { appState.ascManager.credentials }) else {
            return mcpText("Error: ASC credentials not configured.")
        }
        guard await MainActor.run(body: { appState.activeProject }) != nil else {
            return mcpText("Error: no active project.")
        }

        // Resolve IPA path
        let ipaPath: String
        if let path = args["ipaPath"] as? String {
            ipaPath = (path as NSString).expandingTildeInPath
        } else {
            // Try to find most recent IPA in /tmp
            let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            let tmpContents = try FileManager.default.contentsOfDirectory(at: tmpURL, includingPropertiesForKeys: [.contentModificationDateKey])
            let exportDirs = tmpContents.filter { $0.lastPathComponent.hasPrefix("BlitzExport-") }
                .sorted { a, b in
                    let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return aDate > bDate
                }
            var foundIPA: String?
            for dir in exportDirs {
                let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                if let ipa = files.first(where: { $0.pathExtension == "ipa" }) {
                    foundIPA = ipa.path
                    break
                }
            }
            guard let found = foundIPA else {
                return mcpText("Error: no IPA path provided and no recent build found. Run app_store_build first.")
            }
            ipaPath = found
        }

        guard FileManager.default.fileExists(atPath: ipaPath) else {
            return mcpText("Error: IPA not found at \(ipaPath)")
        }

        let skipPolling = args["skipPolling"] as? Bool ?? false

        // Get app ID for polling
        let appId = await MainActor.run { appState.ascManager.app?.id }
        let service = await MainActor.run { appState.ascManager.service }

        // --- Pre-upload validation: build version & encryption key ---
        var existingVersions: Set<String> = []
        do {
            // Extract IPA plist fields in one pass
            let plistXML = try await ProcessRunner.run(
                "/bin/bash",
                arguments: ["-c", "unzip -p '\(ipaPath)' 'Payload/*.app/Info.plist' | plutil -convert xml1 -o - -"]
            )

            // Check CFBundleVersion
            let ipaVersion: String? = {
                guard let range = plistXML.range(of: "<key>CFBundleVersion</key>"),
                      let valueStart = plistXML.range(of: "<string>", range: range.upperBound..<plistXML.endIndex),
                      let valueEnd = plistXML.range(of: "</string>", range: valueStart.upperBound..<plistXML.endIndex) else { return nil }
                return String(plistXML[valueStart.upperBound..<valueEnd.lowerBound])
            }()

            // Check ITSAppUsesNonExemptEncryption
            let hasEncryptionKey = plistXML.contains("ITSAppUsesNonExemptEncryption")
            if !hasEncryptionKey {
                return mcpText(
                    "Error: ITSAppUsesNonExemptEncryption is not set in the IPA's Info.plist. "
                    + "Without this key, App Store Connect will require manual encryption compliance confirmation in the web UI after every upload. "
                    + "Fix: add INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO to your Xcode build settings (both Debug and Release), then rebuild. "
                    + "Or add <key>ITSAppUsesNonExemptEncryption</key><false/> directly to Info.plist."
                )
            }

            // Validate build version against existing builds
            if let ipaVersion, !ipaVersion.isEmpty, let appId, let service {
                let builds = try await service.fetchBuilds(appId: appId)
                existingVersions = Set(builds.map(\.attributes.version))
                if existingVersions.contains(ipaVersion) {
                    let maxVersion = existingVersions.compactMap { Int($0) }.max() ?? 0
                    return mcpText(
                        "Error: build version \(ipaVersion) already exists in App Store Connect. "
                        + "Existing build versions: \(existingVersions.sorted().joined(separator: ", ")). "
                        + "The next valid build version is \(maxVersion + 1). "
                        + "Update CFBundleVersion in Info.plist (or CURRENT_PROJECT_VERSION in the Xcode build settings) and rebuild."
                    )
                }
            }
        } catch {
            // Non-fatal — proceed with upload and let altool catch any issues
        }

        // If we didn't capture existing versions above, fetch them now for polling comparison
        if existingVersions.isEmpty, let appId, let service {
            existingVersions = Set((try? await service.fetchBuilds(appId: appId))?.map(\.attributes.version) ?? [])
        }

        // --- Upload ---
        await MainActor.run {
            appState.ascManager.buildPipelinePhase = .uploading
            appState.ascManager.buildPipelineMessage = "Uploading IPA…"
        }

        let pipeline = BuildPipelineService()
        let appStateRef = appState
        do {
            // Always skip BuildPipelineService's built-in polling — we poll ourselves below
            let result = try await pipeline.uploadToTestFlight(
                ipaPath: ipaPath,
                keyId: credentials.keyId,
                issuerId: credentials.issuerId,
                privateKeyPEM: credentials.privateKey,
                appId: appId,
                ascService: service,
                skipPolling: true,
                onProgress: { msg in
                    Task { @MainActor in
                        appStateRef.ascManager.buildPipelineMessage = String(msg.prefix(120))
                    }
                }
            )

            var allLog = result.log
            var finalState = result.processingState
            var finalVersion = result.buildVersion

            // --- Poll for new build to appear (every 10s, up to 300s) ---
            if !skipPolling, let appId, let service {
                await MainActor.run {
                    appStateRef.ascManager.buildPipelinePhase = .processing
                    appStateRef.ascManager.buildPipelineMessage = "Waiting for new build to appear…"
                }

                let pollInterval: TimeInterval = 10
                let maxAttempts = 30 // 300 seconds total

                for attempt in 1...maxAttempts {
                    try? await Task.sleep(for: .seconds(pollInterval))

                    guard let builds = try? await service.fetchBuilds(appId: appId) else { continue }

                    if let newBuild = builds.first(where: { !existingVersions.contains($0.attributes.version) }) {
                        let state = newBuild.attributes.processingState ?? "UNKNOWN"
                        let version = newBuild.attributes.version
                        let msg = "Poll \(attempt): build \(version) — \(state)"
                        allLog.append(msg)
                        await MainActor.run {
                            appStateRef.ascManager.buildPipelineMessage = msg
                            appStateRef.ascManager.builds = builds
                        }

                        finalVersion = version
                        finalState = state

                        if state == "VALID" {
                            allLog.append("Build processing complete!")
                            // Auto-set encryption exemption via API as backup
                            try? await service.patchBuildEncryption(
                                buildId: newBuild.id,
                                usesNonExemptEncryption: false
                            )
                            // Auto-attach to pending version
                            let versionId = await MainActor.run(body: {
                                appStateRef.ascManager.pendingVersionId
                            })
                            if let versionId {
                                do {
                                    try await service.attachBuild(versionId: versionId, buildId: newBuild.id)
                                    allLog.append("Build \(version) attached to app store version.")
                                } catch {
                                    allLog.append("Warning: could not auto-attach build \u{2014} \(error.localizedDescription)")
                                }
                            }
                            break
                        } else if state == "INVALID" {
                            allLog.append("Build processing failed with INVALID state.")
                            break
                        }
                        // Still processing — keep polling
                    } else {
                        let msg = "Poll \(attempt): new build not yet visible…"
                        allLog.append(msg)
                        await MainActor.run {
                            appStateRef.ascManager.buildPipelineMessage = msg
                        }
                    }
                }
            }

            // --- Finalize: reset UI and refresh tab data ---
            await MainActor.run {
                appState.ascManager.buildPipelinePhase = .idle
                appState.ascManager.buildPipelineMessage = ""
            }
            await appState.ascManager.refreshTabData(.builds)

            var response: [String: Any] = [
                "success": true,
                "processingState": finalState ?? "UNKNOWN",
                "log": allLog
            ]
            if let version = finalVersion {
                response["buildVersion"] = version
            }
            return mcpJSON(response)
        } catch {
            await MainActor.run {
                appState.ascManager.buildPipelinePhase = .idle
                appState.ascManager.buildPipelineMessage = ""
            }
            return mcpText("Error uploading to TestFlight: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func mcpText(_ text: String) -> [String: Any] {
        ["content": [["type": "text", "text": text]]]
    }

    private func mcpJSON(_ value: Any) -> [String: Any] {
        if let data = try? JSONSerialization.data(withJSONObject: value),
           let str = String(data: data, encoding: .utf8) {
            return mcpText(str)
        }
        return mcpText("{}")
    }

    /// Check for ASC write error and return it, clearing pending form values.
    private func checkASCWriteError(tab: String) async -> [String: Any]? {
        guard let error = await MainActor.run(body: { appState.ascManager.writeError }) else { return nil }
        _ = await MainActor.run { appState.ascManager.pendingFormValues.removeValue(forKey: tab) }
        return mcpText("Error: \(error)")
    }

    private struct BuildContext {
        let project: Project
        let bundleId: String
        let teamId: String
        let service: AppStoreConnectService
    }

    /// Resolve and validate bundle ID + ASC service for build pipeline tools.
    /// Returns (context, nil) on success or (nil, errorResponse) on failure.
    private func requireBuildContext(needsTeamId: Bool = false) async -> (BuildContext?, [String: Any]?) {
        guard let project = await MainActor.run(body: { appState.activeProject }) else {
            return (nil, mcpText("Error: no active project."))
        }
        guard let service = await MainActor.run(body: { appState.ascManager.service }) else {
            return (nil, mcpText("Error: ASC credentials not configured."))
        }
        let bundleId = await MainActor.run { () -> String? in
            ProjectStorage().readMetadata(projectId: project.id)?.bundleIdentifier
        }
        guard let bundleId, !bundleId.isEmpty else {
            return (nil, mcpText("Error: no bundle identifier set. Use asc_fill_form tab=settings.bundleId to set it first."))
        }
        let ascBundleId = await MainActor.run { appState.ascManager.app?.bundleId }
        if let ascBundleId, !ascBundleId.isEmpty, ascBundleId != bundleId {
            return (nil, mcpText("Error: bundle ID mismatch. Project has '\(bundleId)' but ASC app uses '\(ascBundleId)'."))
        }
        let teamId = await MainActor.run { () -> String? in
            ProjectStorage().readMetadata(projectId: project.id)?.teamId
        }
        if needsTeamId, (teamId == nil || teamId!.isEmpty) {
            return (nil, mcpText("Error: no team ID set. Run app_store_setup_signing first."))
        }
        return (BuildContext(project: project, bundleId: bundleId, teamId: teamId ?? "", service: service), nil)
    }
}
