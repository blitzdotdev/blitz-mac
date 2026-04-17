import Foundation
import AppKit

/// Owns the App Shots batch flow: current step, captures, form inputs, generated sets.
@MainActor
@Observable
final class AppShotsFlowManager {
    // MARK: - Observable state

    var step: AppShotsStep = .hero
    var captures: [CapturedShot] = []
    /// Fallback headline — used for any capture whose per-row headline is blank.
    var defaultHeadline: String = ""
    /// Fallback subtitle — if blank, the copywriter varies per template.
    var defaultSubtitle: String = ""
    var useFrame: Bool = true
    var selectedFrameName: String = "iPhone 17 Pro Max"
    var templates: [ASCManager.AppShotTemplate] = []
    var availableFrames: [DeviceFrame] = []
    var generated: [GeneratedSet] = []
    var isRecording: Bool = false
    var isCapturing: Bool = false
    var captureError: String?
    var generationError: String?

    // MARK: - Collaborators

    private let recorder = FlowRecorder()
    private let compositor = DeviceFrameCompositor()
    private var currentProjectId: String?
    private var didLoadForProject: String?

    // MARK: - Derived

    var selectedFrame: DeviceFrame? {
        availableFrames.first(where: { $0.name == selectedFrameName })
    }

    var includedCaptures: [CapturedShot] { captures.filter { $0.included } }
    var blankWarningCount: Int { captures.filter { $0.warning != nil }.count }

    var canGenerate: Bool { !includedCaptures.isEmpty && !templates.isEmpty }

    var totalRendersExpected: Int {
        guard !generated.isEmpty else { return 0 }
        return generated.reduce(0) { $0 + $1.screenshots.count }
    }

    var totalRendersDone: Int {
        generated.reduce(0) { $0 + $1.readyCount }
    }

    // MARK: - Lifecycle

    func bootstrap(projectId: String?, projectName: String) async {
        currentProjectId = projectId

        if availableFrames.isEmpty {
            availableFrames = compositor.frames
            if !availableFrames.contains(where: { $0.name == selectedFrameName }) {
                selectedFrameName = availableFrames.first(where: { $0.name.contains("17 Pro Max") })?.name
                    ?? availableFrames.first?.name ?? selectedFrameName
            }
        }

        if templates.isEmpty {
            templates = (try? await ASCManager.appShotsTemplatesList()) ?? []
        }

        guard didLoadForProject != projectId else { return }
        didLoadForProject = projectId

        captures = []
        generated = []
        generationError = nil
        captureError = nil

        if let projectId, let persisted = AppShotsStore(projectId: projectId).load() {
            adopt(persisted: persisted)
            step = .done
        } else {
            defaultHeadline = ""
            defaultSubtitle = ""
            step = .hero
        }
    }

    private func adopt(persisted: PersistedSets) {
        defaultHeadline = persisted.headline
        defaultSubtitle = persisted.subtitle ?? ""
        if let frameName = persisted.deviceFrameName {
            selectedFrameName = frameName
            useFrame = true
        }
        generated = AppShotsStore.rehydrate(persisted)
    }

    // MARK: - Navigation

    func startBuilding() { step = .capture }
    func backToHero() { step = .hero }
    func regenerate() {
        generated = []
        captures = []
        generationError = nil
        step = .capture
    }

    /// Hard reset — clear all in-memory state, delete persisted sets, return to hero.
    func resetToHero() {
        captures = []
        generated = []
        defaultHeadline = ""
        defaultSubtitle = ""
        generationError = nil
        captureError = nil
        if isRecording { recorder.stop(); isRecording = false }
        if let projectId = currentProjectId {
            let store = AppShotsStore(projectId: projectId)
            try? FileManager.default.removeItem(atPath: "\(store.outputDir)/sets.json")
        }
        step = .hero
    }

    // MARK: - Per-capture copy

    /// Resolve the effective headline for a capture: its own override, else default, else project name.
    func effectiveHeadline(for capture: CapturedShot, projectName: String) -> String {
        if !capture.headline.isEmpty { return capture.headline }
        if !defaultHeadline.isEmpty { return defaultHeadline }
        return projectName
    }

    /// Resolve the effective subtitle for a capture: its own override, else default, else nil
    /// (nil triggers the copywriter's per-template variation).
    func effectiveSubtitle(for capture: CapturedShot) -> String? {
        if !capture.subtitle.isEmpty { return capture.subtitle }
        if !defaultSubtitle.isEmpty { return defaultSubtitle }
        return nil
    }

    func updateCaptureHeadline(id: UUID, headline: String) {
        guard let idx = captures.firstIndex(where: { $0.id == id }) else { return }
        captures[idx].headline = headline
    }

    func updateCaptureSubtitle(id: UUID, subtitle: String) {
        guard let idx = captures.firstIndex(where: { $0.id == id }) else { return }
        captures[idx].subtitle = subtitle
    }

    // MARK: - Capture

    func captureOnce(bootedUDID: String?) async {
        captureError = nil
        guard let udid = bootedUDID else { captureError = "No booted simulator."; return }
        isCapturing = true
        defer { isCapturing = false }
        do {
            let shot = try await AppShotsCapture.snapCurrentSimulator(udid: udid)
            captures.append(shot)
        } catch {
            captureError = "Capture failed: \(error.localizedDescription)"
        }
    }

    func toggleRecording(bootedUDID: String?) {
        if isRecording {
            recorder.stop()
            isRecording = false
            return
        }
        guard let udid = bootedUDID else { captureError = "No booted simulator."; return }
        captureError = nil
        isRecording = true
        recorder.start(udid: udid) { [weak self] shot in
            self?.captures.append(shot)
        }
    }

    func importFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Select screenshots"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let image = NSImage(contentsOf: url) {
                captures.append(CapturedShot(path: url.path, image: image))
            }
        }
    }

    func removeCapture(id: UUID) {
        captures.removeAll { $0.id == id }
    }

    func toggleCaptureInclusion(id: UUID) {
        guard let idx = captures.firstIndex(where: { $0.id == id }) else { return }
        captures[idx].included.toggle()
    }

    // MARK: - Generate

    func generate(projectName: String) async {
        let activeCaptures = includedCaptures
        guard !activeCaptures.isEmpty else { return }
        guard let projectId = currentProjectId else {
            generationError = "No active project."
            return
        }

        let chosen = AppShotsGenerator.pickTemplates(from: templates, limit: 8)
        guard !chosen.isEmpty else {
            generationError = "No templates available."
            return
        }

        generationError = nil
        let fallbackHeadline = defaultHeadline.isEmpty ? projectName : defaultHeadline
        let fallbackSubtitle = defaultSubtitle.isEmpty ? nil : defaultSubtitle
        let frame = useFrame ? selectedFrame : nil

        // Seed each set with empty screenshot placeholders for included captures only.
        let labels: [UUID: String] = Dictionary(
            uniqueKeysWithValues: activeCaptures.enumerated().map { ($0.element.id, "Screen \($0.offset + 1)") }
        )
        generated = chosen.map { template in
            let setCopy = AppShotsCopywriter.copy(
                base: fallbackHeadline,
                userSubtitle: fallbackSubtitle,
                category: template.category,
                seed: projectName
            )
            let placeholders = activeCaptures.map { capture in
                GeneratedScreenshot(
                    captureId: capture.id,
                    captureLabel: labels[capture.id] ?? "Screen",
                    sourceScreenshot: capture.path,
                    headline: capture.headline,  // may be empty; fallback resolved at render time
                    subtitle: capture.subtitle
                )
            }
            return GeneratedSet(
                id: template.id,
                template: template,
                headline: setCopy.headline,
                subtitle: setCopy.subtitle,
                screenshots: placeholders
            )
        }
        step = .generating

        let store = AppShotsStore(projectId: projectId)
        store.ensureOutputDir()

        let request = GenerationRequest(
            headline: fallbackHeadline,
            subtitle: fallbackSubtitle,
            captures: activeCaptures,
            frame: frame,
            projectName: projectName,
            outputDir: store.outputDir
        )

        await AppShotsGenerator.run(
            request: request,
            templates: chosen,
            frameCompositor: useFrame ? compositor : nil
        ) { [weak self] outcome in
            self?.applyOutcome(outcome)
        }

        let snapshot = AppShotsStore.snapshot(
            headline: fallbackHeadline,
            subtitle: fallbackSubtitle,
            deviceFrame: frame,
            sets: generated
        )
        store.save(snapshot)
        step = .done
    }

    private func applyOutcome(_ outcome: AppShotsGenerator.Outcome) {
        guard let setIdx = generated.firstIndex(where: { $0.id == outcome.templateId }),
              let shotIdx = generated[setIdx].screenshots.firstIndex(where: { $0.captureId == outcome.captureId })
        else { return }

        switch outcome.result {
        case .success(let path):
            let resolved = (path as NSString).expandingTildeInPath
            generated[setIdx].screenshots[shotIdx].imagePath = resolved
            generated[setIdx].screenshots[shotIdx].image = NSImage(contentsOfFile: resolved)
            generated[setIdx].screenshots[shotIdx].error = nil
        case .failure(let error):
            generated[setIdx].screenshots[shotIdx].error = error.localizedDescription
        }
    }

    // MARK: - Per-shot edits

    /// Update a shot's headline in place. Safe after app restart — doesn't depend on live captures.
    func updateShotHeadline(setId: String, screenshotId: UUID, headline: String) {
        guard let setIdx = generated.firstIndex(where: { $0.id == setId }),
              let shotIdx = generated[setIdx].screenshots.firstIndex(where: { $0.id == screenshotId })
        else { return }
        generated[setIdx].screenshots[shotIdx].headline = headline
    }

    func updateShotSubtitle(setId: String, screenshotId: UUID, subtitle: String) {
        guard let setIdx = generated.firstIndex(where: { $0.id == setId }),
              let shotIdx = generated[setIdx].screenshots.firstIndex(where: { $0.id == screenshotId })
        else { return }
        generated[setIdx].screenshots[shotIdx].subtitle = subtitle
    }

    /// Re-render a single shot using its own current copy + sourceScreenshot.
    /// Used for "retry failed" and "apply edited text" — same call, same effect.
    func applyShotChanges(setId: String, screenshotId: UUID, projectName: String) async {
        guard let setIdx = generated.firstIndex(where: { $0.id == setId }),
              let shotIdx = generated[setIdx].screenshots.firstIndex(where: { $0.id == screenshotId }),
              let projectId = currentProjectId else { return }

        let shot = generated[setIdx].screenshots[shotIdx]
        let template = generated[setIdx].template

        guard shot.canRender, let sourceImage = NSImage(contentsOfFile: shot.sourceScreenshot) else {
            generated[setIdx].screenshots[shotIdx].error = "Source screenshot missing — can't re-render."
            return
        }

        // Reset status so UI shows loading again.
        generated[setIdx].screenshots[shotIdx].error = nil
        generated[setIdx].screenshots[shotIdx].imagePath = nil
        generated[setIdx].screenshots[shotIdx].image = nil

        let store = AppShotsStore(projectId: projectId)
        let headline = shot.effectiveHeadline(defaultHeadline: defaultHeadline, projectName: projectName)
        let subtitle = shot.effectiveSubtitle(defaultSubtitle: defaultSubtitle)
        let frame = useFrame ? selectedFrame : nil

        let request = GenerationRequest(
            headline: headline,
            subtitle: subtitle,
            captures: [CapturedShot(
                id: shot.captureId,
                path: shot.sourceScreenshot,
                image: sourceImage,
                headline: headline,
                subtitle: subtitle ?? ""
            )],
            frame: frame,
            projectName: projectName,
            outputDir: store.outputDir
        )

        await AppShotsGenerator.run(
            request: request,
            templates: [template],
            frameCompositor: useFrame ? compositor : nil
        ) { [weak self] outcome in
            self?.applyOutcome(outcome)
        }

        store.save(AppShotsStore.snapshot(
            headline: defaultHeadline.isEmpty ? projectName : defaultHeadline,
            subtitle: defaultSubtitle.isEmpty ? nil : defaultSubtitle,
            deviceFrame: frame,
            sets: generated
        ))
    }

    /// Back-compat alias — same behavior, kept so existing callers don't break.
    func retryScreenshot(setId: String, screenshotId: UUID, projectName: String) async {
        await applyShotChanges(setId: setId, screenshotId: screenshotId, projectName: projectName)
    }
}
