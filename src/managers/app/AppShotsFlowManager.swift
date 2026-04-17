import Foundation
import AppKit

/// Owns the App Shots batch flow: current step, captures, form inputs, generated sets.
@MainActor
@Observable
final class AppShotsFlowManager {
    // MARK: - Observable state

    var step: AppShotsStep = .hero
    var captures: [CapturedShot] = []
    var headline: String = ""
    var subtitle: String = ""
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
            headline = ""
            subtitle = ""
            step = .hero
        }
    }

    private func adopt(persisted: PersistedSets) {
        headline = persisted.headline
        subtitle = persisted.subtitle ?? ""
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
        headline = ""
        subtitle = ""
        generationError = nil
        captureError = nil
        if isRecording { recorder.stop(); isRecording = false }
        if let projectId = currentProjectId {
            let store = AppShotsStore(projectId: projectId)
            try? FileManager.default.removeItem(atPath: "\(store.outputDir)/sets.json")
        }
        step = .hero
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
        let effectiveHeadline = headline.isEmpty ? projectName : headline
        let rawSubtitle = subtitle.isEmpty ? nil : subtitle
        let frame = useFrame ? selectedFrame : nil

        // Seed each set with empty screenshot placeholders for included captures only.
        let labels: [UUID: String] = Dictionary(
            uniqueKeysWithValues: activeCaptures.enumerated().map { ($0.element.id, "Screen \($0.offset + 1)") }
        )
        generated = chosen.map { template in
            let copy = AppShotsCopywriter.copy(
                base: effectiveHeadline,
                userSubtitle: rawSubtitle,
                category: template.category,
                seed: projectName
            )
            let placeholders = activeCaptures.map { capture in
                GeneratedScreenshot(captureId: capture.id, captureLabel: labels[capture.id] ?? "Screen")
            }
            return GeneratedSet(
                id: template.id,
                template: template,
                headline: copy.headline,
                subtitle: copy.subtitle,
                screenshots: placeholders
            )
        }
        step = .generating

        let store = AppShotsStore(projectId: projectId)
        store.ensureOutputDir()

        let request = GenerationRequest(
            headline: effectiveHeadline,
            subtitle: rawSubtitle,
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
            headline: effectiveHeadline,
            subtitle: rawSubtitle,
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
        case .failure(let error):
            generated[setIdx].screenshots[shotIdx].error = error.localizedDescription
        }
    }
}
