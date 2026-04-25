import Foundation
import AppKit

// Per-project persistence for generated screenshot sets.
// File: ~/.blitz/projects/{id}/assets/AppShots/onboarding/sets.json

struct AppShotsStore {
    let projectId: String

    var outputDir: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.blitz/projects/\(projectId)/assets/AppShots/onboarding"
    }

    private var setsFilePath: String { "\(outputDir)/sets.json" }

    func ensureOutputDir() {
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
    }

    /// Load the persisted sets if format matches. Older formats are ignored (treated as nil) —
    /// the user re-onboards for that project.
    func load() -> PersistedSets? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: setsFilePath)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(PersistedSets.self, from: data),
              payload.formatVersion == PersistedSets.currentFormatVersion else {
            return nil
        }
        return payload
    }

    func save(_ payload: PersistedSets) {
        ensureOutputDir()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(payload) {
            try? data.write(to: URL(fileURLWithPath: setsFilePath))
        }
    }

    /// Rehydrate GeneratedSet models from persisted entries. Each set's screenshots are loaded from disk.
    static func rehydrate(_ persisted: PersistedSets) -> [GeneratedSet] {
        persisted.entries.map { entry in
            let palette = entry.paletteBackground.map { bg in
                ASCManager.AppShotTemplate.Palette(id: entry.templateId, name: entry.templateName, background: bg)
            }
            let template = ASCManager.AppShotTemplate(
                id: entry.templateId,
                name: entry.templateName,
                category: entry.templateCategory,
                description: "",
                deviceCount: 1,
                palette: palette
            )
            let screenshots = entry.screenshots.map { s in
                GeneratedScreenshot(
                    captureId: UUID(),
                    captureLabel: s.captureLabel,
                    sourceScreenshot: s.sourceScreenshot ?? "",
                    headline: s.headline ?? "",
                    subtitle: s.subtitle ?? "",
                    tagline: s.tagline ?? "",
                    appName: s.appName ?? "",
                    imagePath: s.imagePath,
                    image: NSImage(contentsOfFile: s.imagePath)
                )
            }
            return GeneratedSet(
                id: entry.templateId,
                template: template,
                headline: persisted.headline,
                subtitle: persisted.subtitle,
                screenshots: screenshots
            )
        }
    }

    /// Snapshot the current generated sets for persistence.
    static func snapshot(
        headline: String,
        subtitle: String?,
        deviceFrame: DeviceFrame?,
        sets: [GeneratedSet]
    ) -> PersistedSets {
        let entries = sets.map { set -> PersistedSets.Entry in
            let shots = set.screenshots.compactMap { shot -> PersistedSets.Screenshot? in
                guard let path = shot.imagePath, shot.image != nil else { return nil }
                return PersistedSets.Screenshot(
                    captureLabel: shot.captureLabel,
                    imagePath: path,
                    sourceScreenshot: shot.sourceScreenshot,
                    headline: shot.headline,
                    subtitle: shot.subtitle,
                    tagline: shot.tagline,
                    appName: shot.appName
                )
            }
            return PersistedSets.Entry(
                templateId: set.template.id,
                templateName: set.template.name,
                templateCategory: set.template.category,
                paletteBackground: set.template.palette?.background,
                screenshots: shots
            )
        }
        return PersistedSets(
            formatVersion: PersistedSets.currentFormatVersion,
            headline: headline,
            subtitle: subtitle,
            deviceFrameName: deviceFrame?.name,
            createdAt: Date(),
            entries: entries
        )
    }
}
