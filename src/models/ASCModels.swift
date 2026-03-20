import Foundation
import Security

// MARK: - Credentials

struct ASCCredentials: Codable {
    var issuerId: String
    var keyId: String
    var privateKey: String

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
    }

    static func delete() {
        try? FileManager.default.removeItem(at: credentialsURL())
    }

    static func credentialsURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".blitz/asc-credentials.json")
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

// MARK: - App

struct ASCApp: Decodable, Identifiable {
    let id: String
    let attributes: Attributes

    struct Attributes: Decodable {
        let bundleId: String
        let name: String
        let primaryLocale: String?
        let vendorNumber: String?
        let contentRightsDeclaration: String?
    }

    var bundleId: String { attributes.bundleId }
    var name: String { attributes.name }
    var primaryLocale: String? { attributes.primaryLocale }
    var vendorNumber: String? { attributes.vendorNumber }
    var contentRightsDeclaration: String? { attributes.contentRightsDeclaration }
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

    var imageURL: URL? {
        guard let template = attributes.imageAsset?.templateUrl else { return nil }
        let urlStr = template
            .replacingOccurrences(of: "{w}", with: "400")
            .replacingOccurrences(of: "{h}", with: "800")
            .replacingOccurrences(of: "{f}", with: "png")
        return URL(string: urlStr)
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
    }
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
}

// MARK: - SubmissionReadiness

struct SubmissionReadiness {
    struct FieldStatus: Identifiable {
        let id: String
        let label: String
        let value: String?
        let required: Bool
        let actionUrl: String?  // If set, shows an "Open in ASC" button

        init(label: String, value: String?, required: Bool = true, actionUrl: String? = nil) {
            self.id = label
            self.label = label
            self.value = value
            self.required = required
            self.actionUrl = actionUrl
        }
    }

    var fields: [FieldStatus]

    var isComplete: Bool {
        fields.filter(\.required).allSatisfy { $0.value != nil && !($0.value!.isEmpty) }
    }

    var missingRequired: [FieldStatus] {
        fields.filter { $0.required && ($0.value == nil || $0.value!.isEmpty) }
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

// MARK: - Iris Session (Apple ID cookie-based auth for internal APIs)

struct IrisSession: Codable {
    var cookies: [IrisCookie]
    var capturedAt: Date

    struct IrisCookie: Codable {
        let name: String
        let value: String
        let domain: String
        let path: String
    }

    private static let keychainService = "dev.blitz.iris-session"
    private static let keychainAccount = "iris-cookies"

    static func load() -> IrisSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(IrisSession.self, from: data)
    }

    func save() throws {
        let data = try JSONEncoder().encode(self)
        // Delete any existing item first
        Self.delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: "IrisSession", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Failed to save session to Keychain (status: \(status))"])
        }
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Iris API Response Models

struct IrisResolutionCenterThread: Decodable, Identifiable {
    let id: String
    let attributes: Attributes

    struct Attributes: Decodable {
        let state: String?
        let createdDate: String?
    }
}

struct IrisResolutionCenterMessage: Decodable, Identifiable {
    let id: String
    let attributes: Attributes

    struct Attributes: Decodable {
        let messageBody: String?
        let createdDate: String?
    }
}

struct IrisReviewRejection: Decodable, Identifiable {
    let id: String
    let attributes: Attributes

    struct Attributes: Decodable {
        let reasons: [Reason]?
    }

    struct Reason: Decodable {
        let reasonSection: String?
        let reasonDescription: String?
        let reasonCode: String?
    }
}

// MARK: - Iris Feedback Cache

struct IrisFeedbackCache: Codable {
    let appId: String
    let versionString: String
    let fetchedAt: Date
    let messages: [CachedMessage]
    let reasons: [CachedReason]

    struct CachedMessage: Codable {
        let body: String
        let date: String?
    }

    struct CachedReason: Codable {
        let section: String
        let description: String
        let code: String
    }

    // MARK: - Persistence

    func save() throws {
        let url = Self.cacheURL(appId: appId, versionString: versionString)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }

    static func load(appId: String, versionString: String) -> IrisFeedbackCache? {
        let url = cacheURL(appId: appId, versionString: versionString)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(IrisFeedbackCache.self, from: data)
    }

    private static func cacheURL(appId: String, versionString: String) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".blitz/iris-cache/\(appId)/\(versionString).json")
    }
}
