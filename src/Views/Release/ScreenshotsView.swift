import SwiftUI
import UniformTypeIdentifiers

// MARK: - Models

private enum ScreenshotDeviceType: String, CaseIterable, Identifiable {
    case iPhone
    case iPad

    var id: String { rawValue }

    var label: String {
        switch self {
        case .iPhone: "iPhone 6.5\""
        case .iPad: "iPad Pro 12.9\""
        }
    }

    var requiredWidth: Int {
        switch self {
        case .iPhone: 1242
        case .iPad: 2048
        }
    }

    var requiredHeight: Int {
        switch self {
        case .iPhone: 2688
        case .iPad: 2732
        }
    }

    var ascDisplayType: String {
        switch self {
        case .iPhone: "APP_IPHONE_67"
        case .iPad: "APP_IPAD_PRO_3GEN_129"
        }
    }

    var dimensionLabel: String {
        "\(requiredWidth) \u{00d7} \(requiredHeight)"
    }
}

private struct LocalScreenshot: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let image: NSImage

    static func == (lhs: LocalScreenshot, rhs: LocalScreenshot) -> Bool {
        lhs.id == rhs.id
    }
}

private enum ScreenshotCategory {
    case preview   // indices 0–2
    case appStore  // indices 3–9
    case ignored   // indices 10+

    var color: Color {
        switch self {
        case .preview: .blue
        case .appStore: .green
        case .ignored: .gray
        }
    }

    var label: String {
        switch self {
        case .preview: "Preview"
        case .appStore: "App Store"
        case .ignored: "Not uploaded"
        }
    }

    static func from(index: Int) -> ScreenshotCategory {
        if index < 3 { return .preview }
        if index < 10 { return .appStore }
        return .ignored
    }
}

// MARK: - View

struct ScreenshotsView: View {
    var appState: AppState

    private var asc: ASCManager { appState.ascManager }

    @State private var selectedDevice: ScreenshotDeviceType = .iPhone
    @State private var iphoneScreenshots: [LocalScreenshot] = []
    @State private var ipadScreenshots: [LocalScreenshot] = []
    @State private var draggedScreenshot: LocalScreenshot?
    @State private var importError: String?
    @State private var isUploading = false
    @State private var uploadDone = false

    private var screenshotsBinding: Binding<[LocalScreenshot]> {
        selectedDevice == .iPhone ? $iphoneScreenshots : $ipadScreenshots
    }

    private var screenshots: [LocalScreenshot] {
        screenshotsBinding.wrappedValue
    }

    /// ASC screenshots already uploaded for the selected device type
    private var ascScreenshots: [ASCScreenshot] {
        let displayType = selectedDevice.ascDisplayType
        guard let set = asc.screenshotSets.first(where: {
            $0.attributes.screenshotDisplayType == displayType
        }) else { return [] }
        return asc.screenshots[set.id] ?? []
    }

    var body: some View {
        ASCCredentialGate(
            ascManager: asc,
            projectId: appState.activeProjectId ?? "",
            bundleId: appState.activeProject?.metadata.bundleIdentifier
        ) {
            ASCTabContent(asc: asc, tab: .screenshots) {
                screenshotsContent
            }
        }
        .task { await asc.fetchTabData(.screenshots) }
    }

    // MARK: - Content

    @ViewBuilder
    private var screenshotsContent: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if screenshots.isEmpty && ascScreenshots.isEmpty {
                emptyState
            } else if screenshots.isEmpty {
                // Only ASC screenshots exist — show them with the upload prompt
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ascUploadedSection
                    }
                    .padding(20)
                }
            } else {
                legendBar
                Divider()
                screenshotGrid
            }
        }
        .alert("Import Error", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            Picker("Device", selection: $selectedDevice) {
                ForEach(ScreenshotDeviceType.allCases) { device in
                    Text(device.label).tag(device)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)

            Spacer()

            if !screenshots.isEmpty {
                Text("\(screenshots.count) screenshot\(screenshots.count == 1 ? "" : "s")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Button {
                openFilePicker()
            } label: {
                Label("Add Screenshots", systemImage: "plus.rectangle.on.rectangle")
            }

            if !screenshots.isEmpty {
                Button(role: .destructive) {
                    withAnimation { screenshotsBinding.wrappedValue.removeAll() }
                    uploadDone = false
                } label: {
                    Label("Clear All", systemImage: "trash")
                }

                Button {
                    Task { await uploadToASC() }
                } label: {
                    if isUploading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label(uploadDone ? "Uploaded" : "Upload to ASC", systemImage: uploadDone ? "checkmark.circle" : "arrow.up.circle")
                    }
                }
                .disabled(isUploading || screenshots.isEmpty || uploadDone)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.background.secondary)
    }

    // MARK: - Legend

    private var legendBar: some View {
        HStack(spacing: 16) {
            legendDot(color: .blue, label: "App Preview (1\u{2013}3)")
            legendDot(color: .green, label: "App Store (4\u{2013}10)")
            legendDot(color: .gray.opacity(0.5), label: "Not uploaded")
            Spacer()
            Text("Drag to reorder")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .background(.background)
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color.opacity(0.2))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(color, lineWidth: 1.5))
                .frame(width: 14, height: 14)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Empty

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Screenshots", systemImage: "photo.on.rectangle")
        } description: {
            Text("Add \(selectedDevice.label) screenshots (\(selectedDevice.dimensionLabel)) to manage your App Store listing.")
        } actions: {
            Button("Add Screenshots") { openFilePicker() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Grid

    private var screenshotGrid: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 160, maximum: 220))],
                        spacing: 12
                    ) {
                        ForEach(Array(screenshots.enumerated()), id: \.element.id) { index, screenshot in
                            screenshotCard(screenshot, index: index)
                                .onDrag {
                                    draggedScreenshot = screenshot
                                    return NSItemProvider(object: screenshot.id.uuidString as NSString)
                                }
                                .onDrop(
                                    of: [.text],
                                    delegate: ScreenshotReorderDelegate(
                                        item: screenshot,
                                        items: screenshotsBinding,
                                        draggedItem: $draggedScreenshot
                                    )
                                )
                        }
                    }

                    if !ascScreenshots.isEmpty {
                        ascUploadedSection
                    }
                }
                .padding(20)
            }

            if let error = asc.writeError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(.red.opacity(0.08))
            }
        }
    }

    // MARK: - ASC Uploaded Section

    private var ascUploadedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Uploaded to App Store Connect")
                    .font(.callout.bold())
                Text("\u{2014} \(ascScreenshots.count) screenshot\(ascScreenshots.count == 1 ? "" : "s")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 160, maximum: 220))],
                spacing: 12
            ) {
                ForEach(ascScreenshots) { shot in
                    ascScreenshotTile(shot)
                }
            }
        }
    }

    private func ascScreenshotTile(_ shot: ASCScreenshot) -> some View {
        VStack(spacing: 6) {
            Group {
                if let url = shot.imageURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().aspectRatio(contentMode: .fit)
                        case .failure:
                            Image(systemName: "photo")
                                .font(.title)
                                .foregroundStyle(.secondary)
                        default:
                            ProgressView()
                        }
                    }
                } else {
                    Image(systemName: "photo")
                        .font(.title)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 200)
            .frame(maxWidth: .infinity)
            .background(Color(.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if let name = shot.attributes.fileName {
                Text(name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let state = shot.attributes.assetDeliveryState?.state {
                Text(state)
                    .font(.caption2)
                    .foregroundStyle(state == "COMPLETE" ? .green : .orange)
            }
        }
    }

    // MARK: - Card

    private func screenshotCard(_ screenshot: LocalScreenshot, index: Int) -> some View {
        let category = ScreenshotCategory.from(index: index)

        return VStack(spacing: 4) {
            ZStack(alignment: .topLeading) {
                Image(nsImage: screenshot.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 240)

                // Index badge
                Text("\(index + 1)")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(category.color)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(6)
            }
            .frame(maxWidth: .infinity)
            .background(Color(.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(category.color, lineWidth: 2)
            )
            .opacity(category == .ignored ? 0.45 : 1.0)

            Text(category.label)
                .font(.caption2)
                .foregroundStyle(category.color)

            Text(screenshot.url.lastPathComponent)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contextMenu {
            Button("Remove", role: .destructive) {
                withAnimation {
                    screenshotsBinding.wrappedValue.removeAll { $0.id == screenshot.id }
                }
            }
        }
    }

    // MARK: - Actions

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Select \(selectedDevice.label) screenshots (\(selectedDevice.dimensionLabel))"

        guard panel.runModal() == .OK else { return }

        var errors: [String] = []

        for url in panel.urls {
            guard let image = NSImage(contentsOf: url) else {
                errors.append("\(url.lastPathComponent): could not load image")
                continue
            }

            // Get pixel dimensions
            var pixelWidth = 0
            var pixelHeight = 0
            if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
                pixelWidth = rep.pixelsWide
                pixelHeight = rep.pixelsHigh
            } else if let tiffData = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiffData) {
                pixelWidth = bitmap.pixelsWide
                pixelHeight = bitmap.pixelsHigh
            }

            guard pixelWidth == selectedDevice.requiredWidth && pixelHeight == selectedDevice.requiredHeight else {
                errors.append(
                    "\(url.lastPathComponent): \(pixelWidth)\u{00d7}\(pixelHeight) \u{2014} need \(selectedDevice.dimensionLabel)"
                )
                continue
            }

            // Skip duplicates (same file path)
            let binding = screenshotsBinding
            if binding.wrappedValue.contains(where: { $0.url == url }) {
                continue
            }

            binding.wrappedValue.append(LocalScreenshot(id: UUID(), url: url, image: image))
        }

        uploadDone = false

        if !errors.isEmpty {
            importError = "Failed to import \(errors.count) file\(errors.count == 1 ? "" : "s"):\n\n"
                + errors.joined(separator: "\n")
        }
    }

    private func uploadToASC() async {
        let toUpload = Array(screenshots.prefix(10))
        guard !toUpload.isEmpty else { return }

        isUploading = true

        let paths = toUpload.map { $0.url.path }
        await asc.uploadScreenshots(
            paths: paths,
            displayType: selectedDevice.ascDisplayType,
            locale: "en-US"
        )

        isUploading = false

        if asc.writeError == nil {
            uploadDone = true
        }
    }
}

// MARK: - Drop Delegate

private struct ScreenshotReorderDelegate: DropDelegate {
    let item: LocalScreenshot
    @Binding var items: [LocalScreenshot]
    @Binding var draggedItem: LocalScreenshot?

    func performDrop(info: DropInfo) -> Bool {
        draggedItem = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let draggedItem,
              let fromIndex = items.firstIndex(where: { $0.id == draggedItem.id }),
              let toIndex = items.firstIndex(where: { $0.id == item.id }),
              fromIndex != toIndex else { return }
        withAnimation(.default) {
            items.move(
                fromOffsets: IndexSet(integer: fromIndex),
                toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
            )
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        true
    }
}
