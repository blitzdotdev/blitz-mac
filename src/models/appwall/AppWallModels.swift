import Foundation

// MARK: - App

struct AppWallApp: Decodable, Identifiable {
    let id: String
    let name: String
    let bundleId: String
    let ascAppId: String
    let iconUrl: String?
    let subtitle: String?
    let primaryCategory: String?
    let latestVersion: String?
    let currentState: String?

    enum CodingKeys: String, CodingKey {
        case id, name, subtitle
        case bundleId = "bundle_id"
        case ascAppId = "asc_app_id"
        case iconUrl = "icon_url"
        case primaryCategory = "primary_category"
        case latestVersion = "latest_version"
        case currentState = "current_state"
    }
}

// MARK: - App Version

struct AppWallVersion: Decodable, Identifiable {
    let id: String
    let versionString: String
    let platform: String
    let state: String?
    let title: String?
    let subtitle: String?
    let description: String?
    let keywords: String?
    let whatsNew: String?
    let marketingUrl: String?
    let supportUrl: String?

    enum CodingKeys: String, CodingKey {
        case id, platform, state, title, subtitle, description, keywords
        case versionString = "version_string"
        case whatsNew = "whats_new"
        case marketingUrl = "marketing_url"
        case supportUrl = "support_url"
    }
}

// MARK: - Submission Event

struct AppWallEvent: Decodable, Identifiable {
    let id: String
    let versionString: String
    let eventType: String
    let occurredAt: String
    let source: String?
    let accuracy: String?
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case id, source, accuracy, notes
        case versionString = "version_string"
        case eventType = "event_type"
        case occurredAt = "occurred_at"
    }
}

// MARK: - Reviewer Feedback

struct AppWallFeedback: Decodable, Identifiable {
    let id: String
    let versionString: String
    let feedbackType: String
    let rejectionReasons: String?  // JSON array stored as string
    let reviewerMessage: String?
    let guidelineIds: String?      // JSON array stored as string
    let occurredAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case versionString = "version_string"
        case feedbackType = "feedback_type"
        case rejectionReasons = "rejection_reasons"
        case reviewerMessage = "reviewer_message"
        case guidelineIds = "guideline_ids"
        case occurredAt = "occurred_at"
    }

    var parsedRejectionReasons: [String] {
        guard let json = rejectionReasons,
              let data = json.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return arr
    }

    var parsedGuidelineIds: [String] {
        guard let json = guidelineIds,
              let data = json.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return arr
    }
}

// MARK: - List Response

struct AppWallListResponse<T: Decodable>: Decodable {
    let items: [T]
    let total: Int
}
