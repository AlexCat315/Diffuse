import Foundation
import Testing
@testable import GuavaUICompose

@Suite("Phase D4 polish: detach distance threshold")
struct DockDetachThresholdTests {

    private func makeSession() -> (DockController, DockDragSession, DockTab, DockNodeID) {
        let tab = DockTab(userKey: "k", title: "K")
        let leaf = DockLayoutNode.tabs([tab])
        let leafID = leaf.id
        let root = DockLayoutNode.hsplit(first: leaf, second: .empty())
        let controller = DockController(root: root)
        return (controller, controller.dragSession, tab, leafID)
    }

    @Test("Release outside hosts within threshold does NOT detach")
    func belowThresholdSwallowed() {
        let (controller, session, tab, leafID) = makeSession()
        let baseline = controller.version
        session.start(tabID: tab.id,
                      sourceLeafID: leafID,
                      ghost: .init(title: "K"),
                      x: 10, y: 10,
                      globalX: 100, globalY: 100,
                      origin: .mainTreeTab)
        // Pretend the cluster reports "outside" but pointer barely moved.
        session.forceCrossWindowState_forTesting(globalX: 110, globalY: 110,
                                                 isOutsideAllHosts: true)
        session.end(commit: true)
        #expect(controller.version == baseline,
                "controller should not mutate when below detach threshold")
    }

    @Test("Release outside hosts past threshold triggers detach")
    func aboveThresholdDetaches() {
        let (controller, session, tab, leafID) = makeSession()
        let baseline = controller.version
        session.start(tabID: tab.id,
                      sourceLeafID: leafID,
                      ghost: .init(title: "K"),
                      x: 10, y: 10,
                      globalX: 100, globalY: 100,
                      origin: .mainTreeTab)
        session.forceCrossWindowState_forTesting(globalX: 100 + DockDragSession.detachDistanceThreshold + 1,
                                                 globalY: 100,
                                                 isOutsideAllHosts: true)
        session.end(commit: true)
        #expect(controller.version > baseline)
        #expect(controller.satellites.keys.contains(leafID),
                "leaf should have been detached into a satellite")
    }
}

// MARK: - Test-only state injection

extension DockDragSession {
    /// Forcibly stamp the cross-window state without going through a
    /// `DockHostCoordinator`. Mirrors what `updatePointerCrossWindow`
    /// would set so threshold logic can be exercised in isolation.
    func forceCrossWindowState_forTesting(globalX: Float,
                                          globalY: Float,
                                          isOutsideAllHosts: Bool) {
        applyCrossWindowState(globalX: globalX,
                              globalY: globalY,
                              isOutsideAllHosts: isOutsideAllHosts)
    }
}
