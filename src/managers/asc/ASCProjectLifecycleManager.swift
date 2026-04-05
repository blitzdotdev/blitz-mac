import Foundation

extension ASCManager {
    struct ProjectSnapshot {
        let projectId: String
        let bundleId: String?
        let app: ASCApp?
        let appStoreVersions: [ASCAppStoreVersion]
        let localizations: [ASCVersionLocalization]
        let appInfoLocalizationsByLocale: [String: ASCAppInfoLocalization]
        let screenshotSetsByLocale: [String: [ASCScreenshotSet]]
        let screenshotsByLocale: [String: [String: [ASCScreenshot]]]
        let customerReviews: [ASCCustomerReview]
        let builds: [ASCBuild]
        let betaGroups: [ASCBetaGroup]
        let betaLocalizations: [ASCBetaLocalization]
        let betaFeedback: [String: [ASCBetaFeedback]]
        let selectedBuildId: String?
        let inAppPurchases: [ASCInAppPurchase]
        let subscriptionGroups: [ASCSubscriptionGroup]
        let subscriptionsPerGroup: [String: [ASCSubscription]]
        let appPricePoints: [ASCPricePoint]
        let currentAppPricePointId: String?
        let scheduledAppPricePointId: String?
        let scheduledAppPriceEffectiveDate: String?
        let appInfo: ASCAppInfo?
        let appInfoLocalization: ASCAppInfoLocalization?
        let ageRatingDeclaration: ASCAgeRatingDeclaration?
        let reviewDetail: ASCReviewDetail?
        let selectedVersionId: String?
        let selectedVersionBuild: ASCBuild?
        let reviewSubmissions: [ASCReviewSubmission]
        let reviewSubmissionItemsBySubmissionId: [String: [ASCReviewSubmissionItem]]
        let latestSubmissionItems: [ASCReviewSubmissionItem]
        let submissionHistoryEvents: [ASCSubmissionHistoryEvent]
        let attachedSubmissionItemIDs: Set<String>
        let resolutionCenterThreads: [IrisResolutionCenterThread]
        let irisFeedbackCycles: [IrisFeedbackCycle]
        let trackSlots: [String: [TrackSlot?]]
        let savedTrackState: [String: [TrackSlot?]]
        let localScreenshotAssets: [LocalScreenshotAsset]
        let appIconStatus: String?
        let monetizationStatus: String?
        let loadedTabs: Set<AppTab>
        let tabLoadedAt: [AppTab: Date]

        @MainActor
        init(manager: ASCManager, projectId: String) {
            self.projectId = projectId
            bundleId = Self.normalizedBundleId(manager.app?.bundleId)
            app = manager.app
            appStoreVersions = manager.appStoreVersions
            localizations = manager.localizations
            appInfoLocalizationsByLocale = manager.appInfoLocalizationsByLocale
            screenshotSetsByLocale = manager.screenshotSetsByLocale
            screenshotsByLocale = manager.screenshotsByLocale
            customerReviews = manager.customerReviews
            builds = manager.builds
            betaGroups = manager.betaGroups
            betaLocalizations = manager.betaLocalizations
            betaFeedback = manager.betaFeedback
            selectedBuildId = manager.selectedBuildId
            inAppPurchases = manager.inAppPurchases
            subscriptionGroups = manager.subscriptionGroups
            subscriptionsPerGroup = manager.subscriptionsPerGroup
            appPricePoints = manager.appPricePoints
            currentAppPricePointId = manager.currentAppPricePointId
            scheduledAppPricePointId = manager.scheduledAppPricePointId
            scheduledAppPriceEffectiveDate = manager.scheduledAppPriceEffectiveDate
            appInfo = manager.appInfo
            appInfoLocalization = manager.appInfoLocalization
            ageRatingDeclaration = manager.ageRatingDeclaration
            reviewDetail = manager.reviewDetail
            selectedVersionId = manager.selectedVersionId
            selectedVersionBuild = manager.selectedVersionBuild
            reviewSubmissions = manager.reviewSubmissions
            reviewSubmissionItemsBySubmissionId = manager.reviewSubmissionItemsBySubmissionId
            latestSubmissionItems = manager.latestSubmissionItems
            submissionHistoryEvents = manager.submissionHistoryEvents
            attachedSubmissionItemIDs = manager.attachedSubmissionItemIDs
            resolutionCenterThreads = manager.resolutionCenterThreads
            irisFeedbackCycles = manager.irisFeedbackCycles
            trackSlots = manager.trackSlots
            savedTrackState = manager.savedTrackState
            localScreenshotAssets = manager.localScreenshotAssets
            appIconStatus = manager.appIconStatus
            monetizationStatus = manager.monetizationStatus
            let cachedLoadedTabs = manager.loadedTabs.intersection(Self.cachedProjectTabs)
            loadedTabs = cachedLoadedTabs
            tabLoadedAt = manager.tabLoadedAt.filter { cachedLoadedTabs.contains($0.key) }
        }

        @MainActor
        func apply(to manager: ASCManager) {
            manager.app = app
            manager.appStoreVersions = appStoreVersions
            manager.localizations = localizations
            manager.appInfoLocalizationsByLocale = appInfoLocalizationsByLocale
            manager.screenshotSetsByLocale = screenshotSetsByLocale
            manager.screenshotsByLocale = screenshotsByLocale
            manager.customerReviews = customerReviews
            manager.builds = builds
            manager.betaGroups = betaGroups
            manager.betaLocalizations = betaLocalizations
            manager.betaFeedback = betaFeedback
            manager.selectedBuildId = selectedBuildId
            manager.inAppPurchases = inAppPurchases
            manager.subscriptionGroups = subscriptionGroups
            manager.subscriptionsPerGroup = subscriptionsPerGroup
            manager.appPricePoints = appPricePoints
            manager.currentAppPricePointId = currentAppPricePointId
            manager.scheduledAppPricePointId = scheduledAppPricePointId
            manager.scheduledAppPriceEffectiveDate = scheduledAppPriceEffectiveDate
            manager.appInfo = appInfo
            manager.appInfoLocalization = appInfoLocalization
            manager.ageRatingDeclaration = ageRatingDeclaration
            manager.reviewDetail = reviewDetail
            manager.selectedVersionId = selectedVersionId
            manager.selectedVersionBuild = selectedVersionBuild
            manager.reviewSubmissions = reviewSubmissions
            manager.reviewSubmissionItemsBySubmissionId = reviewSubmissionItemsBySubmissionId
            manager.latestSubmissionItems = latestSubmissionItems
            manager.submissionHistoryEvents = submissionHistoryEvents
            manager.attachedSubmissionItemIDs = attachedSubmissionItemIDs
            manager.resolutionCenterThreads = resolutionCenterThreads
            manager.irisFeedbackCycles = irisFeedbackCycles
            manager.trackSlots = trackSlots
            manager.savedTrackState = savedTrackState
            manager.localScreenshotAssets = localScreenshotAssets
            manager.appIconStatus = appIconStatus
            manager.monetizationStatus = monetizationStatus
            manager.loadedTabs = loadedTabs
            manager.tabLoadedAt = tabLoadedAt
            manager.loadedProjectId = projectId
            manager.tabError = [:]
            manager.isLoadingTab = [:]
            manager.isLoadingApp = false
            manager.isLoadingIrisFeedback = false
            manager.loadingFeedbackBuildIds = []
            manager.irisFeedbackError = nil
            manager.writeError = nil
            manager.submissionError = nil
            manager.overviewReadinessLoadingFields = []
        }

        func matches(bundleId: String?) -> Bool {
            let requestedBundleId = Self.normalizedBundleId(bundleId)
            guard let requestedBundleId else { return true }
            guard let snapshotBundleId = self.bundleId else { return false }
            return snapshotBundleId == requestedBundleId
        }

        private static func normalizedBundleId(_ bundleId: String?) -> String? {
            let trimmed = bundleId?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let trimmed, !trimmed.isEmpty else { return nil }
            return trimmed
        }

        private static let cachedProjectTabs: Set<AppTab> = [
            .app,
            .storeListing,
            .screenshots,
            .appDetails,
            .monetization,
            .review,
            .analytics,
            .reviews,
            .builds,
            .groups,
            .betaInfo,
            .feedback,
        ]
    }

    private static let projectCacheFreshness: TimeInterval = 120

    func checkAppIcon(projectId: String) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let iconDir = "\(home)/.blitz/projects/\(projectId)/assets/AppIcon"
        let icon1024 = "\(iconDir)/icon_1024.png"

        if fm.fileExists(atPath: icon1024) {
            appIconStatus = "1024px"
            return
        }

        let projectDir = "\(home)/.blitz/projects/\(projectId)"
        let xcassetsPattern = ["ios", "macos", "."]
        for subdir in xcassetsPattern {
            let searchDir = subdir == "." ? projectDir : "\(projectDir)/\(subdir)"
            guard let enumerator = fm.enumerator(atPath: searchDir) else { continue }
            while let file = enumerator.nextObject() as? String {
                guard file.hasSuffix("AppIcon.appiconset/Contents.json") else { continue }
                let contentsPath = "\(searchDir)/\(file)"
                guard let data = fm.contents(atPath: contentsPath),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let images = json["images"] as? [[String: Any]] else {
                    continue
                }
                if images.contains(where: { $0["filename"] != nil }) {
                    appIconStatus = "Configured"
                    return
                }
            }
        }

        appIconStatus = nil
    }

    func prepareForProjectSwitch(to projectId: String, bundleId: String?) {
        cacheCurrentProjectSnapshot()
        resetProjectData(preserveCredentials: true)

        if let snapshot = projectSnapshots[projectId], snapshot.matches(bundleId: bundleId) {
            snapshot.apply(to: self)
        } else {
            loadedProjectId = projectId
            Task {
                await ASCUpdateLogger.shared.event("project_switch_reset", metadata: [
                    "bundleId": bundleId ?? "nil",
                    "projectId": projectId,
                    "reason": projectSnapshots[projectId] == nil ? "no_snapshot" : "bundle_mismatch",
                ])
            }
        }
    }

    func loadStoredCredentialsIfNeeded() {
        guard credentials == nil || service == nil else { return }
        let creds = ASCCredentials.load()
        try? ASCAuthBridge().syncCredentials(creds)
        Self.syncWebSessionFileFromKeychain()
        credentials = creds
        service = creds.map { AppStoreConnectService(credentials: $0) }
    }

    func loadCredentials(for projectId: String, bundleId: String?) async {
        let normalizedBundleId = bundleId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let loadedAppMatchesBundle = normalizedBundleId == nil || app?.bundleId == normalizedBundleId
        let needsCredentialReload = credentials == nil || service == nil
        let shouldSkip = loadedProjectId == projectId
            && !needsCredentialReload
            && loadedAppMatchesBundle
            && (normalizedBundleId == nil || app != nil)
        guard !shouldSkip else { return }

        credentialsError = nil

        if needsCredentialReload {
            isLoadingCredentials = true
            let creds = ASCCredentials.load()
            try? ASCAuthBridge().syncCredentials(creds)
            Self.syncWebSessionFileFromKeychain()
            credentials = creds
            isLoadingCredentials = false
            service = creds.map { AppStoreConnectService(credentials: $0) }
        }

        // Never reuse app/version data for a different bundle ID, even if
        // credentials are still valid and a previous project left data behind.
        if loadedProjectId != projectId || !loadedAppMatchesBundle {
            resetProjectData(preserveCredentials: true)
        }

        loadedProjectId = projectId
        refreshAppIconStatusIfNeeded(for: projectId)

        if let normalizedBundleId, !normalizedBundleId.isEmpty, credentials != nil,
           app?.bundleId != normalizedBundleId {
            await fetchApp(bundleId: normalizedBundleId)
        }
    }

    func clearForProjectSwitch() {
        resetProjectData(preserveCredentials: false)
    }

    func saveCredentials(_ creds: ASCCredentials, projectId: String, bundleId: String?) async throws {
        try creds.save()
        credentials = creds
        service = AppStoreConnectService(credentials: creds)
        credentialsError = nil
        cancelBackgroundHydrationTasks()
        loadedTabs = []
        tabLoadedAt = [:]
        tabError = [:]
        isLoadingTab = [:]
        loadingFeedbackBuildIds = []

        if let bundleId, !bundleId.isEmpty {
            await fetchApp(bundleId: bundleId)
        }

        credentialActivationRevision += 1
    }

    func deleteCredentials() {
        ASCCredentials.delete()
        let projectId = loadedProjectId
        clearForProjectSwitch()
        loadedProjectId = projectId
    }

    func refreshAppIconStatusIfNeeded(for projectId: String?) {
        guard let projectId, !projectId.isEmpty else { return }
        checkAppIcon(projectId: projectId)
    }

    func cancelBackgroundHydration(for tab: AppTab) {
        tabHydrationTasks[tab]?.cancel()
        tabHydrationTasks.removeValue(forKey: tab)
    }

    func cancelBackgroundHydrationTasks() {
        for task in tabHydrationTasks.values {
            task.cancel()
        }
        tabHydrationTasks.removeAll()
    }

    func startBackgroundHydration(for tab: AppTab, operation: @escaping @MainActor () async -> Void) {
        cancelBackgroundHydration(for: tab)
        tabHydrationTasks[tab] = Task {
            await operation()
        }
    }

    func waitForBackgroundHydration(for tab: AppTab) async {
        if let task = tabHydrationTasks[tab] {
            await task.value
        }
    }

    func resetProjectData(preserveCredentials: Bool) {
        cancelBackgroundHydrationTasks()
        overviewReadinessLoadingFields = []
        loadingFeedbackBuildIds = []

        if !preserveCredentials {
            credentials = nil
            service = nil
        }

        app = nil
        isLoadingCredentials = false
        credentialsError = nil
        isLoadingApp = false
        appStoreVersions = []
        localizations = []
        selectedStoreListingLocale = nil
        appInfoLocalizationsByLocale = [:]
        screenshotSetsByLocale = [:]
        screenshotsByLocale = [:]
        selectedScreenshotsLocale = nil
        customerReviews = []
        builds = []
        betaGroups = []
        betaLocalizations = []
        betaFeedback = [:]
        selectedBuildId = nil
        inAppPurchases = []
        subscriptionGroups = []
        subscriptionsPerGroup = [:]
        appPricePoints = []
        currentAppPricePointId = nil
        scheduledAppPricePointId = nil
        scheduledAppPriceEffectiveDate = nil
        appInfo = nil
        appInfoLocalization = nil
        ageRatingDeclaration = nil
        reviewDetail = nil
        selectedVersionId = nil
        selectedVersionBuild = nil
        pendingFormValues = [:]
        showSubmitPreview = false
        showCreateUpdateSheet = false
        isSubmitting = false
        isCreatingVersion = false
        submissionError = nil
        versionCreationError = nil
        writeError = nil
        reviewSubmissions = []
        reviewSubmissionItemsBySubmissionId = [:]
        latestSubmissionItems = []
        submissionHistoryEvents = []
        appIconStatus = nil
        monetizationStatus = nil
        attachedSubmissionItemIDs = []
        trackSlots = [:]
        savedTrackState = [:]
        localScreenshotAssets = []
        isLoadingTab = [:]
        tabError = [:]
        loadedTabs = []
        tabLoadedAt = [:]
        if !preserveCredentials {
            loadedProjectId = nil
        }

        resolutionCenterThreads = []
        irisFeedbackCycles = []
        isLoadingIrisFeedback = false
        irisFeedbackError = nil
        cancelPendingWebAuth()
    }

    func cacheCurrentProjectSnapshot() {
        guard let projectId = loadedProjectId else { return }
        guard app != nil || !loadedTabs.isEmpty else { return }
        projectSnapshots[projectId] = ProjectSnapshot(manager: self, projectId: projectId)
    }

    func shouldRefreshTabCache(_ tab: AppTab) -> Bool {
        guard loadedTabs.contains(tab) else { return true }
        guard let loadedAt = tabLoadedAt[tab] else { return true }
        return Date().timeIntervalSince(loadedAt) > Self.projectCacheFreshness
    }
}
