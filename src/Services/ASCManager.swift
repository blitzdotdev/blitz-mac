import Foundation

@MainActor
@Observable
final class ASCManager {
    nonisolated init() {}

    // Credentials & service
    var credentials: ASCCredentials?
    private(set) var service: AppStoreConnectService?

    // App
    var app: ASCApp?

    // Loading / error state
    var isLoadingCredentials = false
    var credentialsError: String?
    var isLoadingApp = false

    // Per-tab data
    var appStoreVersions: [ASCAppStoreVersion] = []
    var localizations: [ASCVersionLocalization] = []
    var screenshotSets: [ASCScreenshotSet] = []
    var screenshots: [String: [ASCScreenshot]] = [:]  // keyed by screenshotSet.id
    var customerReviews: [ASCCustomerReview] = []
    var builds: [ASCBuild] = []
    var betaGroups: [ASCBetaGroup] = []
    var betaLocalizations: [ASCBetaLocalization] = []
    var betaFeedback: [String: [ASCBetaFeedback]] = [:]  // keyed by build.id
    var selectedBuildId: String?

    // Monetization data
    var inAppPurchases: [ASCInAppPurchase] = []
    var subscriptionGroups: [ASCSubscriptionGroup] = []
    var subscriptionsPerGroup: [String: [ASCSubscription]] = [:]  // groupId → subs
    var appPricePoints: [ASCPricePoint] = []  // USA price tiers for the app

    // Creation progress (survives tab switches)
    var createProgress: Double = 0
    var createProgressMessage: String = ""
    var isCreating = false
    private var createTask: Task<Void, Never>?

    // New data for submission flow
    var appInfo: ASCAppInfo?
    var appInfoLocalization: ASCAppInfoLocalization?
    var ageRatingDeclaration: ASCAgeRatingDeclaration?
    var reviewDetail: ASCReviewDetail?
    var pendingFormValues: [String: [String: String]] = [:]  // tab → field → value (for MCP pre-fill)
    var pendingFormVersion: Int = 0  // Incremented when pendingFormValues changes; views watch this
    var pendingCreateValues: [String: String]?  // Pre-fill values for IAP/subscription create forms (from MCP)
    var showSubmitPreview = false
    var isSubmitting = false
    var submissionError: String?
    var writeError: String?  // Inline error for write operations (does not replace tab content)

    // App icon status (set externally; nil = not checked / missing)
    var appIconStatus: String?

    // monetization status (set after monetization check or setPriceFree success)
    var monetizationStatus: String?

    // Build pipeline progress (driven by MCPToolExecutor)
    enum BuildPipelinePhase: String {
        case idle
        case signingSetup = "Setting up signing…"
        case archiving = "Archiving…"
        case exporting = "Exporting IPA…"
        case uploading = "Uploading to App Store Connect…"
        case processing = "Processing build…"
    }
    var buildPipelinePhase: BuildPipelinePhase = .idle
    var buildPipelineMessage: String = ""  // Latest progress line from the build

    var submissionReadiness: SubmissionReadiness {
        let loc = localizations.first
        let info = appInfoLocalization
        let review = reviewDetail
        let demoRequired = review?.attributes.demoAccountRequired == true
        let version = appStoreVersions.first

        // Screenshot checks per display type
        let iphoneScreenshots = screenshotSets.first { $0.attributes.screenshotDisplayType == "APP_IPHONE_67" }
        let ipadScreenshots = screenshotSets.first { $0.attributes.screenshotDisplayType == "APP_IPAD_PRO_3GEN_129" }

        // Privacy nutrition labels URL (manual action required)
        let privacyUrl: String? = app.map {
            "https://appstoreconnect.apple.com/apps/\($0.id)/distribution/privacy"
        }

        var fields: [SubmissionReadiness.FieldStatus] = [
            .init(label: "App Name", value: info?.attributes.name ?? loc?.attributes.title),
            .init(label: "Description", value: loc?.attributes.description),
            .init(label: "Keywords", value: loc?.attributes.keywords),
            .init(label: "Support URL", value: loc?.attributes.supportUrl),
            .init(label: "Privacy Policy URL", value: info?.attributes.privacyPolicyUrl),
            .init(label: "Copyright", value: version?.attributes.copyright),
            .init(label: "Content Rights", value: app?.contentRightsDeclaration),
            .init(label: "Primary Category", value: appInfo?.primaryCategoryId),
            .init(label: "Age Rating", value: ageRatingDeclaration != nil ? "Configured" : nil),
            .init(label: "Pricing", value: monetizationStatus),
            .init(label: "Review Contact First Name", value: review?.attributes.contactFirstName),
            .init(label: "Review Contact Last Name", value: review?.attributes.contactLastName),
            .init(label: "Review Contact Email", value: review?.attributes.contactEmail),
            .init(label: "Review Contact Phone", value: review?.attributes.contactPhone),
        ]

        // Conditional: demo credentials required when demoAccountRequired is set
        if demoRequired {
            fields.append(.init(label: "Demo Account Name", value: review?.attributes.demoAccountName))
            fields.append(.init(label: "Demo Account Password", value: review?.attributes.demoAccountPassword))
        }

        fields.append(contentsOf: [
            .init(label: "App Icon", value: appIconStatus),
            .init(label: "iPhone Screenshots", value: iphoneScreenshots != nil ? "\(iphoneScreenshots!.attributes.screenshotCount ?? 0) screenshot(s)" : nil),
            .init(label: "iPad Screenshots", value: ipadScreenshots != nil ? "\(ipadScreenshots!.attributes.screenshotCount ?? 0) screenshot(s)" : nil),
            .init(label: "Privacy Nutrition Labels", value: nil, required: false, actionUrl: privacyUrl),
            .init(label: "Build", value: builds.first?.attributes.version),
        ])

        return SubmissionReadiness(fields: fields)
    }

    // Per-tab loading / error
    var isLoadingTab: [AppTab: Bool] = [:]
    var tabError: [AppTab: String] = [:]
    private var loadedTabs: Set<AppTab> = []

    var loadedProjectId: String?

    // MARK: - App Icon Check

    /// Check whether the project has app icon assets at ~/.blitz/projects/{projectId}/assets/AppIcon/
    func checkAppIcon(projectId: String) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let iconDir = "\(home)/.blitz/projects/\(projectId)/assets/AppIcon"
        let icon1024 = "\(iconDir)/icon_1024.png"

        if fm.fileExists(atPath: icon1024) {
            appIconStatus = "1024px"
        } else {
            // Also check the Xcode project's xcassets as fallback
            let projectDir = "\(home)/.blitz/projects/\(projectId)"
            let xcassetsPattern = ["ios", "macos", "."]
            for subdir in xcassetsPattern {
                let searchDir = subdir == "." ? projectDir : "\(projectDir)/\(subdir)"
                if let enumerator = fm.enumerator(atPath: searchDir) {
                    while let file = enumerator.nextObject() as? String {
                        if file.hasSuffix("AppIcon.appiconset/Contents.json") {
                            let contentsPath = "\(searchDir)/\(file)"
                            if let data = fm.contents(atPath: contentsPath),
                               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                               let images = json["images"] as? [[String: Any]] {
                                let hasFilename = images.contains { $0["filename"] != nil }
                                if hasFilename {
                                    appIconStatus = "Configured"
                                    return
                                }
                            }
                        }
                    }
                }
            }
            appIconStatus = nil
        }
    }

    // MARK: - Project Lifecycle

    func loadCredentials(for projectId: String, bundleId: String?) async {
        guard loadedProjectId != projectId else { return }

        isLoadingCredentials = true
        credentialsError = nil

        let creds = ASCCredentials.load()

        credentials = creds
        isLoadingCredentials = false
        loadedProjectId = projectId

        if let creds {
            service = AppStoreConnectService(credentials: creds)
        }

        if let bundleId, !bundleId.isEmpty, creds != nil {
            await fetchApp(bundleId: bundleId)
        }
    }

    func clearForProjectSwitch() {
        credentials = nil
        service = nil
        app = nil
        isLoadingCredentials = false
        credentialsError = nil
        isLoadingApp = false
        appStoreVersions = []
        localizations = []
        screenshotSets = []
        screenshots = [:]
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
        appInfo = nil
        appInfoLocalization = nil
        ageRatingDeclaration = nil
        reviewDetail = nil
        pendingFormValues = [:]
        showSubmitPreview = false
        isSubmitting = false
        submissionError = nil
        writeError = nil
        appIconStatus = nil
        monetizationStatus = nil
        isLoadingTab = [:]
        tabError = [:]
        loadedTabs = []
        loadedProjectId = nil
    }

    func saveCredentials(_ creds: ASCCredentials, projectId: String, bundleId: String?) async throws {
        try creds.save()
        credentials = creds
        service = AppStoreConnectService(credentials: creds)
        credentialsError = nil
        loadedTabs = []  // force re-fetch after new credentials

        if let bundleId, !bundleId.isEmpty {
            await fetchApp(bundleId: bundleId)
        }
    }

    func deleteCredentials(projectId: String) {
        ASCCredentials.delete()
        let pid = loadedProjectId
        clearForProjectSwitch()
        loadedProjectId = pid  // keep project id so gate re-checks correctly
    }

    // MARK: - App Fetch

    func fetchApp(bundleId: String) async {
        guard let service else { return }
        isLoadingApp = true
        do {
            let fetched = try await service.fetchApp(bundleId: bundleId)
            app = fetched
        } catch {
            credentialsError = error.localizedDescription
        }
        isLoadingApp = false
    }

    // MARK: - Tab Data

    func fetchTabData(_ tab: AppTab) async {
        guard let service else { return }
        guard credentials != nil else { return }
        guard !loadedTabs.contains(tab) else { return }
        guard isLoadingTab[tab] != true else { return }

        isLoadingTab[tab] = true
        tabError.removeValue(forKey: tab)

        do {
            try await loadData(for: tab, service: service)
            isLoadingTab[tab] = false
            loadedTabs.insert(tab)
        } catch {
            isLoadingTab[tab] = false
            tabError[tab] = error.localizedDescription
        }
    }

    /// Called after bundle ID setup completes and the app is confirmed in ASC.
    /// Clears all tab errors and forces data to be re-fetched.
    func resetTabState() {
        tabError.removeAll()
        loadedTabs.removeAll()
    }

    func refreshTabData(_ tab: AppTab) async {
        guard let service else { return }
        guard credentials != nil else { return }

        loadedTabs.remove(tab)
        isLoadingTab[tab] = true
        tabError.removeValue(forKey: tab)

        do {
            try await loadData(for: tab, service: service)
            isLoadingTab[tab] = false
            loadedTabs.insert(tab)
        } catch {
            isLoadingTab[tab] = false
            tabError[tab] = error.localizedDescription
        }
    }

    private func loadData(for tab: AppTab, service: AppStoreConnectService) async throws {
        guard let appId = app?.id else {
            throw ASCError.notFound("App — check your bundle ID in project settings")
        }

        switch tab {
        case .ascOverview:
            let versions = try await service.fetchAppStoreVersions(appId: appId)
            appStoreVersions = versions
            appInfo = try? await service.fetchAppInfo(appId: appId)
            // Fetch all data needed for submission readiness
            if let latestId = versions.first?.id {
                localizations = try await service.fetchLocalizations(versionId: latestId)
                reviewDetail = try? await service.fetchReviewDetail(versionId: latestId)
                let locs = localizations
                if let firstLocId = locs.first?.id {
                    screenshotSets = try await service.fetchScreenshotSets(localizationId: firstLocId)
                }
            }
            if let infoId = appInfo?.id {
                ageRatingDeclaration = try? await service.fetchAgeRating(appInfoId: infoId)
                appInfoLocalization = try? await service.fetchAppInfoLocalization(appInfoId: infoId)
            }
            builds = try await service.fetchBuilds(appId: appId)

            // Check monetization status
            let hasPricing = await service.fetchPricingConfigured(appId: appId)
            monetizationStatus = hasPricing ? "Configured" : nil

        case .storeListing:
            let versions = try await service.fetchAppStoreVersions(appId: appId)
            appStoreVersions = versions
            if let latestId = versions.first?.id {
                localizations = try await service.fetchLocalizations(versionId: latestId)
            }
            // Also fetch appInfoLocalization for privacy policy URL
            if appInfo == nil {
                appInfo = try? await service.fetchAppInfo(appId: appId)
            }
            if let infoId = appInfo?.id, appInfoLocalization == nil {
                appInfoLocalization = try? await service.fetchAppInfoLocalization(appInfoId: infoId)
            }

        case .screenshots:
            let versions = try await service.fetchAppStoreVersions(appId: appId)
            appStoreVersions = versions
            if let latestId = versions.first?.id {
                let locs = try await service.fetchLocalizations(versionId: latestId)
                localizations = locs
                if let firstLocId = locs.first?.id {
                    let sets = try await service.fetchScreenshotSets(localizationId: firstLocId)
                    screenshotSets = sets
                    for set in sets {
                        let shots = try await service.fetchScreenshots(setId: set.id)
                        screenshots[set.id] = shots
                    }
                }
            }

        case .appDetails:
            let versions = try await service.fetchAppStoreVersions(appId: appId)
            appStoreVersions = versions
            appInfo = try? await service.fetchAppInfo(appId: appId)

        case .review:
            let versions = try await service.fetchAppStoreVersions(appId: appId)
            appStoreVersions = versions
            if let latestId = versions.first?.id {
                reviewDetail = try? await service.fetchReviewDetail(versionId: latestId)
            }
            appInfo = try? await service.fetchAppInfo(appId: appId)
            if let infoId = appInfo?.id {
                ageRatingDeclaration = try? await service.fetchAgeRating(appInfoId: infoId)
            }
            builds = try await service.fetchBuilds(appId: appId)

        case .monetization:
            appPricePoints = try await service.fetchAppPricePoints(appId: appId)
            inAppPurchases = try await service.fetchInAppPurchases(appId: appId)
            subscriptionGroups = try await service.fetchSubscriptionGroups(appId: appId)
            for group in subscriptionGroups {
                subscriptionsPerGroup[group.id] = try await service.fetchSubscriptionsInGroup(groupId: group.id)
            }
            let hasPricing = await service.fetchPricingConfigured(appId: appId)
            monetizationStatus = hasPricing ? "Configured" : nil

        case .analytics:
            break  // Sales reports use a separate reports API; handled in view

        case .reviews:
            customerReviews = try await service.fetchCustomerReviews(appId: appId)

        case .builds:
            builds = try await service.fetchBuilds(appId: appId)

        case .groups:
            betaGroups = try await service.fetchBetaGroups(appId: appId)

        case .betaInfo:
            betaLocalizations = try await service.fetchBetaLocalizations(appId: appId)

        case .feedback:
            let fetched = try await service.fetchBuilds(appId: appId)
            builds = fetched
            if let first = fetched.first {
                selectedBuildId = first.id
                do {
                    betaFeedback[first.id] = try await service.fetchBetaFeedback(buildId: first.id)
                } catch {
                    // Feedback may not be available for all apps; non-fatal
                    betaFeedback[first.id] = []
                }
            }

        default:
            break
        }
    }

    // MARK: - Write Methods

    func updateLocalizationField(_ field: String, value: String, locId: String) async {
        guard let service else { return }
        writeError = nil
        do {
            try await service.patchLocalization(id: locId, fields: [field: value])
            if let latestId = appStoreVersions.first?.id {
                localizations = try await service.fetchLocalizations(versionId: latestId)
            }
        } catch {
            writeError = error.localizedDescription
        }
    }

    func updatePrivacyPolicyUrl(_ url: String) async {
        await updateAppInfoLocalizationField("privacyPolicyUrl", value: url)
    }

    /// Update a field on appInfoLocalizations (name, subtitle, privacyPolicyUrl)
    func updateAppInfoLocalizationField(_ field: String, value: String) async {
        guard let service else { return }
        guard let locId = appInfoLocalization?.id else { return }
        writeError = nil
        // Map UI field names to API field names
        let apiField = (field == "title") ? "name" : field
        do {
            try await service.patchAppInfoLocalization(id: locId, fields: [apiField: value])
            if let infoId = appInfo?.id {
                appInfoLocalization = try? await service.fetchAppInfoLocalization(appInfoId: infoId)
            }
        } catch {
            writeError = error.localizedDescription
        }
    }

    func updateAppInfoField(_ field: String, value: String) async {
        guard let service else { return }
        writeError = nil

        // Fields that live on different ASC resources:
        // - copyright → appStoreVersions (PATCH /v1/appStoreVersions/{id})
        // - contentRightsDeclaration → apps (PATCH /v1/apps/{id})
        // - primaryCategory, subcategories → appInfos relationships (PATCH /v1/appInfos/{id})
        if field == "copyright" {
            guard let versionId = appStoreVersions.first?.id else { return }
            do {
                try await service.patchVersion(id: versionId, fields: [field: value])
            } catch {
                writeError = error.localizedDescription
            }
        } else if field == "contentRightsDeclaration" {
            guard let appId = app?.id else { return }
            do {
                try await service.patchApp(id: appId, fields: [field: value])
                // Refetch app to reflect the change
                app = try await service.fetchApp(bundleId: app?.bundleId ?? "")
            } catch {
                writeError = error.localizedDescription
            }
        } else if let infoId = appInfo?.id {
            do {
                try await service.patchAppInfo(id: infoId, fields: [field: value])
                appInfo = try? await service.fetchAppInfo(appId: app?.id ?? "")
            } catch {
                writeError = error.localizedDescription
            }
        }
    }

    func updateAgeRating(_ attributes: [String: Any]) async {
        guard let service else { return }
        guard let id = ageRatingDeclaration?.id else { return }
        writeError = nil
        do {
            try await service.patchAgeRating(id: id, attributes: attributes)
            if let infoId = appInfo?.id {
                ageRatingDeclaration = try? await service.fetchAgeRating(appInfoId: infoId)
            }
        } catch {
            writeError = error.localizedDescription
        }
    }

    func updateReviewContact(_ attributes: [String: Any]) async {
        guard let service else { return }
        guard let versionId = appStoreVersions.first?.id else { return }
        writeError = nil
        do {
            try await service.createOrPatchReviewDetail(versionId: versionId, attributes: attributes)
            reviewDetail = try? await service.fetchReviewDetail(versionId: versionId)
        } catch {
            writeError = error.localizedDescription
        }
    }

    func setAppPrice(pricePointId: String) async {
        guard let service else { return }
        guard let appId = app?.id else { return }
        writeError = nil
        do {
            try await service.setAppPrice(appId: appId, pricePointId: pricePointId)
            monetizationStatus = "Configured"
        } catch {
            writeError = error.localizedDescription
        }
    }

    func setScheduledAppPrice(currentPricePointId: String, futurePricePointId: String, effectiveDate: String) async {
        guard let service else { return }
        guard let appId = app?.id else { return }
        writeError = nil
        do {
            try await service.setScheduledAppPrice(
                appId: appId,
                currentPricePointId: currentPricePointId,
                futurePricePointId: futurePricePointId,
                effectiveDate: effectiveDate
            )
            monetizationStatus = "Configured"
        } catch {
            writeError = error.localizedDescription
        }
    }

    func createIAP(name: String, productId: String, type: String, displayName: String, description: String?, price: String, screenshotPath: String? = nil) {
        guard let service else { return }
        guard let appId = app?.id else { return }
        writeError = nil
        isCreating = true
        createProgress = 0
        createProgressMessage = "Creating in-app purchase…"

        createTask = Task { [weak self] in
            guard let self else { return }
            do {
                createProgress = 0.05
                let iap = try await service.createInAppPurchase(
                    appId: appId, name: name, productId: productId, inAppPurchaseType: type
                )

                createProgressMessage = "Setting localization…"
                createProgress = 0.15
                try await service.localizeInAppPurchase(
                    iapId: iap.id, locale: "en-US", name: displayName, description: description
                )

                createProgressMessage = "Setting availability…"
                createProgress = 0.3
                let territories = try await service.fetchAllTerritories()
                try await service.createIAPAvailability(iapId: iap.id, territoryIds: territories)

                createProgress = 0.5
                if !price.isEmpty, let priceVal = Double(price), priceVal > 0 {
                    createProgressMessage = "Setting price…"
                    let points = try await service.fetchInAppPurchasePricePoints(iapId: iap.id)
                    if let match = points.first(where: {
                        guard let cp = $0.attributes.customerPrice, let cpVal = Double(cp) else { return false }
                        return abs(cpVal - priceVal) < 0.001
                    }) {
                        try await service.setInAppPurchasePrice(iapId: iap.id, pricePointId: match.id)
                    }
                }

                createProgress = 0.7
                if let path = screenshotPath {
                    createProgressMessage = "Uploading screenshot…"
                    try await service.uploadIAPReviewScreenshot(iapId: iap.id, path: path)
                }

                createProgressMessage = "Waiting for status update…"
                createProgress = 0.9
                try await pollRefreshIAPs(service: service, appId: appId)
                createProgress = 1.0
            } catch {
                writeError = error.localizedDescription
            }
            isCreating = false
            createProgress = 0
            createProgressMessage = ""
        }
    }

    func updateIAP(id: String, name: String?, reviewNote: String?, displayName: String?, description: String?) async {
        guard let service else { return }
        guard let appId = app?.id else { return }
        writeError = nil
        do {
            // Patch IAP attributes (name, reviewNote)
            var attrs: [String: Any] = [:]
            if let name { attrs["name"] = name }
            if let reviewNote { attrs["reviewNote"] = reviewNote }
            if !attrs.isEmpty {
                try await service.patchInAppPurchase(iapId: id, attrs: attrs)
            }
            // Patch localization (displayName, description)
            if displayName != nil || description != nil {
                let locs = try await service.fetchIAPLocalizations(iapId: id)
                if let loc = locs.first {
                    var fields: [String: String] = [:]
                    if let displayName { fields["name"] = displayName }
                    if let description { fields["description"] = description }
                    try await service.patchIAPLocalization(locId: loc.id, fields: fields)
                }
            }
            inAppPurchases = try await service.fetchInAppPurchases(appId: appId)
        } catch {
            writeError = error.localizedDescription
        }
    }

    func uploadIAPScreenshot(iapId: String, path: String) async {
        guard let service else { return }
        writeError = nil
        do {
            try await service.uploadIAPReviewScreenshot(iapId: iapId, path: path)
        } catch {
            writeError = error.localizedDescription
        }
    }

    func deleteIAP(id: String) async {
        guard let service else { return }
        guard let appId = app?.id else { return }
        writeError = nil
        do {
            try await service.deleteInAppPurchase(iapId: id)
            inAppPurchases = try await service.fetchInAppPurchases(appId: appId)
        } catch {
            writeError = error.localizedDescription
        }
    }

    func createSubscription(groupName: String, name: String, productId: String, displayName: String, description: String?, duration: String, price: String, screenshotPath: String? = nil) {
        guard let service else { return }
        guard let appId = app?.id else { return }
        writeError = nil
        isCreating = true
        createProgress = 0
        createProgressMessage = "Setting up group…"

        createTask = Task { [weak self] in
            guard let self else { return }
            do {
                createProgress = 0.03
                let group: ASCSubscriptionGroup
                if let existing = subscriptionGroups.first(where: { $0.attributes.referenceName == groupName }) {
                    let groupLocs = try await service.fetchSubscriptionGroupLocalizations(groupId: existing.id)
                    if groupLocs.isEmpty {
                        try await service.localizeSubscriptionGroup(groupId: existing.id, locale: "en-US", name: groupName)
                    }
                    group = existing
                } else {
                    group = try await service.createSubscriptionGroup(appId: appId, referenceName: groupName)
                    try await service.localizeSubscriptionGroup(groupId: group.id, locale: "en-US", name: groupName)
                }

                createProgressMessage = "Creating subscription…"
                createProgress = 0.08
                let sub = try await service.createSubscription(
                    groupId: group.id, name: name, productId: productId, subscriptionPeriod: duration
                )

                createProgressMessage = "Setting localization…"
                createProgress = 0.12
                try await service.localizeSubscription(
                    subscriptionId: sub.id, locale: "en-US", name: displayName, description: description
                )

                createProgressMessage = "Setting availability…"
                createProgress = 0.16
                let territories = try await service.fetchAllTerritories()
                try await service.createSubscriptionAvailability(subscriptionId: sub.id, territoryIds: territories)

                createProgress = 0.2
                if !price.isEmpty, let priceVal = Double(price), priceVal > 0 {
                    let points = try await service.fetchSubscriptionPricePoints(subscriptionId: sub.id)
                    if let match = points.first(where: {
                        guard let cp = $0.attributes.customerPrice, let cpVal = Double(cp) else { return false }
                        return abs(cpVal - priceVal) < 0.001
                    }) {
                        // Pricing loop: 0.2 → 0.8 (bulk of the time)
                        createProgressMessage = "Setting prices (0/175)…"
                        try await service.setSubscriptionPrice(subscriptionId: sub.id, pricePointId: match.id) { done, total in
                            Task { @MainActor [weak self] in
                                self?.createProgressMessage = "Setting prices (\(done)/\(total))…"
                                self?.createProgress = 0.2 + 0.6 * (Double(done) / Double(total))
                            }
                        }
                    }
                }

                createProgress = 0.85
                if let path = screenshotPath {
                    createProgressMessage = "Uploading screenshot…"
                    try await service.uploadSubscriptionReviewScreenshot(subscriptionId: sub.id, path: path)
                }

                createProgressMessage = "Waiting for status update…"
                createProgress = 0.9
                try await pollRefreshSubscriptions(service: service, appId: appId)
                createProgress = 1.0
            } catch {
                writeError = error.localizedDescription
            }
            isCreating = false
            createProgress = 0
            createProgressMessage = ""
        }
    }

    func updateSubscription(id: String, name: String?, reviewNote: String?, displayName: String?, description: String?) async {
        guard let service else { return }
        guard let appId = app?.id else { return }
        writeError = nil
        do {
            var attrs: [String: Any] = [:]
            if let name { attrs["name"] = name }
            if let reviewNote { attrs["reviewNote"] = reviewNote }
            if !attrs.isEmpty {
                try await service.patchSubscription(subscriptionId: id, attrs: attrs)
            }
            if displayName != nil || description != nil {
                let locs = try await service.fetchSubscriptionLocalizations(subscriptionId: id)
                if let loc = locs.first {
                    var fields: [String: String] = [:]
                    if let displayName { fields["name"] = displayName }
                    if let description { fields["description"] = description }
                    try await service.patchSubscriptionLocalization(locId: loc.id, fields: fields)
                }
            }
            subscriptionGroups = try await service.fetchSubscriptionGroups(appId: appId)
            for g in subscriptionGroups {
                subscriptionsPerGroup[g.id] = try await service.fetchSubscriptionsInGroup(groupId: g.id)
            }
        } catch {
            writeError = error.localizedDescription
        }
    }

    func uploadSubscriptionScreenshot(subscriptionId: String, path: String) async {
        guard let service else { return }
        writeError = nil
        do {
            try await service.uploadSubscriptionReviewScreenshot(subscriptionId: subscriptionId, path: path)
        } catch {
            writeError = error.localizedDescription
        }
    }

    func updateSubscriptionGroupLocalization(groupId: String, name: String) async {
        guard let service else { return }
        writeError = nil
        do {
            let locs = try await service.fetchSubscriptionGroupLocalizations(groupId: groupId)
            if let loc = locs.first {
                try await service.patchSubscriptionGroupLocalization(locId: loc.id, name: name)
            } else {
                try await service.localizeSubscriptionGroup(groupId: groupId, locale: "en-US", name: name)
            }
        } catch {
            writeError = error.localizedDescription
        }
    }

    func deleteSubscription(id: String) async {
        guard let service else { return }
        guard let appId = app?.id else { return }
        writeError = nil
        do {
            try await service.deleteSubscription(subscriptionId: id)
            subscriptionGroups = try await service.fetchSubscriptionGroups(appId: appId)
            for g in subscriptionGroups {
                subscriptionsPerGroup[g.id] = try await service.fetchSubscriptionsInGroup(groupId: g.id)
            }
        } catch {
            writeError = error.localizedDescription
        }
    }

    func deleteSubscriptionGroup(id: String) async {
        guard let service else { return }
        guard let appId = app?.id else { return }
        writeError = nil
        do {
            try await service.deleteSubscriptionGroup(groupId: id)
            subscriptionGroups = try await service.fetchSubscriptionGroups(appId: appId)
            subscriptionsPerGroup.removeValue(forKey: id)
        } catch {
            writeError = error.localizedDescription
        }
    }

    // MARK: - Post-Create Polling

    private func pollRefreshIAPs(service: AppStoreConnectService, appId: String) async throws {
        for _ in 0..<5 {
            try await Task.sleep(for: .seconds(1))
            inAppPurchases = try await service.fetchInAppPurchases(appId: appId)
            let allResolved = inAppPurchases.allSatisfy { $0.attributes.state != "MISSING_METADATA" }
            if allResolved { return }
        }
    }

    private func pollRefreshSubscriptions(service: AppStoreConnectService, appId: String) async throws {
        for _ in 0..<5 {
            try await Task.sleep(for: .seconds(1))
            subscriptionGroups = try await service.fetchSubscriptionGroups(appId: appId)
            for g in subscriptionGroups {
                subscriptionsPerGroup[g.id] = try await service.fetchSubscriptionsInGroup(groupId: g.id)
            }
            let allResolved = subscriptionsPerGroup.values.joined().allSatisfy { $0.attributes.state != "MISSING_METADATA" }
            if allResolved { return }
        }
    }

    // MARK: - Review Submissions

    /// Returns true on success, false on failure (writeError set).
    /// Sets writeError to a message starting with "FIRST_SUBMISSION:" if the first-time restriction applies.
    func submitIAPForReview(id: String) async -> Bool {
        guard let service else { return false }
        guard let appId = app?.id else { return false }
        writeError = nil
        do {
            try await service.submitIAPForReview(iapId: id)
            inAppPurchases = try await service.fetchInAppPurchases(appId: appId)
            return true
        } catch {
            let msg = error.localizedDescription
            if msg.contains("FIRST_IAP") || msg.contains("first In-App Purchase") || msg.contains("first in-app purchase") {
                writeError = "FIRST_SUBMISSION:" + msg
            } else {
                writeError = msg
            }
            return false
        }
    }

    /// Returns true on success, false on failure (writeError set).
    /// Sets writeError to a message starting with "FIRST_SUBMISSION:" if the first-time restriction applies.
    func submitSubscriptionForReview(id: String) async -> Bool {
        guard let service else { return false }
        guard let appId = app?.id else { return false }
        writeError = nil
        do {
            try await service.submitSubscriptionForReview(subscriptionId: id)
            subscriptionGroups = try await service.fetchSubscriptionGroups(appId: appId)
            for g in subscriptionGroups {
                subscriptionsPerGroup[g.id] = try await service.fetchSubscriptionsInGroup(groupId: g.id)
            }
            return true
        } catch {
            let msg = error.localizedDescription
            if msg.contains("FIRST_SUBSCRIPTION") || msg.contains("first subscription") {
                writeError = "FIRST_SUBMISSION:" + msg
            } else {
                writeError = msg
            }
            return false
        }
    }

    func refreshMonetization() async {
        guard let service else { return }
        guard let appId = app?.id else { return }
        do {
            inAppPurchases = try await service.fetchInAppPurchases(appId: appId)
            subscriptionGroups = try await service.fetchSubscriptionGroups(appId: appId)
            for group in subscriptionGroups {
                subscriptionsPerGroup[group.id] = try await service.fetchSubscriptionsInGroup(groupId: group.id)
            }
        } catch {
            writeError = error.localizedDescription
        }
    }

    func setPriceFree() async {
        guard let service else { return }
        guard let appId = app?.id else { return }
        writeError = nil
        do {
            try await service.setPriceFree(appId: appId)
            monetizationStatus = "Free"
        } catch {
            writeError = error.localizedDescription
        }
    }

    func uploadScreenshots(paths: [String], displayType: String, locale: String) async {
        guard let service else { writeError = "ASC service not configured"; return }
        // Ensure localizations are loaded (may be empty if tab hasn't been visited)
        if localizations.isEmpty, let versionId = appStoreVersions.first?.id {
            localizations = (try? await service.fetchLocalizations(versionId: versionId)) ?? []
        }
        // If still no versions loaded, try fetching those too
        if localizations.isEmpty, let appId = app?.id {
            let versions = (try? await service.fetchAppStoreVersions(appId: appId)) ?? []
            appStoreVersions = versions
            if let versionId = versions.first?.id {
                localizations = (try? await service.fetchLocalizations(versionId: versionId)) ?? []
            }
        }
        guard let loc = localizations.first(where: { $0.attributes.locale == locale })
                ?? localizations.first else {
            writeError = "No localizations found for locale '\(locale)'. Check that a version exists."
            return
        }
        writeError = nil
        do {
            for path in paths {
                try await service.uploadScreenshot(localizationId: loc.id, path: path, displayType: displayType)
            }
            let sets = try await service.fetchScreenshotSets(localizationId: loc.id)
            screenshotSets = sets
            for set in sets {
                screenshots[set.id] = try await service.fetchScreenshots(setId: set.id)
            }
        } catch {
            writeError = error.localizedDescription
        }
    }

    /// The pending version ID (not live / not removed).
    var pendingVersionId: String? {
        appStoreVersions.first {
            let s = $0.attributes.appStoreState ?? ""
            return s != "READY_FOR_SALE" && s != "REMOVED_FROM_SALE"
                && s != "DEVELOPER_REMOVED_FROM_SALE" && !s.isEmpty
        }?.id ?? appStoreVersions.first?.id
    }

    func attachBuild(buildId: String) async {
        guard let service else { return }
        guard let versionId = pendingVersionId else {
            writeError = "No app store version found to attach build to."
            return
        }
        writeError = nil
        do {
            try await service.attachBuild(versionId: versionId, buildId: buildId)
        } catch {
            writeError = error.localizedDescription
        }
    }

    func submitForReview(attachBuildId: String? = nil) async {
        guard let service else { return }
        guard let appId = app?.id, let versionId = appStoreVersions.first?.id else { return }
        isSubmitting = true
        submissionError = nil
        do {
            // Attach build if specified
            if let buildId = attachBuildId {
                try await service.attachBuild(versionId: versionId, buildId: buildId)
            }
            try await service.submitForReview(appId: appId, versionId: versionId)
            isSubmitting = false
            // Refresh versions to show new state
            appStoreVersions = try await service.fetchAppStoreVersions(appId: appId)
        } catch {
            isSubmitting = false
            submissionError = error.localizedDescription
        }
    }

    func flushPendingLocalizations() async {
        guard let service else { return }
        let appInfoLocFieldNames: Set<String> = ["name", "title", "subtitle", "privacyPolicyUrl"]
        for (tab, fields) in pendingFormValues {
            if tab == "storeListing" {
                var versionLocFields: [String: String] = [:]
                var infoLocFields: [String: String] = [:]
                for (field, value) in fields {
                    if appInfoLocFieldNames.contains(field) {
                        let apiField = (field == "title") ? "name" : field
                        infoLocFields[apiField] = value
                    } else {
                        versionLocFields[field] = value
                    }
                }
                if !versionLocFields.isEmpty, let locId = localizations.first?.id {
                    try? await service.patchLocalization(id: locId, fields: versionLocFields)
                }
                if !infoLocFields.isEmpty, let infoLocId = appInfoLocalization?.id {
                    try? await service.patchAppInfoLocalization(id: infoLocId, fields: infoLocFields)
                }
            }
        }
        pendingFormValues = [:]
    }
}
