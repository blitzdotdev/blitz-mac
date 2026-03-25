import Foundation
import AppKit
import ImageIO
import Security

// MARK: - Screenshot Track Models

struct TrackSlot: Identifiable, Equatable {
    let id: String              // UUID for local, ASC id for uploaded
    var localPath: String?      // file path for local assets
    var localImage: NSImage?    // loaded thumbnail
    var ascScreenshot: ASCScreenshot?  // present if from ASC
    var isFromASC: Bool         // true if this slot was loaded from ASC

    static func == (lhs: TrackSlot, rhs: TrackSlot) -> Bool {
        lhs.id == rhs.id
    }
}

struct LocalScreenshotAsset: Identifiable {
    let id: UUID
    let url: URL
    let image: NSImage
    let fileName: String
}

@MainActor
@Observable
final class ASCManager {
    private struct ProjectSnapshot {
        let projectId: String
        let app: ASCApp?
        let appStoreVersions: [ASCAppStoreVersion]
        let localizations: [ASCVersionLocalization]
        let screenshotSets: [ASCScreenshotSet]
        let screenshots: [String: [ASCScreenshot]]
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
        let reviewSubmissions: [ASCReviewSubmission]
        let reviewSubmissionItemsBySubmissionId: [String: [ASCReviewSubmissionItem]]
        let latestSubmissionItems: [ASCReviewSubmissionItem]
        let submissionHistoryEvents: [ASCSubmissionHistoryEvent]
        let attachedSubmissionItemIDs: Set<String>
        let resolutionCenterThreads: [IrisResolutionCenterThread]
        let rejectionMessages: [IrisResolutionCenterMessage]
        let rejectionReasons: [IrisReviewRejection]
        let cachedFeedback: IrisFeedbackCache?
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
            app = manager.app
            appStoreVersions = manager.appStoreVersions
            localizations = manager.localizations
            screenshotSets = manager.screenshotSets
            screenshots = manager.screenshots
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
            reviewSubmissions = manager.reviewSubmissions
            reviewSubmissionItemsBySubmissionId = manager.reviewSubmissionItemsBySubmissionId
            latestSubmissionItems = manager.latestSubmissionItems
            submissionHistoryEvents = manager.submissionHistoryEvents
            attachedSubmissionItemIDs = manager.attachedSubmissionItemIDs
            resolutionCenterThreads = manager.resolutionCenterThreads
            rejectionMessages = manager.rejectionMessages
            rejectionReasons = manager.rejectionReasons
            cachedFeedback = manager.cachedFeedback
            trackSlots = manager.trackSlots
            savedTrackState = manager.savedTrackState
            localScreenshotAssets = manager.localScreenshotAssets
            appIconStatus = manager.appIconStatus
            monetizationStatus = manager.monetizationStatus
            let cachedLoadedTabs = manager.loadedTabs.intersection(ASCManager.cachedProjectTabs)
            loadedTabs = cachedLoadedTabs
            tabLoadedAt = manager.tabLoadedAt.filter { cachedLoadedTabs.contains($0.key) }
        }

        @MainActor
        func apply(to manager: ASCManager) {
            manager.app = app
            manager.appStoreVersions = appStoreVersions
            manager.localizations = localizations
            manager.screenshotSets = screenshotSets
            manager.screenshots = screenshots
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
            manager.reviewSubmissions = reviewSubmissions
            manager.reviewSubmissionItemsBySubmissionId = reviewSubmissionItemsBySubmissionId
            manager.latestSubmissionItems = latestSubmissionItems
            manager.submissionHistoryEvents = submissionHistoryEvents
            manager.attachedSubmissionItemIDs = attachedSubmissionItemIDs
            manager.resolutionCenterThreads = resolutionCenterThreads
            manager.rejectionMessages = rejectionMessages
            manager.rejectionReasons = rejectionReasons
            manager.cachedFeedback = cachedFeedback
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
    }

    private static let projectCacheFreshness: TimeInterval = 120
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
    private static let overviewLocalizationFieldLabels: Set<String> = [
        "App Name",
        "Description",
        "Keywords",
        "Support URL"
    ]
    private static let overviewVersionFieldLabels: Set<String> = ["Copyright"]
    private static let overviewAppInfoFieldLabels: Set<String> = ["Primary Category"]
    private static let overviewMetadataFieldLabels: Set<String> = [
        "Privacy Policy URL",
        "Age Rating"
    ]
    private static let overviewReviewFieldLabels: Set<String> = [
        "Review Contact First Name",
        "Review Contact Last Name",
        "Review Contact Email",
        "Review Contact Phone",
        "Demo Account Name",
        "Demo Account Password"
    ]
    private static let overviewBuildFieldLabels: Set<String> = ["Build"]
    private static let overviewPricingFieldLabels: Set<String> = [
        "Pricing",
        "In-App Purchases & Subscriptions"
    ]
    private static let overviewScreenshotFieldLabels: Set<String> = [
        "Mac Screenshots",
        "iPhone Screenshots",
        "iPad Screenshots"
    ]

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
    // Bumped after saving credentials so gated ASC tabs rerun their initial load task
    // once the credential form disappears and the app lookup has completed.
    var credentialActivationRevision = 0

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
    var currentAppPricePointId: String?
    var scheduledAppPricePointId: String?
    var scheduledAppPriceEffectiveDate: String?

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
    var pendingCredentialValues: [String: String]?  // Pre-fill values for ASC credential form (from MCP)
    var pendingFormValues: [String: [String: String]] = [:]  // tab → field → value (for MCP pre-fill)
    var pendingFormVersion: Int = 0  // Incremented when pendingFormValues changes; views watch this
    var pendingCreateValues: [String: String]?  // Pre-fill values for IAP/subscription create forms (from MCP)
    var showSubmitPreview = false
    var isSubmitting = false
    var submissionError: String?
    var writeError: String?  // Inline error for write operations (does not replace tab content)

    // Review submission history (for rejection tracking)
    var reviewSubmissions: [ASCReviewSubmission] = []
    var reviewSubmissionItemsBySubmissionId: [String: [ASCReviewSubmissionItem]] = [:]
    var latestSubmissionItems: [ASCReviewSubmissionItem] = []
    var submissionHistoryEvents: [ASCSubmissionHistoryEvent] = []

    // Iris (Apple ID session) — rejection feedback from internal API
    enum IrisSessionState { case unknown, noSession, valid, expired }
    var irisSession: IrisSession?
    private(set) var irisService: IrisService?
    var irisSessionState: IrisSessionState = .unknown
    var isLoadingIrisFeedback = false
    var irisFeedbackError: String?
    var showAppleIDLogin = false
    private var pendingWebAuthContinuation: CheckedContinuation<IrisSession?, Never>?
    var attachedSubmissionItemIDs: Set<String> = []  // IAP/subscription IDs attached via iris API
    var resolutionCenterThreads: [IrisResolutionCenterThread] = []
    var rejectionMessages: [IrisResolutionCenterMessage] = []
    var rejectionReasons: [IrisReviewRejection] = []
    var cachedFeedback: IrisFeedbackCache?  // loaded from disk, survives session expiry

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

    // Screenshot track state per device type
    var trackSlots: [String: [TrackSlot?]] = [:]        // keyed by ascDisplayType, 10-element arrays
    var savedTrackState: [String: [TrackSlot?]] = [:]   // snapshot after last load/save
    var localScreenshotAssets: [LocalScreenshotAsset] = []
    var isSyncing = false

    /// Age rating is "configured" only if the enum fields have actual values (not nil).
    /// ASC returns the declaration object with nil fields by default — submitting with
    /// nil fields causes a 409.
    private var ageRatingIsConfigured: Bool {
        guard let ar = ageRatingDeclaration?.attributes else { return false }
        // Check that at least the required enum fields are non-nil
        return ar.alcoholTobaccoOrDrugUseOrReferences != nil
            && ar.violenceCartoonOrFantasy != nil
            && ar.violenceRealistic != nil
            && ar.sexualContentOrNudity != nil
            && ar.sexualContentGraphicAndNudity != nil
            && ar.profanityOrCrudeHumor != nil
            && ar.gamblingSimulated != nil
    }

    var submissionReadiness: SubmissionReadiness {
        let loc = localizations.first
        let info = appInfoLocalization
        let review = reviewDetail
        let demoRequired = review?.attributes.demoAccountRequired == true
        let version = appStoreVersions.first

        // Screenshot checks per display type — detect platform from available sets
        let macScreenshots = screenshotSets.first { $0.attributes.screenshotDisplayType == "APP_DESKTOP" }
        let isMacApp = macScreenshots != nil
        let iphoneScreenshots = screenshotSets.first { $0.attributes.screenshotDisplayType == "APP_IPHONE_67" }
        let ipadScreenshots = screenshotSets.first { $0.attributes.screenshotDisplayType == "APP_IPAD_PRO_3GEN_129" }

        // Privacy nutrition labels URL (manual action required)
        let privacyUrl: String? = app.map {
            "https://appstoreconnect.apple.com/apps/\($0.id)/distribution/privacy"
        }

        func readinessField(
            label: String,
            value: String?,
            required: Bool = true,
            actionUrl: String? = nil,
            hint: String? = nil
        ) -> SubmissionReadiness.FieldStatus {
            SubmissionReadiness.FieldStatus(
                label: label,
                value: value,
                isLoading: overviewReadinessLoadingFields.contains(label) && (value == nil || value?.isEmpty == true),
                required: required,
                actionUrl: actionUrl,
                hint: hint
            )
        }

        var fields: [SubmissionReadiness.FieldStatus] = [
            readinessField(label: "App Name", value: info?.attributes.name ?? loc?.attributes.title),
            readinessField(label: "Description", value: loc?.attributes.description),
            readinessField(label: "Keywords", value: loc?.attributes.keywords),
            readinessField(label: "Support URL", value: loc?.attributes.supportUrl),
            readinessField(label: "Privacy Policy URL", value: info?.attributes.privacyPolicyUrl),
            readinessField(label: "Copyright", value: version?.attributes.copyright),
            readinessField(label: "Content Rights", value: app?.contentRightsDeclaration),
            readinessField(label: "Primary Category", value: appInfo?.primaryCategoryId),
            readinessField(label: "Age Rating", value: ageRatingIsConfigured ? "Configured" : nil),
            readinessField(label: "Pricing", value: monetizationStatus),
            readinessField(label: "Review Contact First Name", value: review?.attributes.contactFirstName),
            readinessField(label: "Review Contact Last Name", value: review?.attributes.contactLastName),
            readinessField(label: "Review Contact Email", value: review?.attributes.contactEmail),
            readinessField(label: "Review Contact Phone", value: review?.attributes.contactPhone),
        ]

        // Conditional: demo credentials required when demoAccountRequired is set
        if demoRequired {
            fields.append(readinessField(label: "Demo Account Name", value: review?.attributes.demoAccountName))
            fields.append(readinessField(label: "Demo Account Password", value: review?.attributes.demoAccountPassword))
        }

        fields.append(readinessField(label: "App Icon", value: appIconStatus))

        // Count only non-failed screenshots for readiness
        func validCount(for set: ASCScreenshotSet?) -> Int {
            guard let set else { return 0 }
            if let shots = screenshots[set.id] {
                return shots.filter { !$0.hasError }.count
            }
            return set.attributes.screenshotCount ?? 0
        }

        if isMacApp {
            let macCount = validCount(for: macScreenshots)
            fields.append(readinessField(label: "Mac Screenshots", value: macCount > 0 ? "\(macCount) screenshot(s)" : nil))
        } else {
            let iphoneCount = validCount(for: iphoneScreenshots)
            let ipadCount = validCount(for: ipadScreenshots)
            fields.append(readinessField(label: "iPhone Screenshots", value: iphoneCount > 0 ? "\(iphoneCount) screenshot(s)" : nil))
            fields.append(readinessField(label: "iPad Screenshots", value: ipadCount > 0 ? "\(ipadCount) screenshot(s)" : nil))
        }

        fields.append(contentsOf: [
            readinessField(label: "Privacy Nutrition Labels", value: nil, required: false, actionUrl: privacyUrl),
            readinessField(label: "Build", value: builds.first?.attributes.version),
        ])

        // Conditional: first-time IAP/subscription attachment
        // Only shown when (a) IAPs or subscriptions exist in READY_TO_SUBMIT state
        // AND (b) no version has ever been approved (first-time submission)
        let approvedStates: Set<String> = ["READY_FOR_SALE", "REMOVED_FROM_SALE",
            "DEVELOPER_REMOVED_FROM_SALE", "REPLACED_WITH_NEW_VERSION", "PROCESSING_FOR_APP_STORE"]
        let hasApprovedVersion = appStoreVersions.contains {
            approvedStates.contains($0.attributes.appStoreState ?? "")
        }
        let isFirstVersion = !hasApprovedVersion
        if isFirstVersion {
            let readyIAPs = inAppPurchases.filter { $0.attributes.state == "READY_TO_SUBMIT" && !attachedSubmissionItemIDs.contains($0.id) }
            let readySubs = subscriptionsPerGroup.values.flatMap { $0 }
                .filter { $0.attributes.state == "READY_TO_SUBMIT" && !attachedSubmissionItemIDs.contains($0.id) }
            let readyCount = readyIAPs.count + readySubs.count
            if readyCount > 0 {
                let names = (readyIAPs.map { $0.attributes.name ?? $0.attributes.productId ?? $0.id }
                    + readySubs.map { $0.attributes.name ?? $0.attributes.productId ?? $0.id })
                    .joined(separator: ", ")
                let iapUrl: String? = app.map {
                    "https://appstoreconnect.apple.com/apps/\($0.id)/distribution/ios/version/inflight"
                }
                fields.append(readinessField(
                    label: "In-App Purchases & Subscriptions",
                    value: nil,
                    required: true,
                    actionUrl: iapUrl,
                    hint: "\(readyCount) item(s) in Ready to Submit state (\(names)) must be attached to this version before submission. "
                        + "Use the asc-iap-attach skill to attach them via the iris API (asc web session). "
                        + "The public API does not support first-time IAP/subscription attachment — "
                        + "run: asc web auth login, then POST to /iris/v1/subscriptionSubmissions or /iris/v1/inAppPurchaseSubmissions "
                        + "with submitWithNextAppStoreVersion:true for each item."
                ))
            }
        }

        return SubmissionReadiness(fields: fields)
    }

    // Per-tab loading / error
    var isLoadingTab: [AppTab: Bool] = [:]
    var tabError: [AppTab: String] = [:]
    private var loadedTabs: Set<AppTab> = []
    private var tabLoadedAt: [AppTab: Date] = [:]
    private var projectSnapshots: [String: ProjectSnapshot] = [:]
    private var tabHydrationTasks: [AppTab: Task<Void, Never>] = [:]
    private var overviewReadinessLoadingFields: Set<String> = []
    private var loadingFeedbackBuildIds: Set<String> = []

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

    private func refreshAppIconStatusIfNeeded(for projectId: String?) {
        guard let projectId, !projectId.isEmpty else { return }
        checkAppIcon(projectId: projectId)
    }

    private func cancelBackgroundHydration(for tab: AppTab) {
        tabHydrationTasks[tab]?.cancel()
        tabHydrationTasks.removeValue(forKey: tab)
    }

    private func cancelBackgroundHydrationTasks() {
        for task in tabHydrationTasks.values {
            task.cancel()
        }
        tabHydrationTasks.removeAll()
    }

    private func startBackgroundHydration(for tab: AppTab, operation: @escaping @MainActor () async -> Void) {
        cancelBackgroundHydration(for: tab)
        tabHydrationTasks[tab] = Task {
            await operation()
        }
    }

    private func resetProjectData(preserveCredentials: Bool) {
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
        currentAppPricePointId = nil
        scheduledAppPricePointId = nil
        scheduledAppPriceEffectiveDate = nil
        appInfo = nil
        appInfoLocalization = nil
        ageRatingDeclaration = nil
        reviewDetail = nil
        pendingFormValues = [:]
        showSubmitPreview = false
        isSubmitting = false
        submissionError = nil
        writeError = nil
        reviewSubmissions = []
        reviewSubmissionItemsBySubmissionId = [:]
        latestSubmissionItems = []
        submissionHistoryEvents = []
        appIconStatus = nil
        monetizationStatus = nil
        attachedSubmissionItemIDs = []
        isLoadingTab = [:]
        tabError = [:]
        loadedTabs = []
        tabLoadedAt = [:]
        if !preserveCredentials {
            loadedProjectId = nil
        }
        // Clear iris data but keep session (it's account-wide, not project-specific)
        resolutionCenterThreads = []
        rejectionMessages = []
        rejectionReasons = []
        cachedFeedback = nil
        isLoadingIrisFeedback = false
        irisFeedbackError = nil
        cancelPendingWebAuth()
    }

    private func cacheCurrentProjectSnapshot() {
        guard let projectId = loadedProjectId else { return }
        guard app != nil || !loadedTabs.isEmpty else { return }
        projectSnapshots[projectId] = ProjectSnapshot(manager: self, projectId: projectId)
    }

    private func startOverviewReadinessLoading(_ fields: Set<String>) {
        overviewReadinessLoadingFields = fields
    }

    private func finishOverviewReadinessLoading(_ fields: Set<String>) {
        overviewReadinessLoadingFields.subtract(fields)
    }

    private func shouldRefreshTabCache(_ tab: AppTab) -> Bool {
        guard loadedTabs.contains(tab) else { return true }
        guard let loadedAt = tabLoadedAt[tab] else { return true }
        return Date().timeIntervalSince(loadedAt) > Self.projectCacheFreshness
    }

    private func isCurrentProject(_ projectId: String?) -> Bool {
        guard let projectId else { return false }
        return loadedProjectId == projectId
    }

    func prepareForProjectSwitch(to projectId: String) {
        cacheCurrentProjectSnapshot()
        resetProjectData(preserveCredentials: true)

        if let snapshot = projectSnapshots[projectId] {
            snapshot.apply(to: self)
        } else {
            loadedProjectId = projectId
        }
    }

    func loadStoredCredentialsIfNeeded() {
        guard credentials == nil || service == nil else { return }
        let creds = ASCCredentials.load()
        try? ASCAuthBridge().syncCredentials(creds)
        credentials = creds
        if let creds {
            service = AppStoreConnectService(credentials: creds)
        } else {
            service = nil
        }
    }

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

    // MARK: - Project Lifecycle

    func loadCredentials(for projectId: String, bundleId: String?) async {
        let needsCredentialReload = credentials == nil || service == nil
        let shouldSkip = loadedProjectId == projectId
            && !needsCredentialReload
            && (bundleId == nil || app != nil)
        guard !shouldSkip else { return }

        credentialsError = nil

        if needsCredentialReload {
            isLoadingCredentials = true
            let creds = ASCCredentials.load()
            try? ASCAuthBridge().syncCredentials(creds)
            credentials = creds
            isLoadingCredentials = false

            if let creds {
                service = AppStoreConnectService(credentials: creds)
            }
        }

        loadedProjectId = projectId
        refreshAppIconStatusIfNeeded(for: projectId)

        if let bundleId, !bundleId.isEmpty, credentials != nil, app == nil {
            await fetchApp(bundleId: bundleId)
        }
    }

    func clearForProjectSwitch() {
        resetProjectData(preserveCredentials: false)
    }

    // MARK: - Iris Session (Apple ID auth for rejection feedback)

    private func irisLog(_ msg: String) {
        let logPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".blitz/iris-debug.log")
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(msg)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath.path) {
                if let handle = try? FileHandle(forWritingTo: logPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                let dir = logPath.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? data.write(to: logPath)
            }
        }
    }

    func loadIrisSession() {
        irisLog("ASCManager.loadIrisSession: starting")
        guard let loaded = IrisSession.load() else {
            irisLog("ASCManager.loadIrisSession: no session file found")
            irisSessionState = .noSession
            irisSession = nil
            irisService = nil
            return
        }
        // No time-based expiry — we trust the session until a 401 proves otherwise
        irisLog("ASCManager.loadIrisSession: loaded session with \(loaded.cookies.count) cookies, capturedAt=\(loaded.capturedAt)")
        do {
            try Self.storeWebSessionToKeychain(loaded)
        } catch {
            irisLog("ASCManager.loadIrisSession: asc-web-session backfill FAILED: \(error)")
        }
        irisSession = loaded
        irisService = IrisService(session: loaded)
        irisSessionState = .valid
        irisLog("ASCManager.loadIrisSession: session valid, irisService created")
    }

    func requestWebAuthForMCP() async -> IrisSession? {
        pendingWebAuthContinuation?.resume(returning: nil)
        irisFeedbackError = nil
        showAppleIDLogin = true
        return await withCheckedContinuation { continuation in
            pendingWebAuthContinuation = continuation
        }
    }

    func cancelPendingWebAuth() {
        showAppleIDLogin = false
        pendingWebAuthContinuation?.resume(returning: nil)
        pendingWebAuthContinuation = nil
    }

    func setIrisSession(_ session: IrisSession) {
        irisLog("ASCManager.setIrisSession: \(session.cookies.count) cookies")
        do {
            try session.save()
            irisLog("ASCManager.setIrisSession: saved to native keychain")
        } catch {
            irisLog("ASCManager.setIrisSession: save FAILED: \(error)")
            irisFeedbackError = "Failed to save session: \(error.localizedDescription)"
            showAppleIDLogin = false
            pendingWebAuthContinuation?.resume(returning: nil)
            pendingWebAuthContinuation = nil
            return
        }

        // Also write the asc-web-session keychain item used by CLI skill scripts.
        // If that write fails during an MCP-triggered login, keep the native session
        // but fail the MCP request instead of reporting a false success.
        do {
            try Self.storeWebSessionToKeychain(session)
        } catch {
            irisLog("ASCManager.setIrisSession: asc-web-session save FAILED: \(error)")
            irisFeedbackError = "Failed to save ASC web session: \(error.localizedDescription)"
            if let continuation = pendingWebAuthContinuation {
                pendingWebAuthContinuation = nil
                continuation.resume(returning: nil)
            }
        }

        irisSession = session
        irisService = IrisService(session: session)
        irisSessionState = .valid
        irisLog("ASCManager.setIrisSession: state set to .valid")
        showAppleIDLogin = false

        // Notify MCP tool if it triggered this login
        if let continuation = pendingWebAuthContinuation {
            pendingWebAuthContinuation = nil
            continuation.resume(returning: session)
        }
    }

    func clearIrisSession() {
        irisLog("ASCManager.clearIrisSession")
        let currentSession = irisSession
        IrisSession.delete()
        Self.deleteWebSessionFromKeychain(email: currentSession?.email)
        irisSession = nil
        irisService = nil
        irisSessionState = .noSession
        resolutionCenterThreads = []
        rejectionMessages = []
        rejectionReasons = []
        if let appId = app?.id {
            rebuildSubmissionHistory(appId: appId)
        }
    }

    // MARK: - Unified Web Session Keychain (for CLI skill scripts)

    private static let webSessionService = ASCWebSessionStore.keychainService
    private static let webSessionAccount = ASCWebSessionStore.keychainAccount

    /// Write session cookies in the format expected by CLI skill scripts
    /// (readable via `security find-generic-password -s "asc-web-session" -w`).
    private static func storeWebSessionToKeychain(_ session: IrisSession) throws {
        let existingData = readKeychainItem(service: webSessionService, account: webSessionAccount)
        let data = try ASCWebSessionStore.mergedData(storing: session, into: existingData)
        removeWebSessionKeychainItem()
        try writeWebSessionToKeychain(data)
    }

    private static func writeWebSessionToKeychain(_ data: Data) throws {
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: webSessionService,
            kSecAttrAccount as String: webSessionAccount,
            kSecAttrLabel as String: "ASC Web Session Store",
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(
                domain: "ASCWebSessionStore",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Keychain write failed (status: \(status))"]
            )
        }
    }

    private static func deleteWebSessionFromKeychain(email: String?) {
        let existingData = readKeychainItem(service: webSessionService, account: webSessionAccount)
        let updatedData: Data?
        do {
            updatedData = try ASCWebSessionStore.removingSession(email: email, from: existingData)
        } catch {
            return
        }

        if let updatedData = updatedData {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: webSessionService,
                kSecAttrAccount as String: webSessionAccount,
            ]
            let status = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: updatedData] as CFDictionary
            )
            if status == errSecItemNotFound {
                try? writeWebSessionToKeychain(updatedData)
            }
            return
        }

        removeWebSessionKeychainItem()
    }

    private static func removeWebSessionKeychainItem() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: webSessionService,
            kSecAttrAccount as String: webSessionAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Loads cached feedback from disk for the given rejected version. No auth needed.
    func loadCachedFeedback(appId: String, versionString: String) {
        irisLog("ASCManager.loadCachedFeedback: appId=\(appId) version=\(versionString)")
        if let cached = IrisFeedbackCache.load(appId: appId, versionString: versionString) {
            cachedFeedback = cached
            irisLog("ASCManager.loadCachedFeedback: loaded \(cached.reasons.count) reasons, \(cached.messages.count) messages, fetched \(cached.fetchedAt)")
        } else {
            irisLog("ASCManager.loadCachedFeedback: no cache found")
            cachedFeedback = nil
        }
        rebuildSubmissionHistory(appId: appId)
    }

    func fetchRejectionFeedback() async {
        irisLog("ASCManager.fetchRejectionFeedback: irisService=\(irisService != nil), appId=\(app?.id ?? "nil")")
        guard let irisService, let appId = app?.id else {
            irisLog("ASCManager.fetchRejectionFeedback: guard failed, returning")
            return
        }

        // Determine version string for cache
        let rejectedVersion = appStoreVersions.first(where: {
            $0.attributes.appStoreState == "REJECTED"
        })?.attributes.versionString

        isLoadingIrisFeedback = true
        irisFeedbackError = nil

        do {
            let threads = try await irisService.fetchResolutionCenterThreads(appId: appId)
            irisLog("ASCManager.fetchRejectionFeedback: got \(threads.count) threads")
            resolutionCenterThreads = threads

            if let latestThread = threads.first {
                irisLog("ASCManager.fetchRejectionFeedback: fetching messages+rejections for thread \(latestThread.id)")
                let result = try await irisService.fetchMessagesAndRejections(threadId: latestThread.id)
                rejectionMessages = result.messages
                rejectionReasons = result.rejections
                irisLog("ASCManager.fetchRejectionFeedback: got \(rejectionMessages.count) messages, \(rejectionReasons.count) rejections")

                // Write cache
                if let version = rejectedVersion {
                    let cache = buildFeedbackCache(appId: appId, versionString: version)
                    do {
                        try cache.save()
                        cachedFeedback = cache
                        irisLog("ASCManager.fetchRejectionFeedback: cache saved for \(version)")
                    } catch {
                        irisLog("ASCManager.fetchRejectionFeedback: cache save failed: \(error)")
                    }
                }
            } else {
                irisLog("ASCManager.fetchRejectionFeedback: no threads found")
                rejectionMessages = []
                rejectionReasons = []
            }
        } catch let error as IrisError {
            irisLog("ASCManager.fetchRejectionFeedback: IrisError: \(error)")
            if case .sessionExpired = error {
                irisSessionState = .expired
                irisSession = nil
                self.irisService = nil
            } else {
                irisFeedbackError = error.localizedDescription
            }
        } catch {
            irisLog("ASCManager.fetchRejectionFeedback: error: \(error)")
            irisFeedbackError = error.localizedDescription
        }

        isLoadingIrisFeedback = false
        rebuildSubmissionHistory(appId: appId)
        irisLog("ASCManager.fetchRejectionFeedback: done")
    }

    /// Builds a cache object from current in-memory rejection data.
    private func buildFeedbackCache(appId: String, versionString: String) -> IrisFeedbackCache {
        let msgs = rejectionMessages.map { msg in
            IrisFeedbackCache.CachedMessage(
                body: msg.attributes.messageBody.map { htmlToPlainText($0) } ?? "",
                date: msg.attributes.createdDate
            )
        }
        let reasons = rejectionReasons.flatMap { rejection in
            (rejection.attributes.reasons ?? []).map { r in
                IrisFeedbackCache.CachedReason(
                    section: r.reasonSection ?? "",
                    description: r.reasonDescription ?? "",
                    code: r.reasonCode ?? ""
                )
            }
        }
        return IrisFeedbackCache(
            appId: appId,
            versionString: versionString,
            fetchedAt: Date(),
            messages: msgs,
            reasons: reasons
        )
    }

    private func refreshReviewSubmissionData(appId: String, service: AppStoreConnectService) async {
        let submissions = (try? await service.fetchReviewSubmissions(appId: appId)) ?? []
        reviewSubmissions = submissions

        guard !submissions.isEmpty else {
            reviewSubmissionItemsBySubmissionId = [:]
            latestSubmissionItems = []
            return
        }

        var itemsBySubmissionId: [String: [ASCReviewSubmissionItem]] = [:]
        await withTaskGroup(of: (String, [ASCReviewSubmissionItem]).self) { group in
            for submission in submissions {
                group.addTask {
                    let items = (try? await service.fetchReviewSubmissionItems(submissionId: submission.id)) ?? []
                    return (submission.id, items)
                }
            }

            for await (submissionId, items) in group {
                itemsBySubmissionId[submissionId] = items
            }
        }

        reviewSubmissionItemsBySubmissionId = itemsBySubmissionId
        latestSubmissionItems = itemsBySubmissionId[submissions.first?.id ?? ""] ?? []
    }

    private func historyNowString() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private func historyDate(_ iso: String?) -> Date {
        guard let iso else { return .distantPast }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let f2 = ISO8601DateFormatter()
        return f1.date(from: iso) ?? f2.date(from: iso) ?? .distantPast
    }

    private func historyEventType(forVersionState state: String) -> ASCSubmissionHistoryEventType? {
        ASCReleaseStatus.submissionHistoryEventType(forVersionState: state)
    }

    private func historyCoverageKey(
        versionId: String?,
        versionString: String,
        eventType: ASCSubmissionHistoryEventType
    ) -> String {
        "\(versionId ?? "version:\(versionString)")::\(eventType.rawValue)"
    }

    private func versionString(
        for versionId: String?,
        versionSnapshots: [String: ASCSubmissionHistoryCache.VersionSnapshot]
    ) -> String? {
        guard let versionId else { return nil }
        if let version = appStoreVersions.first(where: { $0.id == versionId }) {
            return version.attributes.versionString
        }
        return versionSnapshots[versionId]?.versionString
    }

    private func versionId(
        for versionString: String,
        versionSnapshots: [String: ASCSubmissionHistoryCache.VersionSnapshot]
    ) -> String? {
        if let version = appStoreVersions.first(where: { $0.attributes.versionString == versionString }) {
            return version.id
        }
        return versionSnapshots.values.first(where: { $0.versionString == versionString })?.versionId
    }

    private func versionState(
        for versionId: String?,
        versionSnapshots: [String: ASCSubmissionHistoryCache.VersionSnapshot]
    ) -> String? {
        guard let versionId else { return nil }
        if let version = appStoreVersions.first(where: { $0.id == versionId }) {
            return version.attributes.appStoreState
        }
        return versionSnapshots[versionId]?.lastKnownState
    }

    private func refreshSubmissionHistoryCache(appId: String) -> ASCSubmissionHistoryCache {
        var cache = ASCSubmissionHistoryCache.load(appId: appId)
        let now = historyNowString()

        for version in appStoreVersions {
            let state = version.attributes.appStoreState ?? ""
            guard !state.isEmpty else { continue }

            if var snapshot = cache.versionSnapshots[version.id] {
                snapshot.versionString = version.attributes.versionString
                if snapshot.lastKnownState != state,
                   let eventType = historyEventType(forVersionState: state) {
                    cache.transitionEvents.append(
                        ASCSubmissionHistoryEvent(
                            id: "ledger:\(version.id):\(state):\(now)",
                            versionId: version.id,
                            versionString: version.attributes.versionString,
                            eventType: eventType,
                            appleState: state,
                            occurredAt: now,
                            source: .transitionLedger,
                            accuracy: .firstSeen,
                            submissionId: nil,
                            note: nil
                        )
                    )
                    snapshot.lastKnownState = state
                    snapshot.lastSeenAt = now
                } else {
                    snapshot.lastSeenAt = now
                }
                cache.versionSnapshots[version.id] = snapshot
            } else {
                cache.versionSnapshots[version.id] = .init(
                    versionId: version.id,
                    versionString: version.attributes.versionString,
                    lastKnownState: state,
                    lastSeenAt: now
                )
            }
        }

        cache.transitionEvents.sort { historyDate($0.occurredAt) > historyDate($1.occurredAt) }
        try? cache.save()
        return cache
    }

    private func rebuildSubmissionHistory(appId: String) {
        let cache = refreshSubmissionHistoryCache(appId: appId)
        let versionSnapshots = cache.versionSnapshots

        let submissionEvents = reviewSubmissions.compactMap { submission -> ASCSubmissionHistoryEvent? in
            guard let submittedAt = submission.attributes.submittedDate else { return nil }
            let versionId = reviewSubmissionItemsBySubmissionId[submission.id]?
                .compactMap(\.appStoreVersionId)
                .first
            let versionString = versionString(for: versionId, versionSnapshots: versionSnapshots) ?? "Unknown"
            let versionState = versionState(for: versionId, versionSnapshots: versionSnapshots)
            let eventType = ASCReleaseStatus.reviewSubmissionEventType(forVersionState: versionState)
            return ASCSubmissionHistoryEvent(
                id: "submission:\(submission.id)",
                versionId: versionId,
                versionString: versionString,
                eventType: eventType,
                appleState: versionState ?? "WAITING_FOR_REVIEW",
                occurredAt: submittedAt,
                source: .reviewSubmission,
                accuracy: .exact,
                submissionId: submission.id,
                note: nil
            )
        }

        var rejectionEventsByVersion: [String: ASCSubmissionHistoryEvent] = [:]
        for cacheEntry in IrisFeedbackCache.loadAll(appId: appId) {
            let rejectionAt = cacheEntry.messages
                .compactMap(\.date)
                .sorted(by: { historyDate($0) < historyDate($1) })
                .first
                ?? ISO8601DateFormatter().string(from: cacheEntry.fetchedAt)

            rejectionEventsByVersion[cacheEntry.versionString] = ASCSubmissionHistoryEvent(
                id: "iris:\(cacheEntry.versionString):\(rejectionAt)",
                versionId: versionId(for: cacheEntry.versionString, versionSnapshots: versionSnapshots),
                versionString: cacheEntry.versionString,
                eventType: .rejected,
                appleState: "REJECTED",
                occurredAt: rejectionAt,
                source: .irisFeedback,
                accuracy: .derived,
                submissionId: nil,
                note: cacheEntry.reasons.first?.section
            )
        }

        if let rejectedVersion = appStoreVersions.first(where: { $0.attributes.appStoreState == "REJECTED" }) {
            let rejectionAt = resolutionCenterThreads.first?.attributes.createdDate
                ?? rejectionMessages.compactMap(\.attributes.createdDate)
                    .sorted(by: { historyDate($0) < historyDate($1) })
                    .first
            if let rejectionAt {
                rejectionEventsByVersion[rejectedVersion.attributes.versionString] = ASCSubmissionHistoryEvent(
                    id: "iris-live:\(rejectedVersion.id):\(rejectionAt)",
                    versionId: rejectedVersion.id,
                    versionString: rejectedVersion.attributes.versionString,
                    eventType: .rejected,
                    appleState: "REJECTED",
                    occurredAt: rejectionAt,
                    source: .irisFeedback,
                    accuracy: .derived,
                    submissionId: nil,
                    note: rejectionReasons.first?.attributes.reasons?.first?.reasonSection
                )
            }
        }

        let durableEvents = submissionEvents
            + Array(rejectionEventsByVersion.values)
            + cache.transitionEvents

        let coveredEventKeys = Set(
            durableEvents.map {
                historyCoverageKey(versionId: $0.versionId, versionString: $0.versionString, eventType: $0.eventType)
            }
        )

        let fallbackEvents = appStoreVersions.compactMap { version -> ASCSubmissionHistoryEvent? in
            let state = version.attributes.appStoreState ?? ""
            guard let eventType = historyEventType(forVersionState: state) else { return nil }

            let coverageKey = historyCoverageKey(
                versionId: version.id,
                versionString: version.attributes.versionString,
                eventType: eventType
            )
            guard !coveredEventKeys.contains(coverageKey) else { return nil }

            let occurredAt = version.attributes.createdDate
                ?? cache.versionSnapshots[version.id]?.lastSeenAt
                ?? historyNowString()

            return ASCSubmissionHistoryEvent(
                id: "version:\(version.id):\(state)",
                versionId: version.id,
                versionString: version.attributes.versionString,
                eventType: eventType,
                appleState: state,
                occurredAt: occurredAt,
                source: .currentVersion,
                accuracy: .derived,
                submissionId: nil,
                note: nil
            )
        }

        submissionHistoryEvents = (durableEvents + fallbackEvents)
            .sorted { lhs, rhs in
                historyDate(lhs.occurredAt) > historyDate(rhs.occurredAt)
            }
    }

    func refreshSubmissionFeedbackIfNeeded() {
        guard let appId = app?.id else { return }

        let rejectedVersion = appStoreVersions.first(where: {
            $0.attributes.appStoreState == "REJECTED"
        })
        let pendingVersion = appStoreVersions.first(where: {
            let state = $0.attributes.appStoreState ?? ""
            return state != "READY_FOR_SALE" && state != "REMOVED_FROM_SALE"
                && state != "DEVELOPER_REMOVED_FROM_SALE" && !state.isEmpty
        })

        guard let version = rejectedVersion ?? pendingVersion else {
            cachedFeedback = nil
            rebuildSubmissionHistory(appId: appId)
            return
        }

        loadCachedFeedback(appId: appId, versionString: version.attributes.versionString)
        loadIrisSession()
        if irisSessionState == .valid {
            Task { await fetchRejectionFeedback() }
        }
    }

    func saveCredentials(_ creds: ASCCredentials, projectId: String, bundleId: String?) async throws {
        try creds.save()
        credentials = creds
        service = AppStoreConnectService(credentials: creds)
        credentialsError = nil
        cancelBackgroundHydrationTasks()
        loadedTabs = []  // force re-fetch after new credentials
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
        let pid = loadedProjectId
        clearForProjectSwitch()
        loadedProjectId = pid  // keep project id so gate re-checks correctly
    }

    // MARK: - App Fetch

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

    // MARK: - Tab Data

    func fetchTabData(_ tab: AppTab) async {
        guard let service else { return }
        guard credentials != nil else { return }
        guard !loadedTabs.contains(tab) else { return }
        guard isLoadingTab[tab] != true else { return }

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
        }
    }

    func refreshSubmissionReadinessData() async {
        await refreshMonetization()
        await refreshAttachedSubmissionItemIDs()
    }

    func refreshBetaFeedback(buildId: String) async {
        guard let service else { return }
        guard !buildId.isEmpty else { return }

        loadingFeedbackBuildIds.insert(buildId)
        defer { loadingFeedbackBuildIds.remove(buildId) }

        do {
            betaFeedback[buildId] = try await service.fetchBetaFeedback(buildId: buildId)
        } catch {
            // Feedback may not be available for all apps; non-fatal.
            betaFeedback[buildId] = []
        }
    }

    private func hydrateOverviewSecondaryData(
        projectId: String?,
        appId: String,
        firstLocalizationId: String?,
        appInfoId: String?,
        service: AppStoreConnectService
    ) async {
        if let firstLocalizationId {
            do {
                let fetchedSets = try await service.fetchScreenshotSets(localizationId: firstLocalizationId)
                guard !Task.isCancelled, isCurrentProject(projectId) else { return }
                screenshotSets = fetchedSets

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
                screenshots = Dictionary(uniqueKeysWithValues: fetchedScreenshots)
                finishOverviewReadinessLoading(Self.overviewScreenshotFieldLabels)
            } catch {
                print("Failed to hydrate overview screenshots: \(error)")
                finishOverviewReadinessLoading(Self.overviewScreenshotFieldLabels)
            }
        } else {
            finishOverviewReadinessLoading(Self.overviewScreenshotFieldLabels)
        }

        if let appInfoId {
            async let ageRatingTask: ASCAgeRatingDeclaration? = try? service.fetchAgeRating(appInfoId: appInfoId)
            async let appInfoLocalizationTask: ASCAppInfoLocalization? = try? service.fetchAppInfoLocalization(appInfoId: appInfoId)

            let fetchedAgeRating = await ageRatingTask
            let fetchedAppInfoLocalization = await appInfoLocalizationTask

            guard !Task.isCancelled, isCurrentProject(projectId) else { return }
            ageRatingDeclaration = fetchedAgeRating
            appInfoLocalization = fetchedAppInfoLocalization
            finishOverviewReadinessLoading(Self.overviewMetadataFieldLabels)
        } else {
            finishOverviewReadinessLoading(Self.overviewMetadataFieldLabels)
        }

        guard !Task.isCancelled, isCurrentProject(projectId) else { return }
        await refreshReviewSubmissionData(appId: appId, service: service)
        guard !Task.isCancelled, isCurrentProject(projectId) else { return }
        rebuildSubmissionHistory(appId: appId)
        refreshSubmissionFeedbackIfNeeded()

        if monetizationStatus == nil {
            let hasPricing = await service.fetchPricingConfigured(appId: appId)
            guard !Task.isCancelled, isCurrentProject(projectId) else { return }
            monetizationStatus = hasPricing ? "Configured" : nil
        }

        guard !Task.isCancelled, isCurrentProject(projectId) else { return }
        await refreshSubmissionReadinessData()
        finishOverviewReadinessLoading(Self.overviewPricingFieldLabels)
    }

    private func hydrateScreenshotsSecondaryData(
        projectId: String?,
        localizationId: String,
        service: AppStoreConnectService
    ) async {
        do {
            let fetchedSets = try await service.fetchScreenshotSets(localizationId: localizationId)
            guard !Task.isCancelled, isCurrentProject(projectId) else { return }
            screenshotSets = fetchedSets

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
            screenshots = Dictionary(uniqueKeysWithValues: fetchedScreenshots)
        } catch {
            print("Failed to hydrate screenshots: \(error)")
        }
    }

    private func hydrateReviewSecondaryData(
        projectId: String?,
        appId: String,
        appInfoId: String?,
        service: AppStoreConnectService
    ) async {
        if let appInfoId {
            let fetchedAgeRating = try? await service.fetchAgeRating(appInfoId: appInfoId)
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
            let hasPricing = await service.fetchPricingConfigured(appId: appId)
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
            throw ASCError.notFound("App — check your bundle ID in project settings")
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
            async let appInfoTask: ASCAppInfo? = try? service.fetchAppInfo(appId: appId)
            async let buildsTask = service.fetchBuilds(appId: appId)

            let versions = try await versionsTask
            appStoreVersions = versions
            finishOverviewReadinessLoading(Self.overviewVersionFieldLabels)
            appInfo = await appInfoTask
            finishOverviewReadinessLoading(Self.overviewAppInfoFieldLabels)
            builds = try await buildsTask
            finishOverviewReadinessLoading(Self.overviewBuildFieldLabels)

            var firstLocalizationId: String?
            if let latestId = versions.first?.id {
                async let localizationsTask = service.fetchLocalizations(versionId: latestId)
                async let reviewDetailTask: ASCReviewDetail? = try? service.fetchReviewDetail(versionId: latestId)

                let fetchedLocalizations = try await localizationsTask
                localizations = fetchedLocalizations
                firstLocalizationId = fetchedLocalizations.first?.id
                finishOverviewReadinessLoading(Self.overviewLocalizationFieldLabels)
                reviewDetail = await reviewDetailTask
                finishOverviewReadinessLoading(Self.overviewReviewFieldLabels)
            } else {
                finishOverviewReadinessLoading(
                    Self.overviewLocalizationFieldLabels
                        .union(Self.overviewReviewFieldLabels)
                )
            }

            refreshSubmissionFeedbackIfNeeded()

            let projectId = loadedProjectId
            let currentAppInfoId = appInfo?.id
            startBackgroundHydration(for: .app) {
                await self.hydrateOverviewSecondaryData(
                    projectId: projectId,
                    appId: appId,
                    firstLocalizationId: firstLocalizationId,
                    appInfoId: currentAppInfoId,
                    service: service
                )
            }

        case .storeListing:
            async let versionsTask = service.fetchAppStoreVersions(appId: appId)
            async let appInfoTask: ASCAppInfo? = try? await service.fetchAppInfo(appId: appId)

            let versions = try await versionsTask
            appStoreVersions = versions
            if let latestId = versions.first?.id {
                localizations = try await service.fetchLocalizations(versionId: latestId)
            } else {
                localizations = []
            }
            appInfo = await appInfoTask
            if let infoId = appInfo?.id {
                appInfoLocalization = try? await service.fetchAppInfoLocalization(appInfoId: infoId)
            } else {
                appInfoLocalization = nil
            }

        case .screenshots:
            let versions = try await service.fetchAppStoreVersions(appId: appId)
            appStoreVersions = versions
            if let latestId = versions.first?.id {
                let locs = try await service.fetchLocalizations(versionId: latestId)
                localizations = locs
                if let firstLocId = locs.first?.id {
                    let projectId = loadedProjectId
                    startBackgroundHydration(for: .screenshots) {
                        await self.hydrateScreenshotsSecondaryData(
                            projectId: projectId,
                            localizationId: firstLocId,
                            service: service
                        )
                    }
                } else {
                    screenshotSets = []
                    screenshots = [:]
                }
            } else {
                localizations = []
                screenshotSets = []
                screenshots = [:]
            }

        case .appDetails:
            async let versionsTask = service.fetchAppStoreVersions(appId: appId)
            async let appInfoTask: ASCAppInfo? = try? await service.fetchAppInfo(appId: appId)

            appStoreVersions = try await versionsTask
            appInfo = await appInfoTask

        case .review:
            async let versionsTask = service.fetchAppStoreVersions(appId: appId)
            async let appInfoTask: ASCAppInfo? = try? await service.fetchAppInfo(appId: appId)
            async let buildsTask = service.fetchBuilds(appId: appId)

            let versions = try await versionsTask
            appStoreVersions = versions
            if let latestId = versions.first?.id {
                reviewDetail = try? await service.fetchReviewDetail(versionId: latestId)
            } else {
                reviewDetail = nil
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
            async let pricingStateTask = (try? await service.fetchAppPricingState(appId: appId))
                ?? ASCAppPricingState(currentPricePointId: nil, scheduledPricePointId: nil, scheduledEffectiveDate: nil)
            async let iapTask = service.fetchInAppPurchases(appId: appId)
            async let groupsTask = service.fetchSubscriptionGroups(appId: appId)

            appPricePoints = try await pricePointsTask
            applyAppPricingState(await pricingStateTask)
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
            let resolvedBuildId: String?
            if let currentSelectedBuildId = selectedBuildId,
               fetched.contains(where: { $0.id == currentSelectedBuildId }) {
                resolvedBuildId = currentSelectedBuildId
            } else {
                resolvedBuildId = fetched.first?.id
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
                // Re-fetch versions so submissionReadiness picks up the new copyright
                if let appId = app?.id {
                    appStoreVersions = try await service.fetchAppStoreVersions(appId: appId)
                }
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
            try await service.ensureAppAvailability(appId: appId)
            currentAppPricePointId = pricePointId
            scheduledAppPricePointId = nil
            scheduledAppPriceEffectiveDate = nil
            monetizationStatus = isFreePricePoint(pricePointId) ? "Free" : "Configured"
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
            self.currentAppPricePointId = currentPricePointId
            scheduledAppPricePointId = futurePricePointId
            scheduledAppPriceEffectiveDate = effectiveDate
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

    func refreshAttachedSubmissionItemIDs() async {
        guard let appId = app?.id else {
            attachedSubmissionItemIDs = []
            return
        }
        guard let cookieHeader = ascWebSessionCookieHeader() else {
            attachedSubmissionItemIDs = []
            return
        }

        let subscriptionURL = "https://appstoreconnect.apple.com/iris/v1/apps/\(appId)/subscriptionGroups?include=subscriptions&limit=300&fields%5Bsubscriptions%5D=productId,name,state,submitWithNextAppStoreVersion"
        let iapURL = "https://appstoreconnect.apple.com/iris/v1/apps/\(appId)/inAppPurchasesV2?limit=300&fields%5BinAppPurchases%5D=productId,name,state,submitWithNextAppStoreVersion"

        let attachedSubscriptions = await fetchAttachedSubmissionItemIDs(urlString: subscriptionURL, cookieHeader: cookieHeader)
        let attachedIAPs = await fetchAttachedSubmissionItemIDs(urlString: iapURL, cookieHeader: cookieHeader)
        attachedSubmissionItemIDs = attachedSubscriptions.union(attachedIAPs)
    }

    private func fetchAttachedSubmissionItemIDs(urlString: String, cookieHeader: String) async -> Set<String> {
        guard let url = URL(string: urlString) else { return [] }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("https://appstoreconnect.apple.com", forHTTPHeaderField: "Origin")
        request.setValue("https://appstoreconnect.apple.com/", forHTTPHeaderField: "Referer")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.timeoutInterval = 10

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        let resources = (json["data"] as? [[String: Any]] ?? [])
            + (json["included"] as? [[String: Any]] ?? [])

        return Set(resources.compactMap { item in
            guard let attrs = item["attributes"] as? [String: Any],
                  let id = item["id"] as? String,
                  let submitWithNext = attrs["submitWithNextAppStoreVersion"] as? Bool,
                  submitWithNext else { return nil }
            return id
        })
    }

    private func ascWebSessionCookieHeader() -> String? {
        guard let storeData = Self.readKeychainItem(service: "asc-web-session", account: "asc:web-session:store"),
              let store = try? JSONSerialization.jsonObject(with: storeData) as? [String: Any],
              let lastKey = store["last_key"] as? String,
              let sessions = store["sessions"] as? [String: Any],
              let sessionDict = sessions[lastKey] as? [String: Any],
              let cookies = sessionDict["cookies"] as? [String: [[String: Any]]] else {
            return nil
        }

        let cookieHeader = cookies.values.flatMap { $0 }.compactMap { cookie -> String? in
            guard let name = cookie["name"] as? String,
                  let value = cookie["value"] as? String,
                  !name.isEmpty else { return nil }
            return name.hasPrefix("DES") ? "\(name)=\"\(value)\"" : "\(name)=\(value)"
        }.joined(separator: "; ")

        return cookieHeader.isEmpty ? nil : cookieHeader
    }

    private static func readKeychainItem(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    func setPriceFree() async {
        guard let service else { return }
        guard let appId = app?.id else { return }
        writeError = nil
        do {
            try await service.setPriceFree(appId: appId)
            try await service.ensureAppAvailability(appId: appId)
            currentAppPricePointId = freeAppPricePointId
            scheduledAppPricePointId = nil
            scheduledAppPriceEffectiveDate = nil
            monetizationStatus = "Free"
        } catch {
            writeError = error.localizedDescription
        }
    }

    var freeAppPricePointId: String? {
        appPricePoints.first(where: {
            let price = $0.attributes.customerPrice ?? "0"
            return price == "0" || price == "0.0" || price == "0.00"
        })?.id
    }

    func applyAppPricingState(_ state: ASCAppPricingState) {
        currentAppPricePointId = state.currentPricePointId
        scheduledAppPricePointId = state.scheduledPricePointId
        scheduledAppPriceEffectiveDate = state.scheduledEffectiveDate

        if let currentPricePointId = currentAppPricePointId {
            let isCurrentlyFree = isFreePricePoint(currentPricePointId)
            monetizationStatus = (isCurrentlyFree && state.scheduledPricePointId == nil) ? "Free" : "Configured"
        } else if state.scheduledPricePointId != nil {
            monetizationStatus = "Configured"
        } else {
            monetizationStatus = nil
        }
    }

    func isFreePricePoint(_ pricePointId: String) -> Bool {
        appPricePoints.contains(where: {
            guard $0.id == pricePointId else { return false }
            let price = $0.attributes.customerPrice ?? "0"
            return price == "0" || price == "0.0" || price == "0.00"
        })
    }

    // MARK: - Screenshot Track

    func hasUnsavedChanges(displayType: String) -> Bool {
        let current = trackSlots[displayType] ?? Array(repeating: nil, count: 10)
        let saved = savedTrackState[displayType] ?? Array(repeating: nil, count: 10)
        return zip(current, saved).contains { c, s in c?.id != s?.id }
    }

    func loadTrackFromASC(displayType: String) {
        let previousSlots = trackSlots[displayType] ?? []
        let set = screenshotSets.first { $0.attributes.screenshotDisplayType == displayType }
        var slots: [TrackSlot?] = Array(repeating: nil, count: 10)
        if let set, let shots = screenshots[set.id] {
            for (i, shot) in shots.prefix(10).enumerated() {
                // If ASC hasn't processed the image yet, carry forward the local preview
                var localImage: NSImage? = nil
                if shot.imageURL == nil, i < previousSlots.count, let prev = previousSlots[i] {
                    localImage = prev.localImage
                }
                slots[i] = TrackSlot(
                    id: shot.id,
                    localPath: nil,
                    localImage: localImage,
                    ascScreenshot: shot,
                    isFromASC: true
                )
            }
        }
        trackSlots[displayType] = slots
        savedTrackState[displayType] = slots
    }

    func syncTrackToASC(displayType: String, locale: String) async {
        guard let service else { writeError = "ASC service not configured"; return }
        isSyncing = true
        writeError = nil

        // Ensure localizations are loaded
        if localizations.isEmpty, let versionId = appStoreVersions.first?.id {
            localizations = (try? await service.fetchLocalizations(versionId: versionId)) ?? []
        }
        if localizations.isEmpty, let appId = app?.id {
            let versions = (try? await service.fetchAppStoreVersions(appId: appId)) ?? []
            appStoreVersions = versions
            if let versionId = versions.first?.id {
                localizations = (try? await service.fetchLocalizations(versionId: versionId)) ?? []
            }
        }
        guard let loc = localizations.first(where: { $0.attributes.locale == locale })
                ?? localizations.first else {
            writeError = "No localizations found for locale '\(locale)'."
            isSyncing = false
            return
        }

        let current = trackSlots[displayType] ?? Array(repeating: nil, count: 10)
        let saved = savedTrackState[displayType] ?? Array(repeating: nil, count: 10)

        do {
            // 1. Delete screenshots that were in saved state but not in current track
            let savedIds = Set(saved.compactMap { $0?.id })
            let currentIds = Set(current.compactMap { $0?.id })
            let toDelete = savedIds.subtracting(currentIds)
            for id in toDelete {
                try await service.deleteScreenshot(screenshotId: id)
            }

            // 2. Check if existing ASC screenshots need reorder
            let currentASCIds = current.compactMap { slot -> String? in
                guard let slot, slot.isFromASC else { return nil }
                return slot.id
            }
            let savedASCIds = saved.compactMap { slot -> String? in
                guard let slot, slot.isFromASC else { return nil }
                return slot.id
            }
            let remainingASCIds = Set(currentASCIds)
            let reorderNeeded = currentASCIds != savedASCIds.filter { remainingASCIds.contains($0) }

            if reorderNeeded {
                // Delete remaining ASC screenshots and re-upload in new order
                for id in currentASCIds {
                    if !toDelete.contains(id) {
                        try await service.deleteScreenshot(screenshotId: id)
                    }
                }
            }

            // 3. Upload local assets + re-upload reordered ASC screenshots
            for slot in current {
                guard let slot else { continue }
                if let path = slot.localPath {
                    try await service.uploadScreenshot(localizationId: loc.id, path: path, displayType: displayType)
                } else if reorderNeeded, slot.isFromASC, let ascShot = slot.ascScreenshot {
                    // For reordered ASC screenshots, we need the original file
                    // Download from ASC URL and re-upload
                    if let url = ascShot.imageURL,
                       let (data, _) = try? await URLSession.shared.data(from: url),
                       let fileName = ascShot.attributes.fileName {
                        let tmpPath = FileManager.default.temporaryDirectory.appendingPathComponent(fileName).path
                        try data.write(to: URL(fileURLWithPath: tmpPath))
                        try await service.uploadScreenshot(localizationId: loc.id, path: tmpPath, displayType: displayType)
                        try? FileManager.default.removeItem(atPath: tmpPath)
                    }
                }
            }

            // 4. Reload from ASC
            let sets = try await service.fetchScreenshotSets(localizationId: loc.id)
            screenshotSets = sets
            for set in sets {
                screenshots[set.id] = try await service.fetchScreenshots(setId: set.id)
            }
            loadTrackFromASC(displayType: displayType)
        } catch {
            writeError = error.localizedDescription
        }

        isSyncing = false
    }

    func deleteScreenshot(screenshotId: String) async throws {
        guard let service else { throw ASCError.notFound("ASC service not configured") }
        try await service.deleteScreenshot(screenshotId: screenshotId)
    }

    func scanLocalAssets(projectId: String) {
        let dir = BlitzPaths.screenshots(projectId: projectId)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            localScreenshotAssets = []
            return
        }
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp"]
        localScreenshotAssets = files
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                // Try NSImage first, fall back to CGImageSource for WebP
                var image = NSImage(contentsOf: url)
                if image == nil || image!.representations.isEmpty {
                    if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                       let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                        image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    }
                }
                guard let image else { return nil }
                return LocalScreenshotAsset(id: UUID(), url: url, image: image, fileName: url.lastPathComponent)
            }
    }

    /// Validate pixel dimensions for a display type. Returns nil if valid, or an error string.
    static func validateDimensions(width: Int, height: Int, displayType: String) -> String? {
        switch displayType {
        case "APP_IPHONE_67":
            let validSizes: Set<String> = ["1290x2796", "1284x2778", "1242x2688", "1260x2736"]
            if validSizes.contains("\(width)x\(height)") { return nil }
            return "\(width)\u{00d7}\(height) — need 1290\u{00d7}2796, 1284\u{00d7}2778, 1242\u{00d7}2688, or 1260\u{00d7}2736 for iPhone"
        case "APP_IPAD_PRO_3GEN_129":
            if width == 2048 && height == 2732 { return nil }
            return "\(width)\u{00d7}\(height) — need 2048\u{00d7}2732 for iPad"
        case "APP_DESKTOP":
            let valid: Set<String> = ["1280x800", "1440x900", "2560x1600", "2880x1800"]
            if valid.contains("\(width)x\(height)") { return nil }
            return "\(width)\u{00d7}\(height) — need 1280\u{00d7}800, 1440\u{00d7}900, 2560\u{00d7}1600, or 2880\u{00d7}1800 for Mac"
        default:
            return nil
        }
    }

    /// Add asset to track slot. Returns nil on success, or an error string on dimension mismatch.
    @discardableResult
    func addAssetToTrack(displayType: String, slotIndex: Int, localPath: String) -> String? {
        guard slotIndex >= 0 && slotIndex < 10 else { return "Invalid slot index" }

        guard let image = NSImage(contentsOfFile: localPath) else {
            return "Could not load image"
        }

        // Validate dimensions
        var pixelWidth = 0, pixelHeight = 0
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            pixelWidth = rep.pixelsWide
            pixelHeight = rep.pixelsHigh
        } else if let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff) {
            pixelWidth = bitmap.pixelsWide
            pixelHeight = bitmap.pixelsHigh
        }

        if let error = Self.validateDimensions(width: pixelWidth, height: pixelHeight, displayType: displayType) {
            return error
        }

        var slots = trackSlots[displayType] ?? Array(repeating: nil, count: 10)
        let slot = TrackSlot(
            id: UUID().uuidString,
            localPath: localPath,
            localImage: image,
            ascScreenshot: nil,
            isFromASC: false
        )
        // If target slot occupied, shift right
        if slots[slotIndex] != nil {
            slots.insert(slot, at: slotIndex)
            slots = Array(slots.prefix(10))
        } else {
            slots[slotIndex] = slot
        }
        // Pad back to 10
        while slots.count < 10 { slots.append(nil) }
        trackSlots[displayType] = slots
        return nil
    }

    func removeFromTrack(displayType: String, slotIndex: Int) {
        guard slotIndex >= 0 && slotIndex < 10 else { return }
        var slots = trackSlots[displayType] ?? Array(repeating: nil, count: 10)
        slots.remove(at: slotIndex)
        slots.append(nil) // maintain 10 elements
        trackSlots[displayType] = slots
    }

    func reorderTrack(displayType: String, fromIndex: Int, toIndex: Int) {
        guard fromIndex >= 0 && fromIndex < 10 && toIndex >= 0 && toIndex < 10 else { return }
        guard fromIndex != toIndex else { return }
        var slots = trackSlots[displayType] ?? Array(repeating: nil, count: 10)
        let item = slots.remove(at: fromIndex)
        slots.insert(item, at: toIndex)
        trackSlots[displayType] = slots
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
        guard let appId = app?.id, let versionId = pendingVersionId else { return }
        isSubmitting = true
        submissionError = nil
        do {
            // Attach build if specified
            if let buildId = attachBuildId {
                try await service.attachBuild(versionId: versionId, buildId: buildId)
            }
            try await service.submitForReview(appId: appId, versionId: versionId)
            isSubmitting = false
            await refreshTabData(.app)
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
