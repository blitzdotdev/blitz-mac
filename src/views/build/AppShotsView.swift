import SwiftUI
import WebKit
import AppKit
import UniformTypeIdentifiers

// MARK: - Main View

struct AppShotsView: View {
    var appState: AppState

    @State private var sourceImage: NSImage?
    @State private var sourceImagePath: String?
    @State private var isDropTargeted = false

    @State private var templates: [ASCManager.AppShotTemplate] = []
    @State private var themes: [ASCManager.AppShotTheme] = []
    @State private var templatePreviews: [String: String] = [:]
    @State private var selectedTemplateId: String?
    @State private var selectedThemeId: String?
    @State private var headline: String = "Your Headline"
    @State private var subtitle: String = ""

    // Bezel
    @State private var withFrame = false
    @State private var selectedDevice: String = "iPhone 16 Pro Max"
    @State private var availableDevices: [String] = []
    @State private var frameInsets: [String: FrameInset] = [:]

    @State private var framedPreviewImage: NSImage?

    @State private var isGenerating = false
    @State private var generatedImage: NSImage?
    @State private var generatedImagePath: String?
    @State private var generationError: String?
    @State private var importError: String?
    @State private var showResult = false

    @State private var galleryHTML: String = ""
    @State private var isLoadingGallery = true

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
            rightPanel
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
            VStack(spacing: 14) {
                // Header
                HStack {
                    Text("App Shots")
                        .font(.headline)
                    Spacer()
                }

                // Drop zone
                dropZone

                Button {
                    openScreenshotPicker()
                } label: {
                    Label("Choose File", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Divider()

                // Text fields
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
                    TextField("Optional", text: $subtitle)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout)
                }

                Divider()

                // Bezel
                bezelToggle

                Divider()

                // Theme
                themePicker

                Divider()

                // Generate
                Button {
                    Task { await generate() }
                } label: {
                    HStack(spacing: 6) {
                        if isGenerating {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isGenerating ? "Generating\u{2026}" : "Generate Screenshot")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(!canGenerate)

                if let generationError {
                    Text(generationError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }

                // Selected template info
                if let tid = selectedTemplateId,
                   let template = templates.first(where: { $0.id == tid }) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                        Text(template.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
        }
        .background(.background.secondary)
    }

    private var dropZone: some View {
        ZStack {
            if let displayImage = withFrame ? (framedPreviewImage ?? sourceImage) : sourceImage {
                Image(nsImage: displayImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(6)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "iphone.gen3")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text("Drop screenshot")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 140)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.1) : Color(.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
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

    private var bezelToggle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $withFrame) {
                Text("With Device Frame")
                    .font(.caption.weight(.medium))
            }
            .toggleStyle(.checkbox)
            .onChange(of: withFrame) { _, _ in updateFramedPreview() }

            if withFrame && !availableDevices.isEmpty {
                Picker("Device", selection: $selectedDevice) {
                    ForEach(availableDevices, id: \.self) { device in
                        Text(device).tag(device)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .onChange(of: selectedDevice) { _, _ in updateFramedPreview() }
            }
        }
    }

    private func updateFramedPreview() {
        guard withFrame, let path = sourceImagePath,
              let framedPath = compositeBezel(screenshotPath: path) else {
            framedPreviewImage = nil
            return
        }
        framedPreviewImage = NSImage(contentsOfFile: framedPath)
    }

    private var themePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Theme")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("optional")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                if selectedThemeId != nil {
                    Button("Clear") { selectedThemeId = nil }
                        .font(.caption2)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }

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
                    .font(.caption)
                Text(theme.name)
                    .font(.caption)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Right Panel
    //
    // Three states:
    //   1. Gallery — browsing templates (default)
    //   2. Preview — showing source screenshot while generating, with overlay
    //   3. Result — showing generated screenshot
    //
    // "Templates" / cancel → back to gallery.

    private enum RightPanelMode {
        case gallery
        case preview   // generating — shows source screenshot + overlay
        case result    // done — shows generated screenshot
    }

    private var rightPanelMode: RightPanelMode {
        if showResult && generatedImage != nil { return .result }
        if isGenerating || generationError != nil { return .preview }
        return .gallery
    }

    private var rightPanel: some View {
        ZStack {
            // Gallery always exists underneath to keep WKWebView alive
            galleryView
                .opacity(rightPanelMode == .gallery ? 1 : 0)
                .allowsHitTesting(rightPanelMode == .gallery)

            if rightPanelMode == .preview {
                previewView
            }

            if rightPanelMode == .result {
                resultView
            }
        }
    }

    // MARK: - Gallery View

    private var galleryView: some View {
        ZStack {
            if isLoadingGallery {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("Loading templates\u{2026}")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                AppShotsGalleryWebView(
                    html: galleryHTML,
                    selectedTemplateId: selectedTemplateId,
                    onSelectTemplate: { id in
                        selectedTemplateId = id
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Preview View (generating — shows source screenshot + overlay)

    private var previewView: some View {
        ZStack {
            Color(.windowBackgroundColor)

            // Show source screenshot as background
            if let src = sourceImage {
                Image(nsImage: src)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: 500)
                    .opacity(0.4)
            }

            // Overlay
            VStack(spacing: 16) {
                if isGenerating {
                    ProgressView()
                        .controlSize(.large)
                    Text("Generating\u{2026}")
                        .font(.title3.weight(.medium))
                    if selectedThemeId != nil {
                        Text("AI theme styling may take a moment")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let error = generationError {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32))
                        .foregroundStyle(.orange)
                    Text("Generation Failed")
                        .font(.title3.weight(.medium))
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                    Button("Back to Templates") {
                        generationError = nil
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Result View (done — shows generated screenshot)

    private var resultView: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Button {
                    showResult = false
                    generatedImage = nil
                } label: {
                    Label("Templates", systemImage: "chevron.left")
                        .font(.callout)
                }
                .buttonStyle(.plain)

                Spacer()

                if let path = generatedImagePath {
                    Button {
                        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                            .font(.callout)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    if let image = generatedImage {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
                            .frame(maxWidth: 500)
                            .padding(.top, 20)
                    }

                    if let path = generatedImagePath {
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(24)
            }
        }
        .background(Color(.windowBackgroundColor))
    }

    // MARK: - Data Loading

    private func loadCatalog() async {
        isLoadingGallery = true
        do {
            let output = try await ProcessRunner.run(
                "asc",
                arguments: ["app-shots", "templates", "list", "--output", "json"],
                timeout: 30
            )
            let json = extractJSON(from: output)
            let data = Data(json.utf8)

            guard let wrapper = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = wrapper["data"] as? [[String: Any]] else {
                throw NSError(domain: "AppShots", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid template data"])
            }

            var parsedTemplates: [ASCManager.AppShotTemplate] = []
            var previews: [String: String] = [:]

            for item in items {
                guard let id = item["id"] as? String,
                      let name = item["name"] as? String,
                      let category = item["category"] as? String else { continue }

                var palette: ASCManager.AppShotTemplate.Palette?
                if let p = item["palette"] as? [String: Any] {
                    palette = ASCManager.AppShotTemplate.Palette(
                        id: p["id"] as? String ?? id,
                        name: p["name"] as? String ?? name,
                        background: p["background"] as? String
                    )
                }

                parsedTemplates.append(ASCManager.AppShotTemplate(
                    id: id, name: name, category: category,
                    description: item["description"] as? String ?? "",
                    deviceCount: item["deviceCount"] as? Int ?? 1,
                    palette: palette
                ))

                if let html = item["previewHTML"] as? String {
                    previews[id] = html
                }
            }

            templates = parsedTemplates
            templatePreviews = previews
            if selectedTemplateId == nil, let first = parsedTemplates.first {
                selectedTemplateId = first.id
            }

            async let themesResult = ASCManager.appShotsThemesList()
            themes = (try? await themesResult) ?? []

            galleryHTML = buildGalleryHTML()

            // Load device frames
            loadFrameInsets()
        } catch {
            generationError = "Failed to load: \(error.localizedDescription)"
        }
        isLoadingGallery = false
    }

    private func loadFrameInsets() {
        let bundle = Bundle.appResources
        guard let url = bundle.url(forResource: "insets", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Int]] else { return }
        var insets: [String: FrameInset] = [:]
        for (name, vals) in json {
            guard bundle.url(forResource: name, withExtension: "png") != nil else { continue }
            insets[name] = FrameInset(
                outputWidth: vals["outputWidth"] ?? 0,
                outputHeight: vals["outputHeight"] ?? 0,
                screenInsetX: vals["screenInsetX"] ?? 0,
                screenInsetY: vals["screenInsetY"] ?? 0
            )
        }
        frameInsets = insets
        availableDevices = insets.keys.sorted()
        if !availableDevices.isEmpty && !availableDevices.contains(selectedDevice) {
            selectedDevice = availableDevices.first(where: { $0.contains("16 Pro Max") }) ?? availableDevices[0]
        }
    }

    // MARK: - Gallery HTML

    private func buildGalleryHTML() -> String {
        let categories = orderedCategories()
        var sections = ""

        for category in categories {
            let catTemplates = templates.filter { $0.category == category }
            var cards = ""
            for t in catTemplates {
                let escaped = escapeForSrcdoc(templatePreviews[t.id] ?? "")
                let bg = t.palette?.background ?? "#222"
                let devLabel = t.deviceCount > 1 ? "\(t.deviceCount) devices" : ""
                cards += """
                <div class="c" data-id="\(t.id)" onclick="sel('\(t.id)')">
                  <div class="p" style="background:\(bg)">
                    <iframe srcdoc="\(escaped)" sandbox="allow-same-origin" scrolling="no"></iframe>
                  </div>
                  <div class="i"><div class="n">\(t.name)</div>\(devLabel.isEmpty ? "" : "<div class=\"m\">\(devLabel)</div>")</div>
                </div>
                """
            }
            sections += """
            <div class="cat" data-cat="\(category)">
              <div class="ct">\(category.capitalized)</div>
              <div class="g">\(cards)</div>
            </div>
            """
        }

        let catsJSON = "[" + categories.map { "'\($0)'" }.joined(separator: ",") + "]"

        return """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <style>
        *{margin:0;padding:0;box-sizing:border-box}
        body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;background:#1a1a1a;color:#fff;padding:16px 20px;-webkit-user-select:none}
        .pills{display:flex;gap:6px;flex-wrap:wrap;margin-bottom:16px;position:sticky;top:0;z-index:10;background:#1a1a1a;padding:4px 0 12px}
        .pill{padding:5px 14px;border:1px solid rgba(255,255,255,0.1);border-radius:20px;font-size:11px;font-weight:500;cursor:pointer;background:transparent;color:rgba(255,255,255,0.55);transition:all 0.15s}
        .pill:hover{border-color:#3b82f6;color:#3b82f6}
        .pill.on{background:#2563EB;color:#fff;border-color:#2563EB}
        .cat{margin-bottom:20px}
        .ct{font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:0.1em;color:rgba(255,255,255,0.35);margin-bottom:8px}
        .g{display:grid;grid-template-columns:repeat(auto-fill,minmax(160px,1fr));gap:10px}
        .c{border-radius:10px;overflow:hidden;cursor:pointer;border:2px solid rgba(255,255,255,0.06);transition:all 0.15s;background:#111}
        .c:hover{border-color:rgba(255,255,255,0.2);transform:translateY(-1px);box-shadow:0 4px 16px rgba(0,0,0,0.4)}
        .c.on{border-color:#2563EB;box-shadow:0 0 0 1px #2563EB,0 4px 16px rgba(37,99,235,0.25)}
        .p{width:100%;aspect-ratio:9/19.5;position:relative;overflow:hidden}
        .p iframe{width:100%;height:100%;border:none;pointer-events:none}
        .i{padding:7px 9px}
        .n{font-size:11px;font-weight:600;color:rgba(255,255,255,0.85)}
        .m{font-size:9px;color:rgba(255,255,255,0.35);margin-top:1px}
        </style></head><body>
        <div class="pills" id="pp"></div>
        <div id="gl">\(sections)</div>
        <script>
        var ac='all',cats=['all'].concat(\(catsJSON));
        var pp=document.getElementById('pp');
        pp.innerHTML=cats.map(function(c){return '<button class=\"pill'+(c==='all'?' on':'')+
          '\" onclick=\"fc(\\''+c+'\\')\">'+(c==='all'?'All':c.charAt(0).toUpperCase()+c.slice(1))+'</button>'}).join('');
        function fc(c){ac=c;pp.querySelectorAll('.pill').forEach(function(p){
          p.classList.toggle('on',p.textContent.toLowerCase()===c||(c==='all'&&p.textContent==='All'))});
          document.querySelectorAll('.cat').forEach(function(e){e.style.display=(c==='all'||e.dataset.cat===c)?'':'none'})}
        function sel(id){document.querySelectorAll('.c').forEach(function(c){c.classList.toggle('on',c.dataset.id===id)});
          window.webkit.messageHandlers.templateSelected.postMessage(id)}
        function setSelected(id){document.querySelectorAll('.c').forEach(function(c){c.classList.toggle('on',c.dataset.id===id)})}
        </script></body></html>
        """
    }

    private func escapeForSrcdoc(_ html: String) -> String {
        html.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func orderedCategories() -> [String] {
        let order = ["bold", "minimal", "elegant", "professional", "playful", "showcase", "custom"]
        let present = Set(templates.map(\.category))
        let ordered = order.filter { present.contains($0) }
        let remaining = present.subtracting(ordered).sorted()
        return ordered + remaining
    }

    private func extractJSON(from output: String) -> String {
        for line in output.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("{") { return trimmed }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
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
            DispatchQueue.main.async { loadSourceScreenshot(from: url) }
        }
    }

    private func loadSourceScreenshot(from url: URL) {
        guard let image = NSImage(contentsOf: url) else {
            importError = "Could not load image."
            return
        }
        sourceImage = image
        sourceImagePath = url.path
        generatedImage = nil
        generatedImagePath = nil
        generationError = nil
        showResult = false
        updateFramedPreview()
    }

    private func generate() async {
        guard var screenshotPath = sourceImagePath,
              let templateId = selectedTemplateId else { return }

        isGenerating = true
        generationError = nil
        generatedImage = nil
        generatedImagePath = nil

        if let dir = outputDir {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        // Composite bezel onto source screenshot if enabled
        if withFrame, let framedPath = compositeBezel(screenshotPath: screenshotPath) {
            screenshotPath = framedPath
        }

        let timestamp = Int(Date().timeIntervalSince1970)
        let outputPath = outputDir.map { "\($0)/shot_\(timestamp).png" }

        do {
            let resultPath: String
            if let themeId = selectedThemeId {
                resultPath = try await ASCManager.appShotsThemesApply(
                    themeId: themeId, templateId: templateId, screenshot: screenshotPath,
                    headline: headline.isEmpty ? nil : headline,
                    subtitle: subtitle.isEmpty ? nil : subtitle,
                    imageOutput: outputPath
                )
            } else {
                resultPath = try await ASCManager.appShotsTemplatesApply(
                    templateId: templateId, screenshot: screenshotPath,
                    headline: headline, subtitle: subtitle.isEmpty ? nil : subtitle,
                    imageOutput: outputPath
                )
            }

            let expandedPath = (resultPath as NSString).expandingTildeInPath
            Log("[AppShots] resultPath=\(resultPath) expanded=\(expandedPath) exists=\(FileManager.default.fileExists(atPath: expandedPath))")
            if let image = NSImage(contentsOfFile: expandedPath) {
                generatedImage = image
                generatedImagePath = expandedPath
                showResult = true
                Log("[AppShots] success showResult=true")
            } else {
                generationError = "File not found: \(expandedPath)"
                Log("[AppShots] file not loadable at \(expandedPath)")
            }
        } catch {
            generationError = error.localizedDescription
            Log("[AppShots] error: \(error)")
        }

        isGenerating = false
        Log("[AppShots] done showResult=\(showResult) hasImage=\(generatedImage != nil) error=\(generationError ?? "nil")")
    }

    // MARK: - Bezel Compositing

    /// Composite a device frame bezel onto the source screenshot, returning the path to the composited image.
    private func compositeBezel(screenshotPath: String) -> String? {
        guard let inset = frameInsets[selectedDevice] else { return nil }

        guard let frameURL = Bundle.appResources.url(forResource: selectedDevice, withExtension: "png"),
              let frameImage = NSImage(contentsOf: frameURL),
              let frameCG = frameImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let screenshotImage = NSImage(contentsOfFile: screenshotPath),
              let screenshotCG = screenshotImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        let fw = inset.outputWidth
        let fh = inset.outputHeight
        let ix = inset.screenInsetX
        let iy = inset.screenInsetY
        let sw = fw - ix * 2
        let sh = fh - iy * 2

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: fw, height: fh,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // CoreGraphics has origin at bottom-left, so flip Y
        // Draw screenshot into the screen area
        let screenRect = CGRect(x: ix, y: fh - iy - sh, width: sw, height: sh)

        // Clip to rounded rect for screen corners
        let cornerRadius = CGFloat(fw) * 0.055
        let roundedPath = CGPath(roundedRect: screenRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        ctx.saveGState()
        ctx.addPath(roundedPath)
        ctx.clip()
        ctx.draw(screenshotCG, in: screenRect)
        ctx.restoreGState()

        // Draw frame on top
        ctx.draw(frameCG, in: CGRect(x: 0, y: 0, width: fw, height: fh))

        guard let composited = ctx.makeImage() else { return nil }

        // Save to temp file
        let tmpPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("blitz-framed-\(Int(Date().timeIntervalSince1970)).png").path
        let bitmap = NSBitmapImageRep(cgImage: composited)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else { return nil }
        try? pngData.write(to: URL(fileURLWithPath: tmpPath))
        return tmpPath
    }
}

// MARK: - Frame Inset Model

struct FrameInset {
    let outputWidth: Int
    let outputHeight: Int
    let screenInsetX: Int
    let screenInsetY: Int
}

// MARK: - WKWebView Wrapper

struct AppShotsGalleryWebView: NSViewRepresentable {
    let html: String
    let selectedTemplateId: String?
    let onSelectTemplate: (String) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "templateSelected")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if let id = selectedTemplateId {
            webView.evaluateJavaScript("if(typeof setSelected==='function')setSelected('\(id)')") { _, _ in }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelectTemplate) }

    class Coordinator: NSObject, WKScriptMessageHandler {
        weak var webView: WKWebView?
        let onSelect: (String) -> Void
        init(onSelect: @escaping (String) -> Void) { self.onSelect = onSelect }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "templateSelected", let id = message.body as? String {
                DispatchQueue.main.async { self.onSelect(id) }
            }
        }
    }
}
