import Foundation
import CoreGraphics
import simd

final class SimulatorCatSceneModel {
    enum RenderMode {
        case simulatorStage
        case catsOnlyFullscreen
    }

    enum RemoteActionKind {
        case tap
        case swipe
        case button
    }

    // MARK: - Laser Effect

    struct LaserDot: Sendable {
        let stagePosition: CGPoint     // position in stage pixel coords
        let phoneNormalized: CGPoint   // normalized within phone rect (0-1)
        let startTime: CFTimeInterval
    }

    struct LaserTrail: Sendable {
        let fromStage: CGPoint
        let toStage: CGPoint
        let fromNorm: CGPoint
        let toNorm: CGPoint
        let startTime: CFTimeInterval
    }

    // MARK: - Snapshot (sent to renderer each frame)

    struct Snapshot: Sendable {
        let stageSize: CGSize
        let phoneRect: CGRect
        let phoneVisible: Bool
        let catVertices: [VoxelVertex]
        let laserDots: [LaserDot]
        let laserTrails: [LaserTrail]
        let time: Float
    }

    // MARK: - Private State

    private let lock = NSLock()
    private var catState = CatWorldState()
    private let animator = VoxelCatAnimator()
    private var isInitialized = false
    private var lastUpdateTime: CFTimeInterval = 0

    private var laserDots: [LaserDot] = []
    private var laserTrails: [LaserTrail] = []
    private var pendingFullscreenOnNextOpen = false

    private let laserDotLifetime: CFTimeInterval = 0.8
    private let laserTrailLifetime: CFTimeInterval = 1.2

    // MARK: - Public API (matches existing interface)

    func requestFullscreenOnNextOpen() {
        lock.withLock { pendingFullscreenOnNextOpen = true }
    }

    func consumePendingFullscreenRequest() -> Bool {
        lock.withLock {
            let v = pendingFullscreenOnNextOpen
            pendingFullscreenOnNextOpen = false
            return v
        }
    }

    func recordTap(at normalizedPoint: CGPoint, now: CFTimeInterval = CFAbsoluteTimeGetCurrent()) {
        lock.withLock {
            // We'll compute stage position in snapshot() using phoneRect
            laserDots.append(LaserDot(
                stagePosition: .zero,  // filled in during snapshot
                phoneNormalized: normalizedPoint,
                startTime: now
            ))
            laserDots = Array(laserDots.suffix(6))
            catState.lastActionTime = now
        }
    }

    func recordSwipe(from: CGPoint, to: CGPoint, now: CFTimeInterval = CFAbsoluteTimeGetCurrent()) {
        lock.withLock {
            laserTrails.append(LaserTrail(
                fromStage: .zero,
                toStage: .zero,
                fromNorm: from,
                toNorm: to,
                startTime: now
            ))
            laserTrails = Array(laserTrails.suffix(4))
            catState.lastActionTime = now
        }
    }

    func recordButtonPress(side: SimulatorCatSceneModel.ButtonSide = .bottom, now: CFTimeInterval = CFAbsoluteTimeGetCurrent()) {
        lock.withLock {
            catState.lastActionTime = now
        }
    }

    enum ButtonSide { case left, right, top, bottom }

    func recordRemoteAction(
        kind: RemoteActionKind,
        preferredSide: ButtonSide? = nil,
        now: CFTimeInterval = CFAbsoluteTimeGetCurrent()
    ) {
        lock.withLock {
            catState.lastActionTime = now
        }
    }

    // MARK: - Snapshot Generation

    func snapshot(
        stageSize: CGSize,
        phoneRect: CGRect?,
        mode: RenderMode,
        now: CFTimeInterval = CFAbsoluteTimeGetCurrent()
    ) -> Snapshot {
        lock.lock()

        let choreRect = choreographyRect(for: phoneRect, in: stageSize, mode: mode)

        // Initialize cat if needed
        if !isInitialized || stageSize.width < 1 {
            animator.initializePosition(state: &catState, stageSize: stageSize, phoneRect: choreRect.width > 0 ? choreRect : nil)
            isInitialized = true
            lastUpdateTime = now
        }

        // Compute dt
        let dt = min(now - lastUpdateTime, 0.05)  // cap at 50ms to prevent jumps
        lastUpdateTime = now

        // Resolve laser positions in stage coords
        let activeDots = laserDots.filter { now - $0.startTime < laserDotLifetime }
        let activeTrails = laserTrails.filter { now - $0.startTime < laserTrailLifetime }
        laserDots = activeDots
        laserTrails = activeTrails

        let resolvedDots: [LaserDot] = activeDots.map { dot in
            let sx = choreRect.minX + choreRect.width * dot.phoneNormalized.x
            let sy = choreRect.minY + choreRect.height * dot.phoneNormalized.y
            return LaserDot(stagePosition: CGPoint(x: sx, y: sy), phoneNormalized: dot.phoneNormalized, startTime: dot.startTime)
        }

        let resolvedTrails: [LaserTrail] = activeTrails.map { trail in
            LaserTrail(
                fromStage: CGPoint(
                    x: choreRect.minX + choreRect.width * trail.fromNorm.x,
                    y: choreRect.minY + choreRect.height * trail.fromNorm.y
                ),
                toStage: CGPoint(
                    x: choreRect.minX + choreRect.width * trail.toNorm.x,
                    y: choreRect.minY + choreRect.height * trail.toNorm.y
                ),
                fromNorm: trail.fromNorm,
                toNorm: trail.toNorm,
                startTime: trail.startTime
            )
        }

        // Determine laser target for cat AI
        let laserTarget: CGPoint?
        if let lastDot = resolvedDots.last {
            laserTarget = lastDot.stagePosition
        } else if let lastTrail = resolvedTrails.last {
            laserTarget = lastTrail.toStage
        } else {
            laserTarget = nil
        }

        // Update cat AI
        let phoneRectForAI = (mode == .simulatorStage && phoneRect != nil) ? choreRect : nil
        animator.update(
            state: &catState,
            dt: dt,
            stageSize: stageSize,
            phoneRect: phoneRectForAI,
            laserTarget: laserTarget,
            now: now
        )

        // Generate pose and vertices
        let pose = animator.pose(for: catState, now: now)
        let scale: Float = Float(min(max(stageSize.height * 0.012, 3.5), 6.5))
        let vertices = VoxelCatModel.generateVertices(
            pose: pose,
            rootPosition: SIMD2<Float>(Float(catState.position.x), Float(catState.position.y)),
            heading: catState.heading,
            scale: scale
        )

        lock.unlock()

        return Snapshot(
            stageSize: stageSize,
            phoneRect: choreRect,
            phoneVisible: mode == .simulatorStage && phoneRect != nil,
            catVertices: vertices,
            laserDots: resolvedDots,
            laserTrails: resolvedTrails,
            time: Float(now)
        )
    }

    // MARK: - Helpers

    private func choreographyRect(for phoneRect: CGRect?, in stageSize: CGSize, mode: RenderMode) -> CGRect {
        if let phoneRect, mode == .simulatorStage {
            return phoneRect
        }
        let width = min(stageSize.width * 0.24, 240)
        let height = min(stageSize.height * 0.62, 620)
        return CGRect(
            x: stageSize.width / 2 - width / 2,
            y: stageSize.height / 2 - height / 2,
            width: width,
            height: height
        )
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
