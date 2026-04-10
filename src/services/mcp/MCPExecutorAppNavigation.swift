import Foundation

extension MCPExecutor {
    // MARK: - App State Tools

    func executeAppGetState() async throws -> [String: Any] {
        let state = await MainActor.run { () -> [String: Any] in
            var result: [String: Any] = [
                "activeTab": appState.activeTab.rawValue,
                "activeAppSubTab": appState.activeAppSubTab.rawValue,
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
            return result
        }
        return mcpJSON(state)
    }

    // MARK: - Navigation Tools

    func executeNavSwitchTab(_ args: [String: Any]) async throws -> [String: Any] {
        guard let tabStr = args["tab"] as? String else {
            throw MCPServerService.MCPError.invalidToolArgs
        }

        let legacySubTabMap: [String: AppSubTab] = [
            "simulator": .simulator,
            "tests": .tests,
            "assets": .icon,
            "icon": .icon,
            "ascOverview": .overview,
            "overview": .overview,
        ]

        if let subTab = legacySubTabMap[tabStr] {
            await MainActor.run {
                appState.activeTab = .app
                appState.activeAppSubTab = subTab
            }

            return mcpText("Switched to App > \(subTab.label)")
        }

        guard let tab = MCPAppInformationCompatibility.resolveAppTab(tabStr) else {
            throw MCPServerService.MCPError.invalidToolArgs
        }
        await MainActor.run { appState.activeTab = tab }

        return mcpText("Switched to tab: \(tab.label)")
    }

    func executeNavListTabs() async -> [String: Any] {
        let topLevel: [[String: Any]] = [
            ["name": "dashboard", "label": "Dashboard", "icon": "square.grid.2x2"],
            [
                "name": "app",
                "label": "App",
                "icon": "app",
                "subTabs": AppSubTab.allCases.map {
                    ["name": $0.rawValue, "label": $0.label, "icon": $0.systemImage] as [String: Any]
                }
            ],
        ]
        var groups: [[String: Any]] = [["group": "Top", "tabs": topLevel]]
        for group in AppTab.Group.allCases {
            let tabs = group.tabs.map {
                ["name": $0.rawValue, "label": $0.label, "icon": $0.icon] as [String: Any]
            }
            groups.append(["group": group.rawValue, "tabs": tabs])
        }
        groups.append(["group": "Other", "tabs": [["name": "settings", "label": "Settings", "icon": "gear"]]])
        return mcpJSON(["groups": groups])
    }
}
