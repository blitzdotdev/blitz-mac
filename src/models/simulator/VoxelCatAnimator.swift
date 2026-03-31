import Foundation
import simd
import CoreGraphics

// MARK: - Animation State

enum CatBehavior {
    case patrolling           // walking between waypoints
    case idlePause            // stopped, looking around
    case reaching             // paw over phone, watching laser
    case settling             // transitioning to idle after action
}

// MARK: - Cat Patrol State

struct CatWorldState {
    var position: CGPoint = .zero        // stage pixel coordinates
    var heading: Float = 0               // radians, 0 = facing screen-down (+Z)
    var behavior: CatBehavior = .patrolling
    var walkPhase: Float = 0             // 0...2π walk cycle
    var idleTimer: CFTimeInterval = 0    // time spent in current idle
    var idleDuration: CFTimeInterval = 2.5
    var patrolTarget: CGPoint = .zero
    var reachTarget: CGPoint? = nil      // phone-space laser target (stage coords)
    var reachSide: PhoneSide = .left     // which side the cat sits on
    var settleTimer: CFTimeInterval = 0
    var breathPhase: Float = 0
    var lastActionTime: CFTimeInterval = 0
}

enum PhoneSide {
    case left, right
}

// MARK: - Animator

final class VoxelCatAnimator {
    private let walkSpeed: CGFloat = 55       // pixels per second
    private let turnSpeed: Float = 3.5        // radians per second
    private let walkCycleSpeed: Float = 8.0   // radians per second
    private let idleMinDuration: CFTimeInterval = 1.8
    private let idleMaxDuration: CFTimeInterval = 4.5
    private let reachTimeout: CFTimeInterval = 2.5  // seconds after last action before settling
    private let settleTransitionTime: CFTimeInterval = 0.8

    /// Update the cat's world state given the current time and stage layout.
    func update(
        state: inout CatWorldState,
        dt: CFTimeInterval,
        stageSize: CGSize,
        phoneRect: CGRect?,
        laserTarget: CGPoint?,   // in stage coords, nil = no active laser
        now: CFTimeInterval
    ) {
        state.breathPhase += Float(dt) * 2.2

        switch state.behavior {
        case .patrolling:
            updatePatrol(state: &state, dt: dt, stageSize: stageSize, phoneRect: phoneRect)
        case .idlePause:
            updateIdle(state: &state, dt: dt, stageSize: stageSize, phoneRect: phoneRect)
        case .reaching:
            updateReaching(state: &state, dt: dt, phoneRect: phoneRect, now: now)
        case .settling:
            updateSettling(state: &state, dt: dt, stageSize: stageSize, phoneRect: phoneRect)
        }

        // Check for laser — transition to reaching if we see one
        if let laser = laserTarget, let phoneRect, state.behavior != .reaching {
            state.behavior = .reaching
            state.lastActionTime = now
            state.reachTarget = laser
            state.reachSide = laser.x < phoneRect.midX ? .left : .right
            pickReachPosition(state: &state, phoneRect: phoneRect)
        } else if let laser = laserTarget, state.behavior == .reaching {
            state.lastActionTime = now
            state.reachTarget = laser
        }
    }

    /// Generate the bone pose for the current state.
    func pose(for state: CatWorldState, now: CFTimeInterval) -> CatPose {
        var p = CatPose.rest

        let breath = sin(state.breathPhase) * 0.02

        switch state.behavior {
        case .patrolling:
            applyWalkCycle(&p, phase: state.walkPhase)
            p.set(.body, SIMD3(breath, 0, 0))

        case .idlePause:
            applyIdlePose(&p, state: state, now: now)
            p.set(.body, SIMD3(breath, 0, 0))

        case .reaching:
            applyReachPose(&p, state: state, now: now)

        case .settling:
            let t = Float(min(state.settleTimer / settleTransitionTime, 1.0))
            applySettlePose(&p, blendToIdle: t, state: state, now: now)
        }

        // Tail always has ambient sway
        let tailSway = sin(Float(now) * 2.3 + state.breathPhase) * 0.15
        let tailSway2 = sin(Float(now) * 3.1) * 0.12
        let tailSway3 = sin(Float(now) * 4.0) * 0.1
        p.boneAngles[CatBone.tail1.rawValue].y += tailSway
        p.boneAngles[CatBone.tail2.rawValue].y += tailSway2
        p.boneAngles[CatBone.tail3.rawValue].y += tailSway3

        return p
    }

    // MARK: - Patrol

    private func updatePatrol(state: inout CatWorldState, dt: CFTimeInterval, stageSize: CGSize, phoneRect: CGRect?) {
        let dx = state.patrolTarget.x - state.position.x
        let dy = state.patrolTarget.y - state.position.y
        let dist = hypot(dx, dy)

        if dist < 12 {
            // Arrived at waypoint
            state.behavior = .idlePause
            state.idleTimer = 0
            state.idleDuration = CFTimeInterval.random(in: idleMinDuration...idleMaxDuration)
            state.walkPhase = 0
            return
        }

        // Turn toward target
        let targetHeading = atan2(Float(dx), Float(dy))  // atan2(x,z) for heading
        var headingDiff = targetHeading - state.heading
        // Normalize to [-π, π]
        while headingDiff > .pi { headingDiff -= 2 * .pi }
        while headingDiff < -.pi { headingDiff += 2 * .pi }

        let maxTurn = turnSpeed * Float(dt)
        state.heading += max(-maxTurn, min(maxTurn, headingDiff))

        // Move forward
        let moveX = sin(state.heading) * Float(walkSpeed * CGFloat(dt))
        let moveZ = cos(state.heading) * Float(walkSpeed * CGFloat(dt))
        var nextPos = CGPoint(
            x: state.position.x + CGFloat(moveX),
            y: state.position.y + CGFloat(moveZ)
        )

        // Phone collision: if next position enters the phone rect, deflect
        if let phoneRect {
            let exclusion = phoneRect.insetBy(dx: -35, dy: -35)
            if exclusion.contains(nextPos) {
                // Push out to nearest edge and pick a new patrol target
                let _ = exclusion.midX
                let toLeft   = nextPos.x - exclusion.minX
                let toRight  = exclusion.maxX - nextPos.x
                let toTop    = nextPos.y - exclusion.minY
                let toBottom = exclusion.maxY - nextPos.y
                let minDist  = min(min(toLeft, toRight), min(toTop, toBottom))

                if minDist == toLeft        { nextPos.x = exclusion.minX - 2 }
                else if minDist == toRight  { nextPos.x = exclusion.maxX + 2 }
                else if minDist == toTop    { nextPos.y = exclusion.minY - 2 }
                else                        { nextPos.y = exclusion.maxY + 2 }

                state.patrolTarget = randomPatrolTarget(stageSize: stageSize, phoneRect: phoneRect, from: nextPos)
            }
        }

        // Clamp to stage bounds
        let margin: CGFloat = 20
        nextPos.x = max(margin, min(stageSize.width - margin, nextPos.x))
        nextPos.y = max(margin, min(stageSize.height - margin, nextPos.y))

        state.position = nextPos

        // Advance walk cycle
        state.walkPhase += walkCycleSpeed * Float(dt)
        if state.walkPhase > .pi * 2 { state.walkPhase -= .pi * 2 }
    }

    private func updateIdle(state: inout CatWorldState, dt: CFTimeInterval, stageSize: CGSize, phoneRect: CGRect?) {
        state.idleTimer += dt
        if state.idleTimer >= state.idleDuration {
            state.behavior = .patrolling
            state.patrolTarget = randomPatrolTarget(stageSize: stageSize, phoneRect: phoneRect, from: state.position)
        }
    }

    private func updateReaching(state: inout CatWorldState, dt: CFTimeInterval, phoneRect: CGRect?, now: CFTimeInterval) {
        guard let phoneRect else {
            state.behavior = .settling
            state.settleTimer = 0
            return
        }

        // Move toward reach position (near phone edge)
        let targetPos = reachPosition(state: state, phoneRect: phoneRect)
        let dx = targetPos.x - state.position.x
        let dy = targetPos.y - state.position.y
        let dist = hypot(dx, dy)

        if dist > 3 {
            let speed = walkSpeed * 1.6  // move faster when chasing
            let moveRatio = min(1, CGFloat(dt) * speed / dist)
            state.position.x += dx * moveRatio
            state.position.y += dy * moveRatio
            state.walkPhase += walkCycleSpeed * Float(dt) * 1.3
        }

        // Face the phone
        let phoneCenter = CGPoint(x: phoneRect.midX, y: phoneRect.midY)
        let toPhone = SIMD2<Float>(Float(phoneCenter.x - state.position.x), Float(phoneCenter.y - state.position.y))
        state.heading = atan2(toPhone.x, toPhone.y)

        // Check if action timed out
        if now - state.lastActionTime > reachTimeout {
            state.behavior = .settling
            state.settleTimer = 0
        }
    }

    private func updateSettling(state: inout CatWorldState, dt: CFTimeInterval, stageSize: CGSize, phoneRect: CGRect?) {
        state.settleTimer += dt
        if state.settleTimer >= settleTransitionTime {
            state.behavior = .patrolling
            state.patrolTarget = randomPatrolTarget(stageSize: stageSize, phoneRect: phoneRect, from: state.position)
        }
    }

    // MARK: - Pose Application

    private func applyWalkCycle(_ pose: inout CatPose, phase: Float) {
        let swing: Float = 0.45  // leg swing amplitude
        // Diagonal gait: front-left + rear-right, then front-right + rear-left
        let fl = sin(phase) * swing
        let fr = sin(phase + .pi) * swing
        let rl = sin(phase + .pi) * swing * 0.8
        let rr = sin(phase) * swing * 0.8

        pose.set(.frontLeftUpperLeg, SIMD3(fl, 0, 0))
        pose.set(.frontLeftLowerLeg, SIMD3(max(0, -fl) * 0.5, 0, 0))
        pose.set(.frontRightUpperLeg, SIMD3(fr, 0, 0))
        pose.set(.frontRightLowerLeg, SIMD3(max(0, -fr) * 0.5, 0, 0))
        pose.set(.rearLeftUpperLeg, SIMD3(rl, 0, 0))
        pose.set(.rearLeftLowerLeg, SIMD3(max(0, -rl) * 0.4, 0, 0))
        pose.set(.rearRightUpperLeg, SIMD3(rr, 0, 0))
        pose.set(.rearRightLowerLeg, SIMD3(max(0, -rr) * 0.4, 0, 0))

        // Subtle body bob
        let bob = sin(phase * 2) * 0.03
        pose.set(.body, SIMD3(bob, 0, 0))

        // Head stays level-ish, slight counter-bob
        pose.set(.head, SIMD3(-bob * 0.5, 0, 0))
    }

    private func applyIdlePose(_ pose: inout CatPose, state: CatWorldState, now: CFTimeInterval) {
        // Occasional head look-around
        let lookPhase = Float(now) * 0.8
        let headYaw = sin(lookPhase) * 0.3
        let headTilt = sin(lookPhase * 0.7) * 0.08
        pose.set(.head, SIMD3(headTilt, headYaw, 0))

        // Ears flick
        let earFlick = sin(Float(now) * 5.3)
        if earFlick > 0.85 {
            pose.set(.leftEar, SIMD3(-0.25, 0, 0))
        }
        if earFlick < -0.85 {
            pose.set(.rightEar, SIMD3(-0.25, 0, 0))
        }
    }

    private func applyReachPose(_ pose: inout CatPose, state: CatWorldState, now: CFTimeInterval) {
        let breath = sin(state.breathPhase) * 0.015
        pose.set(.body, SIMD3(breath - 0.05, 0, 0))  // slight lean forward

        // Reaching leg — extend one front leg forward and slightly down
        let reachArm: Float = -0.6   // forward swing
        let reachLower: Float = 0.25  // paw extension
        let pawWiggle = sin(Float(now) * 4.0) * 0.08

        if state.reachSide == .left {
            pose.set(.frontLeftUpperLeg, SIMD3(reachArm + pawWiggle, -0.15, 0))
            pose.set(.frontLeftLowerLeg, SIMD3(reachLower, 0, 0))
            // Other leg normal
            pose.set(.frontRightUpperLeg, SIMD3(0.05, 0, 0))
        } else {
            pose.set(.frontRightUpperLeg, SIMD3(reachArm + pawWiggle, 0.15, 0))
            pose.set(.frontRightLowerLeg, SIMD3(reachLower, 0, 0))
            pose.set(.frontLeftUpperLeg, SIMD3(0.05, 0, 0))
        }

        // Head tracks laser target slightly
        let headTrack = sin(Float(now) * 1.5) * 0.15
        pose.set(.head, SIMD3(-0.12, headTrack, 0))

        // Tail excitement
        let tailExcite = sin(Float(now) * 6.0) * 0.3
        pose.boneAngles[CatBone.tail1.rawValue].y += tailExcite
        pose.boneAngles[CatBone.tail1.rawValue].x = 0.3  // tail up
        pose.boneAngles[CatBone.tail2.rawValue].x = 0.15

        // Ears forward (alert)
        pose.set(.leftEar, SIMD3(0.15, 0.1, 0))
        pose.set(.rightEar, SIMD3(0.15, -0.1, 0))
    }

    private func applySettlePose(_ pose: inout CatPose, blendToIdle: Float, state: CatWorldState, now: CFTimeInterval) {
        // Blend from reach pose to idle
        var reachPose = CatPose.rest
        applyReachPose(&reachPose, state: state, now: now)
        var idlePose = CatPose.rest
        applyIdlePose(&idlePose, state: state, now: now)

        for bone in CatBone.allCases {
            let r = reachPose.get(bone)
            let i = idlePose.get(bone)
            pose.set(bone, r + (i - r) * blendToIdle)
        }
    }

    // MARK: - Helpers

    func randomPatrolTarget(stageSize: CGSize, phoneRect: CGRect?, from: CGPoint) -> CGPoint {
        let margin: CGFloat = 40
        for _ in 0..<20 {
            let x = CGFloat.random(in: margin...(stageSize.width - margin))
            let y = CGFloat.random(in: margin...(stageSize.height - margin))
            let pt = CGPoint(x: x, y: y)

            // Avoid phone rect
            if let phoneRect {
                let expanded = phoneRect.insetBy(dx: -30, dy: -30)
                if expanded.contains(pt) { continue }
            }

            // Don't pick something too close
            if hypot(pt.x - from.x, pt.y - from.y) < 60 { continue }

            return pt
        }
        // Fallback
        return CGPoint(x: margin + 50, y: margin + 50)
    }

    private func pickReachPosition(state: inout CatWorldState, phoneRect: CGRect) {
        // Position cat just outside the phone on the chosen side
    }

    private func reachPosition(state: CatWorldState, phoneRect: CGRect) -> CGPoint {
        let offsetFromEdge: CGFloat = 45
        switch state.reachSide {
        case .left:
            return CGPoint(x: phoneRect.minX - offsetFromEdge, y: phoneRect.midY)
        case .right:
            return CGPoint(x: phoneRect.maxX + offsetFromEdge, y: phoneRect.midY)
        }
    }

    /// Initialize a cat's starting position
    func initializePosition(state: inout CatWorldState, stageSize: CGSize, phoneRect: CGRect?) {
        // Start in a corner area
        let margin: CGFloat = 60
        state.position = CGPoint(
            x: CGFloat.random(in: margin...(stageSize.width - margin)),
            y: CGFloat.random(in: margin...min(margin + 100, stageSize.height - margin))
        )
        // Avoid phone
        if let phoneRect, phoneRect.insetBy(dx: -40, dy: -40).contains(state.position) {
            state.position = CGPoint(x: margin, y: margin)
        }
        state.patrolTarget = randomPatrolTarget(stageSize: stageSize, phoneRect: phoneRect, from: state.position)
        state.heading = Float.random(in: 0...(2 * .pi))
    }
}
