import SwiftUI

// MARK: - Touch Overlay Skin

enum TouchOverlaySkin: String, CaseIterable, Identifiable {
    case laser
    case ripple
    case aurora
    case spark
    case ghost

    var id: String { rawValue }

    var label: String {
        switch self {
        case .laser: "Laser"
        case .ripple: "Ripple"
        case .aurora: "Aurora"
        case .spark: "Spark"
        case .ghost: "Ghost"
        }
    }

    var icon: String {
        switch self {
        case .laser: "light.max"
        case .ripple: "drop.circle"
        case .aurora: "sparkle"
        case .spark: "bolt.fill"
        case .ghost: "aqi.medium"
        }
    }

    var tapAnimation: Animation {
        switch self {
        case .laser: .easeOut(duration: 0.6)
        case .ripple: .easeOut(duration: 0.9)
        case .aurora: .easeInOut(duration: 0.8)
        case .spark: .easeOut(duration: 0.4)
        case .ghost: .easeOut(duration: 0.5)
        }
    }

    var tapCleanupDelay: Double {
        switch self {
        case .laser: 0.7
        case .ripple: 1.0
        case .aurora: 0.9
        case .spark: 0.5
        case .ghost: 0.6
        }
    }

    var swipeAnimation: Animation {
        switch self {
        case .laser: .easeOut(duration: 0.8)
        case .ripple: .easeOut(duration: 0.9)
        case .aurora: .easeInOut(duration: 1.0)
        case .spark: .easeOut(duration: 0.5)
        case .ghost: .easeOut(duration: 0.6)
        }
    }

    var swipeCleanupDelay: Double {
        switch self {
        case .laser: 0.9
        case .ripple: 1.0
        case .aurora: 1.1
        case .spark: 0.6
        case .ghost: 0.7
        }
    }
}

// MARK: - Touch Overlay View

/// Transparent overlay that captures touch/click events and translates to device actions.
/// Renders skin-configurable indicators for taps and swipes.
struct TouchOverlayView: View {
    let deviceConfig: SimulatorDeviceConfig
    let frameWidth: Int
    let frameHeight: Int
    let onTap: (Double, Double) -> Void
    /// (fromX, fromY, toX, toY, duration, delta)
    let onSwipe: (Double, Double, Double, Double, Double, Int) -> Void
    let gestureVisualization: GestureVisualizationSocketService
    let activeDeviceID: String?
    let skin: TouchOverlaySkin

    @State private var dragStart: CGPoint?
    @State private var dragStartTime: Date?
    @State private var clickMarkers: [ClickMarker] = []
    @State private var swipePath: [CGPoint] = []
    @State private var remoteSwipeTrails: [RemoteSwipeTrail] = []
    @State private var renderedGestureIDs: Set<String> = []

    struct ClickMarker: Identifiable {
        let id = UUID()
        let position: CGPoint
        var opacity: Double = 1.0
    }

    struct RemoteSwipeTrail: Identifiable {
        let id = UUID()
        let from: CGPoint
        let to: CGPoint
        var opacity: Double = 1.0
    }

    private var gestureEventIDs: [String] { gestureEvents.map(\.id) }
    private var gestureEvents: [GestureVisualizationEvent] {
        gestureVisualization.events(for: activeDeviceID)
    }

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if dragStart == nil {
                                dragStart = value.startLocation
                                dragStartTime = Date()
                            }
                            swipePath.append(value.location)
                        }
                        .onEnded { value in
                            let start = dragStart ?? value.startLocation
                            let end = value.location
                            let distance = hypot(end.x - start.x, end.y - start.y)

                            if distance < 10 {
                                let (simX, simY) = SimulatorConfigDatabase.viewToSimulatorCoords(
                                    viewX: Double(end.x),
                                    viewY: Double(end.y),
                                    viewWidth: Double(geometry.size.width),
                                    viewHeight: Double(geometry.size.height),
                                    config: deviceConfig,
                                    frameWidth: frameWidth,
                                    frameHeight: frameHeight
                                )
                                onTap(simX, simY)
                                renderTap(at: end)
                            } else {
                                let (startX, startY) = SimulatorConfigDatabase.viewToSimulatorCoords(
                                    viewX: Double(start.x),
                                    viewY: Double(start.y),
                                    viewWidth: Double(geometry.size.width),
                                    viewHeight: Double(geometry.size.height),
                                    config: deviceConfig,
                                    frameWidth: frameWidth,
                                    frameHeight: frameHeight
                                )
                                let (endX, endY) = SimulatorConfigDatabase.viewToSimulatorCoords(
                                    viewX: Double(end.x),
                                    viewY: Double(end.y),
                                    viewWidth: Double(geometry.size.width),
                                    viewHeight: Double(geometry.size.height),
                                    config: deviceConfig,
                                    frameWidth: frameWidth,
                                    frameHeight: frameHeight
                                )

                                let duration = dragStartTime.map { Date().timeIntervalSince($0) } ?? 0.3
                                let simDistance = hypot(endX - startX, endY - startY)
                                let delta = max(1, Int(round(simDistance / 10)))

                                onSwipe(startX, startY, endX, endY, duration, delta)
                            }

                            dragStart = nil
                            dragStartTime = nil
                            swipePath = []
                        }
                )
                .overlay {
                    ForEach(clickMarkers) { marker in
                        skin.tapIndicator(opacity: marker.opacity)
                            .position(marker.position)
                    }

                    if swipePath.count > 1 {
                        skin.activeSwipeTrail(points: swipePath)
                    }

                    ForEach(remoteSwipeTrails) { trail in
                        skin.remoteSwipeTrail(from: trail.from, to: trail.to, opacity: trail.opacity)
                    }
                }
                .onAppear {
                    renderNewGestureEvents(viewSize: geometry.size)
                }
                .onChange(of: gestureEventIDs) {
                    renderNewGestureEvents(viewSize: geometry.size)
                }
                .onChange(of: activeDeviceID) {
                    renderedGestureIDs.removeAll()
                    remoteSwipeTrails.removeAll()
                    renderNewGestureEvents(viewSize: geometry.size)
                }
        }
    }

    private func renderNewGestureEvents(viewSize: CGSize) {
        renderedGestureIDs.formIntersection(Set(gestureEventIDs))

        for event in gestureEvents where !renderedGestureIDs.contains(event.id) {
            renderedGestureIDs.insert(event.id)

            switch event.kind {
            case .tap:
                guard let x = event.x, let y = event.y else { continue }
                renderTap(at: protocolToView(x: x, y: y, event: event, viewSize: viewSize))
            case .swipe:
                guard let x = event.x, let y = event.y,
                      let x2 = event.x2, let y2 = event.y2 else { continue }
                renderSwipe(
                    from: protocolToView(x: x, y: y, event: event, viewSize: viewSize),
                    to: protocolToView(x: x2, y: y2, event: event, viewSize: viewSize)
                )
            default:
                continue
            }
        }
    }

    private func renderTap(at position: CGPoint) {
        let marker = ClickMarker(position: position)
        clickMarkers.append(marker)
        withAnimation(skin.tapAnimation) {
            if let index = clickMarkers.firstIndex(where: { $0.id == marker.id }) {
                clickMarkers[index].opacity = 0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + skin.tapCleanupDelay) {
            clickMarkers.removeAll { $0.id == marker.id }
        }
    }

    private func renderSwipe(from: CGPoint, to: CGPoint) {
        let trail = RemoteSwipeTrail(from: from, to: to)
        remoteSwipeTrails.append(trail)
        let trailID = trail.id
        withAnimation(skin.swipeAnimation) {
            if let index = remoteSwipeTrails.firstIndex(where: { $0.id == trailID }) {
                remoteSwipeTrails[index].opacity = 0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + skin.swipeCleanupDelay) {
            remoteSwipeTrails.removeAll { $0.id == trailID }
        }
    }

    private func protocolToView(x: Double, y: Double, event: GestureVisualizationEvent, viewSize: CGSize) -> CGPoint {
        let normalizedX = x / event.referenceWidth
        let normalizedY = y / event.referenceHeight
        let simulatorX = normalizedX * deviceConfig.widthPoints
        let simulatorY = normalizedY * deviceConfig.heightPoints
        let mapped = SimulatorConfigDatabase.simulatorToViewCoords(
            simX: simulatorX,
            simY: simulatorY,
            viewWidth: viewSize.width,
            viewHeight: viewSize.height,
            config: deviceConfig,
            frameWidth: frameWidth,
            frameHeight: frameHeight
        )
        return CGPoint(
            x: mapped.x.clamped(to: 0...viewSize.width),
            y: mapped.y.clamped(to: 0...viewSize.height)
        )
    }
}

// MARK: - Skin Rendering Dispatch

extension TouchOverlaySkin {
    @ViewBuilder
    func tapIndicator(opacity: Double) -> some View {
        switch self {
        case .laser: LaserTapIndicator(opacity: opacity)
        case .ripple: RippleTapIndicator(opacity: opacity)
        case .aurora: AuroraTapIndicator(opacity: opacity)
        case .spark: SparkTapIndicator(opacity: opacity)
        case .ghost: GhostTapIndicator(opacity: opacity)
        }
    }

    @ViewBuilder
    func activeSwipeTrail(points: [CGPoint]) -> some View {
        switch self {
        case .laser:
            SwipeTrailShape(points: points)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color(red: 0.25, green: 0.6, blue: 1.0).opacity(0.3),
                            Color(red: 0.35, green: 0.7, blue: 1.0).opacity(0.8),
                        ],
                        startPoint: .leading, endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                )
                .shadow(color: Color(red: 0.2, green: 0.55, blue: 1.0).opacity(0.7), radius: 6)
                .shadow(color: Color(red: 0.3, green: 0.65, blue: 1.0).opacity(0.35), radius: 14)

        case .ripple:
            SwipeTrailShape(points: points)
                .stroke(
                    Color(red: 0.0, green: 0.83, blue: 1.0).opacity(0.7),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                )
                .shadow(color: Color(red: 0.0, green: 0.83, blue: 1.0).opacity(0.4), radius: 8)

        case .aurora:
            SwipeTrailShape(points: points)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color(red: 0.61, green: 0.35, blue: 1.0).opacity(0.6),
                            Color(red: 0.0, green: 0.90, blue: 0.80).opacity(0.7),
                        ],
                        startPoint: .leading, endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                )
                .shadow(color: Color(red: 0.61, green: 0.35, blue: 1.0).opacity(0.35), radius: 10)
                .shadow(color: Color(red: 0.0, green: 0.90, blue: 0.80).opacity(0.2), radius: 16)

        case .spark:
            SwipeTrailShape(points: points)
                .stroke(
                    Color(red: 1.0, green: 0.84, blue: 0.0).opacity(0.8),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [8, 4])
                )
                .shadow(color: Color(red: 1.0, green: 0.84, blue: 0.0).opacity(0.5), radius: 6)

        case .ghost:
            SwipeTrailShape(points: points)
                .stroke(
                    Color.white.opacity(0.3),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                )
                .shadow(color: Color.white.opacity(0.1), radius: 4)
        }
    }

    @ViewBuilder
    func remoteSwipeTrail(from: CGPoint, to: CGPoint, opacity: Double) -> some View {
        switch self {
        case .laser:
            Path { p in p.move(to: from); p.addLine(to: to) }
                .stroke(
                    Color(red: 0.35, green: 0.7, blue: 1.0).opacity(0.7 * opacity),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .shadow(color: Color(red: 0.2, green: 0.55, blue: 1.0).opacity(0.6 * opacity), radius: 8)
                .shadow(color: Color(red: 0.3, green: 0.65, blue: 1.0).opacity(0.3 * opacity), radius: 16)

        case .ripple:
            Path { p in p.move(to: from); p.addLine(to: to) }
                .stroke(
                    Color(red: 0.0, green: 0.83, blue: 1.0).opacity(0.6 * opacity),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .shadow(color: Color(red: 0.0, green: 0.83, blue: 1.0).opacity(0.35 * opacity), radius: 10)

        case .aurora:
            Path { p in p.move(to: from); p.addLine(to: to) }
                .stroke(
                    LinearGradient(
                        colors: [
                            Color(red: 0.61, green: 0.35, blue: 1.0).opacity(0.6 * opacity),
                            Color(red: 0.0, green: 0.90, blue: 0.80).opacity(0.6 * opacity),
                        ],
                        startPoint: .leading, endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .shadow(color: Color(red: 0.61, green: 0.35, blue: 1.0).opacity(0.3 * opacity), radius: 10)
                .shadow(color: Color(red: 0.0, green: 0.90, blue: 0.80).opacity(0.2 * opacity), radius: 14)

        case .spark:
            Path { p in p.move(to: from); p.addLine(to: to) }
                .stroke(
                    Color(red: 1.0, green: 0.84, blue: 0.0).opacity(0.7 * opacity),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [8, 4])
                )
                .shadow(color: Color(red: 1.0, green: 0.84, blue: 0.0).opacity(0.4 * opacity), radius: 6)

        case .ghost:
            Path { p in p.move(to: from); p.addLine(to: to) }
                .stroke(
                    Color.white.opacity(0.3 * opacity),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                )
                .shadow(color: Color.white.opacity(0.1 * opacity), radius: 4)
        }
    }
}

// MARK: - Laser Skin

private struct LaserTapIndicator: View {
    let opacity: Double

    var body: some View {
        ZStack {
            // Outer glow halo
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.2, green: 0.6, blue: 1.0).opacity(0.5 * opacity),
                            Color(red: 0.2, green: 0.6, blue: 1.0).opacity(0),
                        ],
                        center: .center, startRadius: 2, endRadius: 20
                    )
                )
                .frame(width: 40, height: 40)

            // Bright core
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.85, green: 0.93, blue: 1.0).opacity(opacity),
                            Color(red: 0.35, green: 0.7, blue: 1.0).opacity(0.8 * opacity),
                            Color(red: 0.2, green: 0.5, blue: 1.0).opacity(0),
                        ],
                        center: .center, startRadius: 0, endRadius: 8
                    )
                )
                .frame(width: 16, height: 16)

            // Hot center
            Circle()
                .fill(Color.white.opacity(0.95 * opacity))
                .frame(width: 4, height: 4)
        }
    }
}

// MARK: - Ripple Skin

private struct RippleTapIndicator: View {
    let opacity: Double

    private let cyan = Color(red: 0.0, green: 0.83, blue: 1.0)

    var body: some View {
        ZStack {
            // Outer expanding ring
            Circle()
                .stroke(cyan.opacity(0.4 * opacity), lineWidth: 1)
                .frame(width: 40, height: 40)
                .scaleEffect(0.2 + 0.8 * (1 - opacity))

            // Inner expanding ring
            Circle()
                .stroke(cyan.opacity(0.7 * opacity), lineWidth: 1.5)
                .frame(width: 24, height: 24)
                .scaleEffect(0.4 + 0.6 * (1 - opacity))

            // Center dot
            Circle()
                .fill(cyan.opacity(0.9 * opacity))
                .frame(width: 4, height: 4)
        }
    }
}

// MARK: - Aurora Skin

private struct AuroraTapIndicator: View {
    let opacity: Double

    private let purple = Color(red: 0.61, green: 0.35, blue: 1.0)
    private let teal = Color(red: 0.0, green: 0.90, blue: 0.80)

    var body: some View {
        ZStack {
            // Soft outer glow
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            purple.opacity(0.35 * opacity),
                            teal.opacity(0.15 * opacity),
                            Color.clear,
                        ],
                        center: .center, startRadius: 0, endRadius: 24
                    )
                )
                .frame(width: 48, height: 48)

            // Inner orb
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.6 * opacity),
                            purple.opacity(0.45 * opacity),
                            teal.opacity(0),
                        ],
                        center: .center, startRadius: 0, endRadius: 10
                    )
                )
                .frame(width: 20, height: 20)

            // Bright core
            Circle()
                .fill(Color.white.opacity(0.8 * opacity))
                .frame(width: 4, height: 4)
        }
    }
}

// MARK: - Spark Skin

private struct SparkTapIndicator: View {
    let opacity: Double

    private let gold = Color(red: 1.0, green: 0.84, blue: 0.0)

    var body: some View {
        ZStack {
            // Flash core
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.9 * opacity),
                            gold.opacity(0.5 * opacity),
                            Color.clear,
                        ],
                        center: .center, startRadius: 0, endRadius: 10
                    )
                )
                .frame(width: 20, height: 20)

            // Expanding rays
            ForEach(0..<4, id: \.self) { i in
                Capsule()
                    .fill(gold.opacity(0.7 * opacity))
                    .frame(width: 1.5, height: 12)
                    .offset(y: -12)
                    .rotationEffect(.degrees(Double(i) * 90 + 45))
                    .scaleEffect(0.5 + 0.5 * (1 - opacity))
            }

            // Hot center
            Circle()
                .fill(Color.white.opacity(0.95 * opacity))
                .frame(width: 3, height: 3)
        }
    }
}

// MARK: - Ghost Skin

private struct GhostTapIndicator: View {
    let opacity: Double

    var body: some View {
        ZStack {
            // Subtle ring
            Circle()
                .stroke(Color.white.opacity(0.3 * opacity), lineWidth: 1)
                .frame(width: 24, height: 24)

            // Soft fill
            Circle()
                .fill(Color.white.opacity(0.06 * opacity))
                .frame(width: 24, height: 24)

            // Center dot
            Circle()
                .fill(Color.white.opacity(0.6 * opacity))
                .frame(width: 3, height: 3)
        }
        .shadow(color: Color.white.opacity(0.12 * opacity), radius: 6)
    }
}

// MARK: - Shared Shapes

private struct SwipeTrailShape: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
