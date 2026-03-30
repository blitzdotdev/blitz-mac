import Foundation

// MARK: - Store Listing Manager
// Extension containing store listing-related functionality for ASCManager

extension ASCManager {
    // MARK: - Locale Selection

    /// Primary store-listing locale from ASC app settings, falling back to the first loaded localization.
    func primaryLocalizationLocale() -> String? {
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

    /// Active store-listing locale for the UI/editor, preferring the user's selected locale when it is still valid.
    func activeStoreListingLocale() -> String? {
        selectedStoreListingLocale.flatMap { locale in
            localizations.contains(where: { $0.attributes.locale == locale }) ? locale : nil
        } ?? primaryLocalizationLocale()
    }

    func storeListingLocalization(locale: String? = nil) -> ASCVersionLocalization? {
        if let locale {
            return localizations.first(where: { $0.attributes.locale == locale })
        }
        return primaryVersionLocalization()
    }

    func appInfoLocalizationForLocale(_ locale: String? = nil) -> ASCAppInfoLocalization? {
        if let resolvedLocale = locale ?? activeStoreListingLocale() {
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

    func refreshStoreListingMetadata(
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
            selectedStoreListingLocale = preferredLocale
        }

        localizations = versionLocalizations
        appInfoLocalizationsByLocale = Dictionary(uniqueKeysWithValues: fetchedAppInfoLocalizations.map {
            ($0.attributes.locale, $0)
        })

        appInfoLocalization = primaryAppInfoLocalization(in: fetchedAppInfoLocalizations)
        selectedStoreListingLocale = activeStoreListingLocale()
    }

    // MARK: - Localization Updates

    private func mappedAppInfoLocalizationFields(_ fields: [String: String]) -> [String: String] {
        var mapped: [String: String] = [:]
        for (field, value) in fields {
            mapped[field == "title" ? "name" : field] = value
        }
        return mapped
    }

    func updateLocalizationField(_ field: String, value: String, locale: String) async {
        await updateStoreListingFields(
            versionFields: [field: value],
            appInfoFields: [:],
            locale: locale
        )
    }

    func updateStoreListingFields(
        versionFields: [String: String],
        appInfoFields rawAppInfoFields: [String: String],
        locale: String
    ) async {
        guard let service else { return }
        let trimmedLocale = locale.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLocale.isEmpty else {
            writeError = "No store listing locale selected."
            return
        }

        writeError = nil

        do {
            if !versionFields.isEmpty {
                guard let locId = storeListingLocalization(locale: trimmedLocale)?.id else {
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
            try await refreshStoreListingMetadata(
                service: service,
                appId: appId,
                preferredVersionId: selectedVersion?.id,
                preferredLocale: trimmedLocale
            )
        } catch {
            writeError = error.localizedDescription
        }
    }
}
