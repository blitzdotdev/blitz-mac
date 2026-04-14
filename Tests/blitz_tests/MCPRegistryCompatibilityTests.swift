import Testing
@testable import Blitz

struct MCPRegistryCompatibilityTests {
    @Test func tabSchemasDoNotAdvertiseRemovedLegacyTabs() throws {
        let tools = MCPRegistry.allTools()

        let navSwitchTab = try #require(tool(named: "nav_switch_tab", in: tools))
        let navEnum = try #require(enumValues(for: "tab", in: navSwitchTab))
        #expect(!navEnum.contains("storeListing"))
        #expect(!navEnum.contains("appDetails"))

        let getTabState = try #require(tool(named: "get_tab_state", in: tools))
        let stateEnum = try #require(enumValues(for: "tab", in: getTabState))
        #expect(!stateEnum.contains("storeListing"))
        #expect(!stateEnum.contains("appDetails"))
    }

    @Test func ascFillFormStillAdvertisesLegacyAppInformationAliases() throws {
        let tools = MCPRegistry.allTools()
        let fillForm = try #require(tool(named: "asc_fill_form", in: tools))
        let fillEnum = try #require(enumValues(for: "tab", in: fillForm))
        #expect(fillEnum.contains("storeListing"))
        #expect(fillEnum.contains("appDetails"))
    }

    @Test func ascConfirmCreatedAppIsRegisteredAsQueryTool() throws {
        let tools = MCPRegistry.allTools()
        let confirmCreatedApp = try #require(tool(named: "asc_confirm_created_app", in: tools))
        #expect(MCPRegistry.category(for: "asc_confirm_created_app") == .query)
        let properties = try #require((confirmCreatedApp["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])
        #expect(properties["bundleId"] != nil)
    }

    @Test func screenshotRegistryUsesDirectTrackTools() {
        let tools = MCPRegistry.allTools()
        #expect(tool(named: "screenshots_add_asset", in: tools) == nil)
        #expect(tool(named: "screenshots_set_track", in: tools) == nil)
        #expect(tool(named: "screenshots_put_track_slot", in: tools) != nil)
        #expect(tool(named: "screenshots_remove_track_slot", in: tools) != nil)
        #expect(tool(named: "screenshots_reorder_track", in: tools) != nil)
    }

    private func tool(named name: String, in tools: [[String: Any]]) -> [String: Any]? {
        tools.first { $0["name"] as? String == name }
    }

    private func enumValues(for property: String, in tool: [String: Any]) -> [String]? {
        let properties = tool["inputSchema"] as? [String: Any]
        let schemaProperties = properties?["properties"] as? [String: Any]
        let field = schemaProperties?[property] as? [String: Any]
        return field?["enum"] as? [String]
    }
}
