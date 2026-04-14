import SwiftUI
import AppKit
import UniformTypeIdentifiers

// First-time "Zero → 8 sets" journey.
//
// Steps:
//   .hero       — big CTA, "Generate screenshots with AI"
//   .capture    — grab frames from the booted simulator (or upload)
//   .copy       — one headline, kick off generation
//   .generating — fan-out across one template per category, live progress
//   .done       — grid of finished sets
//
// Completion hands the chosen set back to the caller so the user can keep editing.

struct AppShotsOnboardingView: View {
    var appState: AppState
    /// Called when the user picks a set to continue editing. Payload: source screenshot path + template id.
    var onPickSet: (String, String) -> Void
    /// Called when the user dismisses to the classic editor without picking anything.
    var onDismiss: () -> Void

    enum Step {
        case hero, capture, copy, generating, done
    }

    @State private var step: Step = .hero
    @State private var captures: [CapturedShot] = []
    @State private var headline: String = ""
    @State private var subtitle: String = ""
    @State private var isCapturing = false
    @State private var captureError: String?
    @State private var isRecording = false
    @State private var recordingTask: Task<Void, Never>?
    @State private var templates: [ASCManager.AppShotTemplate] = []
    @State private var batchResults: [BatchResult] = []
    @State private var batchError: String?

    struct CapturedShot: Identifiable, Equatable {
        let id = UUID()
        let path: String
        let image: NSImage
    }

    struct BatchResult: Identifiable {
        let id: String          // template id
        let template: ASCManager.AppShotTemplate
        var image: NSImage?     // nil while in-flight
        var path: String?
        var error: String?
    }

    private var projectId: String? { appState.activeProjectId }
    private var projectName: String { appState.activeProject?.name ?? "Your App" }

    private var outputDir: String? {
        guard let projectId else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.blitz/projects/\(projectId)/assets/AppShots/onboarding"
    }

    var body: some View {
        ZStack {
            background
            Group {
                switch step {
                case .hero:       heroView
                case .capture:    captureView
                case .copy:       copyView
                case .generating: generatingView
                case .done:       doneView
                }
            }
            .frame(maxWidth: 920)
            .padding(40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await loadTemplatesIfNeeded() }
    }

    private var background: some View {
        LinearGradient(
            colors: [Color(red: 0.06, green: 0.07, blue: 0.09), Color.black],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    // MARK: - Hero

    private var heroView: some View {
        VStack(spacing: 20) {
            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text("No screenshots yet")
            }
            .font(.caption)
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.3)))
            .foregroundStyle(Color.accentColor)

            Text("Let AI create your screenshots")
                .font(.system(size: 32, weight: .semibold))
                .multilineTextAlignment(.center)

            Text("Capture a few screens from your simulator and we'll lay them into 8 polished template sets.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)

            Button {
                step = .capture
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                    Text("Generate screenshots with AI")
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 24).padding(.vertical, 14)
                .frame(minWidth: 280)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 8)

            Button("Upload screenshots instead") { onDismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.callout)

            Spacer()

            HStack(spacing: 14) {
                flowTile(num: "01", title: "Capture", body: "Grab screens from the booted simulator.")
                flowTile(num: "02", title: "Frame & write", body: "We add device frames and layout.")
                flowTile(num: "03", title: "8 sets", body: "Pick a favorite and keep editing.")
            }
            .padding(.top, 24)
        }
    }

    private func flowTile(num: String, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(num).font(.caption2).foregroundStyle(.tertiary)
            Text(title).font(.callout.weight(.semibold))
            Text(body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.08)))
    }

    // MARK: - Capture

    private var captureView: some View {
        VStack(spacing: 18) {
            stepHeader(title: "Capture screens", subtitle: "Navigate your simulator and capture each screen you want to showcase.")

            if let error = captureError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 12) {
                Button {
                    Task { await captureFromSimulator() }
                } label: {
                    HStack {
                        if isCapturing && !isRecording { ProgressView().controlSize(.small) }
                        Image(systemName: "camera")
                        Text(isCapturing && !isRecording ? "Capturing…" : "Capture current screen")
                    }
                    .frame(minWidth: 220, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isCapturing || isRecording || appState.simulatorManager.bootedDeviceId == nil)

                Button {
                    toggleRecording()
                } label: {
                    HStack {
                        Image(systemName: isRecording ? "stop.circle.fill" : "record.circle")
                            .foregroundStyle(isRecording ? .red : .primary)
                        Text(isRecording ? "Stop recording" : "Record flow")
                    }
                    .frame(minHeight: 44)
                    .padding(.horizontal, 14)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(appState.simulatorManager.bootedDeviceId == nil)

                Button {
                    openFilePicker()
                } label: {
                    Label("Upload", systemImage: "square.and.arrow.up")
                        .frame(minHeight: 44)
                        .padding(.horizontal, 14)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            if isRecording {
                Text("Recording — tap around your simulator. We're grabbing a frame every 2 seconds and dropping near-duplicates.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            if appState.simulatorManager.bootedDeviceId == nil {
                Text("No booted simulator detected — boot one in the Simulator tab, or upload a PNG.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            thumbnailStrip

            Spacer()

            HStack {
                Button("Back") { step = .hero }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(captures.count) captured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    step = .copy
                } label: {
                    HStack { Text("Next"); Image(systemName: "arrow.right") }
                        .padding(.horizontal, 18).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(captures.isEmpty)
            }
        }
    }

    private var thumbnailStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(captures) { shot in
                    ZStack(alignment: .topTrailing) {
                        Image(nsImage: shot.image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.1)))
                        Button {
                            captures.removeAll { $0.id == shot.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.white, .black.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                        .padding(6)
                    }
                }
                if captures.isEmpty {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        .foregroundStyle(.tertiary)
                        .frame(width: 110, height: 220)
                        .overlay(
                            VStack(spacing: 6) {
                                Image(systemName: "iphone.gen3").font(.title)
                                Text("No captures").font(.caption)
                            }
                            .foregroundStyle(.tertiary)
                        )
                }
            }
            .padding(.vertical, 4)
        }
        .frame(height: 240)
    }

    // MARK: - Copy

    private var copyView: some View {
        VStack(spacing: 20) {
            stepHeader(title: "Add your headline", subtitle: "We'll use this for every template. You can tweak per-set afterwards.")

            VStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("HEADLINE").font(.caption2).foregroundStyle(.tertiary)
                    TextField(projectName, text: $headline, prompt: Text("e.g. Plan your day in seconds"))
                        .textFieldStyle(.roundedBorder)
                        .font(.title3)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("SUBTITLE (OPTIONAL)").font(.caption2).foregroundStyle(.tertiary)
                    TextField("", text: $subtitle, prompt: Text("e.g. AI-powered focus, built for you"))
                        .textFieldStyle(.roundedBorder)
                }
            }
            .padding(20)
            .frame(maxWidth: 540)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.08)))

            Spacer()

            HStack {
                Button("Back") { step = .capture }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await runBatchGeneration() }
                } label: {
                    HStack { Image(systemName: "sparkles"); Text("Generate 8 sets") }
                        .padding(.horizontal, 20).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(templates.isEmpty)
            }
        }
    }

    // MARK: - Generating

    private var generatingView: some View {
        VStack(spacing: 16) {
            stepHeader(
                title: "Generating your sets…",
                subtitle: "\(batchResults.filter { $0.image != nil }.count) of \(batchResults.count) ready"
            )

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                ForEach(batchResults) { result in
                    resultCard(result, interactive: false)
                }
            }

            if let batchError {
                Text(batchError).font(.caption).foregroundStyle(.red)
            }

            Spacer()
        }
    }

    // MARK: - Done

    private var doneView: some View {
        VStack(spacing: 16) {
            stepHeader(
                title: "Pick a set to continue",
                subtitle: "Click any set to open it in the editor — change the theme, swap screens, export."
            )

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) {
                ForEach(batchResults) { result in
                    resultCard(result, interactive: true)
                }
            }

            Spacer()

            HStack {
                Button("Start over") { resetToHero() }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Button("Open editor") { onDismiss() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func resultCard(_ result: BatchResult, interactive: Bool) -> some View {
        let bg = result.template.palette?.background ?? "#1f2937"
        return VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(hex: bg) ?? Color.gray.opacity(0.3))
                if let image = result.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else if result.error != nil {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title)
                        .foregroundStyle(.orange)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .aspectRatio(9/16, contentMode: .fit)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.08)))

            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.template.name).font(.caption.weight(.semibold))
                    Text(result.template.category.capitalized)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if result.image != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            }
            .padding(.top, 8)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard interactive, result.image != nil,
                  let firstScreenshot = captures.first?.path else { return }
            onPickSet(firstScreenshot, result.template.id)
        }
    }

    // MARK: - Step header

    private func stepHeader(title: String, subtitle: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 24, weight: .semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func loadTemplatesIfNeeded() async {
        guard templates.isEmpty else { return }
        templates = (try? await ASCManager.appShotsTemplatesList()) ?? []
    }

    private func captureFromSimulator() async {
        captureError = nil
        guard let udid = appState.simulatorManager.bootedDeviceId else {
            captureError = "No booted simulator."
            return
        }
        isCapturing = true
        defer { isCapturing = false }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blitz-onboarding-\(Int(Date().timeIntervalSince1970))-\(captures.count).png")
        do {
            try await SimctlClient().screenshot(udid: udid, path: dir.path)
            guard let image = NSImage(contentsOfFile: dir.path) else {
                captureError = "Screenshot saved but could not be loaded."
                return
            }
            captures.append(CapturedShot(path: dir.path, image: image))
        } catch {
            captureError = "Capture failed: \(error.localizedDescription)"
        }
    }

    private func toggleRecording() {
        if isRecording {
            recordingTask?.cancel()
            recordingTask = nil
            isRecording = false
            return
        }
        guard appState.simulatorManager.bootedDeviceId != nil else {
            captureError = "No booted simulator."
            return
        }
        captureError = nil
        isRecording = true
        recordingTask = Task {
            var lastHash: Int?
            while !Task.isCancelled, isRecording {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled || !isRecording { break }
                if let hash = await captureOnce(dedupeAgainst: lastHash) {
                    lastHash = hash
                }
            }
            await MainActor.run { isRecording = false }
        }
    }

    /// One capture pass for the recorder. Returns a quick hash of the PNG bytes
    /// so the next frame can be compared and skipped if identical.
    private func captureOnce(dedupeAgainst previousHash: Int?) async -> Int? {
        guard let udid = appState.simulatorManager.bootedDeviceId else { return nil }
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("blitz-rec-\(Int(Date().timeIntervalSince1970 * 1000)).png")
        do {
            try await SimctlClient().screenshot(udid: udid, path: path.path)
        } catch {
            return nil
        }
        guard let data = try? Data(contentsOf: path) else { return nil }
        let hash = data.withUnsafeBytes { ptr -> Int in
            var h = 5381
            for byte in ptr.bindMemory(to: UInt8.self).prefix(4096) {
                h = ((h << 5) &+ h) &+ Int(byte)
            }
            return h
        }
        if hash == previousHash { return hash }
        guard let image = NSImage(contentsOf: path) else { return hash }
        await MainActor.run {
            captures.append(CapturedShot(path: path.path, image: image))
        }
        return hash
    }

    private func openFilePicker() {
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

    private func runBatchGeneration() async {
        guard let screenshot = captures.first?.path else { return }
        let chosen = pickOneTemplatePerCategory(from: templates).prefix(8)
        guard !chosen.isEmpty else {
            batchError = "No templates available."
            return
        }

        batchResults = chosen.map { BatchResult(id: $0.id, template: $0) }
        batchError = nil
        step = .generating

        if let dir = outputDir {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        let effectiveHeadline = headline.isEmpty ? projectName : headline
        let rawSubtitle = subtitle.isEmpty ? nil : subtitle
        let stamp = Int(Date().timeIntervalSince1970)

        await withTaskGroup(of: (String, Result<String, Error>).self) { group in
            for template in chosen {
                let outPath = outputDir.map { "\($0)/\(stamp)_\(template.id).png" }
                let copy = AppShotsCopywriter.copy(
                    base: effectiveHeadline,
                    userSubtitle: rawSubtitle,
                    category: template.category,
                    seed: projectName
                )
                group.addTask {
                    do {
                        let path = try await ASCManager.appShotsTemplatesApply(
                            templateId: template.id,
                            screenshot: screenshot,
                            headline: copy.headline,
                            subtitle: copy.subtitle,
                            imageOutput: outPath
                        )
                        return (template.id, .success(path))
                    } catch {
                        return (template.id, .failure(error))
                    }
                }
            }
            for await (templateId, outcome) in group {
                guard let index = batchResults.firstIndex(where: { $0.id == templateId }) else { continue }
                switch outcome {
                case .success(let path):
                    let resolved = (path as NSString).expandingTildeInPath
                    batchResults[index].path = resolved
                    batchResults[index].image = NSImage(contentsOfFile: resolved)
                case .failure(let error):
                    batchResults[index].error = error.localizedDescription
                }
            }
        }

        step = .done
    }

    private func pickOneTemplatePerCategory(from all: [ASCManager.AppShotTemplate]) -> [ASCManager.AppShotTemplate] {
        var seen = Set<String>()
        var primary: [ASCManager.AppShotTemplate] = []
        var rest: [ASCManager.AppShotTemplate] = []
        for t in all {
            if seen.insert(t.category).inserted { primary.append(t) } else { rest.append(t) }
        }
        return primary + rest
    }

    private func resetToHero() {
        captures = []
        headline = ""
        subtitle = ""
        batchResults = []
        batchError = nil
        step = .hero
    }
}

// Tiny hex → Color helper so palette strings render.
private extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self = Color(
            red:   Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8)  & 0xFF) / 255,
            blue:  Double( v        & 0xFF) / 255
        )
    }
}