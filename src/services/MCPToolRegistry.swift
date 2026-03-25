import Foundation

/// Static definitions for all MCP tools exposed by Blitz
enum MCPToolRegistry {

    /// Returns all tool definitions for the MCP tools/list response
    static func allTools() -> [[String: Any]] {
        var tools: [[String: Any]] = []

        // -- App State --
        tools.append(tool(
            name: "app_get_state",
            description: "Get current project, active tab, and streaming status",
            properties: [:],
            required: []
        ))

        // -- Navigation --
        tools.append(tool(
            name: "nav_switch_tab",
            description: "Switch the active sidebar tab",
            properties: [
                "tab": ["type": "string", "description": "Tab name. Use 'dashboard' or 'app' for top-level tabs. Legacy names (simulator, database, tests, assets, ascOverview) map to App sub-tabs.", "enum": [
                    "dashboard", "app",
                    "simulator", "database", "tests", "assets", "overview", "ascOverview",
                    "storeListing", "screenshots", "appDetails", "monetization", "review",
                    "analytics", "reviews",
                    "builds", "groups", "betaInfo", "feedback",
                    "settings"
                ]]
            ],
            required: ["tab"]
        ))

        tools.append(tool(
            name: "nav_list_tabs",
            description: "List all available tabs with their groups",
            properties: [:],
            required: []
        ))

        // -- Projects --
        tools.append(tool(
            name: "project_list",
            description: "List all projects",
            properties: [:],
            required: []
        ))

        tools.append(tool(
            name: "project_get_active",
            description: "Get active project details",
            properties: [:],
            required: []
        ))

        tools.append(tool(
            name: "project_open",
            description: "Open a project by its ID",
            properties: [
                "projectId": ["type": "string", "description": "Project ID to open"]
            ],
            required: ["projectId"]
        ))

        tools.append(tool(
            name: "project_create",
            description: "Create a new Blitz project",
            properties: [
                "name": ["type": "string", "description": "Project name"],
                "type": ["type": "string", "description": "Project type (blitz, react-native, flutter, swift)", "enum": ["blitz", "react-native", "flutter", "swift"]],
                "platform": ["type": "string", "description": "Target platform (iOS or macOS). Defaults to iOS.", "enum": ["iOS", "macOS"]]
            ],
            required: ["name", "type"]
        ))

        tools.append(tool(
            name: "project_import",
            description: "Import an existing project from a path",
            properties: [
                "path": ["type": "string", "description": "Absolute path to project"],
                "type": ["type": "string", "description": "Project type", "enum": ["blitz", "react-native", "flutter", "swift"]],
                "platform": ["type": "string", "description": "Target platform (iOS or macOS). Defaults to iOS.", "enum": ["iOS", "macOS"]]
            ],
            required: ["path", "type"]
        ))

        tools.append(tool(
            name: "project_close",
            description: "Close the current project",
            properties: [:],
            required: []
        ))

        // -- Simulator --
        tools.append(tool(
            name: "simulator_list_devices",
            description: "List all simulators and physical devices",
            properties: [:],
            required: []
        ))

        tools.append(tool(
            name: "simulator_select_device",
            description: "Select and boot a simulator by UDID",
            properties: [
                "udid": ["type": "string", "description": "Device UDID"]
            ],
            required: ["udid"]
        ))


        // -- Settings --
        tools.append(tool(
            name: "settings_get",
            description: "Get current app settings",
            properties: [:],
            required: []
        ))

        tools.append(tool(
            name: "settings_update",
            description: "Update app settings (cursor)",
            properties: [
                "showCursor": ["type": "boolean", "description": "Show cursor overlay"],
                "cursorSize": ["type": "number", "description": "Cursor size in pixels"]
            ],
            required: []
        ))

        tools.append(tool(
            name: "settings_save",
            description: "Save current settings to disk",
            properties: [:],
            required: []
        ))

        tools.append(tool(
            name: "get_blitz_screenshot",
            description: "Capture a screenshot of the Blitz macOS app main window",
            properties: [:],
            required: []
        ))

        // -- Rejection Feedback --
        tools.append(tool(
            name: "get_rejection_feedback",
            description: "Get Apple's detailed rejection feedback (guideline violations, reviewer messages) for the current or specified app version. Returns cached data — no Apple ID auth required. Use this when an app is rejected to understand what needs to be fixed.",
            properties: [
                "version": ["type": "string", "description": "Version string to get feedback for (e.g. \"1.0.0\"). Defaults to the latest rejected version."]
            ],
            required: []
        ))

        // -- Tab State --
        tools.append(tool(
            name: "get_tab_state",
            description: "Get the structured data state of any Blitz tab. Returns form field values, submission readiness, versions, builds, localizations, etc. Use this instead of screenshots to read UI state.",
            properties: [
                "tab": ["type": "string", "description": "Tab to read state from (defaults to currently active tab). 'app' or 'ascOverview' returns overview/submission readiness.", "enum": [
                    "app", "ascOverview", "overview",
                    "storeListing", "screenshots", "appDetails", "monetization", "review",
                    "analytics", "reviews", "builds", "groups", "betaInfo", "feedback"
                ]]
            ],
            required: []
        ))

        // -- ASC Credentials --
        tools.append(tool(
            name: "asc_set_credentials",
            description: "Pre-fill the App Store Connect API credential form with issuer ID, key ID, and private key file. The user must click 'Save Credentials' to confirm. Works in both onboarding and release tabs.",
            properties: [
                "issuerId": ["type": "string", "description": "Issuer ID (UUID format)"],
                "keyId": ["type": "string", "description": "Key ID (10-character alphanumeric)"],
                "privateKeyPath": ["type": "string", "description": "Absolute path to the .p8 private key file (e.g. ~/.blitz/AuthKey_XXXXXXXXXX.p8)"]
            ],
            required: ["issuerId", "keyId", "privateKeyPath"]
        ))

        // -- ASC Form Tools --
        tools.append(tool(
            name: "asc_fill_form",
            description: "Fill one or more App Store Connect form fields. Navigates to the tab automatically if auto-nav is enabled. See CLAUDE.md for complete field reference.",
            properties: [
                "tab": ["type": "string", "description": "Target form tab", "enum": [
                    "storeListing", "appDetails", "monetization", "review.ageRating", "review.contact", "settings.bundleId"
                ]],
                "fields": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "field": ["type": "string"],
                            "value": ["type": "string"]
                        ],
                        "required": ["field", "value"]
                    ] as [String: Any]
                ] as [String: Any]
            ],
            required: ["tab", "fields"]
        ))

        // -- Screenshot Track Tools --
        tools.append(tool(
            name: "screenshots_add_asset",
            description: "Copy a screenshot file into the project's local screenshots asset library.",
            properties: [
                "sourcePath": ["type": "string", "description": "Absolute path to the source image file"],
                "fileName": ["type": "string", "description": "Optional file name for the copy (defaults to source file name)"]
            ],
            required: ["sourcePath"]
        ))

        tools.append(tool(
            name: "screenshots_set_track",
            description: "Place a local screenshot asset into a specific track slot (1-10) for upload staging.",
            properties: [
                "assetFileName": ["type": "string", "description": "File name of the asset in the local screenshots library"],
                "slotIndex": ["type": "integer", "description": "Track slot position (1-10)"],
                "displayType": ["type": "string", "description": "Display type (default APP_IPHONE_67)", "enum": ["APP_IPHONE_67", "APP_IPAD_PRO_3GEN_129", "APP_DESKTOP"]]
            ],
            required: ["assetFileName", "slotIndex"]
        ))

        tools.append(tool(
            name: "screenshots_save",
            description: "Save the current screenshot track to App Store Connect. Syncs all changes (additions, removals, reorder) for the specified device type.",
            properties: [
                "displayType": ["type": "string", "description": "Display type (default APP_IPHONE_67)", "enum": ["APP_IPHONE_67", "APP_IPAD_PRO_3GEN_129", "APP_DESKTOP"]],
                "locale": ["type": "string", "description": "Locale code (default en-US)"]
            ],
            required: []
        ))

        tools.append(tool(
            name: "asc_open_submit_preview",
            description: "Check submission readiness and open the Submit for Review modal. Returns list of missing required fields if incomplete.",
            properties: [:],
            required: []
        ))

        // -- ASC IAP / Subscriptions / Pricing --
        tools.append(tool(
            name: "asc_create_iap",
            description: "Create an in-app purchase in App Store Connect. Creates the IAP, adds en-US localization, sets the price, and uploads a review screenshot. You MUST provide a screenshot — take one of the IAP content in the app simulator first (e.g. the purchase UI or content being unlocked), save to /tmp, then pass the path.",
            properties: [
                "productId": ["type": "string", "description": "Unique product identifier (e.g. com.app.coins100)"],
                "name": ["type": "string", "description": "Internal reference name"],
                "type": ["type": "string", "description": "IAP type", "enum": ["CONSUMABLE", "NON_CONSUMABLE", "NON_RENEWING_SUBSCRIPTION"]],
                "displayName": ["type": "string", "description": "User-facing display name (en-US localization)"],
                "price": ["type": "string", "description": "Price in USD (e.g. \"0.99\", \"4.99\")"],
                "description": ["type": "string", "description": "User-facing description (optional)"],
                "screenshotPath": ["type": "string", "description": "Path to review screenshot (min 640x920px PNG/JPEG). Use blitz-iphone to take a screenshot of the IAP content in the simulator."]
            ],
            required: ["productId", "name", "type", "displayName", "price", "screenshotPath"]
        ))

        tools.append(tool(
            name: "asc_create_subscription",
            description: "Create an auto-renewable subscription in App Store Connect. Creates or reuses a subscription group, adds the subscription with en-US localization, sets the price, and uploads a review screenshot. You MUST provide a screenshot — take one of the subscription content in the app simulator first (e.g. the paywall or premium features screen), save to /tmp, then pass the path.",
            properties: [
                "groupName": ["type": "string", "description": "Subscription group name (created if doesn't exist)"],
                "productId": ["type": "string", "description": "Unique product identifier"],
                "name": ["type": "string", "description": "Internal reference name"],
                "displayName": ["type": "string", "description": "User-facing display name (en-US localization)"],
                "duration": ["type": "string", "description": "Billing period", "enum": [
                    "ONE_WEEK", "ONE_MONTH", "TWO_MONTHS", "THREE_MONTHS", "SIX_MONTHS", "ONE_YEAR"
                ]],
                "price": ["type": "string", "description": "Price in USD (e.g. \"4.99\")"],
                "description": ["type": "string", "description": "User-facing description (optional)"],
                "screenshotPath": ["type": "string", "description": "Path to review screenshot (min 640x920px PNG/JPEG). Use blitz-iphone to take a screenshot of the subscription content in the simulator."]
            ],
            required: ["groupName", "productId", "name", "displayName", "duration", "price", "screenshotPath"]
        ))

        tools.append(tool(
            name: "asc_web_auth",
            description: "Open the Apple ID login window in Blitz to authenticate a web session for App Store Connect. Use when the iris API returns 401 (session expired). The login captures cookies and syncs them to ~/.blitz/asc-agent/web-session.json for CLI skills. Requires user interaction (Apple ID + 2FA).",
            properties: [:],
            required: []
        ))

        tools.append(tool(
            name: "asc_set_app_price",
            description: "Set the app's price on the App Store. Use \"0\" for free. Optionally schedule a future price change with effectiveDate.",
            properties: [
                "price": ["type": "string", "description": "Price in USD (e.g. \"0.99\", \"0\" for free)"],
                "effectiveDate": ["type": "string", "description": "ISO date for scheduled price change (e.g. \"2026-06-01\"). Omit for immediate change."]
            ],
            required: ["price"]
        ))

        // -- Build Pipeline --
        tools.append(tool(
            name: "app_store_setup_signing",
            description: "Set up code signing for iOS or macOS: registers bundle ID, creates distribution certificate (and installer certificate for macOS), installs provisioning profile, and configures the Xcode project. Automatically detects platform from project metadata. Idempotent — re-running skips completed steps.",
            properties: [
                "teamId": ["type": "string", "description": "Apple Developer Team ID (optional if already saved in project metadata)"]
            ],
            required: []
        ))

        tools.append(tool(
            name: "app_store_build",
            description: "Build an IPA for App Store submission. Archives the Xcode project and exports a signed IPA.",
            properties: [
                "scheme": ["type": "string", "description": "Xcode scheme (auto-detected if omitted)"],
                "configuration": ["type": "string", "description": "Build configuration (default: Release)"]
            ],
            required: []
        ))

        tools.append(tool(
            name: "app_store_upload",
            description: "Upload an IPA to App Store Connect / TestFlight. Optionally polls until build processing completes.",
            properties: [
                "ipaPath": ["type": "string", "description": "Path to IPA file (uses latest build output if omitted)"],
                "skipPolling": ["type": "boolean", "description": "Skip waiting for build processing (default: false)"]
            ],
            required: []
        ))

        return tools
    }

    /// Determine the category for a given tool name
    static func category(for toolName: String) -> ApprovalRequest.ToolCategory {
        switch toolName {
        // Navigation / read-only
        case "app_get_state", "nav_switch_tab", "nav_list_tabs":
            return .navigation
        case "project_list", "project_get_active":
            return .query
        case "simulator_list_devices":
            return .query
        case "settings_get":
            return .query
        case "get_blitz_screenshot", "get_tab_state", "get_rejection_feedback":
            return .query

        // Mutations
        case "project_open", "project_create", "project_import", "project_close":
            return .projectMutation
        case "simulator_select_device":
            return .simulatorControl
        case "settings_update", "settings_save":
            return .settingsMutation

        // ASC credential pre-fill — no approval needed, user must click Save
        case "asc_set_credentials":
            return .query
        case "asc_fill_form":
            return .ascFormMutation
        case "screenshots_add_asset", "screenshots_set_track", "screenshots_save":
            return .ascScreenshotMutation
        case "asc_open_submit_preview":
            return .ascSubmitMutation
        case "asc_web_auth":
            return .query  // user-interactive (Apple ID login) — no approval needed
        case "asc_create_iap", "asc_create_subscription", "asc_set_app_price":
            return .ascFormMutation

        // Build pipeline tools
        case "app_store_setup_signing", "app_store_build", "app_store_upload":
            return .buildPipeline

        default:
            return .unknown
        }
    }

    // MARK: - Helper

    /// Returns all tool names registered in the registry.
    static func allToolNames() -> [String] {
        allTools().compactMap { $0["name"] as? String }
    }

    private static func tool(
        name: String,
        description: String,
        properties: [String: Any],
        required: [String]
    ) -> [String: Any] {
        var schema: [String: Any] = [
            "type": "object",
            "properties": properties
        ]
        if !required.isEmpty {
            schema["required"] = required
        }
        return [
            "name": name,
            "description": description,
            "inputSchema": schema
        ]
    }
}
