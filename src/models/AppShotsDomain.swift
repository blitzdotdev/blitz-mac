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

    init(id: UUID = UUID(), path: String, image: NSImage) {
        self.id = id; self.path = path; self.image = image
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
    let captures: [CapturedShot]
    let frame: DeviceFrame?
    let projectName: String
    let outputDir: String
}

/// One rendered screenshot inside a set.
struct GeneratedScreenshot: Identifiable {
    let id: UUID
    let captureId: UUID         // which source capture this came from
    let captureLabel: String    // "Screen 1", "Screen 2", …
    var imagePath: String?
    var image: NSImage?
    var error: String?

    init(id: UUID = UUID(), captureId: UUID, captureLabel: String,
         imagePath: String? = nil, image: NSImage? = nil, error: String? = nil) {
        self.id = id; self.captureId = captureId; self.captureLabel = captureLabel
        self.imagePath = imagePath; self.image = image; self.error = error
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
    }

    static let currentFormatVersion = 2
}
