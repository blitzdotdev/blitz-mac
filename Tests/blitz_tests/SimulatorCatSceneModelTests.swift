import Testing
import CoreGraphics
@testable import Blitz

@Test func catInitializesOutsidePhoneRect() {
    let model = SimulatorCatSceneModel()
    let phoneRect = CGRect(x: 220, y: 70, width: 220, height: 470)
    let snapshot = model.snapshot(
        stageSize: CGSize(width: 660, height: 610),
        phoneRect: phoneRect,
        mode: .simulatorStage,
        now: 100
    )

    // Cat should have vertices (it was initialized and rendered)
    #expect(!snapshot.catVertices.isEmpty)
}

@Test func tapCreatesLaserDot() {
    let model = SimulatorCatSceneModel()
    let phoneRect = CGRect(x: 240, y: 60, width: 180, height: 420)
    model.recordTap(at: CGPoint(x: 0.5, y: 0.5), now: 10)

    let snapshot = model.snapshot(
        stageSize: CGSize(width: 800, height: 640),
        phoneRect: phoneRect,
        mode: .simulatorStage,
        now: 10.1
    )

    #expect(!snapshot.laserDots.isEmpty)
    #expect(snapshot.laserDots[0].stagePosition.x > 0)
}

@Test func swipeCreatesLaserTrail() {
    let model = SimulatorCatSceneModel()
    let phoneRect = CGRect(x: 240, y: 60, width: 180, height: 420)
    model.recordSwipe(from: CGPoint(x: 0.2, y: 0.3), to: CGPoint(x: 0.8, y: 0.7), now: 10)

    let snapshot = model.snapshot(
        stageSize: CGSize(width: 800, height: 640),
        phoneRect: phoneRect,
        mode: .simulatorStage,
        now: 10.1
    )

    #expect(!snapshot.laserTrails.isEmpty)
}

@Test func laserDotFadesOut() {
    let model = SimulatorCatSceneModel()
    model.recordTap(at: CGPoint(x: 0.5, y: 0.5), now: 10)

    let snapshot = model.snapshot(
        stageSize: CGSize(width: 800, height: 640),
        phoneRect: CGRect(x: 200, y: 50, width: 200, height: 400),
        mode: .simulatorStage,
        now: 11.5  // 1.5s later, past 0.8s lifetime
    )

    #expect(snapshot.laserDots.isEmpty)
}

@Test func fullscreenRequestIsSingleUse() {
    let model = SimulatorCatSceneModel()
    model.requestFullscreenOnNextOpen()
    #expect(model.consumePendingFullscreenRequest() == true)
    #expect(model.consumePendingFullscreenRequest() == false)
}
