import Foundation
import AppKit

// Batch template rendering. For each template × each capture, runs `asc app-shots templates apply`,
// optionally pre-compositing a device frame onto the capture first.
//
// Reports each finished render via `onProgress(templateId, captureId, result)` so the caller
// (manager) can mutate observable state incrementally.

enum AppShotsGenerator {
    /// Pick one template per category (up to `limit`).
    static func pickTemplates(
        from all: [ASCManager.AppShotTemplate],
        limit: Int = 8
    ) -> [ASCManager.AppShotTemplate] {
        var seen = Set<String>()
        var primary: [ASCManager.AppShotTemplate] = []
        var rest: [ASCManager.AppShotTemplate] = []
        for t in all {
            if seen.insert(t.category).inserted { primary.append(t) } else { rest.append(t) }
        }
        return Array((primary + rest).prefix(limit))
    }

    struct Outcome {
        let templateId: String
        let captureId: UUID
        let result: Result<String, Error>
    }

    /// Fan out templates × captures.
    static func run(
        request: GenerationRequest,
        templates: [ASCManager.AppShotTemplate],
        frameCompositor: DeviceFrameCompositor?,
        onProgress: @MainActor @escaping (Outcome) -> Void
    ) async {
        guard !request.captures.isEmpty else { return }

        // Pre-composite each capture once if a frame is selected — reused across templates.
        let sources: [(captureId: UUID, path: String)] = request.captures.map { capture in
            if let frame = request.frame,
               let compositor = frameCompositor,
               let framed = compositor.composite(screenshotPath: capture.path, device: frame) {
                return (capture.id, framed)
            }
            return (capture.id, capture.path)
        }

        try? FileManager.default.createDirectory(atPath: request.outputDir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)

        await withTaskGroup(of: Outcome.self) { group in
            for template in templates {
                let copy = AppShotsCopywriter.copy(
                    base: request.headline,
                    userSubtitle: request.subtitle,
                    category: template.category,
                    seed: request.projectName
                )
                for source in sources {
                    let outPath = "\(request.outputDir)/\(stamp)_\(template.id)_\(source.captureId.uuidString).png"
                    group.addTask {
                        do {
                            let resultPath = try await ASCManager.appShotsTemplatesApply(
                                templateId: template.id,
                                screenshot: source.path,
                                headline: copy.headline,
                                subtitle: copy.subtitle,
                                imageOutput: outPath
                            )
                            return Outcome(templateId: template.id, captureId: source.captureId, result: .success(resultPath))
                        } catch {
                            return Outcome(templateId: template.id, captureId: source.captureId, result: .failure(error))
                        }
                    }
                }
            }
            for await outcome in group {
                await onProgress(outcome)
            }
        }
    }
}
