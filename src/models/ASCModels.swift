import Foundation
import Security
import AppKit

// MARK: - Credentials

struct ASCCredentials: Codable {
    var issuerId: String
    var keyId: String
    var privateKey: String

    static func keyID(fromPrivateKeyFilename filename: String?) -> String? {
        guard let filename else { return nil }
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let basename = URL(fileURLWithPath: trimmed).lastPathComponent
        let pattern = #"^AuthKey_([A-Za-z0-9]{10})\.p8$"#
        let nsRange = NSRange(basename.startIndex..<basename.endIndex, in: basename)
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: basename, range: nsRange),
              match.numberOfRanges == 2,
              let captureRange = Range(match.range(at: 1), in: basename) else {
            return nil
        }

        return String(basename[captureRange]).uppercased()
    }

    static func load() -> ASCCredentials? {
        let url = credentialsURL()
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ASCCredentials.self, from: data)
    }

    func save() throws {
        let url = Self.credentialsURL()
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
        try ASCAuthBridge().syncCredentials(self)
    }

    static func delete() {
        try? FileManager.default.removeItem(at: credentialsURL())
        cleanupLegacyPrivateKeys()
        ASCAuthBridge().cleanup()
    }

    static func credentialsURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".blitz/asc-credentials.json")
    }

    private static func cleanupLegacyPrivateKeys() {
        let fm = FileManager.default
        let home = FileManager.default.homeDirectoryForCurrentUser
        let blitzRoot = home.appendingPathComponent(".blitz")
        guard let entries = try? fm.contentsOfDirectory(
            at: blitzRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for entry in entries where entry.lastPathComponent.hasPrefix("AuthKey_") && entry.pathExtension == "p8" {
            try? fm.removeItem(at: entry)
        }
    }
}

// MARK: - JSON:API Response Wrappers

struct ASCSingleResponse<T: Decodable>: Decodable {
    let data: T
}

struct ASCListResponse<T: Decodable>: Decodable {
    let data: [T]
}

struct ASCPaginatedResponse<T: Decodable>: Decodable {
    let data: [T]
    let links: Links?

    struct Links: Decodable {
        let next: String?
    }
}

// MARK: - Shared Assets

struct ASCImageAsset: Codable {
    let templateUrl: String?
    let width: Int?
    let height: Int?

    func renderedURL(width: Int, height: Int, format: String = "png") -> URL? {
        guard let templateUrl,
              width > 0,
              height > 0 else {
            return nil
        }

        let urlString = templateUrl
            .replacingOccurrences(of: "{w}", with: "\(width)")
            .replacingOccurrences(of: "{h}", with: "\(height)")
            .replacingOccurrences(of: "{f}", with: format)
        return URL(string: urlString)
    }
}

struct ASCAppStoreIconReference: Codable, Sendable {
    let appStoreVersionId: String
    let iconType: String
    let masked: Bool

    init?(relationshipId: String) {
        let trimmedId = relationshipId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else { return nil }

        let paddingCount = (4 - (trimmedId.count % 4)) % 4
        let padded = trimmedId + String(repeating: "=", count: paddingCount)
        guard let data = Data(base64Encoded: padded),
              let decoded = String(data: data, encoding: .utf8) else {
            return nil
        }

        let parts = decoded.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 4,
              parts[0] == "build" else {
            return nil
        }

        let maskedValue = String(parts[3]).lowercased()
        guard maskedValue == "true" || maskedValue == "false" else {
            return nil
        }

        appStoreVersionId = String(parts[1])
        iconType = String(parts[2])
        masked = maskedValue == "true"
    }
}

// MARK: - App

struct ASCApp: Codable, Identifiable {
    let id: String
    let attributes: Attributes
    let relationships: Relationships?

    struct Attributes: Codable {
        let bundleId: String
        let name: String
        let primaryLocale: String?
        let vendorNumber: String?
        let contentRightsDeclaration: String?
    }

    struct Relationships: Codable {
        let appStoreIcon: AppStoreIconRelationship?

        struct AppStoreIconRelationship: Codable {
            let data: RelationshipData?

            struct RelationshipData: Codable {
                let id: String
                let type: String
            }
        }
    }

    var bundleId: String { attributes.bundleId }
    var name: String { attributes.name }
    var primaryLocale: String? { attributes.primaryLocale }
    var vendorNumber: String? { attributes.vendorNumber }
    var contentRightsDeclaration: String? { attributes.contentRightsDeclaration }
    var appStoreIconReference: ASCAppStoreIconReference? {
        guard let relationshipId = relationships?.appStoreIcon?.data?.id else { return nil }
        return ASCAppStoreIconReference(relationshipId: relationshipId)
    }
}

// MARK: - AppStoreVersion

struct ASCAppStoreVersion: Decodable, Identifiable {
    let id: String
    let attributes: Attributes

    struct Attributes: Decodable {
        let versionString: String
        let appStoreState: String?
        let releaseType: String?
        let createdDate: String?
        let copyright: String?
    }
}

enum ASCSubmissionHistoryEventType: String, Codable {
    case submitted
    case submissionError
    case inReview
    case processing
    case accepted
    case live
    case rejected
    case withdrawn
    case removed
}

enum ASCSubmissionHistoryEventSource: String, Codable {
    case reviewSubmission
    case irisFeedback
}

enum ASCSubmissionHistoryAccuracy: String, Codable {
    case exact
    case derived
}

struct ASCSubmissionHistoryEvent: Codable, Identifiable {
    let id: String
    let versionId: String?
    let versionString: String
    let eventType: ASCSubmissionHistoryEventType
    let appleState: String?
    let occurredAt: String
    let source: ASCSubmissionHistoryEventSource
    let accuracy: ASCSubmissionHistoryAccuracy
    let submissionId: String?
    let note: String?
}

// MARK: - VersionLocalization

struct ASCVersionLocalization: Decodable, Identifiable {
    let id: String
    let attributes: Attributes

    struct Attributes: Decodable {
        let locale: String
        let title: String?
        let subtitle: String?
        let description: String?
        let keywords: String?
        let promotionalText: String?
        let marketingUrl: String?
        let supportUrl: String?
        let whatsNew: String?
    }
}

// MARK: - ScreenshotSet

struct ASCScreenshotSet: Decodable, Identifiable {
    let id: String
    let attributes: Attributes

    struct Attributes: Decodable {
        let screenshotDisplayType: String
        let screenshotCount: Int?
    }
}

// MARK: - Screenshot

struct ASCScreenshot: Decodable, Identifiable {
    let id: String
    let attributes: Attributes

    struct Attributes: Decodable {
        let fileName: String?
        let fileSize: Int?
        let imageAsset: ImageAsset?
        let assetDeliveryState: AssetDeliveryState?

        struct ImageAsset: Decodable {
            let templateUrl: String?
            let width: Int?
            let height: Int?
        }

        struct AssetDeliveryState: Decodable {
            let state: String?
            let errors: [DeliveryError]?

            struct DeliveryError: Decodable {
                let code: String?
                let description: String?
            }
        }
    }

    private var fileFormat: String {
        let ext = (attributes.fileName as NSString?)?.pathExtension.lowercased() ?? ""
        switch ext {
        case "jpg", "jpeg":
            return "jpg"
        case "png":
            return "png"
        default:
            return "png"
        }
    }

    private func renderedImageURL(width: Int, height: Int, format: String) -> URL? {
        guard let template = attributes.imageAsset?.templateUrl,
              width > 0,
              height > 0 else {
            return nil
        }
        let urlStr = template
            .replacingOccurrences(of: "{w}", with: "\(width)")
            .replacingOccurrences(of: "{h}", with: "\(height)")
            .replacingOccurrences(of: "{f}", with: format)
        return URL(string: urlStr)
    }

    var imageURL: URL? {
        renderedImageURL(width: 400, height: 800, format: "png")
    }

    var originalImageURL: URL? {
        guard let width = attributes.imageAsset?.width,
              let height = attributes.imageAsset?.height else {
            return nil
        }
        return renderedImageURL(width: width, height: height, format: fileFormat)
    }

    var hasError: Bool {
        if !(attributes.assetDeliveryState?.errors ?? []).isEmpty { return true }
        let state = attributes.assetDeliveryState?.state ?? ""
        return state == "FAILED"
    }

    var errorDescription: String? {
        if let errors = attributes.assetDeliveryState?.errors, !errors.isEmpty {
            return errors.compactMap { $0.description }.joined(separator: "\n")
        }
        let state = attributes.assetDeliveryState?.state ?? ""
        if state == "FAILED" { return "Upload failed" }
        return nil
    }
}

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

// MARK: - CustomerReview

struct ASCCustomerReview: Decodable, Identifiable {
    let id: String
    let attributes: Attributes

    struct Attributes: Decodable {
        let rating: Int
        let title: String?
        let body: String?
        let reviewerNickname: String?
        let createdDate: String?
        let territory: String?
    }
}

// MARK: - Build

struct ASCBuild: Decodable, Identifiable {
    let id: String
    let attributes: Attributes

    struct Attributes: Decodable {
        let version: String
        let uploadedDate: String?
        let processingState: String?
        let expirationDate: String?
        let expired: Bool?
        let minOsVersion: String?
        let iconAssetToken: ASCImageAsset?
    }

    func iconURL(dimension: Int = 1024) -> URL? {
        attributes.iconAssetToken?.renderedURL(width: dimension, height: dimension)
    }
}

struct ASCBuildIcon: Decodable, Identifiable {
    let id: String
    let attributes: Attributes

    struct Attributes: Decodable {
        let iconAsset: ASCImageAsset?
        let iconType: String?
        let masked: Bool?
        let name: String?
    }

    func imageURL(dimension: Int = 1024) -> URL? {
        attributes.iconAsset?.renderedURL(width: dimension, height: dimension)
    }
}

struct ASCBuildUpload: Decodable, Identifiable {
    let id: String
    let attributes: Attributes
    let relationships: Relationships?

    struct Attributes: Decodable {
        let cfBundleShortVersionString: String?
        let cfBundleVersion: String?
        let platform: String?
        let createdDate: String?
        let uploadedDate: String?
        let state: AssetState?

        struct AssetState: Decodable {
            let state: String?
            let errors: [StateDetail]?
            let warnings: [StateDetail]?
            let infos: [StateDetail]?

            struct StateDetail: Decodable {
                let code: String?
                let message: String?
            }
        }
    }

    struct Relationships: Decodable {
        let build: ASCToOneRelationship?
    }

    var buildId: String? { relationships?.build?.data?.id }
}

// MARK: - BetaGroup

struct ASCBetaGroup: Decodable, Identifiable {
    let id: String
    let attributes: Attributes

    struct Attributes: Decodable {
        let name: String
        let isInternalGroup: Bool?
        let hasAccessToAllBuilds: Bool?
        let publicLinkEnabled: Bool?
        let feedbackEnabled: Bool?
    }
}

// MARK: - BetaLocalization

struct ASCBetaLocalization: Decodable, Identifiable {
    let id: String
    let attributes: Attributes

    struct Attributes: Decodable {
        let locale: String
        let description: String?
        let feedbackEmail: String?
        let marketingUrl: String?
        let privacyPolicyUrl: String?
    }
}

// MARK: - BetaFeedback

struct ASCBetaFeedback: Decodable, Identifiable {
    let id: String
    let attributes: Attributes

    struct Attributes: Decodable {
        let comment: String?
        let timestamp: String?
        let screenshotUrl: String?
        let emailAddress: String?
        let architecture: String?
        let osVersion: String?
        let deviceModel: String?
        let locale: String?
    }
}

// MARK: - AppInfo

struct ASCAppInfo: Decodable, Identifiable {
    let id: String
    struct Attributes: Decodable {}
    let attributes: Attributes?

    // Relationships — primaryCategory is a relationship, not an attribute
    struct Relationships: Decodable {
        var primaryCategory: CategoryRelationship?
        struct CategoryRelationship: Decodable {
            var data: CategoryData?
            struct CategoryData: Decodable {
                var id: String
            }
        }
    }
    let relationships: Relationships?

    /// The primary category ID (e.g. "PRODUCTIVITY"), extracted from relationships
    var primaryCategoryId: String? {
        relationships?.primaryCategory?.data?.id
    }
}

// MARK: - AppInfoLocalization

struct ASCAppInfoLocalization: Decodable, Identifiable {
    let id: String
    struct Attributes: Decodable {
        var locale: String
        var name: String?
        var subtitle: String?
        var privacyPolicyUrl: String?
        var privacyChoicesUrl: String?
        var privacyPolicyText: String?
    }
    let attributes: Attributes
}

// MARK: - AgeRatingDeclaration

struct ASCAgeRatingDeclaration: Decodable, Identifiable {
    let id: String
    struct Attributes: Decodable {
        var alcoholTobaccoOrDrugUseOrReferences: String?
        var contests: String?
        var gambling: Bool?
        var gamblingSimulated: String?
        var gunsOrOtherWeapons: String?
        var horrorOrFearThemes: String?
        var matureOrSuggestiveThemes: String?
        var medicalOrTreatmentInformation: String?
        var messagingAndChat: Bool?
        var profanityOrCrudeHumor: String?
        var sexualContentGraphicAndNudity: String?
        var sexualContentOrNudity: String?
        var unrestrictedWebAccess: Bool?
        var userGeneratedContent: Bool?
        var violenceCartoonOrFantasy: String?
        var violenceRealistic: String?
        var violenceRealisticProlongedGraphicOrSadistic: String?
        var advertising: Bool?
        var lootBox: Bool?
        var healthOrWellnessTopics: Bool?
        var parentalControls: Bool?
        var ageAssurance: Bool?
    }
    let attributes: Attributes
}

// MARK: - ReviewDetail

struct ASCReviewDetail: Decodable, Identifiable {
    let id: String
    struct Attributes: Decodable {
        var contactFirstName: String?
        var contactLastName: String?
        var contactPhone: String?
        var contactEmail: String?
        var demoAccountRequired: Bool?
        var demoAccountName: String?
        var demoAccountPassword: String?
        var notes: String?
    }
    let attributes: Attributes

    var isPlaceholder: Bool {
        id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - SubmissionReadiness

struct SubmissionReadiness {
    struct FieldStatus: Identifiable {
        let id: String
        let label: String
        let value: String?
        let isLoading: Bool
        let required: Bool
        let actionUrl: String?  // If set, shows an "Open in ASC" button
        let hint: String?       // Agent-visible guidance for resolving this field

        init(
            label: String,
            value: String?,
            isLoading: Bool = false,
            required: Bool = true,
            actionUrl: String? = nil,
            hint: String? = nil
        ) {
            self.id = label
            self.label = label
            self.value = value
            self.isLoading = isLoading
            self.required = required
            self.actionUrl = actionUrl
            self.hint = hint
        }
    }

    var fields: [FieldStatus]

    var isComplete: Bool {
        fields.filter(\.required).allSatisfy { !$0.isLoading && $0.value != nil && !($0.value!.isEmpty) }
    }

    var missingRequired: [FieldStatus] {
        fields.filter { $0.required && !$0.isLoading && ($0.value == nil || $0.value!.isEmpty) }
    }
}

// MARK: - InAppPurchase

struct ASCInAppPurchase: Decodable, Identifiable {
    let id: String
    struct Attributes: Decodable {
        let name: String?
        let productId: String?
        let inAppPurchaseType: String?
        let state: String?
        let reviewNote: String?
    }
    let attributes: Attributes
}

// MARK: - SubscriptionGroup

struct ASCSubscriptionGroup: Decodable, Identifiable {
    let id: String
    struct Attributes: Decodable {
        let referenceName: String?
    }
    let attributes: Attributes
}

// MARK: - Subscription

struct ASCSubscription: Decodable, Identifiable {
    let id: String
    struct Attributes: Decodable {
        let name: String?
        let productId: String?
        let subscriptionPeriod: String?
        let state: String?
        let reviewNote: String?
    }
    let attributes: Attributes
}

// MARK: - InAppPurchaseLocalization

struct ASCIAPLocalization: Decodable, Identifiable {
    let id: String
    struct Attributes: Decodable {
        let locale: String?
        let name: String?
        let description: String?
    }
    let attributes: Attributes
}

// MARK: - SubscriptionLocalization

struct ASCSubscriptionLocalization: Decodable, Identifiable {
    let id: String
    struct Attributes: Decodable {
        let locale: String?
        let name: String?
        let description: String?
    }
    let attributes: Attributes
}

// MARK: - SubscriptionGroupLocalization

struct ASCSubscriptionGroupLocalization: Decodable, Identifiable {
    let id: String
    struct Attributes: Decodable {
        let locale: String?
        let name: String?
    }
    let attributes: Attributes
}

// MARK: - PriceSchedule (for pricing check)

struct ASCPriceSchedule: Decodable, Identifiable {
    let id: String
}

struct ASCPriceScheduleEntry: Decodable, Identifiable {
    let id: String
}

struct ASCResourceIdentifier: Decodable {
    let id: String
    let type: String?
}

struct ASCToOneRelationship: Decodable {
    let data: ASCResourceIdentifier?
}

struct ASCAppPrice: Decodable, Identifiable {
    let id: String
    let attributes: Attributes?
    let relationships: Relationships?

    struct Attributes: Decodable {
        let startDate: String?
        let endDate: String?
    }

    struct Relationships: Decodable {
        let appPricePoint: ASCToOneRelationship?
    }

    var appPricePointId: String? { relationships?.appPricePoint?.data?.id }
    var startDate: String? { attributes?.startDate }
    var endDate: String? { attributes?.endDate }
}

struct ASCAppPricingState {
    let currentPricePointId: String?
    let scheduledPricePointId: String?
    let scheduledEffectiveDate: String?
}

// MARK: - Territory

struct ASCTerritory: Decodable, Identifiable {
    let id: String
}

// MARK: - BundleId

struct ASCBundleId: Decodable, Identifiable {
    let id: String
    struct Attributes: Decodable {
        let identifier: String
        let name: String
        let platform: String?
    }
    let attributes: Attributes
}

// MARK: - Certificate

struct ASCCertificate: Decodable, Identifiable {
    let id: String
    struct Attributes: Decodable {
        let certificateType: String
        let displayName: String?
        let expirationDate: String?
        let certificateContent: String?
        let name: String?
    }
    let attributes: Attributes
}

// MARK: - Profile

struct ASCProfile: Decodable, Identifiable {
    let id: String
    struct Attributes: Decodable {
        let name: String
        let profileType: String
        let profileContent: String?
        let uuid: String?
        let expirationDate: String?
        let profileState: String?
    }
    let attributes: Attributes
}
