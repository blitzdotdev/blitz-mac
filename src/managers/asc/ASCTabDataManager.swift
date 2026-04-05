import Foundation

extension ASCManager {
    func ensureTabData(_ tab: AppTab) async {
        guard credentials != nil else { return }

        if loadedTabs.contains(tab) {
            if shouldRefreshTabCache(tab) {
                await refreshTabData(tab)
            }
            return
        }

        await fetchTabData(tab)
    }

    func hasLoadedTabData(_ tab: AppTab) -> Bool {
        loadedTabs.contains(tab)
    }

    func isTabLoading(_ tab: AppTab) -> Bool {
        isLoadingTab[tab] == true || isLoadingApp
    }

    func isFeedbackLoading(for buildId: String?) -> Bool {
        guard let buildId, !buildId.isEmpty else {
            return isLoadingTab[.feedback] == true
        }
        return loadingFeedbackBuildIds.contains(buildId)
    }

    @discardableResult
    func fetchApp(bundleId: String, exactName: String? = nil) async -> Bool {
        guard let service else { return false }
        isLoadingApp = true
        do {
            let fetched = try await service.fetchApp(bundleId: bundleId, exactName: exactName)
            app = fetched
            credentialsError = nil
            isLoadingApp = false
            return true
        } catch {
            app = nil
            credentialsError = error.localizedDescription
            isLoadingApp = false
            return false
        }
    }

    func fetchTabData(_ tab: AppTab) async {
        guard let service else { return }
        guard credentials != nil else { return }
        guard !loadedTabs.contains(tab) else { return }
        guard isLoadingTab[tab] != true else { return }
        // Project switches can briefly leave tabs asking for data while the next
        // app lookup is still in flight. Treat that as "not ready yet" instead
        // of surfacing a false bundle-ID/app-not-found error.
        guard !(app == nil && isLoadingApp) else { return }

        cancelBackgroundHydration(for: tab)
        isLoadingTab[tab] = true
        tabError.removeValue(forKey: tab)

        do {
            try await loadData(for: tab, service: service)
            isLoadingTab[tab] = false
            loadedTabs.insert(tab)
            tabLoadedAt[tab] = Date()
        } catch {
            isLoadingTab[tab] = false
            tabError[tab] = error.localizedDescription
            await logDataFetchFailure("asc_tab_fetch_failed", error: error, metadata: [
                "tab": tab.rawValue,
            ])
        }
    }

    /// Called after bundle ID setup completes and the app is confirmed in ASC.
    /// Clears all tab errors and forces data to be re-fetched.
    func resetTabState() {
        cancelBackgroundHydrationTasks()
        tabError.removeAll()
        loadedTabs.removeAll()
        tabLoadedAt.removeAll()
        loadingFeedbackBuildIds = []
    }

    func refreshTabData(_ tab: AppTab) async {
        guard let service else { return }
        guard credentials != nil else { return }
        // Same guard as fetchTabData(_:): an in-flight app lookup should not be
        // rendered as a tab error. The active tab will be re-requested once the
        // project load finishes.
        guard !(app == nil && isLoadingApp) else { return }

        let hadLoadedData = loadedTabs.contains(tab)
        cancelBackgroundHydration(for: tab)
        isLoadingTab[tab] = true
        tabError.removeValue(forKey: tab)

        do {
            try await loadData(for: tab, service: service)
            isLoadingTab[tab] = false
            loadedTabs.insert(tab)
            tabLoadedAt[tab] = Date()
        } catch {
            isLoadingTab[tab] = false
            if !hadLoadedData {
                loadedTabs.remove(tab)
                tabLoadedAt.removeValue(forKey: tab)
            }
            tabError[tab] = error.localizedDescription
            await logDataFetchFailure("asc_tab_refresh_failed", error: error, metadata: [
                "tab": tab.rawValue,
            ])
        }
    }

    func refreshSubmissionReadinessData() async {
        await refreshCurrentApp()
        await refreshMonetization()
        await refreshAttachedSubmissionItemIDs()
    }

    func syncOverviewSubmissionReadiness(forceRefresh: Bool = false) async {
        if forceRefresh {
            await refreshTabData(.app)
        } else {
            await ensureTabData(.app)
        }
        await waitForBackgroundHydration(for: .app)
        await refreshSubmissionReadinessData()
    }

    func startOverviewReadinessLoading(_ fields: Set<String>) {
        overviewReadinessLoadingFields = fields
    }

    func finishOverviewReadinessLoading(_ fields: Set<String>) {
        overviewReadinessLoadingFields.subtract(fields)
    }

    func isCurrentProject(_ projectId: String?) -> Bool {
        guard let projectId else { return false }
        return loadedProjectId == projectId
    }

    private func refreshCurrentApp() async {
        guard let service, let appId = app?.id else { return }
        if let refreshedApp = try? await service.fetchApp(id: appId) {
            app = refreshedApp
        }
    }

    private struct OverviewPrimaryLocalization {
        /// ASC localization record ID used in follow-up API calls like `fetchScreenshotSets(localizationId:)`.
        let localizationId: String
        /// Locale code used when storing overview data in Blitz's locale-keyed caches.
        let locale: String

        init?(_ localization: ASCVersionLocalization?) {
            guard let localization else { return nil }
            localizationId = localization.id
            locale = localization.attributes.locale
        }
    }

    private func hydrateOverviewSecondaryData(
        projectId: String?,
        appId: String,
        primaryLocalization: OverviewPrimaryLocalization?,
        appInfoId: String?,
        service: AppStoreConnectService
    ) async {
        if let primaryLocalization {
            do {
                let fetchedSets = try await service.fetchScreenshotSets(localizationId: primaryLocalization.localizationId)
                let fetchedScreenshots = try await withThrowingTaskGroup(of: (String, [ASCScreenshot]).self) { group in
                    for set in fetchedSets {
                        group.addTask {
                            let screenshots = try await service.fetchScreenshots(setId: set.id)
                            return (set.id, screenshots)
                        }
                    }

                    var pairs: [(String, [ASCScreenshot])] = []
                    for try await pair in group {
                        pairs.append(pair)
                    }
                    return pairs
                }

                guard !Task.isCancelled, isCurrentProject(projectId) else { return }
                updateScreenshotCache(
                    locale: primaryLocalization.locale,
                    sets: fetchedSets,
                    screenshots: Dictionary(uniqueKeysWithValues: fetchedScreenshots)
                )
                finishOverviewReadinessLoading(Self.overviewScreenshotFieldLabels)
            } catch {
                print("Failed to hydrate overview screenshots: \(error)")
                finishOverviewReadinessLoading(Self.overviewScreenshotFieldLabels)
            }
        } else {
            finishOverviewReadinessLoading(Self.overviewScreenshotFieldLabels)
        }

        if let appInfoId {
            async let ageRatingTask = fetchAgeRatingLogged(
                service: service,
                appInfoId: appInfoId,
                context: "overview_secondary"
            )
            async let appInfoLocalizationsTask: [ASCAppInfoLocalization]? = try? service.fetchAppInfoLocalizations(appInfoId: appInfoId)

            let fetchedAgeRating = await ageRatingTask
            let fetchedAppInfoLocalizations = await appInfoLocalizationsTask ?? []

            guard !Task.isCancelled, isCurrentProject(projectId) else { return }
            ageRatingDeclaration = fetchedAgeRating
            appInfoLocalizationsByLocale = Dictionary(uniqueKeysWithValues: fetchedAppInfoLocalizations.map {
                ($0.attributes.locale, $0)
            })
            appInfoLocalization = primaryAppInfoLocalization(in: fetchedAppInfoLocalizations)
            finishOverviewReadinessLoading(Self.overviewMetadataFieldLabels)
        } else {
            ageRatingDeclaration = nil
            appInfoLocalizationsByLocale = [:]
            appInfoLocalization = nil
            finishOverviewReadinessLoading(Self.overviewMetadataFieldLabels)
        }

        guard !Task.isCancelled, isCurrentProject(projectId) else { return }
        await refreshReviewSubmissionData(appId: appId, service: service)
        guard !Task.isCancelled, isCurrentProject(projectId) else { return }
        rebuildSubmissionHistory(appId: appId)
        refreshSubmissionFeedbackIfNeeded()

        if monetizationStatus == nil {
            let hasPricing = await fetchPricingConfiguredLogged(
                service: service,
                appId: appId,
                context: "overview_secondary"
            )
            guard !Task.isCancelled, isCurrentProject(projectId) else { return }
            monetizationStatus = hasPricing ? "Configured" : nil
        }

        guard !Task.isCancelled, isCurrentProject(projectId) else { return }
        await refreshSubmissionReadinessData()
        finishOverviewReadinessLoading(Self.overviewPricingFieldLabels)
    }

    private func hydrateReviewSecondaryData(
        projectId: String?,
        appId: String,
        appInfoId: String?,
        service: AppStoreConnectService
    ) async {
        if let appInfoId {
            let fetchedAgeRating = await fetchAgeRatingLogged(
                service: service,
                appInfoId: appInfoId,
                context: "review_secondary"
            )
            guard !Task.isCancelled, isCurrentProject(projectId) else { return }
            ageRatingDeclaration = fetchedAgeRating
        } else {
            ageRatingDeclaration = nil
        }

        guard !Task.isCancelled, isCurrentProject(projectId) else { return }
        await refreshReviewSubmissionData(appId: appId, service: service)
        guard !Task.isCancelled, isCurrentProject(projectId) else { return }
        rebuildSubmissionHistory(appId: appId)
        refreshSubmissionFeedbackIfNeeded()
    }

    private func hydrateMonetizationSecondaryData(
        projectId: String?,
        appId: String,
        groups: [ASCSubscriptionGroup],
        service: AppStoreConnectService
    ) async {
        do {
            let fetchedSubscriptions = try await withThrowingTaskGroup(of: (String, [ASCSubscription]).self) { taskGroup in
                for subscriptionGroup in groups {
                    taskGroup.addTask {
                        let subscriptions = try await service.fetchSubscriptionsInGroup(groupId: subscriptionGroup.id)
                        return (subscriptionGroup.id, subscriptions)
                    }
                }

                var pairs: [(String, [ASCSubscription])] = []
                for try await pair in taskGroup {
                    pairs.append(pair)
                }
                return pairs
            }

            guard !Task.isCancelled, isCurrentProject(projectId) else { return }
            subscriptionsPerGroup = Dictionary(uniqueKeysWithValues: fetchedSubscriptions)
        } catch {
            print("Failed to hydrate monetization subscriptions: \(error)")
        }

        if currentAppPricePointId == nil && scheduledAppPricePointId == nil && monetizationStatus == nil {
            let hasPricing = await fetchPricingConfiguredLogged(
                service: service,
                appId: appId,
                context: "monetization_secondary"
            )
            guard !Task.isCancelled, isCurrentProject(projectId) else { return }
            monetizationStatus = hasPricing ? "Configured" : nil
        }
    }

    private func hydrateFeedbackSecondaryData(
        projectId: String?,
        buildId: String,
        service: AppStoreConnectService
    ) async {
        guard isCurrentProject(projectId) else { return }
        guard !Task.isCancelled else { return }
        loadingFeedbackBuildIds.insert(buildId)
        defer { loadingFeedbackBuildIds.remove(buildId) }

        do {
            let items = try await service.fetchBetaFeedback(buildId: buildId)
            guard !Task.isCancelled, isCurrentProject(projectId) else { return }
            betaFeedback[buildId] = items
        } catch {
            guard !Task.isCancelled, isCurrentProject(projectId) else { return }
            betaFeedback[buildId] = []
        }
    }

    private func loadData(for tab: AppTab, service: AppStoreConnectService) async throws {
        guard let appId = app?.id else {
            throw ASCError.notFound("App - check your bundle ID in project settings")
        }

        switch tab {
        case .app:
            refreshAppIconStatusIfNeeded(for: loadedProjectId)
            startOverviewReadinessLoading(
                Self.overviewLocalizationFieldLabels
                    .union(Self.overviewVersionFieldLabels)
                    .union(Self.overviewAppInfoFieldLabels)
                    .union(Self.overviewMetadataFieldLabels)
                    .union(Self.overviewReviewFieldLabels)
                    .union(Self.overviewBuildFieldLabels)
                    .union(Self.overviewPricingFieldLabels)
                    .union(Self.overviewScreenshotFieldLabels)
            )
            async let versionsTask = service.fetchAppStoreVersions(appId: appId)
            async let appTask: ASCApp? = try? service.fetchApp(id: appId)
            async let appInfoTask: ASCAppInfo? = try? service.fetchAppInfo(appId: appId)
            async let buildsTask = service.fetchBuilds(appId: appId)

            let versions = try await versionsTask
            appStoreVersions = versions
            syncSelectedVersion()
            finishOverviewReadinessLoading(Self.overviewVersionFieldLabels)
            if let refreshedApp = await appTask {
                app = refreshedApp
            }
            appInfo = await appInfoTask
            finishOverviewReadinessLoading(Self.overviewAppInfoFieldLabels)
            builds = try await buildsTask

            var primaryLocalization: OverviewPrimaryLocalization?
            if let selectedVersionId = selectedVersion?.id {
                async let localizationsTask = service.fetchLocalizations(versionId: selectedVersionId)
                async let reviewDetailTask = fetchReviewDetailLogged(
                    service: service,
                    versionId: selectedVersionId,
                    context: "overview_primary"
                )
                async let selectedBuildTask: ASCBuild? = try? service.fetchBuildAttachedToVersion(versionId: selectedVersionId)

                let fetchedLocalizations = try await localizationsTask
                localizations = fetchedLocalizations
                primaryLocalization = OverviewPrimaryLocalization(
                    primaryVersionLocalization(in: fetchedLocalizations)
                )
                finishOverviewReadinessLoading(Self.overviewLocalizationFieldLabels)
                reviewDetail = await reviewDetailTask
                finishOverviewReadinessLoading(Self.overviewReviewFieldLabels)
                selectedVersionBuild = await selectedBuildTask
                finishOverviewReadinessLoading(Self.overviewBuildFieldLabels)
            } else {
                selectedVersionBuild = nil
                finishOverviewReadinessLoading(
                    Self.overviewLocalizationFieldLabels
                        .union(Self.overviewReviewFieldLabels)
                        .union(Self.overviewBuildFieldLabels)
                )
            }

            refreshSubmissionFeedbackIfNeeded()

            let projectId = loadedProjectId
            let currentAppInfoId = appInfo?.id
            startBackgroundHydration(for: .app) {
                await self.hydrateOverviewSecondaryData(
                    projectId: projectId,
                    appId: appId,
                    primaryLocalization: primaryLocalization,
                    appInfoId: currentAppInfoId,
                    service: service
                )
            }

        case .storeListing:
            try await refreshStoreListingMetadata(
                service: service,
                appId: appId,
                preferredVersionId: selectedVersionId,
                preferredLocale: selectedStoreListingLocale
            )

        case .screenshots:
            let versions = try await service.fetchAppStoreVersions(appId: appId)
            appStoreVersions = versions
            syncSelectedVersion()
            if let selectedVersionId = selectedVersion?.id {
                let localizations = try await service.fetchLocalizations(versionId: selectedVersionId)
                self.localizations = localizations
                let preferredLocale = selectedScreenshotsLocale
                let targetLocalization = localizations.first(where: { $0.attributes.locale == preferredLocale })
                    ?? localizations.first
                if let targetLocalization {
                    selectedScreenshotsLocale = targetLocalization.attributes.locale
                    await loadScreenshots(locale: targetLocalization.attributes.locale, force: true)
                } else {
                    screenshotSetsByLocale = [:]
                    screenshotsByLocale = [:]
                    selectedScreenshotsLocale = nil
                }
            } else {
                localizations = []
                screenshotSetsByLocale = [:]
                screenshotsByLocale = [:]
                selectedScreenshotsLocale = nil
            }

        case .appDetails:
            async let versionsTask = service.fetchAppStoreVersions(appId: appId)
            async let appTask: ASCApp? = try? service.fetchApp(id: appId)
            async let appInfoTask: ASCAppInfo? = try? await service.fetchAppInfo(appId: appId)

            appStoreVersions = try await versionsTask
            syncSelectedVersion()
            if let refreshedApp = await appTask {
                app = refreshedApp
            }
            appInfo = await appInfoTask

        case .review:
            async let versionsTask = service.fetchAppStoreVersions(appId: appId)
            async let appInfoTask: ASCAppInfo? = try? await service.fetchAppInfo(appId: appId)
            async let buildsTask = service.fetchBuilds(appId: appId)

            let versions = try await versionsTask
            appStoreVersions = versions
            syncSelectedVersion()
            if let selectedVersionId = selectedVersion?.id {
                reviewDetail = await fetchReviewDetailLogged(
                    service: service,
                    versionId: selectedVersionId,
                    context: "review_tab_load"
                )
                selectedVersionBuild = try? await service.fetchBuildAttachedToVersion(versionId: selectedVersionId)
            } else {
                reviewDetail = nil
                selectedVersionBuild = nil
            }
            appInfo = await appInfoTask
            builds = try await buildsTask
            let projectId = loadedProjectId
            let currentAppInfoId = appInfo?.id
            startBackgroundHydration(for: .review) {
                await self.hydrateReviewSecondaryData(
                    projectId: projectId,
                    appId: appId,
                    appInfoId: currentAppInfoId,
                    service: service
                )
            }

        case .monetization:
            async let pricePointsTask = service.fetchAppPricePoints(appId: appId)
            async let pricingStateTask = fetchAppPricingStateLogged(
                service: service,
                appId: appId,
                context: "monetization_tab_load"
            )
            async let iapTask = service.fetchInAppPurchases(appId: appId)
            async let groupsTask = service.fetchSubscriptionGroups(appId: appId)

            appPricePoints = try await pricePointsTask
            applyAppPricingState(
                await pricingStateTask
                    ?? ASCAppPricingState(
                        currentPricePointId: nil,
                        scheduledPricePointId: nil,
                        scheduledEffectiveDate: nil
                    )
            )
            inAppPurchases = try await iapTask
            let groups = try await groupsTask
            subscriptionGroups = groups

            let projectId = loadedProjectId
            startBackgroundHydration(for: .monetization) {
                await self.hydrateMonetizationSecondaryData(
                    projectId: projectId,
                    appId: appId,
                    groups: groups,
                    service: service
                )
            }

        case .analytics:
            break

        case .reviews:
            customerReviews = try await service.fetchCustomerReviews(appId: appId)

        case .builds:
            builds = try await service.fetchBuilds(appId: appId)

        case .groups:
            betaGroups = try await service.fetchBetaGroups(appId: appId)

        case .betaInfo:
            betaLocalizations = try await service.fetchBetaLocalizations(appId: appId)

        case .feedback:
            let fetchedBuilds = try await service.fetchBuilds(appId: appId)
            builds = fetchedBuilds
            let resolvedBuildId: String?
            if let currentSelectedBuildId = selectedBuildId,
               fetchedBuilds.contains(where: { $0.id == currentSelectedBuildId }) {
                resolvedBuildId = currentSelectedBuildId
            } else {
                resolvedBuildId = fetchedBuilds.first?.id
            }
            selectedBuildId = resolvedBuildId
            if let resolvedBuildId {
                let projectId = loadedProjectId
                startBackgroundHydration(for: .feedback) {
                    await self.hydrateFeedbackSecondaryData(
                        projectId: projectId,
                        buildId: resolvedBuildId,
                        service: service
                    )
                }
            } else {
                betaFeedback = [:]
            }

        default:
            break
        }
    }
}
