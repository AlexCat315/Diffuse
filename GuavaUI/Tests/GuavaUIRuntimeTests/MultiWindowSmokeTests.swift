import CoreGraphics
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
    @Test("Failed frame callbacks keep the window pending for retry")
    func failedFrameCallbacksRetry() throws {
        let shell = MockShell(eventBatches: [[], [], []])
        let host = SDL3PlatformHost(shellFactory: { shell })

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

    func tick(deltaTime: Double) {}

    func finishImmediately() {
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
    struct CursorRequest: Equatable {
        let windowID: WindowID
        let cursor: SystemCursor
    }

    var eventBatches: [[WindowInputEvent]]
    var cursorRequests: [CursorRequest] = []
    var textInputAreas: [WindowID: TextInputArea?] = [:]

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
        defer {
            pollIndex += 1
            if pollIndex >= eventBatches.count {
                loopRunning = false
            }
        }
        guard pollIndex < eventBatches.count else { return [] }
        return eventBatches[pollIndex]
    }

    func setTextInputArea(windowID: WindowID, _ area: TextInputArea?) {
        textInputAreas[windowID] = area
    }

    func setCursor(windowID: WindowID, _ cursor: SystemCursor) {
        cursorRequests.append(CursorRequest(windowID: windowID, cursor: cursor))
    }

    func shutdown() {
        handles.removeAll()
        order.removeAll()
        loopRunning = false
    }
}