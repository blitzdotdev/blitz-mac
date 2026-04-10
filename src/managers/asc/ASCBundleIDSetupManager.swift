import Foundation

extension ASCManager {
    struct PendingBundleIDSetupContext {
        let bundleId: String
        let tab: AppTab
    }

    enum BundleIDSetupConfirmationError: LocalizedError {
        case ascServiceNotConfigured
        case missingBundleId

        var errorDescription: String? {
            switch self {
            case .ascServiceNotConfigured:
                return "ASC service not configured"
            case .missingBundleId:
                return "The registered bundle ID is missing. Register the bundle ID again before confirming."
            }
        }
    }

    func beginPendingBundleIDSetup(bundleId: String, tab: AppTab) {
        let trimmedBundleId = bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBundleId.isEmpty else {
            pendingBundleIDSetup = nil
            return
        }
        pendingBundleIDSetup = PendingBundleIDSetupContext(bundleId: trimmedBundleId, tab: tab)
    }

    func clearPendingBundleIDSetup() {
        pendingBundleIDSetup = nil
    }

    func confirmBundleIDSetupAppCreated(bundleId overrideBundleId: String? = nil) async throws -> ASCApp {
        guard let service else {
            throw BundleIDSetupConfirmationError.ascServiceNotConfigured
        }

        let bundleId = try resolvePendingBundleIDSetupBundleId(overrideBundleId)
        let refreshTab = resolvedPendingBundleIDSetupRefreshTab()
        let app = try await service.fetchApp(bundleId: bundleId)

        self.app = app
        credentialsError = nil
        resetTabState()
        await fetchTabData(refreshTab)
        pendingBundleIDSetup = nil
        return app
    }

    private func resolvePendingBundleIDSetupBundleId(_ overrideBundleId: String?) throws -> String {
        let trimmedOverride = overrideBundleId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedOverride.isEmpty {
            return trimmedOverride
        }

        if let pendingBundleIDSetup {
            return pendingBundleIDSetup.bundleId
        }

        throw BundleIDSetupConfirmationError.missingBundleId
    }

    private func resolvedPendingBundleIDSetupRefreshTab() -> AppTab {
        if let pendingBundleIDSetup {
            return pendingBundleIDSetup.tab
        }

        if let activeTab = appState?.activeTab, activeTab.isASCTab {
            return activeTab
        }

        return .app
    }
}
