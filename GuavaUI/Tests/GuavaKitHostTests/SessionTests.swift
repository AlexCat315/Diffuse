import Testing
import GuavaKit
import GuavaUIRuntime
@testable import GuavaKitHost

@Suite("GuavaKitHost event adapter")
struct EventAdapterTests {

    /// Builds a context with a single hittable node at (10,10) size (30,30).
    private func makeContext() -> (UIContext, UINode) {
        let ctx = UIContext()
        let root = UINode(geometry: Geometry(frame: Rect(x: 0, y: 0, width: 100, height: 100)))
        let child = UINode(geometry: Geometry(frame: Rect(x: 10, y: 10, width: 30, height: 30)))
        root.append(child)
        ctx.install(root: root)
        return (ctx, child)
    }

    private final class Sink {
        var events: [(phase: GuavaKit.EventPhase, action: GuavaKit.PointerAction)] = []
        var enterCount = 0; var leaveCount = 0
    }

    @Test("pointerDown delivers through capture/target/bubble and stops on handled")
    func pointerDownDelivery() {
        let (ctx, node) = makeContext()
        let sink = Sink()
        // Set handler on both root (ancestor) and child (target) — capture phase
        // visits ancestors first (excluding the target).
        ctx.root?.interaction.onPointer = { event, phase, _ in
            sink.events.append((phase, event.action))
            return .ignored // let it propagate to target
        }
        node.interaction.onPointer = { event, phase, _ in
            sink.events.append((phase, event.action))
            return phase == .target ? .handled : .ignored
        }

        let adapter = EventAdapter(context: ctx)
        let result = adapter.pointerDown(at: Point(x: 20, y: 20))

        // Capture (root) → target (child, handled) → no bubble.
        #expect(result == .handled)
        #expect(sink.events.count == 2)
        #expect(sink.events[0].phase == .capture)
        #expect(sink.events[1].phase == .target)
    }

    @Test("pointerDown outside any node returns ignored")
    func pointerDownOutside() {
        let (ctx, _) = makeContext()
        let adapter = EventAdapter(context: ctx)
        let result = adapter.pointerDown(at: Point(x: 200, y: 200))
        #expect(result == .ignored)
    }

    @Test("pointerCapture routes up to the captured node, skipping hit-test")
    func pointerCaptureRoutesToCaptured() {
        let (ctx, node) = makeContext()
        let adapter = EventAdapter(context: ctx)

        // Acquire capture via down.
        node.interaction.onPointer = { _, phase, ctx in
            if phase == .target { ctx.pointerCapture.acquire(node); return .handled }
            return .ignored
        }
        adapter.pointerDown(at: Point(x: 20, y: 20))
        #expect(ctx.pointerCapture.target === node)

        // Move far outside — capture target still receives it.
        var moveReceived = false
        node.interaction.onPointer = { event, _, _ in
            if event.action == .move { moveReceived = true; return .handled }
            return .ignored
        }
        let result = adapter.pointerMove(to: Point(x: 500, y: 500))
        #expect(result == .handled)
        #expect(moveReceived)

        // Up also goes to captured.
        var upReceived = false
        node.interaction.onPointer = { event, _, _ in
            if event.action == .up { upReceived = true; return .handled }
            return .ignored
        }
        let upResult = adapter.pointerUp(at: Point(x: 500, y: 500))
        #expect(upResult == .handled)
        #expect(upReceived)
    }

    @Test("pointerMove fires hover enter/leave")
    func hoverTransitions() {
        let (ctx, node) = makeContext()
        let sink = Sink()

        node.interaction.onHoverEnter = { sink.enterCount += 1 }
        node.interaction.onHoverLeave = { sink.leaveCount += 1 }
        node.interaction.onPointer = { _, _, _ in .ignored }

        let adapter = EventAdapter(context: ctx)

        // Move into the node → enter.
        adapter.pointerMove(to: Point(x: 20, y: 20))
        #expect(sink.enterCount == 1)
        #expect(sink.leaveCount == 0)

        // Move out → leave.
        adapter.pointerMove(to: Point(x: 200, y: 200))
        #expect(sink.enterCount == 1)
        #expect(sink.leaveCount == 1)

        // Move back in → enter again.
        adapter.pointerMove(to: Point(x: 20, y: 20))
        #expect(sink.enterCount == 2)
        #expect(sink.leaveCount == 1)
    }
}

@Suite("GuavaKitHost session tick")
struct GuavaKitSessionTests {

    /// A minimal root view for testing the render pipeline.
    private struct TestRoot: View {
        var body: some View { Element(width: 100, height: 80, color: Color(r: 1, g: 0, b: 0)) }
    }

    @Test("tick returns nil when no renderer is configured")
    func tickWithoutRenderer() {
        let session = GuavaKitSession()
        session.install(root: TestRoot())
        let dl = session.tick(available: Size(width: 200, height: 200))
        #expect(dl == nil)
    }

    @Test("tick returns a DrawList after installing root and configuring renderer")
    func tickProducesDrawList() {
        let session = GuavaKitSession()
        session.install(root: TestRoot())
        session.renderer = DisplayListRenderer()
        let dl = session.tick(available: Size(width: 200, height: 200))
        #expect(dl != nil)
        // One fill rect → 4 vertices (one quad).
        #expect(dl!.vertices.count == 4)
    }

    @Test("consecutive ticks without state changes return nil (frame skipping)")
    func tickSkipsCleanFrames() {
        let session = GuavaKitSession()
        session.install(root: TestRoot())
        session.renderer = DisplayListRenderer()

        // First tick → dirty, produces DrawList.
        let dl1 = session.tick(available: Size(width: 200, height: 200))
        #expect(dl1 != nil)

        // Second tick → nothing changed, returns nil.
        let dl2 = session.tick(available: Size(width: 200, height: 200))
        #expect(dl2 == nil)
    }

    @Test("tick after re-installing a different view produces a new DrawList")
    func tickAfterReinstallProducesNewDrawList() {
        struct App: View {
            var w: Float
            var body: some View { Element(width: w, height: 20, color: Color(r: 0, g: 1, b: 0)) }
        }

        let session = GuavaKitSession()
        session.renderer = DisplayListRenderer()

        let view1 = App(w: 10)
        session.install(root: view1)

        // Initial tick.
        let dl1 = session.tick(available: Size(width: 200, height: 200))
        #expect(dl1 != nil)
        let v1 = dl1!.vertices.count

        // Clean frame.
        let dl2 = session.tick(available: Size(width: 200, height: 200))
        #expect(dl2 == nil)

        // Re-install with different width.
        let view2 = App(w: 15)
        session.install(root: view2)
        let dl3 = session.tick(available: Size(width: 200, height: 200))
        #expect(dl3 != nil)
        // Still one quad.
        #expect(dl3!.vertices.count == v1)
    }

    @Test("tick with text and font bridge produces glyph quads")
    func tickWithText() throws {
        let bridge = FontBridge()
        let ok = bridge.loadFont(path: "/System/Library/Fonts/Supplemental/Arial.ttf", size: 16)
        try #require(ok)

        let session = GuavaKitSession()
        session.textMeasurer = FontBridgeMeasurer(bridge: bridge)
        session.renderer = DisplayListRenderer(fontBridge: bridge, atlasTextureID: .none)

        struct TextRoot: View {
            var body: some View { GuavaKit.Text("Hello") }
        }
        session.install(root: TextRoot())

        let dl = session.tick(available: Size(width: 200, height: 200))
        #expect(dl != nil)
        // "Hello" has at least 5 glyphs → 20+ vertices.
        #expect(dl!.vertices.count >= 20)
    }
}
