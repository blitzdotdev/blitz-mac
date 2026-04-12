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
        ASCManager.screenshotDimensionSummary(displayType: ascDisplayType) ?? "Unsupported size"
    }

    var placeholderAspectRatio: CGFloat {
        switch self {
        case .iPhone: return 9.0 / 19.5
        case .iPad: return 3.0 / 4.0
        case .mac: return 16.0 / 10.0
        }
    }

    func validateDimensions(width: Int, height: Int) -> Bool {
        ASCManager.validateDimensions(width: width, height: height, displayType: ascDisplayType) == nil
    }

    static func types(for platform: ProjectPlatform) -> [ScreenshotDeviceType] {
        switch platform {
        case .iOS: return [.iPhone, .iPad]
        case .macOS: return [.mac]
        }
    }
}

// MARK: - Preference Key for Slot Frames

private struct SlotFramePreference: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct SlotViewportFramePreference: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct DragHoverState {
    let index: Int
    var anchor: CGPoint
    var startedAt: Date
}

// MARK: - NSScrollView Finder

private struct ScrollViewFinder: NSViewRepresentable {
    @Binding var scrollView: NSScrollView?

    private static func resolveScrollView(from view: NSView) -> NSScrollView? {
        if let scrollView = view.enclosingScrollView {
            return scrollView
        }

        var current: NSView? = view
        while let candidate = current {
            if let scrollView = candidate as? NSScrollView {
                return scrollView
            }
            current = candidate.superview
        }

        return nil
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            self.scrollView = Self.resolveScrollView(from: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            self.scrollView = Self.resolveScrollView(from: nsView)
        }
    }
}

// MARK: - View

struct ScreenshotsView: View {
    var appState: AppState

    private var asc: ASCManager { appState.ascManager }
    private var platform: ProjectPlatform { appState.activeProject?.platform ?? .iOS }

    // General state
    @State private var selectedDevice: ScreenshotDeviceType = .iPhone
    @State private var importError: String?
    @State private var isDropTargeted = false

    // Drag reorder state
    @State private var dragSourceIndex: Int?
    @State private var dragViewportPos: CGPoint = .zero
    @State private var dragStartOffset: CGSize = .zero
    @State private var dropTargetIndex: Int?
    @State private var hoverState: DragHoverState?
    @State private var isActivelyDragging = false
    @State private var slotFrames: [Int: CGRect] = [:]
    @State private var slotViewportFrames: [Int: CGRect] = [:]
    @State private var dragBaseSlotFrames: [Int: CGRect] = [:]
    @State private var viewportSize: CGSize = .zero
    @State private var scrollViewRef: NSScrollView?
    @State private var lastAutoScrollTickAt: Date?

    private var availableDeviceTypes: [ScreenshotDeviceType] {
        ScreenshotDeviceType.types(for: platform)
    }

    private var currentLocale: String {
        if let selectedScreenshotsLocale = asc.selectedScreenshotsLocale,
           asc.localizations.contains(where: { $0.attributes.locale == selectedScreenshotsLocale }) {
            return selectedScreenshotsLocale
        }
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

    /// Drag position adjusted for the initial grab offset (gives slot center in viewport space)
    private var adjustedDragPos: CGPoint {
        CGPoint(x: dragViewportPos.x - dragStartOffset.width, y: dragViewportPos.y - dragStartOffset.height)
    }

    private var activeSlotFrames: [Int: CGRect] {
        dragBaseSlotFrames.isEmpty ? slotFrames : dragBaseSlotFrames
    }

    private var currentHorizontalScrollOffset: CGFloat {
        if let scrollViewRef {
            return scrollViewRef.contentView.bounds.origin.x
        }
        for index in slotFrames.keys.sorted() {
            guard let contentFrame = slotFrames[index],
                  let viewportFrame = slotViewportFrames[index] else { continue }
            return contentFrame.minX - viewportFrame.minX
        }
        return 0
    }

    private func currentDragViewportFrame() -> CGRect? {
        guard let src = dragSourceIndex,
              let sourceSize = activeSlotFrames[src]?.size,
              sourceSize.width > 0,
              sourceSize.height > 0 else {
            return nil
        }

        return CGRect(
            x: adjustedDragPos.x - sourceSize.width / 2,
            y: adjustedDragPos.y - sourceSize.height / 2,
            width: sourceSize.width,
            height: sourceSize.height
        )
    }

    private func currentDragContentCenter() -> CGPoint? {
        guard let dragViewportFrame = currentDragViewportFrame() else { return nil }
        return CGPoint(
            x: dragViewportFrame.midX + currentHorizontalScrollOffset,
            y: dragViewportFrame.midY
        )
    }

    private func occupiedIndicesForReorder() -> [Int] {
        (0..<10).filter { index in
            currentTrack[index] != nil && activeSlotFrames[index] != nil
        }
    }

    private func targetZone(
        for targetIndex: Int,
        horizontalSlack: CGFloat,
        verticalSlackFactor: CGFloat
    ) -> CGRect? {
        let orderedIndices = occupiedIndicesForReorder()
        guard let order = orderedIndices.firstIndex(of: targetIndex),
              let frame = activeSlotFrames[targetIndex] else {
            return nil
        }

        let leftBoundary: CGFloat
        if order > 0, let previousFrame = activeSlotFrames[orderedIndices[order - 1]] {
            leftBoundary = (previousFrame.midX + frame.midX) / 2
        } else {
            leftBoundary = frame.minX - (frame.width * 0.5)
        }

        let rightBoundary: CGFloat
        if order + 1 < orderedIndices.count, let nextFrame = activeSlotFrames[orderedIndices[order + 1]] {
            rightBoundary = (frame.midX + nextFrame.midX) / 2
        } else {
            rightBoundary = frame.maxX + (frame.width * 0.5)
        }

        let verticalSlack = frame.height * verticalSlackFactor
        return CGRect(
            x: leftBoundary - horizontalSlack,
            y: frame.minY - verticalSlack,
            width: (rightBoundary - leftBoundary) + (horizontalSlack * 2),
            height: frame.height + (verticalSlack * 2)
        )
    }

    // MARK: - Body

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

                    trackToolbar

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

                    GeometryReader { geometry in
                        let screenshotHeight = geometry.size.height * 0.8

                        ZStack {
                            ScrollView(.horizontal, showsIndicators: true) {
                                HStack(alignment: .center, spacing: 16) {
                                    ForEach(0..<10, id: \.self) { index in
                                        slotContainer(index: index, screenshotHeight: screenshotHeight)
                                    }
                                }
                                .background(ScrollViewFinder(scrollView: $scrollViewRef))
                                .padding(20)
                                .frame(minHeight: geometry.size.height)
                                .coordinateSpace(name: "trackContent")
                            }
                            .coordinateSpace(name: "trackArea")
                            .onPreferenceChange(SlotFramePreference.self) { slotFrames = $0 }
                            .onPreferenceChange(SlotViewportFramePreference.self) { slotViewportFrames = $0 }

                            // Floating drag overlay
                            if let src = dragSourceIndex {
                                dragOverlayView(sourceIndex: src, screenshotHeight: screenshotHeight)
                            }

                            // Frame-rate driver for auto-scroll + overlap during drag
                            if isActivelyDragging {
                                TimelineView(.periodic(from: .now, by: 1.0 / 120.0)) { timeline in
                                    Color.clear
                                        .frame(width: 0, height: 0)
                                        .onChange(of: timeline.date) { _, _ in
                                            autoScrollAndOverlapTick(at: timeline.date)
                                        }
                                }
                            }
                        }
                        .onAppear { viewportSize = geometry.size }
                        .onChange(of: geometry.size) { _, s in viewportSize = s }
                    }
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleFinderDrop(providers)
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

    // MARK: - Toolbar

    private var trackToolbar: some View {
        HStack(spacing: 12) {
            if availableDeviceTypes.count > 1 {
                Picker("", selection: $selectedDevice) {
                    ForEach(availableDeviceTypes) { device in
                        Text(device.label).tag(device)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
            }

            Spacer()

            HStack(spacing: 4) {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("Synced").font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 4) {
                Circle().fill(.orange).frame(width: 8, height: 8)
                Text("Changed").font(.caption).foregroundStyle(.secondary)
            }

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
    }

    // MARK: - Slot Container

    private func slotContainer(index: Int, screenshotHeight: CGFloat) -> some View {
        let slot = currentTrack[index]
        let saved = asc.savedTrackStateForDisplayType(selectedDevice.ascDisplayType, locale: currentLocale)[index]
        let isSynced = slot?.id == saved?.id && slot != nil
        let hasError = slot?.ascScreenshot?.hasError == true

        return Group {
            if let slot {
                filledSlotView(slot: slot, index: index, isSynced: isSynced, hasError: hasError, screenshotHeight: screenshotHeight)
            } else {
                emptySlotView(index: index, screenshotHeight: screenshotHeight)
            }
        }
        .opacity(dragSourceIndex == index ? 0.3 : 1.0)
        .offset(x: slotReorderOffset(for: index))
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: dropTargetIndex)
        .background(
            GeometryReader { geo in
                Color.clear
                    .preference(
                        key: SlotFramePreference.self,
                        value: [index: geo.frame(in: .named("trackContent"))]
                    )
                    .preference(
                        key: SlotViewportFramePreference.self,
                        value: [index: geo.frame(in: .named("trackArea"))]
                    )
            }
        )
        .highPriorityGesture(
            DragGesture(minimumDistance: 5, coordinateSpace: .named("trackArea"))
                .onChanged { value in
                    guard currentTrack[index] != nil else { return }
                    if dragSourceIndex == nil {
                        startDrag(from: index, with: value)
                    }
                    guard dragSourceIndex == index else { return }
                    dragViewportPos = value.location
                    updateDropIntent(at: Date())
                }
                .onEnded { _ in
                    guard dragSourceIndex == index else { return }
                    commitDrag()
                }
        )
        .onDrop(of: [.fileURL], delegate: FileDropDelegate(slotIndex: index) { url, idx in
            importFileToSlot(url: url, slotIndex: idx)
        })
    }

    // MARK: - Drag Overlay

    @ViewBuilder
    private func dragOverlayView(sourceIndex: Int, screenshotHeight: CGFloat) -> some View {
        let slot = currentTrack[sourceIndex]
        let saved = asc.savedTrackStateForDisplayType(selectedDevice.ascDisplayType, locale: currentLocale)[sourceIndex]
        let isSynced = slot?.id == saved?.id && slot != nil
        let hasError = slot?.ascScreenshot?.hasError == true

        Group {
            if let slot {
                slotImageContent(slot: slot, hasError: hasError, screenshotHeight: screenshotHeight,
                                 borderColor: hasError ? .red : (isSynced ? .green : .orange))
            } else {
                emptySlotPlaceholder(screenshotHeight: screenshotHeight)
            }
        }
        .scaleEffect(1.05)
        .shadow(color: .black.opacity(0.3), radius: 15, y: 5)
        .position(adjustedDragPos)
        .allowsHitTesting(false)
    }

    // MARK: - Auto-scroll & Hover Targeting

    private func autoScrollAndOverlapTick(at now: Date) {
        guard isActivelyDragging, dragSourceIndex != nil else { return }

        let edgeThreshold: CGFloat = 60
        let maxPointsPerSecond: CGFloat = 1800 * 0.8
        let deltaTime = min(
            max(lastAutoScrollTickAt.map { now.timeIntervalSince($0) } ?? (1.0 / 120.0), 0),
            1.0 / 20.0
        )
        lastAutoScrollTickAt = now

        var velocity: CGFloat = 0

        if let dragFrame = currentDragViewportFrame() {
            let leftSwallow = max(0, -dragFrame.minX)
            let rightSwallow = max(0, dragFrame.maxX - viewportSize.width)
            let responseWidth = max(dragFrame.width, edgeThreshold)

            if leftSwallow > 0 {
                let fraction = min(leftSwallow / responseWidth, 1)
                velocity = -maxPointsPerSecond * sqrt(fraction)
            } else if rightSwallow > 0 {
                let fraction = min(rightSwallow / responseWidth, 1)
                velocity = maxPointsPerSecond * sqrt(fraction)
            }
        } else {
            let cursorX = min(max(dragViewportPos.x, 0), viewportSize.width)

            if cursorX < edgeThreshold {
                let t = 1.0 - (cursorX / edgeThreshold)
                velocity = -maxPointsPerSecond * pow(t, 2)
            } else if cursorX > viewportSize.width - edgeThreshold {
                let distanceToRightEdge = max(viewportSize.width - cursorX, 0)
                let t = 1.0 - (distanceToRightEdge / edgeThreshold)
                velocity = maxPointsPerSecond * pow(t, 2)
            }
        }

        if let scrollView = scrollViewRef, velocity != 0 {
            let clip = scrollView.contentView.bounds
            let maxX = max(0, (scrollView.documentView?.frame.width ?? 0) - clip.width)
            let deltaX = velocity * CGFloat(deltaTime)
            let newX = min(max(0, clip.origin.x + deltaX), maxX)
            if newX != clip.origin.x {
                scrollView.contentView.scroll(to: NSPoint(x: newX, y: clip.origin.y))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }

        updateDropIntent(at: now)
    }

    private func updateDropIntent(at now: Date) {
        guard let src = dragSourceIndex,
              let dragContentCenter = currentDragContentCenter() else {
            return
        }

        if let activeTarget = dropTargetIndex,
           !shouldKeepActivePreview(for: activeTarget, dragContentCenter: dragContentCenter) {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                dropTargetIndex = nil
            }
        }

        guard let candidateIndex = hoveredTargetIndex(for: dragContentCenter, excluding: src) else {
            hoverState = nil
            if dropTargetIndex != nil {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                    dropTargetIndex = nil
                }
            }
            return
        }

        if hoverState?.index != candidateIndex {
            hoverState = DragHoverState(index: candidateIndex, anchor: dragViewportPos, startedAt: now)
            return
        }

        guard var hoverState else { return }
        let dx = abs(dragViewportPos.x - hoverState.anchor.x)
        let dy = abs(dragViewportPos.y - hoverState.anchor.y)

        if dx >= 20 || dy >= 20 {
            hoverState.anchor = dragViewportPos
            hoverState.startedAt = now
            self.hoverState = hoverState
            return
        }

        let hoverElapsed = now.timeIntervalSince(hoverState.startedAt)
        guard hoverElapsed >= 1.0 else { return }

        if dropTargetIndex != candidateIndex {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                dropTargetIndex = candidateIndex
            }
        }
    }

    private func hoveredTargetIndex(for dragContentCenter: CGPoint, excluding sourceIndex: Int) -> Int? {
        for index in occupiedIndicesForReorder() where index != sourceIndex {
            guard let zone = targetZone(
                for: index,
                horizontalSlack: 0,
                verticalSlackFactor: 0.18
            ) else {
                continue
            }
            if zone.contains(dragContentCenter) {
                return index
            }
        }

        return nil
    }

    private func shouldKeepActivePreview(
        for index: Int,
        dragContentCenter: CGPoint
    ) -> Bool {
        guard let zone = targetZone(
            for: index,
            horizontalSlack: 28,
            verticalSlackFactor: 0.28
        ) else {
            return false
        }
        return zone.contains(dragContentCenter)
    }

    // MARK: - Reorder Preview Offset

    private func slotReorderOffset(for index: Int) -> CGFloat {
        guard let destinationIndex = previewDestinationIndex(for: index),
              let currentFrame = activeSlotFrames[index],
              let destinationFrame = activeSlotFrames[destinationIndex] else {
            return 0
        }

        return destinationFrame.minX - currentFrame.minX
    }

    private func previewDestinationIndex(for index: Int) -> Int? {
        guard let src = dragSourceIndex, let dst = dropTargetIndex, src != dst else { return nil }
        guard index != src else { return nil }

        if src < dst, index > src && index <= dst {
            return index - 1
        }

        if src > dst, index >= dst && index < src {
            return index + 1
        }

        return nil
    }

    // MARK: - Commit Drag

    private func commitDrag() {
        guard let src = dragSourceIndex else { return }
        isActivelyDragging = false

        if let dst = dropTargetIndex, src != dst {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.85)) {
                dragViewportPos = dragHandleViewportPosition(for: dst)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    asc.reorderTrack(
                        displayType: selectedDevice.ascDisplayType,
                        fromIndex: src,
                        toIndex: dst,
                        locale: currentLocale
                    )
                    resetDrag()
                }
            }
        } else {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.85)) {
                dragViewportPos = dragHandleViewportPosition(for: src)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    resetDrag()
                }
            }
        }
    }

    private func resetDrag() {
        dragSourceIndex = nil
        dropTargetIndex = nil
        hoverState = nil
        isActivelyDragging = false
        dragViewportPos = .zero
        dragStartOffset = .zero
        dragBaseSlotFrames = [:]
        lastAutoScrollTickAt = nil
    }

    private func startDrag(from index: Int, with value: DragGesture.Value) {
        let frozenFrames = slotFrames
        guard let contentFrame = frozenFrames[index], contentFrame.width > 0, contentFrame.height > 0 else { return }
        guard let viewportFrame = slotViewportFrames[index], viewportFrame.width > 0, viewportFrame.height > 0 else { return }

        dragSourceIndex = index
        isActivelyDragging = true
        dragBaseSlotFrames = frozenFrames
        hoverState = nil
        lastAutoScrollTickAt = nil

        let viewportCenter = CGPoint(
            x: viewportFrame.midX,
            y: viewportFrame.midY
        )

        dragStartOffset = CGSize(
            width: value.startLocation.x - viewportCenter.x,
            height: value.startLocation.y - viewportCenter.y
        )
        dragViewportPos = value.location
        dropTargetIndex = nil
    }

    private func dragHandleViewportPosition(for index: Int) -> CGPoint {
        let scrollOffset = currentHorizontalScrollOffset
        let frame = activeSlotFrames[index] ?? .zero
        return CGPoint(
            x: frame.midX - scrollOffset + dragStartOffset.width,
            y: frame.midY + dragStartOffset.height
        )
    }

    // MARK: - Slot Views

    @ViewBuilder
    private func filledSlotView(slot: TrackSlot, index: Int, isSynced: Bool, hasError: Bool, screenshotHeight: CGFloat) -> some View {
        let borderColor: Color = hasError ? .red : (isSynced ? .green : .orange)

        ZStack(alignment: .topTrailing) {
            slotImageContent(slot: slot, hasError: hasError, screenshotHeight: screenshotHeight, borderColor: borderColor)

            Button {
                withAnimation {
                    asc.removeFromTrack(
                        displayType: selectedDevice.ascDisplayType,
                        slotIndex: index,
                        locale: currentLocale
                    )
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white, Color(.darkGray))
                    .shadow(color: .black.opacity(0.3), radius: 2)
            }
            .buttonStyle(.plain)
            .padding(6)
        }
    }

    @ViewBuilder
    private func slotImageContent(slot: TrackSlot, hasError: Bool, screenshotHeight: CGFloat, borderColor: Color) -> some View {
        if hasError {
            slotPlaceholder(screenshotHeight: screenshotHeight) {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.title)
                        .foregroundStyle(.red)

                    if let description = slot.ascScreenshot?.errorDescription, !description.isEmpty {
                        Text(description)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .padding(.horizontal, 12)
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.red, lineWidth: 2)
            )
        } else if let image = slot.localImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: screenshotHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(borderColor, lineWidth: 2)
                )
        } else if let url = slot.ascScreenshot?.imageURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                case .failure:
                    slotPlaceholder(icon: "photo", screenshotHeight: screenshotHeight)
                default:
                    slotPlaceholder(screenshotHeight: screenshotHeight) {
                        ProgressView()
                    }
                }
            }
            .frame(height: screenshotHeight)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(borderColor, lineWidth: 2)
            )
        } else {
            slotPlaceholder(icon: "photo", screenshotHeight: screenshotHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(borderColor, lineWidth: 2)
                )
        }
    }

    private func emptySlotView(index: Int, screenshotHeight: CGFloat) -> some View {
        Button {
            addFileToSlot(index: index)
        } label: {
            emptySlotPlaceholder(screenshotHeight: screenshotHeight)
        }
        .buttonStyle(.plain)
    }

    private func emptySlotPlaceholder(screenshotHeight: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(.controlBackgroundColor))
            .aspectRatio(selectedDevice.placeholderAspectRatio, contentMode: .fit)
            .frame(height: screenshotHeight)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .foregroundStyle(.quaternary)
            )
            .overlay(
                Image(systemName: "plus")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            )
    }

    private func slotPlaceholder(icon: String? = nil, screenshotHeight: CGFloat, @ViewBuilder content: () -> some View = { EmptyView() }) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(.controlBackgroundColor))
            .aspectRatio(selectedDevice.placeholderAspectRatio, contentMode: .fit)
            .frame(height: screenshotHeight)
            .overlay(
                Group {
                    if let icon {
                        Image(systemName: icon)
                            .font(.title)
                            .foregroundStyle(.secondary)
                    } else {
                        content()
                    }
                }
            )
    }

    // MARK: - Data Loading

    private func loadData() async {
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

    // MARK: - File Import

    private func addFileToSlot(index: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .webP]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a screenshot to add"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        importFileToSlot(url: url, slotIndex: index)
    }

    private func importFileToSlot(url: URL, slotIndex: Int) {
        guard let projectId = appState.activeProjectId else {
            importError = "No active project"
            return
        }

        let destDir = BlitzPaths.screenshots(projectId: projectId)
        let fm = FileManager.default
        try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        let ext = url.pathExtension.lowercased()
        var destPath: String?

        if ext == "png" {
            let dest = destDir.appendingPathComponent(url.lastPathComponent)
            do {
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: url, to: dest)
                destPath = dest.path
            } catch {
                importError = "\(url.lastPathComponent): \(error.localizedDescription)"
                return
            }
        } else {
            guard let image = loadImage(from: url) else {
                importError = "\(url.lastPathComponent): unsupported format or could not load image"
                return
            }
            let pngName = url.deletingPathExtension().lastPathComponent + ".png"
            let dest = destDir.appendingPathComponent(pngName)
            do {
                guard let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let pngData = bitmap.representation(using: .png, properties: [:]) else {
                    importError = "\(url.lastPathComponent): failed to convert to PNG"
                    return
                }
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try pngData.write(to: dest)
                destPath = dest.path
            } catch {
                importError = "\(url.lastPathComponent): \(error.localizedDescription)"
                return
            }
        }

        guard let path = destPath else { return }

        asc.scanLocalAssets(projectId: projectId)

        if let error = asc.addAssetToTrack(
            displayType: selectedDevice.ascDisplayType,
            slotIndex: slotIndex,
            localPath: path,
            locale: currentLocale
        ) {
            importError = error
        }
    }

    private func loadImage(from url: URL) -> NSImage? {
        if let image = NSImage(contentsOf: url), !image.representations.isEmpty {
            return image
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private func handleFinderDrop(_ providers: [NSItemProvider]) -> Bool {
        guard appState.activeProjectId != nil else { return false }

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
                        guard let slotIndex = self.currentTrack.firstIndex(where: { $0 == nil }) else {
                            self.importError = "All 10 slots are full"
                            return
                        }
                        self.importFileToSlot(url: url, slotIndex: slotIndex)
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

// MARK: - File Drop Delegate (Finder → slot)

private struct FileDropDelegate: DropDelegate {
    let slotIndex: Int
    let onDrop: (URL, Int) -> Void

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.fileURL])
        guard let provider = providers.first else { return false }

        provider.loadObject(ofClass: NSURL.self) { reading, _ in
            guard let url = reading as? URL, url.isFileURL else { return }
            Task { @MainActor in
                onDrop(url, slotIndex)
            }
        }
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard !info.itemProviders(for: [.fileURL]).isEmpty else {
            return DropProposal(operation: .cancel)
        }
        return DropProposal(operation: .copy)
    }

    func validateDrop(info: DropInfo) -> Bool {
        !info.itemProviders(for: [.fileURL]).isEmpty
    }
}
