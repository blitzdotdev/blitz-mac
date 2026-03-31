import SwiftUI

/// Transparent overlay that captures touch/click events and translates to device actions.
/// Renders laser-pointer-style indicators: neon dots for taps, plasma trails for swipes.
struct TouchOverlayView: View {
    let deviceConfig: SimulatorDeviceConfig
    let frameWidth: Int
    let frameHeight: Int
    let onTap: (Double, Double) -> Void
    /// (fromX, fromY, toX, toY, duration, delta)
    let onSwipe: (Double, Double, Double, Double, Double, Int) -> Void

    @State private var dragStart: CGPoint?
    @State private var dragStartTime: Date?
    @State private var clickMarkers: [ClickMarker] = []
    @State private var swipePath: [CGPoint] = []

    struct ClickMarker: Identifiable {
        let id = UUID()
        let position: CGPoint
        var opacity: Double = 1.0
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
                                // Tap
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

                                let marker = ClickMarker(position: end)
                                clickMarkers.append(marker)
                                withAnimation(.easeOut(duration: 0.6)) {
                                    if let index = clickMarkers.firstIndex(where: { $0.id == marker.id }) {
                                        clickMarkers[index].opacity = 0
                                    }
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                                    clickMarkers.removeAll { $0.id == marker.id }
                                }
                            } else {
                                // Swipe
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
                    // Laser dot indicators
                    ForEach(clickMarkers) { marker in
                        LaserDotView(opacity: marker.opacity)
                            .position(marker.position)
                    }

                    // Laser trail for active swipe
                    if swipePath.count > 1 {
                        LaserTrailShape(points: swipePath)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color(red: 1.0, green: 0.15, blue: 0.1).opacity(0.3),
                                        Color(red: 1.0, green: 0.2, blue: 0.15).opacity(0.8),
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ),
                                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                            )
                            .shadow(color: Color(red: 1.0, green: 0.1, blue: 0.08).opacity(0.7), radius: 6)
                            .shadow(color: Color(red: 1.0, green: 0.2, blue: 0.1).opacity(0.35), radius: 14)
                    }
                }
        }
    }
}

// MARK: - Laser Dot View

private struct LaserDotView: View {
    let opacity: Double

    var body: some View {
        ZStack {
            // Outer glow
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 1.0, green: 0.1, blue: 0.08).opacity(0.5 * opacity),
                            Color(red: 1.0, green: 0.1, blue: 0.08).opacity(0),
                        ],
                        center: .center,
                        startRadius: 2,
                        endRadius: 20
                    )
                )
                .frame(width: 40, height: 40)

            // Bright core
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 1.0, green: 0.85, blue: 0.8).opacity(opacity),
                            Color(red: 1.0, green: 0.2, blue: 0.15).opacity(0.8 * opacity),
                            Color(red: 1.0, green: 0.1, blue: 0.08).opacity(0),
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 8
                    )
                )
                .frame(width: 16, height: 16)

            // Center point
            Circle()
                .fill(Color.white.opacity(0.95 * opacity))
                .frame(width: 4, height: 4)
        }
    }
}

// MARK: - Laser Trail Shape

private struct LaserTrailShape: Shape {
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
