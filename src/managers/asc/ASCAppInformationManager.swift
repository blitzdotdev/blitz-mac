import Foundation

// MARK: - App Information Manager
// Extension containing merged app-information functionality for ASCManager

extension ASCManager {
    // MARK: - Locale Selection

    /// Primary app-information locale from ASC app settings, falling back to
    /// the first loaded version localization.
    func primaryAppInformationLocale() -> String? {
        if let primaryLocale = app?.primaryLocale,
           localizations.contains(where: { $0.attributes.locale == primaryLocale }) {
            return primaryLocale
        }
        return localizations.first?.attributes.locale
    }

    /// Primary version-localization record used for overview/readiness, independent of the active editor locale.
    func primaryVersionLocalization(in candidates: [ASCVersionLocalization]? = nil) -> ASCVersionLocalization? {
        let candidates = candidates ?? localizations
        guard let primaryLocale = app?.primaryLocale else { return candidates.first }
        return candidates.first(where: { $0.attributes.locale == primaryLocale }) ?? candidates.first
    }

    /// Primary app-info-localization record used for overview/readiness, independent of the active editor locale.
    func primaryAppInfoLocalization(in candidates: [ASCAppInfoLocalization]? = nil) -> ASCAppInfoLocalization? {
        let primaryLocale = app?.primaryLocale

        if let primaryLocale,
           let match = candidates?.first(where: { $0.attributes.locale == primaryLocale }) ?? appInfoLocalizationsByLocale[primaryLocale] {
            return match
        }

        return candidates?.first ?? appInfoLocalization
    }

    /// Active app-information locale for the UI/editor, preferring the user's
    /// selected locale when it is still valid.
    func activeAppInformationLocale() -> String? {
        selectedAppInformationLocale.flatMap { locale in
            localizations.contains(where: { $0.attributes.locale == locale }) ? locale : nil
        } ?? primaryAppInformationLocale()
    }

    func appInformationLocalization(locale: String? = nil) -> ASCVersionLocalization? {
        if let locale {
            return localizations.first(where: { $0.attributes.locale == locale })
        }
        return primaryVersionLocalization()
    }

    func appInfoLocalizationForLocale(_ locale: String? = nil) -> ASCAppInfoLocalization? {
        if let resolvedLocale = locale ?? activeAppInformationLocale() {
            return appInfoLocalizationsByLocale[resolvedLocale]
        }
        return primaryAppInfoLocalization()
    }

    /// Release notes are only mandatory when the selected version is an update
    /// on top of an already-live App Store version.
    var selectedVersionRequiresWhatsNew: Bool {
        guard let selectedVersion, let liveVersion else { return false }
        guard selectedVersion.id != liveVersion.id else { return false }
        return ASCReleaseStatus.isCurrentUpdateCandidate(selectedVersion.attributes.appStoreState)
    }

    /// App Store Connect validates `What's New` per version localization, so the
    /// readiness model has to look at every localization on the selected update.
    func selectedVersionLocalizationsMissingWhatsNew(
        in candidates: [ASCVersionLocalization]? = nil
    ) -> [ASCVersionLocalization] {
        guard selectedVersionRequiresWhatsNew else { return [] }
        let candidates = candidates ?? localizations
        return candidates
            .filter { localization in
                localization.attributes.whatsNew?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty ?? true
            }
            .sorted { lhs, rhs in
                lhs.attributes.locale.localizedCompare(rhs.attributes.locale) == .orderedAscending
            }
    }

    func refreshAppInformationMetadata(
        service: AppStoreConnectService,
        appId: String,
        preferredVersionId: String? = nil,
        preferredLocale: String? = nil
    ) async throws {
        async let versionsTask = service.fetchAppStoreVersions(appId: appId)
        async let appInfoTask: ASCAppInfo? = try? await service.fetchAppInfo(appId: appId)

        let versions = try await versionsTask
        let fetchedAppInfo = await appInfoTask ?? appInfo

        appStoreVersions = versions
        appInfo = fetchedAppInfo
        let resolvedVersionId = syncSelectedVersion(preferredVersionId: preferredVersionId)

        let versionLocalizations: [ASCVersionLocalization]
        if let resolvedVersionId {
            versionLocalizations = try await service.fetchLocalizations(versionId: resolvedVersionId)
        } else {
            versionLocalizations = []
        }

        let fetchedAppInfoLocalizations: [ASCAppInfoLocalization]
        if let infoId = fetchedAppInfo?.id {
            fetchedAppInfoLocalizations = try await service.fetchAppInfoLocalizations(appInfoId: infoId)
        } else {
            fetchedAppInfoLocalizations = []
        }

        if let preferredLocale {
            selectedAppInformationLocale = preferredLocale
        }

        localizations = versionLocalizations
        appInfoLocalizationsByLocale = Dictionary(uniqueKeysWithValues: fetchedAppInfoLocalizations.map {
            ($0.attributes.locale, $0)
        })

        appInfoLocalization = primaryAppInfoLocalization(in: fetchedAppInfoLocalizations)
        selectedAppInformationLocale = activeAppInformationLocale()
    }

    // MARK: - App Information Updates

    private func mappedAppInfoLocalizationFields(_ fields: [String: String]) -> [String: String] {
        var mapped: [String: String] = [:]
        for (field, value) in fields {
            mapped[field == "title" ? "name" : field] = value
        }
        return mapped
    }

    func updateVersionLocalizationField(_ field: String, value: String, locale: String) async {
        await updateAppInformationFields(
            versionFields: [field: value],
            appInfoFields: [:],
            locale: locale
        )
    }

    func updateAppInformationFields(
        versionFields: [String: String],
        appInfoFields rawAppInfoFields: [String: String],
        locale: String
    ) async {
        guard let service else { return }
        let trimmedLocale = locale.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLocale.isEmpty else {
            writeError = "No app information locale selected."
            return
        }

        let startedAt = Date()
        writeError = nil

        do {
            if !versionFields.isEmpty {
                guard let locId = appInformationLocalization(locale: trimmedLocale)?.id else {
                    throw ASCError.notFound("Version localization for locale '\(trimmedLocale)'")
                }
                try await service.patchLocalization(id: locId, fields: versionFields)
            }

            let appInfoFields = mappedAppInfoLocalizationFields(rawAppInfoFields)
            if !appInfoFields.isEmpty {
                guard let infoId = appInfo?.id else {
                    throw ASCError.notFound("AppInfo")
                }

                if let locId = appInfoLocalizationForLocale(trimmedLocale)?.id {
                    try await service.patchAppInfoLocalization(id: locId, fields: appInfoFields)
                } else {
                    _ = try await service.createAppInfoLocalization(
                        appInfoId: infoId,
                        locale: trimmedLocale,
                        fields: appInfoFields
                    )
                }
            }

            guard let appId = app?.id else { return }
            try await refreshAppInformationMetadata(
                service: service,
                appId: appId,
                preferredVersionId: selectedVersion?.id,
                preferredLocale: trimmedLocale
            )
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "app_information.update",
                success: true,
                startedAt: startedAt
            )
        } catch {
            writeError = error.localizedDescription
            AnalyticsService.trackBlitzManagedASCUsage(
                commandType: "app_information.update",
                success: false,
                startedAt: startedAt
            )
        }
    }

    func updateAppInfoField(_ field: String, value: String) async {
        guard let service else { return }
        let startedAt = Date()
        writeError = nil

        // Fields live on different ASC resources:
        // - copyright -> appStoreVersions
        // - contentRightsDeclaration -> apps
        // - primaryCategory -> appInfos
        if field == "copyright" {
            guard let versionId = selectedVersion?.id else { return }
            do {
                try await service.patchVersion(id: versionId, fields: [field: value])
                if let appId = app?.id {
                    appStoreVersions = try await service.fetchAppStoreVersions(appId: appId)
                    syncSelectedVersion(preferredVersionId: versionId)
                }
                AnalyticsService.trackBlitzManagedASCUsage(
                    commandType: "app_information.update",
                    success: true,
                    startedAt: startedAt
                )
            } catch {
                writeError = error.localizedDescription
                AnalyticsService.trackBlitzManagedASCUsage(
                    commandType: "app_information.update",
                    success: false,
                    startedAt: startedAt
                )
            }
        } else if field == "contentRightsDeclaration" {
            guard let appId = app?.id else { return }
            do {
                try await service.patchApp(id: appId, fields: [field: value])
                app = try await service.fetchApp(id: appId)
                AnalyticsService.trackBlitzManagedASCUsage(
                    commandType: "app_information.update",
                    success: true,
                    startedAt: startedAt
                )
            } catch {
                writeError = error.localizedDescription
                AnalyticsService.trackBlitzManagedASCUsage(
                    commandType: "app_information.update",
                    success: false,
                    startedAt: startedAt
                )
            }
        } else if let infoId = appInfo?.id {
            do {
                try await service.patchAppInfo(id: infoId, fields: [field: value])
                appInfo = try? await service.fetchAppInfo(appId: app?.id ?? "")
                AnalyticsService.trackBlitzManagedASCUsage(
                    commandType: "app_information.update",
                    success: true,
                    startedAt: startedAt
                )
            } catch {
                writeError = error.localizedDescription
                AnalyticsService.trackBlitzManagedASCUsage(
                    commandType: "app_information.update",
                    success: false,
                    startedAt: startedAt
                )
            }
        }
    }

    func updatePrivacyPolicyUrl(_ url: String) async {
        await updateAppInfoLocalizationField("privacyPolicyUrl", value: url)
    }

    /// Update a field on app-info localizations (`name`, `subtitle`,
    /// `privacyPolicyUrl`) for the active app-information locale.
    func updateAppInfoLocalizationField(_ field: String, value: String, locale: String? = nil) async {
        let targetLocale = locale ?? activeAppInformationLocale()
        guard let targetLocale else {
            writeError = "No app info localization selected."
            return
        }

        await updateAppInformationFields(
            versionFields: [:],
            appInfoFields: [field: value],
            locale: targetLocale
        )
    }
}
