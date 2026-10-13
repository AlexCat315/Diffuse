#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import EngineKernel
import PlatformShell
import Testing
@testable import GuavaUIRuntime

@Suite("Multi-window smoke")
struct MultiWindowSmokeTests {
    @MainActor
    @Test("Each routed event reaches only its own window session")
    func routesEventsPerWindow() throws {
        let shell = MockShell(eventBatches: [])
        let host = SDL3PlatformHost(shellFactory: { shell })

        let treeA = NodeTree()
        let treeB = NodeTree()
        var hitsA = 0
        var hitsB = 0

        let sessionA = try host.openWindow(title: "A", tree: treeA)
        let sessionB = try host.openWindow(title: "B", tree: treeB)

        treeA.root = makeHitTree(interactions: sessionA.interactions) { hitsA += 1 }
        treeB.root = makeHitTree(interactions: sessionB.interactions) { hitsB += 1 }

        var sessionAHadCurrentContext = false
        var sessionBHadCurrentContext = false
        sessionA.onEvent = { _ in
            sessionAHadCurrentContext = (InteractionRegistryHolder.current === sessionA.interactions)
                && (FocusChainHolder.current === sessionA.focusChain)
                && (PointerCaptureHolder.current === sessionA.pointerCapture)
        }
        sessionB.onEvent = { _ in
            sessionBHadCurrentContext = (InteractionRegistryHolder.current === sessionB.interactions)
                && (FocusChainHolder.current === sessionB.focusChain)
                && (PointerCaptureHolder.current === sessionB.pointerCapture)
        }

        shell.eventBatches = [[
            WindowInputEvent(windowID: sessionA.id,
                             event: .mouseButtonDown(MouseButtonEvent(button: .left, x: 12, y: 12, clicks: 1))),
            WindowInputEvent(windowID: sessionB.id,
                             event: .mouseButtonDown(MouseButtonEvent(button: .left, x: 18, y: 18, clicks: 1))),
        ]]

        host.run()

        #expect(hitsA == 1)
        #expect(hitsB == 1)
        #expect(sessionAHadCurrentContext)
        #expect(sessionBHadCurrentContext)
    }

    @MainActor
    @Test("Cursor requests are routed to the matching native window")
    func routesCursorPerWindow() throws {
        let shell = MockShell(eventBatches: [])
        let host = SDL3PlatformHost(shellFactory: { shell })

        let treeA = NodeTree()
        let treeB = NodeTree()
        let sessionA = try host.openWindow(title: "A", tree: treeA)
        let sessionB = try host.openWindow(title: "B", tree: treeB)

        treeA.root = makeCursorTree(cursor: .pointer)
        treeB.root = makeCursorTree(cursor: .move)

        shell.eventBatches = [[
            WindowInputEvent(windowID: sessionA.id,
                             event: .mouseMotion(MouseMotionEvent(x: 16, y: 16, deltaX: 1, deltaY: 1))),
            WindowInputEvent(windowID: sessionB.id,
                             event: .mouseMotion(MouseMotionEvent(x: 16, y: 16, deltaX: 1, deltaY: 1))),
        ]]

        host.run()

        #expect(shell.cursorRequests.contains { $0.windowID == sessionA.id && $0.cursor == .pointer })
        #expect(shell.cursorRequests.contains { $0.windowID == sessionB.id && $0.cursor == .move })
    }

    @MainActor
    @Test("Render-dirty nodes trigger a frame without global animation forcing")
    func renderDirtyTriggersFrame() throws {
        let shell = MockShell(eventBatches: [[], [], []])
        let host = SDL3PlatformHost(shellFactory: { shell })

        let tree = NodeTree()
        let session = try host.openWindow(title: "A", tree: tree)
        let root = Node()
        let leaf = Node()
        root.addChild(leaf)
        tree.root = root

        (shell.window(for: session.id) as? MockWindowHandle)?.renderSurface = mockSurface

        var frameCount = 0
        session.onFrame = { _ in
            frameCount += 1
            if frameCount == 1 {
                leaf.opacity = 0.5
                session.requestDisplay()
            }
            return true
        }

        host.run()

        #expect(frameCount == 2)
    }

    @MainActor
    @Test("Window input events request a redraw after the initial frame")
    func inputEventsRequestRedraw() throws {
        let shell = MockShell(eventBatches: [[], [], []])
        let host = SDL3PlatformHost(shellFactory: { shell })

        let tree = NodeTree()
        let session = try host.openWindow(title: "A", tree: tree)
        tree.root = makeHitTree(interactions: session.interactions) {}
        (shell.window(for: session.id) as? MockWindowHandle)?.renderSurface = mockSurface

        shell.eventBatches = [
            [],
            [WindowInputEvent(windowID: session.id,
                              event: .mouseButtonDown(MouseButtonEvent(button: .left,
                                                                       x: 12,
                                                                       y: 12,
                                                                       clicks: 1)))],
            [],
        ]

        var frameCount = 0
        session.onFrame = { _ in
            frameCount += 1
            return true
        }

        host.run()

        #expect(frameCount == 2)
    }

    @MainActor
    @Test("External display requests redraw every open window")
    func externalDisplayRequestsRedrawEveryWindow() throws {
        let shell = MockShell(eventBatches: [[], [], []])
        let host = SDL3PlatformHost(shellFactory: { shell })

        let treeA = NodeTree()
        let treeB = NodeTree()
        let sessionA = try host.openWindow(title: "A", tree: treeA)
        let sessionB = try host.openWindow(title: "B", tree: treeB)
        treeA.root = Node()
        treeB.root = Node()
        (shell.window(for: sessionA.id) as? MockWindowHandle)?.renderSurface = mockSurface
        (shell.window(for: sessionB.id) as? MockWindowHandle)?.renderSurface = mockSurface

        var drainCount = 0
        host.externalDisplayRequestDrain = {
            drainCount += 1
            return drainCount == 2
        }

        var framesA = 0
        var framesB = 0
        sessionA.onFrame = { _ in
            framesA += 1
            return true
        }
        sessionB.onFrame = { _ in
            framesB += 1
            return true
        }

        host.run()

        #expect(framesA == 2)
        #expect(framesB == 2)
    }

    @MainActor
    @Test("Native display callbacks drive each window independently without timer polling")
    func nativeDisplayRefreshUsesPerWindowSignals() throws {
        let shell = MockShell(eventBatches: Array(repeating: [], count: 5))
        shell.nativeRefresh.supported = true
        let host = SDL3PlatformHost(shellFactory: { shell })
        host.setFrameRateMode(.displayRefresh)
        let a = try host.openWindow(title: "A", tree: NodeTree())
        let b = try host.openWindow(title: "B", tree: NodeTree())
        (shell.window(for: a.id) as? MockWindowHandle)?.renderSurface = mockSurface
        (shell.window(for: b.id) as? MockWindowHandle)?.renderSurface = mockSurface
        var time = 100.0
        host.frameClock = { time }
        var poll = 0
        shell.onPoll = {
            defer { poll += 1; time += 0.004 }
            let id: WindowID?
            switch poll {
            case 1, 4: id = a.id
            case 3: id = b.id
            default: id = nil
            }
            if let id {
                let target = poll == 1 ? 100.040 : poll == 3 ? 100.030 : 100.060
                shell.nativeRefresh.pending[id] = .init(timestamp: time, targetTimestamp: target)
            }
        }
        var framesA = 0
        var framesB = 0
        var preparationDeltas: [Double] = []
        a.onFrame = { _ in framesA += 1; return true }
        b.onFrame = { _ in framesB += 1; return true }
        host.onBeforeCommit = { preparationDeltas.append($0) }
        host.run()
        #expect(framesA == 2)
        #expect(framesB == 1)
        #expect(preparationDeltas.count == 3)
        #expect(preparationDeltas[1] == 0)
        #expect(abs(preparationDeltas[2] - 0.020) < 1e-9)
        #expect(shell.waitTimeouts.allSatisfy { $0 == 0.25 })
    }

    @MainActor
    @Test("Native callbacks queued during present trigger the next frame without another period wait")
    func nativeRefreshAvoidsDoubleThrottle() throws {
        let shell = MockShell(eventBatches: [[], [], []])
        shell.nativeRefresh.supported = true
        let host = SDL3PlatformHost(shellFactory: { shell })
        host.setFrameRateMode(.displayRefresh)
        let session = try host.openWindow(title: "Blocked present", tree: NodeTree())
        (shell.window(for: session.id) as? MockWindowHandle)?.renderSurface = mockSurface
        var time = 100.0
        host.frameClock = { time }
        shell.nativeRefresh.pending[session.id] = .init(timestamp: time, targetTimestamp: time + 0.016)
        shell.onWait = { _ in
            #expect(!shell.nativeRefresh.pending.isEmpty)
            return true
        }
        var frameTimes: [Double] = []
        session.onFrame = { _ in
            frameTimes.append(time)
            time += 0.020
            shell.nativeRefresh.pending[session.id] = .init(timestamp: time, targetTimestamp: time + 0.016)
            return true
        }
        host.run()
        #expect(frameTimes.count == 3)
        for (previous, current) in zip(frameTimes, frameTimes.dropFirst()) {
            #expect(abs(current - previous - 0.020) < 1e-9)
        }
    }

    @MainActor
    @Test("Native animation ticks preserve input responsiveness and stop when animations finish")
    func nativeAnimationInputAndStop() throws {
        let shell = MockShell(eventBatches: [[], [], [], []])
        shell.nativeRefresh.supported = true
        let host = SDL3PlatformHost(shellFactory: { shell })
        let tree = NodeTree()
        tree.root = Node()
        let session = try host.openWindow(title: "Animation", tree: tree)
        (shell.window(for: session.id) as? MockWindowHandle)?.renderSurface = mockSurface
        shell.eventBatches[1] = [
            .init(windowID: session.id, event: .mouseMotion(.init(x: 8, y: 8, deltaX: 1, deltaY: 0))),
        ]
        var time = 100.0
        var poll = 0
        host.frameClock = { time }
        shell.onPoll = {
            defer { poll += 1; time += 0.003 }
            if poll == 2 {
                shell.nativeRefresh.pending[session.id] = .init(timestamp: time, targetTimestamp: time + 0.016)
            }
        }
        let scheduler = AnimatorScheduler()
        let controller = TickCountingController()
        scheduler.register(controller)
        var frameCount = 0
        var ticksAtInput: Int?
        session.onEvent = { _ in ticksAtInput = controller.tickCount }
        session.onFrame = { _ in frameCount += 1; return true }
        AnimatorScheduler.$current.withValue(scheduler) { host.run() }
        #expect(ticksAtInput == 0)
        #expect(controller.tickCount == 1)
        #expect(frameCount == 2)
        #expect(shell.nativeRefresh.requests[session.id]?.contains(false) == true)
        #expect(shell.waitTimeouts.allSatisfy { $0 == 0.25 })
    }

    @MainActor
    @Test("Display-refresh frame-rate mode drives cadence frames")
    func displayRefreshModeDrivesCadenceFrames() throws {
        let shell = MockShell(eventBatches: Array(repeating: [], count: 32))
        shell.refreshRate = 240
        shell.pollDelay = 0.001
        let host = SDL3PlatformHost(shellFactory: { shell })
        host.setFrameRateMode(.displayRefresh)

        let tree = NodeTree()
        let session = try host.openWindow(title: "A", tree: tree)
        tree.root = Node()
        (shell.window(for: session.id) as? MockWindowHandle)?.renderSurface = mockSurface

        var frameCount = 0
        session.onFrame = { _ in
            frameCount += 1
            return true
        }

        host.run()

        #expect(frameCount > 1)
    }

    @MainActor
    @Test("Display-refresh mode falls back when reported refresh is implausibly low")
    func displayRefreshModeFallsBackForImplausiblyLowReportedRefresh() throws {
        let shell = MockShell(eventBatches: [[]])
        shell.refreshRate = 11
        let host = SDL3PlatformHost(shellFactory: { shell })
        host.setFrameRateMode(.displayRefresh)

        let tree = NodeTree()
        let session = try host.openWindow(title: "A", tree: tree)
        tree.root = Node()
        (shell.window(for: session.id) as? MockWindowHandle)?.renderSurface = mockSurface

        var deltas: [Double] = []
        host.onBeforeCommit = { deltaTime in
            deltas.append(deltaTime)
        }
        session.onFrame = { _ in true }

        host.run()

        #expect((deltas.first ?? 1) < 0.02)
    }

    @MainActor
    @Test("Event-driven frame delta excludes idle time")
    func eventDrivenFrameDeltaExcludesIdleTime() throws {
        let shell = MockShell(eventBatches: [])
        var frameTime = 100.0
        shell.onPoll = { frameTime += 0.005 }
        let host = SDL3PlatformHost(shellFactory: { shell })
        host.frameClock = { frameTime }
        host.setFrameRateMode(.eventDriven)

        let tree = NodeTree()
        let session = try host.openWindow(title: "A", tree: tree)
        tree.root = Node()
        (shell.window(for: session.id) as? MockWindowHandle)?.renderSurface = mockSurface

        shell.eventBatches = Array(repeating: [], count: 8) + [[
            WindowInputEvent(windowID: session.id,
                             event: .mouseMotion(MouseMotionEvent(x: 8, y: 8, deltaX: 1, deltaY: 0))),
        ]]

        var deltas: [Double] = []
        host.onBeforeCommit = { deltaTime in
            deltas.append(deltaTime)
        }
        session.onFrame = { _ in true }

        host.run()

        #expect(deltas.count >= 2)
        #expect(abs((deltas.last ?? 1) - 0.005) < 1e-9)
    }

    @MainActor
    @Test("Event-driven host waits for events when no frame is pending")
    func eventDrivenHostWaitsWhenIdle() throws {
        let shell = MockShell(eventBatches: [[], [], []])
        let host = SDL3PlatformHost(shellFactory: { shell })
        host.setFrameRateMode(.eventDriven)

        let tree = NodeTree()
        let session = try host.openWindow(title: "A", tree: tree)
        tree.root = Node()
        (shell.window(for: session.id) as? MockWindowHandle)?.renderSurface = mockSurface
        session.onFrame = { _ in true }

        host.run()

        #expect(!shell.waitTimeouts.isEmpty)
        #expect(shell.waitTimeouts.allSatisfy { $0 > 0 })
    }

    @MainActor
    @Test("Active animations alone do not force extra frames")
    func activeAnimationsDoNotForceFrames() throws {
        let shell = MockShell(eventBatches: [[], []])
        let host = SDL3PlatformHost(shellFactory: { shell })

        let tree = NodeTree()
        let session = try host.openWindow(title: "A", tree: tree)
        tree.root = Node()
        (shell.window(for: session.id) as? MockWindowHandle)?.renderSurface = mockSurface

        let scheduler = AnimatorScheduler()
        scheduler.register(IdleAnimationController())

        var frameCount = 0
        session.onFrame = { _ in
            frameCount += 1
            return true
        }

        AnimatorScheduler.$current.withValue(scheduler) {
            host.run()
        }

        #expect(frameCount == 1)
    }

    @MainActor
    @Test("Animation waits include work already spent in the frame", arguments: [0.004, 0.020])
    func animationWaitUsesRemainingFrameBudget(renderDuration: Double) throws {
        let shell = MockShell(eventBatches: [[], [], []])
        shell.refreshRate = 60
        let host = SDL3PlatformHost(shellFactory: { shell })
        var time = 100.0
        host.frameClock = { time }
        shell.onPoll = { time += 0.002 }
        shell.onWait = { timeout in
            time += timeout
            return false
        }

        let tree = NodeTree()
        let root = Node()
        tree.root = root
        let session = try host.openWindow(title: "Animation", tree: tree)
        (shell.window(for: session.id) as? MockWindowHandle)?.renderSurface = mockSurface

        let scheduler = AnimatorScheduler()
        let controller = IdleAnimationController()
        controller.onTick = { root.markRenderDirty() }
        scheduler.register(controller)

        var frameTimes: [Double] = []
        session.onFrame = { _ in
            frameTimes.append(time)
            time += renderDuration
            return true
        }

        AnimatorScheduler.$current.withValue(scheduler) { host.run() }

        let workDuration = 0.002 + renderDuration
        let expectedWait = max(0, 1.0 / 60.0 - workDuration)
        #expect(frameTimes.count == 3)
        #expect(shell.waitTimeouts.count == 3)
        #expect(shell.waitTimeouts.allSatisfy { abs($0 - expectedWait) < 1e-9 })
        for (previous, current) in zip(frameTimes, frameTimes.dropFirst()) {
            #expect(abs(current - previous - max(1.0 / 60.0, workDuration)) < 1e-9)
        }
    }

    @MainActor
    @Test("Input wakes an animation wait and redraws before its timeout")
    func animationWaitRemainsInterruptibleByInput() throws {
        let shell = MockShell(eventBatches: [[], [], []])
        shell.refreshRate = 60
        let host = SDL3PlatformHost(shellFactory: { shell })
        var time = 100.0
        host.frameClock = { time }
        var waitCount = 0
        shell.onWait = { timeout in
            waitCount += 1
            time += waitCount == 1 ? 0.003 : timeout
            return waitCount == 1
        }

        let tree = NodeTree()
        tree.root = Node()
        let session = try host.openWindow(title: "Input", tree: tree)
        (shell.window(for: session.id) as? MockWindowHandle)?.renderSurface = mockSurface
        shell.eventBatches[1] = [
            WindowInputEvent(windowID: session.id,
                             event: .mouseMotion(MouseMotionEvent(x: 8, y: 8, deltaX: 1, deltaY: 0))),
        ]

        let scheduler = AnimatorScheduler()
        scheduler.register(IdleAnimationController())
        var frameTimes: [Double] = []
        var deliveredAt: Double?
        session.onEvent = { _ in deliveredAt = time }
        session.onFrame = { _ in
            frameTimes.append(time)
            return true
        }

        AnimatorScheduler.$current.withValue(scheduler) { host.run() }

        #expect(frameTimes.count == 2)
        #expect(abs((frameTimes.last ?? 0) - (frameTimes.first ?? 0) - 0.003) < 1e-9)
        #expect(deliveredAt == frameTimes.last)
        #expect((shell.waitTimeouts.first ?? 0) > 0.003)
    }

    @MainActor
    @Test("Finished animations return to the idle event wait")
    func finishedAnimationReturnsToIdleWait() throws {
        let shell = MockShell(eventBatches: [[], []])
        let host = SDL3PlatformHost(shellFactory: { shell })
        var time = 100.0
        host.frameClock = { time }
        shell.onWait = { timeout in time += timeout; return false }

        let tree = NodeTree()
        tree.root = Node()
        let session = try host.openWindow(title: "Idle", tree: tree)
        (shell.window(for: session.id) as? MockWindowHandle)?.renderSurface = mockSurface
        let scheduler = AnimatorScheduler()
        scheduler.register(TickCountingController())
        var frameCount = 0
        session.onFrame = { _ in frameCount += 1; return true }

        AnimatorScheduler.$current.withValue(scheduler) { host.run() }

        #expect(frameCount == 1)
        #expect(shell.waitTimeouts == [0.25, 0.25])
    }

    @MainActor
    @Test("Host frame loop ticks task-local animation scheduler")
    func hostTicksTaskLocalScheduler() throws {
        let shell = MockShell(eventBatches: [[], []])
        let host = SDL3PlatformHost(shellFactory: { shell })

        let tree = NodeTree()
        let session = try host.openWindow(title: "A", tree: tree)
        tree.root = Node()
        (shell.window(for: session.id) as? MockWindowHandle)?.renderSurface = mockSurface

        let scheduler = AnimatorScheduler()
        let controller = TickCountingController()
        scheduler.register(controller)

        session.onFrame = { _ in true }

        AnimatorScheduler.$current.withValue(scheduler) {
            host.run()
        }

        #expect(controller.tickCount > 0)
    }

    @MainActor
    @Test("Failed frame callbacks keep the window pending for retry")
    func failedFrameCallbacksRetry() throws {
        let shell = MockShell(eventBatches: [[], [], [], []])
        let host = SDL3PlatformHost(shellFactory: { shell })
        var time: Double = 0
        host.frameClock = { time }
        shell.onPoll = { time += 0.01 }

        let tree = NodeTree()
        let session = try host.openWindow(title: "A", tree: tree)
        tree.root = Node()
        (shell.window(for: session.id) as? MockWindowHandle)?.renderSurface = mockSurface

        var frameAttempts = 0
        session.onFrame = { _ in
            frameAttempts += 1
            return frameAttempts >= 2
        }

        host.run()

        #expect(frameAttempts == 2)
        #expect(shell.waitTimeouts.contains { $0 > 0.005 })
    }

    @MainActor
    @Test("Unavailable surfaces preserve dirty work and throttle repeated attempts")
    func unavailableSurfaceWaitsForRetryDeadline() throws {
        let shell = MockShell(eventBatches: [[], [], [], []])
        let host = SDL3PlatformHost(shellFactory: { shell })
        var time: Double = 0
        host.frameClock = { time }
        shell.onPoll = { time += 0.002 }
        let tree = NodeTree()
        let session = try host.openWindow(title: "Occluded", tree: tree)
        tree.root = Node()
        tree.root?.markRenderDirty()
        (shell.window(for: session.id) as? MockWindowHandle)?.renderSurface = mockSurface
        var attempts = 0
        session.onFrame = { _ in attempts += 1; return false }
        host.run()
        #expect(attempts == 1)
        #expect(tree.hasRenderUpdates)
        #expect(shell.waitTimeouts.allSatisfy { $0 >= 0.01 })
    }

    @MainActor
    @Test("OS close request releases window resources before native destroy")
    func osCloseRequestReleasesWindowResourcesBeforeDestroy() throws {
        let shell = MockShell(eventBatches: [])
        let host = SDL3PlatformHost(shellFactory: { shell })

        let session = try host.openWindow(title: "A", tree: NodeTree())
        var tornDown: [WindowID] = []
        host.onWindowTeardown = { tornDown.append($0) }

        let shouldShellDestroy = shell.closeInterceptor?(session.id) ?? true

        #expect(shouldShellDestroy == false)
        #expect(tornDown == [session.id])
        #expect(shell.window(for: session.id) == nil)
    }

    @MainActor
    @Test("OS close veto keeps native window alive")
    func osCloseVetoKeepsNativeWindowAlive() throws {
        let shell = MockShell(eventBatches: [])
        let host = SDL3PlatformHost(shellFactory: { shell })

        let session = try host.openWindow(title: "A", tree: NodeTree())
        var tornDown: [WindowID] = []
        host.onWindowTeardown = { tornDown.append($0) }
        host.windowCloseInterceptor = { _ in false }

        let shouldShellDestroy = shell.closeInterceptor?(session.id) ?? true

        #expect(shouldShellDestroy == false)
        #expect(tornDown.isEmpty)
        #expect(shell.window(for: session.id) != nil)
    }

    @MainActor
    @Test("Focused text input area syncs to the shell from the live node")
    func focusedTextInputAreaSyncsToShell() throws {
        let shell = MockShell(eventBatches: [[], []])
        let host = SDL3PlatformHost(shellFactory: { shell })

        let tree = NodeTree()
        let session = try host.openWindow(title: "A", tree: tree)
        (shell.window(for: session.id) as? MockWindowHandle)?.renderSurface = mockSurface

        let root = Node()
        let field = Node()
        field.isFocusable = true
        let area = TextInputArea(x: 18, y: 24, width: 12, height: 20, cursorX: 0)
        field.attachments[TextInputAttachmentKey.area] = area
        root.addChild(field)
        tree.root = root

        // Phase 7: the host reads the focused node's text-input area live from
        // its attachments (the input mirror was removed).
        session.focusChain.focus(field)
        session.onFrame = { _ in true }

        host.run()

        #expect(shell.textInputAreas[session.id] == area)
    }

    @MainActor
    private func makeHitTree(interactions: InteractionRegistry,
                             onPointerDown: @escaping () -> Void) -> Node {
        let root = Node()
        root.frame = CGRect(x: 0, y: 0, width: 100, height: 100)

        let leaf = Node()
        leaf.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        leaf.isHitTestable = true
        interactions.setPointer(leaf) { _, phase, _ in
            if phase == .down {
                onPointerDown()
            }
            return .handled
        }

        root.addChild(leaf)
        return root
    }

    @MainActor
    private func makeCursorTree(cursor: SystemCursor) -> Node {
        let root = Node()
        root.frame = CGRect(x: 0, y: 0, width: 100, height: 100)

        let leaf = Node()
        leaf.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        leaf.isHitTestable = true
        leaf.cursor = cursor

        root.addChild(leaf)
        return root
    }
}

@MainActor
private let mockSurface = NativeRenderSurface.metalLayer(UnsafeMutableRawPointer(bitPattern: 0x1)!)

private final class IdleAnimationController: AnyAnimationController {
    var isFinished: Bool = false
    var onTick: (() -> Void)?

    func tick(deltaTime: Double) { onTick?() }

    func finishImmediately() {
        isFinished = true
    }

    func cancel() {
        isFinished = true
    }
}

private final class TickCountingController: AnyAnimationController {
    var isFinished: Bool = false
    var tickCount: Int = 0

    func tick(deltaTime: Double) {
        _ = deltaTime
        tickCount += 1
        isFinished = true
    }

    func finishImmediately() {
        isFinished = true
    }

    func cancel() {
        isFinished = true
    }
}

@MainActor
private final class MockWindowHandle: WindowHandle {
    let id: WindowID
    var renderSurface: NativeRenderSurface? = nil
    var drawableSize: (width: UInt32, height: UInt32)
    var logicalSize: (width: UInt32, height: UInt32)
    var isFocused: Bool = true
    var isMinimized: Bool = false
    var isOccluded: Bool = false

    init(id: WindowID,
         drawableSize: (width: UInt32, height: UInt32) = (640, 480),
         logicalSize: (width: UInt32, height: UInt32) = (640, 480)) {
        self.id = id
        self.drawableSize = drawableSize
        self.logicalSize = logicalSize
    }
}

@MainActor
private final class MockShell: Shell {
    var closeInterceptor: ((WindowID?) -> Bool)?
    struct CursorRequest: Equatable {
        let windowID: WindowID
        let cursor: SystemCursor
    }

    struct NativeRefresh {
        var supported = false
        var pending: [WindowID: DisplayRefreshTick] = [:]
        var requests: [WindowID: [Bool]] = [:]
    }

    var eventBatches: [[WindowInputEvent]]
    var refreshRate: Double?
    var pollDelay: TimeInterval = 0
    var onPoll: (() -> Void)?
    var onWait: ((TimeInterval) -> Bool)?
    var waitTimeouts: [TimeInterval] = []
    var cursorRequests: [CursorRequest] = []
    var textInputAreas: [WindowID: TextInputArea?] = [:]
    var nativeRefresh = NativeRefresh()

    private var handles: [WindowID: MockWindowHandle] = [:]
    private var order: [WindowID] = []
    private var nextWindowID: WindowID = 1
    private var pollIndex = 0
    private var loopRunning = true

    init(eventBatches: [[WindowInputEvent]]) {
        self.eventBatches = eventBatches
    }

    var mainWindowID: WindowID? { order.first }
    var windowIDs: [WindowID] { order.filter { handles[$0] != nil } }
    var isRunning: Bool { loopRunning && !handles.isEmpty }

    @discardableResult
    func createWindow(title: String, options: WindowOptions) throws -> any WindowHandle {
        let id = nextWindowID
        nextWindowID += 1
        let handle = MockWindowHandle(
            id: id,
            drawableSize: (UInt32(max(1, options.width)), UInt32(max(1, options.height))),
            logicalSize: (UInt32(max(1, options.width)), UInt32(max(1, options.height)))
        )
        handles[id] = handle
        order.append(id)
        _ = title
        return handle
    }

    func window(for id: WindowID) -> (any WindowHandle)? {
        handles[id]
    }

    func destroyWindow(_ id: WindowID) {
        handles.removeValue(forKey: id)
        order.removeAll { $0 == id }
        if handles.isEmpty {
            loopRunning = false
        }
    }

    @discardableResult
    func pollWindowEvents() -> [WindowInputEvent] {
        onPoll?()
        if pollDelay > 0 {
            Thread.sleep(forTimeInterval: pollDelay)
        }
        defer {
            pollIndex += 1
            if pollIndex >= eventBatches.count {
                loopRunning = false
            }
        }
        guard pollIndex < eventBatches.count else { return [] }
        return eventBatches[pollIndex]
    }

    @discardableResult
    func waitForEvents(timeout: TimeInterval) -> Bool {
        waitTimeouts.append(timeout)
        return onWait?(timeout) ?? false
    }

    func setTextInputArea(windowID: WindowID, _ area: TextInputArea?) {
        textInputAreas[windowID] = area
    }

    func setCursor(windowID: WindowID, _ cursor: SystemCursor) {
        cursorRequests.append(CursorRequest(windowID: windowID, cursor: cursor))
    }

    func displayRefreshRate(windowID: WindowID?) -> Double? {
        _ = windowID
        return refreshRate
    }

    func setDisplayRefreshEnabled(_ enabled: Bool, windowID: WindowID) -> Bool {
        nativeRefresh.requests[windowID, default: []].append(enabled)
        if !enabled { nativeRefresh.pending.removeValue(forKey: windowID) }
        return nativeRefresh.supported
    }

    func takeDisplayRefresh(windowID: WindowID) -> DisplayRefreshTick? {
        nativeRefresh.pending.removeValue(forKey: windowID)
    }

    func shutdown() {
        handles.removeAll()
        order.removeAll()
        loopRunning = false
    }
}
