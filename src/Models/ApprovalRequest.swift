import Foundation

struct ApprovalRequest: Identifiable {
    let id: String
    let toolName: String
    let description: String
    let parameters: [String: String]
    let category: ToolCategory

    enum ToolCategory: String {
        case navigation, query
        case projectMutation
        case settingsMutation
        case simulatorControl
        case ascFormMutation
        case ascScreenshotMutation
        case ascSubmitMutation
        case buildPipeline
        case unknown
    }

    /// Check whether this request requires user approval.
    /// Pass the permission toggles from SettingsService to avoid coupling to the singleton.
    func requiresApproval(permissionToggles: [String: Bool]) -> Bool {
        switch category {
        case .navigation, .query: return false
        default:
            // Toggle ON (true) = user has approved this category = no approval popup needed
            let approved = permissionToggles[category.rawValue] ?? false
            return !approved
        }
    }
}
