import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AppShotsView: View {
    var appState: AppState

    // Source screenshot
    @State private var sourceImage: NSImage?
    @State private var sourceImagePath: String?
    @State private var sourceImageName: String?
    @State private var isDropTargeted = false

    // Templates & themes
    @State private var templates: [ASCManager.AppShotTemplate] = []
    @State private var themes: [ASCManager.AppShotTheme] = []
    @State private var selectedTemplateId: String?
    @State private var selectedThemeId: String?
    @State private var headline: String = "Your Headline"
    @State private var subtitle: String = ""

    // Generation state
    @State private var isGenerating = false
    @State private var generatedImage: NSImage?
    @State private var generatedImagePath: String?
    @State private var generationError: String?
    @State private var importError: String?

    private var projectId: String? { appState.activeProjectId }

    private var outputDir: String? {
        guard let projectId else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.blitz/projects/\(projectId)/assets/AppShots"
    }

    private var canGenerate: Bool {
        sourceImagePath != nil && selectedTemplateId != nil && !isGenerating
    }

    var body: some View {
        HStack(spacing: 0) {
            sourcePanel
                .frame(width: 240)
            Divider()
            previewPanel
        }
        .task { await loadCatalog() }
        .alert("Error", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    // MARK: - Source Panel (Left)

    private var sourcePanel: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("Source Screenshot")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)

                dropZone

                Button {
                    openScreenshotPicker()
                } label: {
                    Label("Choose File", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Divider()

                headlineFields

                Divider()

                templatePicker

                Divider()

                themePicker

                Divider()

                generateButton

                if let generationError {
                    Text(generationError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(16)
        }
        .background(.background.secondary)
    }

    // MARK: - Drop Zone

    private var dropZone: some View {
        ZStack {
            if let image = sourceImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(8)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "iphone.gen3")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("Drop screenshot here")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 200)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.1) : Color(.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                    style: StrokeStyle(lineWidth: 2, dash: sourceImage == nil ? [6, 4] : [])
                )
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
            return true
        }
    }

    // MARK: - Headline Fields

    private var headlineFields: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Headline")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("Your Headline", text: $headline)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Subtitle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("Optional subtitle", text: $subtitle)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
            }
        }
    }

    // MARK: - Template Picker

    private var templatePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Template")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            if templates.isEmpty {
                Text("Loading\u{2026}")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(orderedCategories(), id: \.self) { category in
                    templateCategorySection(category)
                }
            }
        }
    }

    private func templateCategorySection(_ category: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(category.capitalized)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)

            ForEach(templates.filter { $0.category == category }) { template in
                templateRow(template)
            }
        }
    }

    private func templateRow(_ template: ASCManager.AppShotTemplate) -> some View {
        let isSelected = selectedTemplateId == template.id
        return Button {
            selectedTemplateId = template.id
        } label: {
            HStack {
                Text(template.name)
                    .font(.caption)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Theme Picker

    private var themePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Theme")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if selectedThemeId != nil {
                    Button("Clear") { selectedThemeId = nil }
                        .font(.caption2)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Optional \u{2014} AI-powered styling")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            ForEach(themes) { theme in
                themeRow(theme)
            }
        }
    }

    private func themeRow(_ theme: ASCManager.AppShotTheme) -> some View {
        let isSelected = selectedThemeId == theme.id
        return Button {
            selectedThemeId = isSelected ? nil : theme.id
        } label: {
            HStack(spacing: 6) {
                Text(theme.icon)
                    .font(.callout)
                Text(theme.name)
                    .font(.caption)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Generate Button

    private var generateButton: some View {
        Button {
            Task { await generate() }
        } label: {
            HStack {
                if isGenerating {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(isGenerating ? "Generating\u{2026}" : "Generate")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canGenerate)
    }

    // MARK: - Preview Panel (Right)

    private var previewPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                previewHeader
                previewContent
            }
            .padding(24)
        }
    }

    private var previewHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("App Shots")
                .font(.title2.weight(.semibold))

            if let tid = selectedTemplateId,
               let template = templates.first(where: { $0.id == tid }) {
                HStack(spacing: 8) {
                    Text(template.name)
                        .font(.callout.weight(.medium))
                    if let thId = selectedThemeId,
                       let theme = themes.first(where: { $0.id == thId }) {
                        Text("\(theme.icon) \(theme.name)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        if isGenerating {
            generatingPlaceholder
        } else if let generatedImage {
            generatedPreview(generatedImage)
        } else {
            emptyPlaceholder
        }
    }

    private var generatingPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text("Generating screenshot\u{2026}")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func generatedPreview(_ image: NSImage) -> some View {
        VStack(spacing: 12) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                .frame(maxWidth: 400)

            if let path = generatedImagePath {
                HStack(spacing: 8) {
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Button {
                        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                    } label: {
                        Image(systemName: "folder")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Show in Finder")
                }
            }
        }
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)
            Text("Drop a screenshot, pick a template,\nand click Generate")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Data Loading

    private func loadCatalog() async {
        do {
            async let t = ASCManager.appShotsTemplatesList()
            async let th = ASCManager.appShotsThemesList()
            let (loadedTemplates, loadedThemes) = try await (t, th)
            templates = loadedTemplates
            themes = loadedThemes
            if selectedTemplateId == nil, let first = loadedTemplates.first {
                selectedTemplateId = first.id
            }
        } catch {
            generationError = "Failed to load catalog: \(error.localizedDescription)"
        }
    }

    private func orderedCategories() -> [String] {
        let order = ["bold", "minimal", "elegant", "professional", "playful", "showcase", "custom"]
        let present = Set(templates.map(\.category))
        let ordered = order.filter { present.contains($0) }
        let remaining = present.subtracting(ordered).sorted()
        return ordered + remaining
    }

    // MARK: - Actions

    private func openScreenshotPicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a screenshot"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadSourceScreenshot(from: url)
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
            guard let data = data as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            DispatchQueue.main.async {
                loadSourceScreenshot(from: url)
            }
        }
    }

    private func loadSourceScreenshot(from url: URL) {
        guard let image = NSImage(contentsOf: url) else {
            importError = "Could not load image."
            return
        }
        sourceImage = image
        sourceImagePath = url.path
        sourceImageName = url.lastPathComponent
        generatedImage = nil
        generatedImagePath = nil
        generationError = nil
    }

    private func generate() async {
        guard let screenshotPath = sourceImagePath,
              let templateId = selectedTemplateId else { return }

        isGenerating = true
        generationError = nil
        generatedImage = nil
        generatedImagePath = nil

        if let dir = outputDir {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        let timestamp = Int(Date().timeIntervalSince1970)
        let outputPath = outputDir.map { "\($0)/shot_\(timestamp).png" }

        do {
            let resultPath: String
            if let themeId = selectedThemeId {
                resultPath = try await ASCManager.appShotsThemesApply(
                    themeId: themeId,
                    templateId: templateId,
                    screenshot: screenshotPath,
                    headline: headline.isEmpty ? nil : headline,
                    subtitle: subtitle.isEmpty ? nil : subtitle,
                    imageOutput: outputPath
                )
            } else {
                resultPath = try await ASCManager.appShotsTemplatesApply(
                    templateId: templateId,
                    screenshot: screenshotPath,
                    headline: headline,
                    subtitle: subtitle.isEmpty ? nil : subtitle,
                    imageOutput: outputPath
                )
            }

            let expandedPath = (resultPath as NSString).expandingTildeInPath
            if let image = NSImage(contentsOfFile: expandedPath) {
                generatedImage = image
                generatedImagePath = expandedPath
            } else {
                generationError = "Generated file not found at: \(expandedPath)"
            }
        } catch {
            generationError = error.localizedDescription
        }

        isGenerating = false
    }
}
