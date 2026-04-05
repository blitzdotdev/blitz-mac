import AppKit
import Foundation
import Security

/// Runs an async operation with a timeout. Throws CancellationError if the deadline is exceeded.
func withThrowingTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
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
actor MCPExecutor {
    private struct NavigationState: Sendable {
        let tab: AppTab
        let appSubTab: AppSubTab
    }

    let appState: AppState
    private static let gateableCategories: [ApprovalRequest.ToolCategory] = [
        .ascFormMutation, .ascScreenshotMutation, .ascSubmitMutation,
        .buildPipeline, .projectMutation, .settingsMutation, .simulatorControl,
    ]

    init(appState: AppState) {
        self.appState = appState
    }

    func parseFieldMap(_ rawFields: Any?, applyAliases: Bool) -> [String: String] {
        var fieldMap: [String: String] = [:]
        let mapField: (String) -> String = { field in
            applyAliases ? (Self.fieldAliases[field] ?? field) : field
        }

        if let fieldsArray = rawFields as? [[String: Any]] {
            for item in fieldsArray {
                if let field = item["field"] as? String, let value = item["value"] as? String {
                    fieldMap[mapField(field)] = value
                }
            }
        } else if let fieldsDict = rawFields as? [String: Any] {
            for (key, value) in fieldsDict {
                fieldMap[mapField(key)] = "\(value)"
            }
        } else if let fieldsString = rawFields as? String,
                  let data = fieldsString.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) {
            fieldMap = parseFieldMap(parsed, applyAliases: applyAliases)
        }

        return fieldMap
    }

    /// Execute a tool call, requesting approval if needed.
    func execute(name: String, arguments: [String: Any]) async throws -> [String: Any] {
        let category = MCPRegistry.category(for: name)

        // Pre-navigate for ASC form tools so the user sees the target tab before approving.
        var previousNavigation: NavigationState?
        if name == "asc_fill_form" || name == "asc_create_version" || name == "asc_open_submit_preview"
            || name == "store_listing_switch_localization"
            || name == "asc_create_iap" || name == "asc_create_subscription" || name == "asc_set_app_price"
            || name == "screenshots_switch_localization"
            || name == "screenshots_add_asset" || name == "screenshots_set_track" || name == "screenshots_save" {
            previousNavigation = await preNavigateASCTool(name: name, arguments: arguments)
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
                if let prev = previousNavigation {
                    await MainActor.run {
                        appState.activeTab = prev.tab
                        appState.activeAppSubTab = prev.appSubTab
                    }
                    _ = await MainActor.run { appState.ascManager.pendingFormValues.removeAll() }
                }
                return mcpText("Tool '\(name)' was denied by the user.")
            }
        }

        return try await executeTool(name: name, arguments: arguments)
    }

    /// Navigate to the appropriate tab before approval, and set pending form values.
    /// Returns the previous navigation state so we can navigate back if denied.
    private func preNavigateASCTool(name: String, arguments: [String: Any]) async -> NavigationState {
        let previousNavigation = await MainActor.run {
            NavigationState(tab: appState.activeTab, appSubTab: appState.activeAppSubTab)
        }

        let targetTab: AppTab?
        let targetAppSubTab: AppSubTab?
        if name == "asc_fill_form" {
            let tab = arguments["tab"] as? String ?? ""
            switch tab {
            case "storeListing":
                targetTab = .storeListing
            case "appDetails":
                targetTab = .appDetails
            case "monetization":
                targetTab = .monetization
            case "review.ageRating", "review.contact":
                targetTab = .review
            case "settings.bundleId":
                targetTab = .settings
            default:
                targetTab = nil
            }
            targetAppSubTab = nil
        } else if name == "store_listing_switch_localization" {
            targetTab = .storeListing
            targetAppSubTab = nil
        } else if name == "asc_create_version" || name == "asc_open_submit_preview" {
            targetTab = .app
            targetAppSubTab = .overview
        } else if name == "screenshots_switch_localization"
                    || name == "screenshots_add_asset"
                    || name == "screenshots_set_track" || name == "screenshots_save" {
            targetTab = .screenshots
            targetAppSubTab = nil
        } else if name == "asc_set_app_price" {
            targetTab = .monetization
            targetAppSubTab = nil
        } else if name == "asc_create_iap" || name == "asc_create_subscription" {
            targetTab = .monetization
            targetAppSubTab = nil
        } else {
            targetTab = nil
            targetAppSubTab = nil
        }

        if let targetTab {
            await MainActor.run {
                appState.activeTab = targetTab
                if let targetAppSubTab {
                    appState.activeAppSubTab = targetAppSubTab
                }
            }
            if targetTab == .app, targetAppSubTab == .overview {
                await appState.ascManager.ensureTabData(.app)
            } else if targetTab.isASCTab {
                await appState.ascManager.fetchTabData(targetTab)
            }
        }

        if name == "asc_fill_form",
           let tab = arguments["tab"] as? String {
            let fieldMap = parseFieldMap(arguments["fields"], applyAliases: false)

            if !fieldMap.isEmpty {
                let fieldMapCopy = fieldMap
                await MainActor.run {
                    let existing = appState.ascManager.pendingFormValues[tab] ?? [:]
                    appState.ascManager.pendingFormValues[tab] = existing.merging(fieldMapCopy) { _, new in new }
                    appState.ascManager.pendingFormVersion += 1
                }
            }
        }

        return previousNavigation
    }

    // MARK: - Approval Flow

    private func requestApproval(_ request: ApprovalRequest) async -> Bool {
        let result = await MainActor.run { () -> (approved: Bool, approveAll: Bool) in
            NSApp.activate(ignoringOtherApps: true)

            let alert = NSAlert()
            alert.messageText = "AI Tool Request"
            alert.informativeText = request.description
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Approve")
            alert.addButton(withTitle: "Deny")

            let checkbox = NSButton(checkboxWithTitle: "Approve all in the future", target: nil, action: nil)
            checkbox.state = .off
            alert.accessoryView = checkbox

            // Auto-deny after 5 minutes
            let timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { _ in
                NSApp.abortModal()
            }

            let response = alert.runModal()
            timer.invalidate()

            if response == .abort {
                return (false, false)
            }
            return (response == .alertFirstButtonReturn, checkbox.state == .on)
        }

        if result.approved && result.approveAll {
            await MainActor.run {
                for category in Self.gateableCategories {
                    SettingsService.shared.permissionToggles[category.rawValue] = true
                }
                SettingsService.shared.save()
            }
        }

        return result.approved
    }

    // MARK: - Tool Dispatch

    func executeTool(name: String, arguments: [String: Any]) async throws -> [String: Any] {
        switch name {
        case "app_get_state":
            return try await executeAppGetState()

        case "nav_switch_tab":
            return try await executeNavSwitchTab(arguments)
        case "nav_list_tabs":
            return await executeNavListTabs()

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

        case "simulator_list_devices":
            return await executeSimulatorListDevices()
        case "simulator_select_device":
            return try await executeSimulatorSelectDevice(arguments)

        case "settings_get":
            return await executeSettingsGet()
        case "settings_update":
            return await executeSettingsUpdate(arguments)
        case "settings_save":
            return await executeSettingsSave()

        case "get_rejection_feedback":
            return try await executeGetRejectionFeedback(arguments)
        case "get_tab_state":
            return try await executeGetTabState(arguments)

        case "asc_set_credentials":
            return await executeASCSetCredentials(arguments)
        case "asc_fill_form":
            return try await executeASCFillForm(arguments)
        case "store_listing_switch_localization":
            return try await executeStoreListingSwitchLocalization(arguments)
        case "asc_select_version":
            return try await executeASCSelectVersion(arguments)
        case "asc_create_version":
            return try await executeASCCreateVersion(arguments)
        case "screenshots_switch_localization":
            return try await executeScreenshotsSwitchLocalization(arguments)
        case "screenshots_add_asset":
            return try await executeScreenshotsAddAsset(arguments)
        case "screenshots_set_track":
            return try await executeScreenshotsSetTrack(arguments)
        case "screenshots_save":
            return try await executeScreenshotsSave(arguments)
        case "asc_open_submit_preview":
            return await executeASCOpenSubmitPreview()
        case "asc_create_iap":
            return try await executeASCCreateIAP(arguments)
        case "asc_create_subscription":
            return try await executeASCCreateSubscription(arguments)
        case "asc_set_app_price":
            return try await executeASCSetAppPrice(arguments)
        case "asc_web_auth":
            return await executeASCWebAuth()

        case "app_store_setup_signing":
            return try await executeSetupSigning(arguments)
        case "app_store_build":
            return try await executeBuildIPA(arguments)
        case "app_store_upload":
            return try await executeUploadToTestFlight(arguments)

        case "get_blitz_screenshot":
            let path = "/tmp/blitz-app-screenshot-\(Int(Date().timeIntervalSince1970)).png"
            let saved = await MainActor.run { () -> Bool in
                guard let window = NSApp.windows.first(where: {
                    $0.title != "Welcome to Blitz" && $0.canBecomeMain && $0.isVisible
                }) ?? NSApp.mainWindow else {
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
            return saved ? mcpText(path) : mcpText("Error: could not capture Blitz window screenshot")

        default:
            throw MCPServerService.MCPError.unknownTool(name)
        }
    }

    // MARK: - Shared Helpers

    func mcpText(_ text: String) -> [String: Any] {
        ["content": [["type": "text", "text": text]]]
    }

    func mcpJSON(_ value: Any) -> [String: Any] {
        if let data = try? JSONSerialization.data(withJSONObject: value),
           let str = String(data: data, encoding: .utf8) {
            return mcpText(str)
        }
        return mcpText("{}")
    }

    /// Check for ASC write error and return it, clearing pending form values.
    func checkASCWriteError(tab: String) async -> [String: Any]? {
        let error = await MainActor.run { () -> String? in
            let asc = appState.ascManager
            let current = asc.writeError
            if current != nil {
                asc.writeError = nil
                asc.pendingFormValues.removeValue(forKey: tab)
            }
            return current
        }
        guard let error else { return nil }
        return mcpText("Error: \(error)")
    }

    struct BuildContext {
        let project: Project
        let bundleId: String
        let teamId: String
        let service: AppStoreConnectService
    }

    /// Resolve and validate bundle ID + ASC service for build pipeline tools.
    /// Returns `(context, nil)` on success or `(nil, errorResponse)` on failure.
    func requireBuildContext(needsTeamId: Bool = false) async -> (BuildContext?, [String: Any]?) {
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
            return (nil, mcpText(
                "Error: no bundle identifier set. Use asc_fill_form tab=settings.bundleId to set it first."
            ))
        }
        let ascBundleId = await MainActor.run { appState.ascManager.app?.bundleId }
        if let ascBundleId, !ascBundleId.isEmpty, ascBundleId != bundleId {
            return (
                nil,
                mcpText("Error: bundle ID mismatch. Project has '\(bundleId)' but ASC app uses '\(ascBundleId)'.")
            )
        }
        let teamId = await MainActor.run { () -> String? in
            ProjectStorage().readMetadata(projectId: project.id)?.teamId
        }
        if needsTeamId, (teamId == nil || teamId?.isEmpty == true) {
            return (nil, mcpText("Error: no team ID set. Run app_store_setup_signing first."))
        }
        return (BuildContext(project: project, bundleId: bundleId, teamId: teamId ?? "", service: service), nil)
    }
}
