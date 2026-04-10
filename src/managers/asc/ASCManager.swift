import Foundation

@MainActor
@Observable
final class ASCManager {
    nonisolated init() {}

    weak var appState: AppState?

    // Credentials & service
    var credentials: ASCCredentials?
    var service: AppStoreConnectService?

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
    var selectedAppInformationLocale: String?
    var appInfoLocalizationsByLocale: [String: ASCAppInfoLocalization] = [:]
    var screenshotSetsByLocale: [String: [ASCScreenshotSet]] = [:]
    var screenshotsByLocale: [String: [String: [ASCScreenshot]]] = [:]
    var selectedScreenshotsLocale: String?
    var customerReviews: [ASCCustomerReview] = []
    var builds: [ASCBuild] = []
    var betaGroups: [ASCBetaGroup] = []
    var betaLocalizations: [ASCBetaLocalization] = []
    var betaFeedback: [String: [ASCBetaFeedback]] = [:]  // keyed by build.id
    var selectedBuildId: String?

    // Monetization data
    var inAppPurchases: [ASCInAppPurchase] = []
    var subscriptionGroups: [ASCSubscriptionGroup] = []
    var subscriptionsPerGroup: [String: [ASCSubscription]] = [:]  // groupId -> subs
    var appPricePoints: [ASCPricePoint] = []  // USA price tiers for the app
    var currentAppPricePointId: String?
    var scheduledAppPricePointId: String?
    var scheduledAppPriceEffectiveDate: String?

    // Creation progress (survives tab switches)
    var createProgress: Double = 0
    var createProgressMessage: String = ""
    var isCreating = false
    internal var createTask: Task<Void, Never>?

    // New data for submission flow
    var appInfo: ASCAppInfo?
    var appInfoLocalization: ASCAppInfoLocalization?
    var ageRatingDeclaration: ASCAgeRatingDeclaration?
    var reviewDetail: ASCReviewDetail?
    var selectedVersionId: String?
    var selectedVersionBuild: ASCBuild?
    var pendingCredentialValues: [String: String]?  // Pre-fill values for ASC credential form (from MCP)
    var pendingFormValues: [String: [String: String]] = [:]  // tab -> field -> value (for MCP pre-fill)
    var pendingFormVersion: Int = 0  // Incremented when pendingFormValues changes; views watch this
    var pendingCreateValues: [String: String]?  // Pre-fill values for IAP/subscription create forms (from MCP)
    var showSubmitPreview = false
    var showCreateUpdateSheet = false
    var isSubmitting = false
    var isCreatingVersion = false
    var submissionError: String?
    var versionCreationError: String?
    var writeError: String?  // Inline error for write operations (does not replace tab content)

    // Review submission history (for rejection tracking)
    var reviewSubmissions: [ASCReviewSubmission] = []
    var reviewSubmissionItemsBySubmissionId: [String: [ASCReviewSubmissionItem]] = [:]
    var latestSubmissionItems: [ASCReviewSubmissionItem] = []
    var submissionHistoryEvents: [ASCSubmissionHistoryEvent] = []

    // Iris (Apple ID session) - rejection feedback from internal API
    enum IrisSessionState { case unknown, noSession, valid, expired }
    var irisSession: IrisSession?
    var irisService: IrisService?
    var irisSessionState: IrisSessionState = .unknown
    var isLoadingIrisFeedback = false
    var irisFeedbackError: String?
    var showAppleIDLogin = false
    var pendingWebAuthContinuation: CheckedContinuation<IrisSession?, Never>?
    var irisFetchTasksByAppId: [String: Task<Void, Never>] = [:]
    var irisLastFetchedAtByAppId: [String: Date] = [:]
    var attachedSubmissionItemIDs: Set<String> = []  // IAP/subscription IDs attached via iris API
    var resolutionCenterThreads: [IrisResolutionCenterThread] = []
    var irisFeedbackCycles: [IrisFeedbackCycle] = []

    // App icon status (set externally; nil = not checked / missing)
    var appIconStatus: String?

    // Monetization status (set after monetization check or setPriceFree success)
    var monetizationStatus: String?

    // Build pipeline progress (driven by MCPExecutor)
    enum BuildPipelinePhase: String {
        case idle
        case signingSetup = "Setting up signing…"
        case archiving = "Archiving…"
        case exporting = "Exporting IPA…"
        case uploading = "Uploading to App Store Connect…"
        case processing = "Processing build…"
    }
    var buildPipelinePhase: BuildPipelinePhase = .idle
    var buildPipelineMessage: String = ""

    // Screenshot track state per device type
    var trackSlots: [String: [TrackSlot?]] = [:]      // keyed by locale + ascDisplayType, 10-element arrays
    var savedTrackState: [String: [TrackSlot?]] = [:] // snapshot after last load/save
    var localScreenshotAssets: [LocalScreenshotAsset] = []
    var isSyncing = false

    // Per-tab loading / error
    var isLoadingTab: [AppTab: Bool] = [:]
    var tabError: [AppTab: String] = [:]

    // Shared internal state used by feature extensions.
    var loadedTabs: Set<AppTab> = []
    var tabLoadedAt: [AppTab: Date] = [:]
    var projectSnapshots: [String: ProjectSnapshot] = [:]
    var tabHydrationTasks: [AppTab: Task<Void, Never>] = [:]
    var overviewReadinessLoadingFields: Set<String> = []
    var loadingFeedbackBuildIds: Set<String> = []
    var loadedProjectId: String?
    var pendingBundleIDSetup: PendingBundleIDSetupContext?

    // Submission readiness labels used by both the view model and background hydration.
    static let overviewWhatsNewFieldLabel = "What's New"
    static let overviewLocalizationFieldLabels: Set<String> = [
        "App Name",
        "Description",
        "Keywords",
        "Support URL",
        overviewWhatsNewFieldLabel
    ]
    static let overviewVersionFieldLabels: Set<String> = ["Copyright"]
    static let overviewAppInfoFieldLabels: Set<String> = ["Primary Category"]
    static let overviewMetadataFieldLabels: Set<String> = [
        "Privacy Policy URL",
        "Age Rating"
    ]
    static let overviewReviewFieldLabels: Set<String> = [
        "Review Contact First Name",
        "Review Contact Last Name",
        "Review Contact Email",
        "Review Contact Phone",
        "Demo Account Name",
        "Demo Account Password"
    ]
    static let overviewBuildFieldLabels: Set<String> = ["Build"]
    static let overviewPricingFieldLabels: Set<String> = [
        "Pricing",
        "In-App Purchases & Subscriptions"
    ]
    static let overviewScreenshotFieldLabels: Set<String> = [
        "Mac Screenshots",
        "iPhone Screenshots",
        "iPad Screenshots"
    ]
}
