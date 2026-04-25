import Foundation
import AppKit

// Value types for the App Shots batch flow.
//
// A "set" is one template × N captures. So if the user captured 5 screens and
// we render 8 templates, we get 8 sets of 5 screenshots each (40 renders total).

enum AppShotsStep: Equatable {
    case hero, capture, generating, done
}

struct CapturedShot: Identifiable, Equatable {
    let id: UUID
    let path: String
    let image: NSImage
    var included: Bool
    var warning: String?
    /// Per-capture text slots. Empty means "fall back to the manager's default."
    var headline: String
    var subtitle: String
    var tagline: String
    var appName: String

    init(id: UUID = UUID(), path: String, image: NSImage,
         included: Bool = true, warning: String? = nil,
         headline: String = "", subtitle: String = "",
         tagline: String = "", appName: String = "") {
        self.id = id; self.path = path; self.image = image
        self.included = included; self.warning = warning
        self.headline = headline; self.subtitle = subtitle
        self.tagline = tagline; self.appName = appName
    }
}

struct DeviceFrame: Hashable {
    let name: String
    let outputWidth: Int
    let outputHeight: Int
    let screenInsetX: Int
    let screenInsetY: Int
}

struct GenerationRequest {
    let headline: String
    let subtitle: String?
    let tagline: String?
    let appName: String?
    let captures: [CapturedShot]
    let frame: DeviceFrame?
    let projectName: String
    let outputDir: String
}

/// One rendered screenshot inside a set. Carries its own copy + source path so edits
/// and retries work without needing the live `CapturedShot` (which isn't persisted).
struct GeneratedScreenshot: Identifiable {
    let id: UUID
    let captureId: UUID         // which source capture this came from (may not be live)
    let captureLabel: String    // "Screen 1", "Screen 2", …
    let sourceScreenshot: String
    /// Editable text slots the ASC CLI accepts. Empty = fall back to defaults.
    var headline: String
    var subtitle: String
    var tagline: String
    var appName: String
    var imagePath: String?
    var image: NSImage?
    var error: String?

    init(id: UUID = UUID(),
         captureId: UUID, captureLabel: String, sourceScreenshot: String,
         headline: String = "", subtitle: String = "",
         tagline: String = "", appName: String = "",
         imagePath: String? = nil, image: NSImage? = nil, error: String? = nil) {
        self.id = id
        self.captureId = captureId
        self.captureLabel = captureLabel
        self.sourceScreenshot = sourceScreenshot
        self.headline = headline
        self.subtitle = subtitle
        self.tagline = tagline
        self.appName = appName
        self.imagePath = imagePath
        self.image = image
        self.error = error
    }

    // MARK: - Domain behavior

    /// Resolved copy values the renderer actually uses.
    /// Own value → project-level default → fallback (nil or project name).
    func effectiveHeadline(defaultHeadline: String, projectName: String) -> String {
        if !headline.isEmpty { return headline }
        if !defaultHeadline.isEmpty { return defaultHeadline }
        return projectName
    }

    func effectiveSubtitle(defaultSubtitle: String) -> String? {
        if !subtitle.isEmpty { return subtitle }
        if !defaultSubtitle.isEmpty { return defaultSubtitle }
        return nil
    }

    func effectiveTagline(defaultTagline: String) -> String? {
        if !tagline.isEmpty { return tagline }
        if !defaultTagline.isEmpty { return defaultTagline }
        return nil
    }

    func effectiveAppName(projectName: String) -> String? {
        if !appName.isEmpty { return appName }
        return projectName.isEmpty ? nil : projectName
    }

    var canRender: Bool {
        !sourceScreenshot.isEmpty && FileManager.default.fileExists(atPath: sourceScreenshot)
    }
}

/// One template's "set" — the same template applied to every capture.
struct GeneratedSet: Identifiable {
    let id: String              // template id
    let template: ASCManager.AppShotTemplate
    let headline: String
    let subtitle: String?
    var screenshots: [GeneratedScreenshot]

    var readyCount: Int { screenshots.filter { $0.image != nil }.count }
    var isReady: Bool { !screenshots.isEmpty && readyCount == screenshots.count }
    var firstReady: GeneratedScreenshot? { screenshots.first(where: { $0.image != nil }) }
}

/// JSON persisted to `~/.blitz/projects/{id}/assets/AppShots/onboarding/sets.json`.
struct PersistedSets: Codable {
    let formatVersion: Int      // bump when schema changes
    let headline: String
    let subtitle: String?
    let deviceFrameName: String?
    let createdAt: Date
    let entries: [Entry]

    struct Entry: Codable {
        let templateId: String
        let templateName: String
        let templateCategory: String
        let paletteBackground: String?
        let screenshots: [Screenshot]
    }

    struct Screenshot: Codable {
        let captureLabel: String
        let imagePath: String
        /// v3+ fields — optional so older payloads still decode.
        let sourceScreenshot: String?
        let headline: String?
        let subtitle: String?
        /// v4+ slots.
        let tagline: String?
        let appName: String?
    }

    /// v4 adds `tagline` + `appName` per shot.
    static let currentFormatVersion = 4
}
