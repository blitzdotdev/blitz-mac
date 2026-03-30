import SwiftUI
import UniformTypeIdentifiers
import ImageIO

// MARK: - Models

private enum ScreenshotDeviceType: String, CaseIterable, Identifiable {
    case iPhone
    case iPad
    case mac

    var id: String { rawValue }

    var label: String {
        switch self {
        case .iPhone: "iPhone 6.7\""
        case .iPad: "iPad Pro 12.9\""
        case .mac: "Mac"
        }
    }

    var ascDisplayType: String {
        switch self {
        case .iPhone: "APP_IPHONE_67"
        case .iPad: "APP_IPAD_PRO_3GEN_129"
        case .mac: "APP_DESKTOP"
        }
    }

    var dimensionLabel: String {
        switch self {
        case .iPhone: "1290\u{00d7}2796, 1284\u{00d7}2778, 1242\u{00d7}2688, or 1260\u{00d7}2736"
        case .iPad: "2048 \u{00d7} 2732"
        case .mac: "1280\u{00d7}800, 1440\u{00d7}900, 2560\u{00d7}1600, or 2880\u{00d7}1800"
        }
    }

    /// Validate pixel dimensions for this device type
    func validateDimensions(width: Int, height: Int) -> Bool {
        switch self {
        case .iPhone:
            let validSizes: Set<String> = [
                "1290x2796", "1284x2778", "1242x2688", "1260x2736"
            ]
            return validSizes.contains("\(width)x\(height)")
        case .iPad:
            return width == 2048 && height == 2732
        case .mac:
            let validSizes: Set<String> = [
                "1280x800", "1440x900", "2560x1600", "2880x1800"
            ]
            return validSizes.contains("\(width)x\(height)")
        }
    }

    /// Device types applicable for a given platform
    static func types(for platform: ProjectPlatform) -> [ScreenshotDeviceType] {
        switch platform {
        case .iOS: return [.iPhone, .iPad]
        case .macOS: return [.mac]
        }
    }
}

// MARK: - View

struct ScreenshotsView: View {
    var appState: AppState

    private var asc: ASCManager { appState.ascManager }
    private var platform: ProjectPlatform { appState.activeProject?.platform ?? .iOS }

    @State private var selectedDevice: ScreenshotDeviceType = .iPhone
    @State private var selectedAssetId: UUID?         // selected in asset library
    @State private var selectedTrackIndex: Int?       // selected in track
    @State private var draggedAssetId: UUID?          // drag from asset library
    @State private var draggedTrackIndex: Int?        // drag within track
    @State private var importError: String?
    @State private var isDropTargeted = false

    private var availableDeviceTypes: [ScreenshotDeviceType] {
        ScreenshotDeviceType.types(for: platform)
    }

    private var currentLocale: String {
        if let selectedScreenshotsLocale = asc.selectedScreenshotsLocale,
           asc.localizations.contains(where: { $0.attributes.locale == selectedScreenshotsLocale }) {
            return selectedScreenshotsLocale
        }
        // fallback
        return asc.localizations.first?.attributes.locale ?? "en-US"
    }

    private var selectedLocaleBinding: Binding<String> {
        Binding(
            get: { currentLocale },
            set: { newValue in
                asc.selectedScreenshotsLocale = newValue
                Task { await loadSelectedLocaleData() }
            }
        )
    }

    private var selectedVersionBinding: Binding<String> {
        Binding(
            get: { asc.selectedVersion?.id ?? "" },
            set: { newValue in
                guard !newValue.isEmpty else { return }
                asc.prepareForVersionSelection(newValue)
                Task { await loadData() }
            }
        )
    }

    private var currentTrack: [TrackSlot?] {
        asc.trackSlotsForDisplayType(selectedDevice.ascDisplayType, locale: currentLocale)
    }

    private var hasChanges: Bool {
        asc.hasUnsavedChanges(displayType: selectedDevice.ascDisplayType, locale: currentLocale)
    }

    private var filledSlotCount: Int {
        currentTrack.compactMap { $0 }.count
    }

    var body: some View {
        ASCCredentialGate(
            appState: appState,
            ascManager: asc,
            projectId: appState.activeProjectId ?? "",
            bundleId: appState.activeProject?.metadata.bundleIdentifier
        ) {
            ASCTabContent(appState: appState, asc: asc, tab: .screenshots, platform: appState.activeProject?.platform ?? .iOS) {
                VStack(spacing: 0) {
                    if asc.app != nil {
                        ASCVersionPickerBar(
                            asc: asc,
                            selection: selectedVersionBinding
                        ) {
                            if !asc.localizations.isEmpty {
                                Picker("Locale", selection: selectedLocaleBinding) {
                                    ForEach(asc.localizations) { localization in
                                        Text(localization.attributes.locale).tag(localization.attributes.locale)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 160)
                            }
                            ASCTabRefreshButton(asc: asc, tab: .screenshots, helpText: "Refresh screenshots")
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                    }

                    Divider()

                    HStack(spacing: 0) {
                        assetLibraryPanel
                            .frame(width: 220)
                        Divider()
                        VStack(spacing: 0) {
                            detailView
                            Divider()
                            trackView
                                .frame(minHeight: 200)
                        }
                    }
                }
            }
        }
        .task(id: "\(appState.activeProjectId ?? ""):\(asc.credentialActivationRevision)") {
            await loadData()
        }
        .onChange(of: selectedDevice) { _, _ in loadTrackForDevice() }
        .alert("Import Error", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    // MARK: - Asset Library Panel (left)

    private var assetLibraryPanel: some View {
        VStack(spacing: 0) {
            // Device picker
            VStack(spacing: 8) {
                if availableDeviceTypes.count > 1 {
                    ForEach(availableDeviceTypes) { device in
                        Button {
                            selectedDevice = device
                        } label: {
                            HStack {
                                Text(device.label)
                                    .font(.callout)
                                Spacer()
                                if asc.hasUnsavedChanges(displayType: device.ascDisplayType, locale: currentLocale) {
                                    Circle()
                                        .fill(.orange)
                                        .frame(width: 6, height: 6)
                                }
                                if device == selectedDevice {
                                    Image(systemName: "checkmark")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(device == selectedDevice ? Color.accentColor.opacity(0.12) : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                } else if let device = availableDeviceTypes.first {
                    Text(device.label)
                        .font(.callout.bold())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)

            Divider()

            // Asset list
            if asc.localScreenshotAssets.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("No local assets")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Add files to get started")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(asc.localScreenshotAssets) { asset in
                            assetRow(asset)
                        }
                    }
                    .padding(8)
                }
            }

            Divider()

            // Add button
            Button {
                openFilePicker()
            } label: {
                Label("Add Files", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .padding(10)
        }
        .background(.background)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor, lineWidth: 2)
                .opacity(isDropTargeted ? 1 : 0)
                .padding(2)
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleFinderDrop(providers)
        }
    }

    private func assetRow(_ asset: LocalScreenshotAsset) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: asset.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 36, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            Text(asset.fileName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(selectedAssetId == asset.id ? Color.accentColor.opacity(0.15) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture {
            selectedAssetId = asset.id
            selectedTrackIndex = nil
        }
        .contextMenu {
            Button("Delete", role: .destructive) {
                deleteAsset(asset)
            }
        }
        .onDrag {
            draggedAssetId = asset.id
            return NSItemProvider(object: asset.url.path as NSString)
        }
    }

    // MARK: - Detail View (top right)

    private var detailView: some View {
        Group {
            if let trackIdx = selectedTrackIndex, let slot = currentTrack[trackIdx] {
                // Show selected track slot
                slotDetailImage(slot)
            } else if let assetId = selectedAssetId,
                      let asset = asc.localScreenshotAssets.first(where: { $0.id == assetId }) {
                // Show selected asset
                Image(nsImage: asset.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(20)
            } else {
                ContentUnavailableView {
                    Label("No Selection", systemImage: "photo.on.rectangle")
                } description: {
                    Text("Select an asset or track slot to preview")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.controlBackgroundColor))
    }

    @ViewBuilder
    private func slotDetailImage(_ slot: TrackSlot) -> some View {
        if let ascShot = slot.ascScreenshot, ascShot.hasError {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.red)
                Text("Screenshot Error")
                    .font(.headline)
                    .foregroundStyle(.red)
                if let desc = ascShot.errorDescription {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                }
                Text("Delete and re-upload this screenshot.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        } else if let image = slot.localImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(20)
        } else if let ascShot = slot.ascScreenshot, let url = ascShot.imageURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fit).padding(20)
                case .failure:
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                default:
                    ProgressView()
                }
            }
        } else {
            Image(systemName: "photo")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Track View (bottom right)

    private var trackView: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                HStack(spacing: 4) {
                    legendDot(color: .green, label: "Synced")
                    legendDot(color: .orange, label: "Changed")
                }

                Spacer()

                Text("\(filledSlotCount)/10 slots")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Button {
                    Task { await save() }
                } label: {
                    if asc.isSyncing {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Saving...")
                        }
                    } else {
                        Label("Save", systemImage: "arrow.up.circle")
                    }
                }
                .disabled(!hasChanges || asc.isSyncing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.background.secondary)

            if let error = asc.writeError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .padding(6)
                .frame(maxWidth: .infinity)
                .background(.red.opacity(0.08))
            }

            Divider()

            // Track slots
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 8) {
                    ForEach(0..<10, id: \.self) { index in
                        trackSlotView(index: index)
                    }
                }
                .padding(12)
            }
        }
    }

    private func trackSlotView(index: Int) -> some View {
        let slot = currentTrack[index]
        let saved = asc.savedTrackStateForDisplayType(selectedDevice.ascDisplayType, locale: currentLocale)[index]
        let isSynced = slot?.id == saved?.id && slot != nil
        let hasError = slot?.ascScreenshot?.hasError == true

        return VStack(spacing: 4) {
            ZStack(alignment: .topLeading) {
                if let slot {
                    // Slot has content
                    Group {
                        if hasError {
                            // Error state: portrait phone frame with red outline and error icon
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(.controlBackgroundColor))
                                .aspectRatio(9.0/19.5, contentMode: .fit)
                                .overlay(
                                    VStack(spacing: 4) {
                                        Image(systemName: "exclamationmark.circle.fill")
                                            .font(.callout)
                                            .foregroundStyle(.red)
                                    }
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(.red, lineWidth: 1.5)
                                )
                        } else if let image = slot.localImage {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        } else if let ascShot = slot.ascScreenshot, let url = ascShot.imageURL {
                            AsyncImage(url: url) { phase in
                                switch phase {
                                case .success(let img):
                                    img.resizable().aspectRatio(contentMode: .fit)
                                case .failure:
                                    Image(systemName: "photo")
                                        .foregroundStyle(.secondary)
                                default:
                                    ProgressView().controlSize(.small)
                                }
                            }
                        }
                    }
                    .frame(width: 110, height: 110)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    // Delete button (top-right)
                    Button {
                        withAnimation {
                            asc.removeFromTrack(
                                displayType: selectedDevice.ascDisplayType,
                                slotIndex: index,
                                locale: currentLocale
                            )
                        }
                        if selectedTrackIndex == index { selectedTrackIndex = nil }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.white, .red)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(4)
                } else {
                    // Empty slot placeholder
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(.controlBackgroundColor))
                        .frame(width: 110, height: 110)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
                                .foregroundStyle(.quaternary)
                        )
                }

                // Index badge
                Text("\(index + 1)")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(hasError ? Color.red : (slot != nil ? (isSynced ? Color.green : Color.orange) : Color.gray.opacity(0.5)))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(4)
            }
            .frame(width: 130, height: 120)
            .background(Color(.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(hasError ? Color.red : (slot != nil ? (isSynced ? Color.green : Color.orange) : .clear), lineWidth: 2)
            )
            .onTapGesture {
                if slot != nil {
                    selectedTrackIndex = index
                    selectedAssetId = nil
                }
            }
            .onDrop(of: [.text], delegate: TrackSlotDropDelegate(
                targetIndex: index,
                displayType: selectedDevice.ascDisplayType,
                locale: currentLocale,
                asc: asc,
                localAssets: asc.localScreenshotAssets,
                draggedAssetId: $draggedAssetId,
                draggedTrackIndex: $draggedTrackIndex,
                importError: $importError
            ))
            .onDrag {
                if slot != nil {
                    draggedTrackIndex = index
                    return NSItemProvider(object: "\(index)" as NSString)
                }
                return NSItemProvider()
            }

            if slot != nil, hasError {
                Text("Error")
                    .font(.caption2)
                    .foregroundStyle(.red)
            } else if slot != nil {
                Text(isSynced ? "Synced" : "Changed")
                    .font(.caption2)
                    .foregroundStyle(isSynced ? .green : .orange)
            }
        }
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

    // MARK: - Actions

    private func loadData() async {
        // Default device for platform
        if let first = availableDeviceTypes.first, !availableDeviceTypes.contains(selectedDevice) {
            selectedDevice = first
        }

        if let projectId = appState.activeProjectId {
            asc.scanLocalAssets(projectId: projectId)
        }

        await asc.ensureTabData(.screenshots)
        if asc.selectedScreenshotsLocale == nil {
            asc.selectedScreenshotsLocale = asc.localizations.first?.attributes.locale
        }
        await loadSelectedLocaleData()
    }

    private func loadSelectedLocaleData(force: Bool = false) async {
        guard !currentLocale.isEmpty else { return }
        await asc.loadScreenshots(locale: currentLocale, force: force)
        loadTrackForDevice(force: force)
    }

    private func loadTrackForDevice(force: Bool = false) {
        let displayType = selectedDevice.ascDisplayType
        let locale = currentLocale
        if force || !asc.hasTrackState(displayType: displayType, locale: locale) {
            asc.loadTrackFromASC(displayType: displayType, locale: locale)
        }
    }

    private func deleteAsset(_ asset: LocalScreenshotAsset) {
        let fm = FileManager.default
        try? fm.removeItem(at: asset.url)
        if selectedAssetId == asset.id { selectedAssetId = nil }
        if let projectId = appState.activeProjectId {
            asc.scanLocalAssets(projectId: projectId)
        }
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .webP]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Select screenshot files to add to the asset library"

        guard panel.runModal() == .OK else { return }

        guard let projectId = appState.activeProjectId else {
            importError = "No active project"
            return
        }

        importFiles(urls: panel.urls, projectId: projectId)
    }

    /// Load an image from a URL, using CGImageSource as fallback for formats NSImage may not handle (e.g. WebP).
    private func loadImage(from url: URL) -> NSImage? {
        // Try NSImage first
        if let image = NSImage(contentsOf: url), !image.representations.isEmpty {
            return image
        }
        // Fallback: CGImageSource (handles WebP on macOS 11+)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Copy image files into the screenshots directory, converting non-PNG formats to PNG.
    private func importFiles(urls: [URL], projectId: String) {
        let destDir = BlitzPaths.screenshots(projectId: projectId)
        let fm = FileManager.default
        try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        var errors: [String] = []
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if ext == "png" {
                // Copy PNG directly
                let dest = destDir.appendingPathComponent(url.lastPathComponent)
                do {
                    if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                    try fm.copyItem(at: url, to: dest)
                } catch {
                    errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            } else {
                // Convert JPEG/WebP to PNG
                guard let image = loadImage(from: url) else {
                    errors.append("\(url.lastPathComponent): unsupported format or could not load image")
                    continue
                }
                let pngName = url.deletingPathExtension().lastPathComponent + ".png"
                let dest = destDir.appendingPathComponent(pngName)
                do {
                    guard let tiff = image.tiffRepresentation,
                          let bitmap = NSBitmapImageRep(data: tiff),
                          let pngData = bitmap.representation(using: .png, properties: [:]) else {
                        errors.append("\(url.lastPathComponent): failed to convert to PNG")
                        continue
                    }
                    if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                    try pngData.write(to: dest)
                } catch {
                    errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }

        asc.scanLocalAssets(projectId: projectId)

        if !errors.isEmpty {
            importError = "Failed to import \(errors.count) file\(errors.count == 1 ? "" : "s"):\n\n"
                + errors.joined(separator: "\n")
        }
    }

    private func handleFinderDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let projectId = appState.activeProjectId else { return false }

        let validExtensions: Set<String> = ["png", "jpg", "jpeg", "webp"]
        var hasValidProvider = false

        for provider in providers {
            if provider.canLoadObject(ofClass: NSURL.self) {
                hasValidProvider = true
                provider.loadObject(ofClass: NSURL.self) { reading, _ in
                    guard let url = reading as? URL,
                          url.isFileURL,
                          validExtensions.contains(url.pathExtension.lowercased()) else { return }

                    Task { @MainActor in
                        self.importFiles(urls: [url], projectId: projectId)
                    }
                }
            }
        }
        return hasValidProvider
    }

    private func save() async {
        await asc.syncTrackToASC(
            displayType: selectedDevice.ascDisplayType,
            locale: currentLocale
        )
    }
}

// MARK: - Drop Delegate

private struct TrackSlotDropDelegate: DropDelegate {
    let targetIndex: Int
    let displayType: String
    let locale: String
    let asc: ASCManager
    let localAssets: [LocalScreenshotAsset]
    @Binding var draggedAssetId: UUID?
    @Binding var draggedTrackIndex: Int?
    @Binding var importError: String?

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggedAssetId = nil
            draggedTrackIndex = nil
        }

        // Drop from asset library
        if let assetId = draggedAssetId,
           let asset = localAssets.first(where: { $0.id == assetId }) {
            let error = asc.addAssetToTrack(
                displayType: displayType,
                slotIndex: targetIndex,
                localPath: asset.url.path,
                locale: locale
            )
            if let error {
                importError = "Cannot add \(asset.fileName): \(error)"
                return false
            }
            return true
        }

        // Reorder within track
        if let fromIndex = draggedTrackIndex, fromIndex != targetIndex {
            withAnimation {
                asc.reorderTrack(
                    displayType: displayType,
                    fromIndex: fromIndex,
                    toIndex: targetIndex,
                    locale: locale
                )
            }
            return true
        }

        return false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        draggedAssetId != nil || draggedTrackIndex != nil
    }
}
