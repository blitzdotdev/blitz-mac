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

        // Per-capture copy: capture's own value wins, else request-level fallback.
        struct CaptureCopy { let headline: String; let subtitle: String?; let tagline: String?; let appName: String? }
        let copyByCapture: [UUID: CaptureCopy] = Dictionary(
            uniqueKeysWithValues: request.captures.map { capture in
                let h = capture.headline.isEmpty ? request.headline : capture.headline
                let s = capture.subtitle.isEmpty ? request.subtitle : capture.subtitle
                let t = capture.tagline.isEmpty ? request.tagline : capture.tagline
                let a = capture.appName.isEmpty ? request.appName : capture.appName
                return (capture.id, CaptureCopy(headline: h, subtitle: s, tagline: t, appName: a))
            }
        )

        // Build a flat job list. ASC plugin can't handle ~48 simultaneous `apply`
        // calls — it throws transient "template not found" errors. Throttle below.
        struct Job { let templateId: String; let category: String; let captureId: UUID; let screenshotPath: String; let outPath: String }
        var jobs: [Job] = []
        for template in templates {
            for source in sources {
                let outPath = "\(request.outputDir)/\(stamp)_\(template.id)_\(source.captureId.uuidString).png"
                jobs.append(Job(
                    templateId: template.id,
                    category: template.category,
                    captureId: source.captureId,
                    screenshotPath: source.path,
                    outPath: outPath
                ))
            }
        }

        // Cap concurrent ASC CLI invocations.
        let maxConcurrent = 4
        await withTaskGroup(of: Outcome.self) { group in
            var next = 0
            func enqueue() {
                guard next < jobs.count else { return }
                let job = jobs[next]
                next += 1
                let perCapture = copyByCapture[job.captureId]
                    ?? CaptureCopy(headline: request.headline, subtitle: request.subtitle, tagline: request.tagline, appName: request.appName)
                // Copywriter still varies subtitle per template category when user hasn't supplied one.
                let copy = AppShotsCopywriter.copy(
                    base: perCapture.headline,
                    userSubtitle: perCapture.subtitle,
                    category: job.category,
                    seed: request.projectName
                )
                let tagline = perCapture.tagline
                let appName = perCapture.appName
                group.addTask {
                    do {
                        let resultPath = try await ASCManager.appShotsTemplatesApply(
                            templateId: job.templateId,
                            screenshot: job.screenshotPath,
                            headline: copy.headline,
                            subtitle: copy.subtitle,
                            tagline: tagline,
                            appName: appName,
                            imageOutput: job.outPath
                        )
                        return Outcome(templateId: job.templateId, captureId: job.captureId, result: .success(resultPath))
                    } catch {
                        return Outcome(templateId: job.templateId, captureId: job.captureId, result: .failure(error))
                    }
                }
            }

            for _ in 0..<min(maxConcurrent, jobs.count) { enqueue() }
            while let outcome = await group.next() {
                await onProgress(outcome)
                enqueue()
            }
        }
    }
}
