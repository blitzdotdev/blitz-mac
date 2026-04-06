import Foundation

enum MCPAppInformationCompatibility {
    static let canonicalTab = "appInformation"
    static let legacyTabAliases: Set<String> = ["storeListing", "appDetails"]
    static let canonicalLocalizationTool = "app_information_switch_localization"
    static let legacyLocalizationTool = "store_listing_switch_localization"

    static func canonicalTabName(_ rawTab: String) -> String {
        legacyTabAliases.contains(rawTab) ? canonicalTab : rawTab
    }

    static func resolveAppTab(_ rawTab: String) -> AppTab? {
        if canonicalTabName(rawTab) == canonicalTab {
            return .appInformation
        }
        return AppTab(rawValue: rawTab)
    }

    static func isLocalizationTool(_ toolName: String) -> Bool {
        toolName == canonicalLocalizationTool || toolName == legacyLocalizationTool
    }
}
