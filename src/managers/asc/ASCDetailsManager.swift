import Foundation

// MARK: - App Details Manager
// Extension containing app details-related functionality for ASCManager

extension ASCManager {
    // MARK: - App Info Updates

    func updateAppInfoField(_ field: String, value: String) async {
        guard let service else { return }
        let startedAt = Date()
        writeError = nil

        // Fields that live on different ASC resources:
        // - copyright → appStoreVersions (PATCH /v1/appStoreVersions/{id})
        // - contentRightsDeclaration → apps (PATCH /v1/apps/{id})
        // - primaryCategory, subcategories → appInfos relationships (PATCH /v1/appInfos/{id})
        if field == "copyright" {
            guard let versionId = selectedVersion?.id else { return }
            do {
                try await service.patchVersion(id: versionId, fields: [field: value])
                // Re-fetch versions so submissionReadiness picks up the new copyright
                if let appId = app?.id {
                    appStoreVersions = try await service.fetchAppStoreVersions(appId: appId)
                    syncSelectedVersion(preferredVersionId: versionId)
                }
                AnalyticsService.trackBlitzManagedASCUsage(
                    commandType: "app_details.update",
                    success: true,
                    startedAt: startedAt
                )
            } catch {
                writeError = error.localizedDescription
                AnalyticsService.trackBlitzManagedASCUsage(
                    commandType: "app_details.update",
                    success: false,
                    startedAt: startedAt
                )
            }
        } else if field == "contentRightsDeclaration" {
            guard let appId = app?.id else { return }
            do {
                try await service.patchApp(id: appId, fields: [field: value])
                // Refetch app to reflect the change
                app = try await service.fetchApp(bundleId: app?.bundleId ?? "")
                AnalyticsService.trackBlitzManagedASCUsage(
                    commandType: "app_details.update",
                    success: true,
                    startedAt: startedAt
                )
            } catch {
                writeError = error.localizedDescription
                AnalyticsService.trackBlitzManagedASCUsage(
                    commandType: "app_details.update",
                    success: false,
                    startedAt: startedAt
                )
            }
        } else if let infoId = appInfo?.id {
            do {
                try await service.patchAppInfo(id: infoId, fields: [field: value])
                appInfo = try? await service.fetchAppInfo(appId: app?.id ?? "")
                AnalyticsService.trackBlitzManagedASCUsage(
                    commandType: "app_details.update",
                    success: true,
                    startedAt: startedAt
                )
            } catch {
                writeError = error.localizedDescription
                AnalyticsService.trackBlitzManagedASCUsage(
                    commandType: "app_details.update",
                    success: false,
                    startedAt: startedAt
                )
            }
        }
    }

    func updatePrivacyPolicyUrl(_ url: String) async {
        await updateAppInfoLocalizationField("privacyPolicyUrl", value: url)
    }

    /// Update a field on appInfoLocalizations (name, subtitle, privacyPolicyUrl)
    func updateAppInfoLocalizationField(_ field: String, value: String, locale: String? = nil) async {
        let targetLocale = locale ?? activeStoreListingLocale()
        guard let targetLocale else {
            writeError = "No app info localization selected."
            return
        }

        await updateStoreListingFields(
            versionFields: [:],
            appInfoFields: [field: value],
            locale: targetLocale
        )
    }

    // MARK: - Age Rating

    func updateAgeRating(_ attributes: [String: Any]) async {
        guard let service else { return }
        guard let id = ageRatingDeclaration?.id else { return }
        let startedAt = Date()
        writeError = nil
        do {
            try await service.patchAgeRating(id: id, attributes: attributes)
            if let infoId = appInfo?.id {
                ageRatingDeclaration = await fetchAgeRatingLogged(
                    service: service,
                    appInfoId: infoId,
                    context: "age_rating_update"
                )
            }
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "age_rating.update",
                success: true,
                startedAt: startedAt
            )
        } catch {
            writeError = error.localizedDescription
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "age_rating.update",
                success: false,
                startedAt: startedAt
            )
        }
    }
}
