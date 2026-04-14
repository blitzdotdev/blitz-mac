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

private struct SlotDisplayState {
    let slot: TrackSlot?
    let isSynced: Bool
    let hasError: Bool

    var borderColor: Color {
        hasError ? .red : (isSynced ? .green : .orange)
    }
}

private struct ScreenshotTrackItem: Identifiable, Equatable {
    let id: String
    let index: Int
    let slot: TrackSlot?
}

private struct SlotViewportFramePreference: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

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
            scrollView = Self.resolveScrollView(from: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            scrollView = Self.resolveScrollView(from: nsView)
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
    @State private var draggingSlot: TrackSlot?
    @State private var dragPointerLocation: CGPoint = .zero
    @State private var dragGrabOffset: CGSize = .zero
    @State private var slotViewportFrames: [String: CGRect] = [:]
    @State private var viewportSize: CGSize = .zero
    @State private var scrollViewRef: NSScrollView?
    @State private var lastAutoScrollTickAt: Date?
    @State private var lastReorderTime: Date?
    @State private var beganDragOnEdgeSlot = false
    @State private var previousDragPointerX: CGFloat = .zero
    @State private var dragStartSlotIndex: Int?

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
                resetDragState()
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
                resetDragState()
                asc.prepareForVersionSelection(newValue)
                Task { await loadData() }
            }
        )
    }

    private var currentTrack: [TrackSlot?] {
        asc.trackSlotsForDisplayType(selectedDisplayType, locale: currentLocale)
    }

    private var hasChanges: Bool {
        asc.hasUnsavedChanges(displayType: selectedDisplayType, locale: currentLocale)
    }

    private var filledSlotCount: Int {
        currentTrack.compactMap { $0 }.count
    }

    private var selectedDisplayType: String {
        selectedDevice.ascDisplayType
    }

    private var savedTrack: [TrackSlot?] {
        asc.savedTrackStateForDisplayType(selectedDisplayType, locale: currentLocale)
    }

    private var trackItems: [ScreenshotTrackItem] {
        currentTrack.enumerated().map { index, slot in
            ScreenshotTrackItem(
                id: slot?.id ?? "empty-\(index)",
                index: index,
                slot: slot
            )
        }
    }

    private var trackAnimationKey: [String] {
        trackItems.map(\.id)
    }

    private var currentViewportWidth: CGFloat {
        scrollViewRef?.contentView.bounds.width ?? viewportSize.width
    }

    private func slotDisplayState(at index: Int) -> SlotDisplayState {
        let slot = currentTrack[index]
        let isSynced = slot?.id == savedTrack[index]?.id && slot != nil
        let hasError = slot?.ascScreenshot?.hasError == true
        return SlotDisplayState(slot: slot, isSynced: isSynced, hasError: hasError)
    }

    private func slotViewportFrame(for slot: TrackSlot) -> CGRect? {
        slotViewportFrames[slot.id]
    }

    private func currentDragDisplayState() -> SlotDisplayState? {
        guard let draggingSlot,
              let index = currentTrack.firstIndex(where: { $0?.id == draggingSlot.id }) else {
            return nil
        }
        return slotDisplayState(at: index)
    }

    private func beginDrag(for slot: TrackSlot, with value: DragGesture.Value) {
        draggingSlot = slot
        dragPointerLocation = value.location
        previousDragPointerX = value.location.x
        lastAutoScrollTickAt = nil
        dragStartSlotIndex = currentTrack.firstIndex(where: { $0?.id == slot.id })

        guard let frame = slotViewportFrame(for: slot) else {
            dragGrabOffset = .zero
            return
        }

        if getLeftOrRightOverflow() != 0 {
            beganDragOnEdgeSlot = true
        }

        dragGrabOffset = CGSize(
            width: value.startLocation.x - frame.midX,
            height: value.startLocation.y - frame.midY
        )
    }

    private func resetDragState() {
        draggingSlot = nil
        dragPointerLocation = .zero
        dragGrabOffset = .zero
        lastAutoScrollTickAt = nil
        beganDragOnEdgeSlot = false
        previousDragPointerX = .zero
        dragStartSlotIndex = nil
    }

    private func currentDraggedViewportFrame() -> CGRect? {
        guard let draggingSlot,
              let frame = slotViewportFrame(for: draggingSlot) else {
            return nil
        }

        let center = CGPoint(
            x: dragPointerLocation.x - dragGrabOffset.width,
            y: dragPointerLocation.y - dragGrabOffset.height
        )

        return CGRect(
            x: center.x - frame.width / 2,
            y: center.y - frame.height / 2,
            width: frame.width,
            height: frame.height
        )
    }

    private func currentAutoScrollProbeBounds() -> (minX: CGFloat, maxX: CGFloat, width: CGFloat)? {
        guard let dragFrame = currentDraggedViewportFrame() else {
            return nil
        }

        guard let draggingSlot,
              let slotFrame = slotViewportFrame(for: draggingSlot) else {
            return (minX: dragFrame.minX, maxX: dragFrame.maxX, width: dragFrame.width)
        }

        return (
            minX: min(dragFrame.minX, slotFrame.minX),
            maxX: max(dragFrame.maxX, slotFrame.maxX),
            width: dragFrame.width
        )
    }

    private func getLeftOrRightOverflow() -> Int {
        guard let probe = currentAutoScrollProbeBounds(),
              currentViewportWidth > 0 else {
            return 0
        }

        let edgeMargin: CGFloat = 120
        let leftOverflow = max(0, edgeMargin - probe.minX)
        let rightOverflow = max(0, probe.maxX - (currentViewportWidth - edgeMargin))

        if leftOverflow > 0 { return -1 }
        if rightOverflow > 0 { return 1 }
        return 0
    }

    private func getLeftOrRightOverflow(forSlotAt index: Int) -> Int {
        guard let slot = currentTrack[index],
              let frame = slotViewportFrame(for: slot),
              currentViewportWidth > 0 else {
            return 0
        }

        let edgeMargin: CGFloat = 120
        let leftOverflow = max(0, edgeMargin - frame.minX)
        let rightOverflow = max(0, frame.maxX - (currentViewportWidth - edgeMargin))

        if leftOverflow > 0 { return -1 }
        if rightOverflow > 0 { return 1 }
        return 0
    }

    private func autoScrollVelocity() -> CGFloat {
        guard let probe = currentAutoScrollProbeBounds(),
              currentViewportWidth > 0 else {
            return 0
        }

        let edgeMargin: CGFloat = 120
        let responseWidth = max(probe.width, 60)
        let maxPointsPerSecond: CGFloat = 1440
        let leftOverflow = max(0, edgeMargin - probe.minX)
        let rightOverflow = max(0, probe.maxX - (currentViewportWidth - edgeMargin))

        // When drag started on an edge slot, use drag direction instead of
        // overflow direction so the user can drag away from the wall freely.
        if beganDragOnEdgeSlot {
            let dragDelta = dragPointerLocation.x - previousDragPointerX
            let overflow = max(leftOverflow, rightOverflow)
            if overflow > 0, abs(dragDelta) > 0.5 {
                let fraction = min(overflow / responseWidth, 1)
                let speed = maxPointsPerSecond * sqrt(fraction)
                return dragDelta > 0 ? speed : -speed
            }
            return 0
        }

        if leftOverflow > 0 {
            let fraction = min(leftOverflow / responseWidth, 1)
            return -maxPointsPerSecond * sqrt(fraction)
        }

        if rightOverflow > 0 {
            let fraction = min(rightOverflow / responseWidth, 1)
            return maxPointsPerSecond * sqrt(fraction)
        }

        return 0
    }

    private func updateReorderIntent() {
        guard let draggingSlot,
              let dragFrame = currentDraggedViewportFrame(),
              let sourceIndex = currentTrack.firstIndex(where: { $0?.id == draggingSlot.id }) else {
            return
        }

        let filledIndices = currentTrack.indices.filter { currentTrack[$0] != nil }
        guard let sourceNonNilIndex = filledIndices.firstIndex(of: sourceIndex) else { return }

        if sourceNonNilIndex > 0 {
            let previousIndex = filledIndices[sourceNonNilIndex - 1]
            if let previousSlot = currentTrack[previousIndex],
               let previousFrame = slotViewportFrame(for: previousSlot),
               dragFrame.midX < previousFrame.midX {
                lastReorderTime = Date()
                withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                    asc.reorderTrack(
                        displayType: selectedDisplayType,
                        fromIndex: sourceIndex,
                        toIndex: previousIndex,
                        locale: currentLocale
                    )
                }
                return
            }
        }

        if sourceNonNilIndex + 1 < filledIndices.count {
            let nextIndex = filledIndices[sourceNonNilIndex + 1]
            if let nextSlot = currentTrack[nextIndex],
               let nextFrame = slotViewportFrame(for: nextSlot),
               dragFrame.midX > nextFrame.midX {
                lastReorderTime = Date()
                withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                    asc.reorderTrack(
                        displayType: selectedDisplayType,
                        fromIndex: sourceIndex,
                        toIndex: nextIndex,
                        locale: currentLocale
                    )
                }
            }
        }
    }

    private func autoScrollTick(at now: Date) {
        guard draggingSlot != nil else {
            lastAutoScrollTickAt = nil
            return
        }

        if NSEvent.pressedMouseButtons == 0 {
            resetDragState()
            return
        }

        // Skip auto-scroll if a reorder animation is in progress
        // The spring animation has response: 0.5, so wait ~0.6s for it to settle
        if let lastReorderTime, now.timeIntervalSince(lastReorderTime) < 0.6 { return }

        let deltaTime = min(
            max(lastAutoScrollTickAt.map { now.timeIntervalSince($0) } ?? (1.0 / 120.0), 0),
            1.0 / 20.0
        )
        lastAutoScrollTickAt = now

        guard let scrollView = scrollViewRef else { return }

        let velocity = autoScrollVelocity()
        guard velocity != 0 else { return }

        let clipBounds = scrollView.contentView.bounds
        let maxOffsetX = max(0, (scrollView.documentView?.frame.width ?? 0) - clipBounds.width)
        let proposedOffsetX = clipBounds.origin.x + (velocity * CGFloat(deltaTime))
        let newOffsetX = min(max(0, proposedOffsetX), maxOffsetX)

        guard newOffsetX != clipBounds.origin.x else { return }

        scrollView.contentView.scroll(to: NSPoint(x: newOffsetX, y: clipBounds.origin.y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        //updateReorderIntent()
    }

    private func slotDragGesture(for slot: TrackSlot) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("trackArea"))
            .onChanged { value in
                if draggingSlot == nil {
                    beginDrag(for: slot, with: value)
                }
                guard draggingSlot?.id == slot.id else { return }
                previousDragPointerX = dragPointerLocation.x
                dragPointerLocation = value.location

                // Flip off edge-slot mode once the original slot position leaves the wall
                if beganDragOnEdgeSlot, let startIndex = dragStartSlotIndex {
                    if getLeftOrRightOverflow(forSlotAt: startIndex) == 0 {
                        beganDragOnEdgeSlot = false
                    }
                }

                updateReorderIntent()
            }
            .onEnded { _ in
                guard draggingSlot?.id == slot.id else { return }
                resetDragState()
            }
    }

    @ViewBuilder
    private func dragOverlayView(screenshotHeight: CGFloat) -> some View {
        if let draggingSlot,
           let displayState = currentDragDisplayState(),
           let dragFrame = currentDraggedViewportFrame() {
            slotImageContent(
                slot: draggingSlot,
                displayState: displayState,
                screenshotHeight: screenshotHeight
            )
            .scaleEffect(1.03)
            .shadow(color: .black.opacity(0.22), radius: 12, y: 5)
            .position(x: dragFrame.midX, y: dragFrame.midY)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Body

    var body: some View {
        ASCCredentialGate(
            appState: appState,
            ascManager: asc,
            projectId: appState.activeProjectId ?? "",
            bundleId: appState.activeProject?.metadata.bundleIdentifier
        ) {
            ASCTabContent(appState: appState, asc: asc, tab: .screenshots, platform: platform, allowWithoutLocalProject: true) {
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

                    writeErrorBanner

                    GeometryReader { geometry in
                        trackCanvas(in: geometry.size)
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
        .onChange(of: draggingSlot) { _, newValue in
            if newValue == nil {
                dragGrabOffset = .zero
                lastAutoScrollTickAt = nil
            }
        }
        .onChange(of: selectedDevice) { _, _ in
            resetDragState()
            loadTrackForDevice()
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

    // MARK: - Layout

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

    @ViewBuilder
    private var writeErrorBanner: some View {
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
    }

    private func trackCanvas(in size: CGSize) -> some View {
        let screenshotHeight = size.height * 0.65

        return ZStack {
            trackScrollView(screenshotHeight: screenshotHeight, minHeight: size.height)

            if draggingSlot != nil {
                dragOverlayView(screenshotHeight: screenshotHeight)

                TimelineView(.periodic(from: .now, by: 1.0 / 120.0)) { timeline in
                    Color.clear
                        .frame(width: 0, height: 0)
                        .onChange(of: timeline.date) { _, newDate in
                            autoScrollTick(at: newDate)
                        }
                }
            }
        }
        .onAppear { viewportSize = size }
        .onChange(of: size) { _, newSize in
            viewportSize = newSize
        }
    }

    private let trackPaddingSlots = 2
    private let trackSpacing: CGFloat = 16

    private func trackPaddingWidth(screenshotHeight: CGFloat) -> CGFloat {
        let slotWidth = screenshotHeight * selectedDevice.placeholderAspectRatio
        return CGFloat(trackPaddingSlots) * slotWidth + CGFloat(trackPaddingSlots) * trackSpacing
    }

    private func trackScrollView(screenshotHeight: CGFloat, minHeight: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .center, spacing: trackSpacing) {
                Color.clear.frame(width: trackPaddingWidth(screenshotHeight: screenshotHeight), height: 1)
                ForEach(trackItems) { item in
                    slotContainer(item: item, screenshotHeight: screenshotHeight)
                }
                Color.clear.frame(width: trackPaddingWidth(screenshotHeight: screenshotHeight), height: 1)
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.82), value: trackAnimationKey)
            .background(ScrollViewFinder(scrollView: $scrollViewRef))
            .padding(20)
            .frame(minHeight: minHeight)
        }
        .coordinateSpace(name: "trackArea")
        .onPreferenceChange(SlotViewportFramePreference.self) { slotViewportFrames = $0 }
        .onAppear {
            DispatchQueue.main.async {
                guard let scrollView = scrollViewRef else { return }
                let offsetX = trackPaddingWidth(screenshotHeight: screenshotHeight) + trackSpacing
                scrollView.contentView.scroll(to: NSPoint(x: offsetX, y: 0))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
    }

    // MARK: - Slot Container

    private func slotContainer(item: ScreenshotTrackItem, screenshotHeight: CGFloat) -> some View {
        let displayState = slotDisplayState(at: item.index)

        return Group {
            if let slot = item.slot {
                reorderableFilledSlotView(
                    slot: slot,
                    index: item.index,
                    displayState: displayState,
                    screenshotHeight: screenshotHeight
                )
                .onDrop(of: [.fileURL], delegate: FileDropDelegate(slotIndex: item.index) { url, idx in
                    importFileToSlot(url: url, slotIndex: idx)
                })
            } else {
                emptySlotView(index: item.index, screenshotHeight: screenshotHeight)
                    .onDrop(of: [.fileURL], delegate: FileDropDelegate(slotIndex: item.index) { url, idx in
                        importFileToSlot(url: url, slotIndex: idx)
                    })
            }
        }
        .opacity(draggingSlot != nil && draggingSlot?.id == item.slot?.id ? 0.08 : 1)
        .background(slotFrameReader(for: item))
    }

    private func slotFrameReader(for item: ScreenshotTrackItem) -> some View {
        GeometryReader { geo in
            Color.clear
                .preference(
                    key: SlotViewportFramePreference.self,
                    value: [item.id: geo.frame(in: .named("trackArea"))]
                )
        }
    }

    private func reorderableFilledSlotView(
        slot: TrackSlot,
        index: Int,
        displayState: SlotDisplayState,
        screenshotHeight: CGFloat
    ) -> some View {
        filledSlotView(
            slot: slot,
            index: index,
            displayState: displayState,
            screenshotHeight: screenshotHeight
        )
    }

    // MARK: - Slot Views

    @ViewBuilder
    private func filledSlotView(
        slot: TrackSlot,
        index: Int,
        displayState: SlotDisplayState,
        screenshotHeight: CGFloat
    ) -> some View {
        ZStack(alignment: .topTrailing) {
            slotImageContent(slot: slot, displayState: displayState, screenshotHeight: screenshotHeight)
                .contentShape(Rectangle())
                .highPriorityGesture(slotDragGesture(for: slot))

            Button {
                withAnimation {
                    asc.removeFromTrack(
                        displayType: selectedDisplayType,
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
    private func slotImageContent(
        slot: TrackSlot,
        displayState: SlotDisplayState,
        screenshotHeight: CGFloat
    ) -> some View {
        if displayState.hasError {
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
                        .stroke(displayState.borderColor, lineWidth: 2)
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
                    .stroke(displayState.borderColor, lineWidth: 2)
            )
        } else {
            slotPlaceholder(icon: "photo", screenshotHeight: screenshotHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(displayState.borderColor, lineWidth: 2)
                )
        }
    }

    private func emptySlotView(index: Int, screenshotHeight: CGFloat) -> some View {
        Button {
            addFileToSlot(index: index)
        } label: {
            emptySlotBody(screenshotHeight: screenshotHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func emptySlotBody(screenshotHeight: CGFloat) -> some View {
        slotPlaceholder(screenshotHeight: screenshotHeight) {
            VStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up")
                    .font(.title2)
                Text("Upload")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                .foregroundStyle(.secondary)
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
        syncSelectedDeviceIfNeeded()
        await asc.ensureTabData(.screenshots)
        if asc.selectedScreenshotsLocale == nil {
            asc.selectedScreenshotsLocale = asc.localizations.first?.attributes.locale
        }
        await loadSelectedLocaleData()
    }

    private func syncSelectedDeviceIfNeeded() {
        if let first = availableDeviceTypes.first, !availableDeviceTypes.contains(selectedDevice) {
            selectedDevice = first
        }
    }

    private func loadSelectedLocaleData(force: Bool = false) async {
        guard !currentLocale.isEmpty else { return }
        await asc.loadScreenshots(locale: currentLocale, force: force)
        loadTrackForDevice(force: force)
    }

    private func loadTrackForDevice(force: Bool = false) {
        if force || !asc.hasTrackState(displayType: selectedDisplayType, locale: currentLocale) {
            asc.loadTrackFromASC(displayType: selectedDisplayType, locale: currentLocale)
        }
    }

    // MARK: - File Import

    @MainActor
    private func addFileToSlot(index: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
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

        if let error = asc.addAssetToTrack(
            displayType: selectedDisplayType,
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
            displayType: selectedDisplayType,
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
