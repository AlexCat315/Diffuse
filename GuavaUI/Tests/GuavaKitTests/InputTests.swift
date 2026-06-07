import Testing
@testable import GuavaKit

@Suite("GuavaKit input")
struct InputTests {

    private final class Log { var entries: [String] = [] }

    // root(0,0,100x100) > a(0,0,50x50) > b(10,10,30x30). All hittable.
    //  (20,20) → b   (45,45) → a   (60,60) → root
    private func makeTree(_ log: Log) -> (ctx: UIContext, disp: EventDispatcher, root: UINode, a: UINode, b: UINode) {
        func make(_ name: String, _ frame: Rect) -> UINode {
            let n = UINode(geometry: Geometry(frame: frame))
            n.debugName = name
            n.interaction.onPointer = { e, phase, _ in
                log.entries.append("\(name).\(e.action).\(phase)")
                return .ignored
            }
            return n
        }
        let root = make("root", Rect(x: 0, y: 0, width: 100, height: 100))
        let a = make("a", Rect(x: 0, y: 0, width: 50, height: 50))
        let b = make("b", Rect(x: 10, y: 10, width: 30, height: 30))
        root.append(a); a.append(b)
        let ctx = UIContext(); ctx.install(root: root)
        return (ctx, EventDispatcher(context: ctx), root, a, b)
    }

    @Test("Pointer delivery follows capture → target → bubble order")
    func phaseOrder() {
        let log = Log()
        let t = makeTree(log)
        t.disp.pointerDown(PointerEvent(position: Point(x: 20, y: 20), action: .down))
        #expect(log.entries == [
            "root.down.capture", "a.down.capture",
            "b.down.target",
            "a.down.bubble", "root.down.bubble",
        ])
    }

    @Test("Returning .handled stops propagation")
    func handledStops() {
        let log = Log()
        let t = makeTree(log)
        t.a.interaction.onPointer = { e, phase, _ in
            log.entries.append("a.\(e.action).\(phase)")
            return phase == .capture ? .handled : .ignored
        }
        t.disp.pointerDown(PointerEvent(position: Point(x: 20, y: 20), action: .down))
        // a consumes in capture phase → b's target never runs.
        #expect(log.entries == ["root.down.capture", "a.down.capture"])
    }

    @Test("Pointer capture routes up to the captured node even off-target")
    func captureRoutesUp() {
        let log = Log()
        let t = makeTree(log)
        // b captures on its down.target.
        t.b.interaction.onPointer = { e, phase, ctx in
            log.entries.append("b.\(e.action).\(phase)")
            if e.action == .down, phase == .target { ctx.pointerCapture.acquire(t.b) }
            return .ignored
        }
        t.disp.pointerDown(PointerEvent(position: Point(x: 20, y: 20), action: .down))
        #expect(t.ctx.pointerCapture.target === t.b)

        log.entries.removeAll()
        // Up happens at (60,60) — over root, NOT over b — but capture routes it to b.
        t.disp.pointerUp(PointerEvent(position: Point(x: 60, y: 60), action: .up))
        #expect(log.entries.contains("b.up.target"))
    }

    // MARK: - The stuck-capture bug class, structurally prevented

    @Test("Capture is released when the captured node detaches")
    func captureReleasedOnDetach() {
        let log = Log()
        let t = makeTree(log)
        t.ctx.pointerCapture.acquire(t.b)
        #expect(t.ctx.pointerCapture.isActive)

        t.b.removeFromParent()
        #expect(t.ctx.pointerCapture.target == nil) // never outlives the node
    }

    @Test("Capture is released when an ANCESTOR of the captured node detaches")
    func captureReleasedOnAncestorDetach() {
        let log = Log()
        let t = makeTree(log)
        t.ctx.pointerCapture.acquire(t.b)
        // Remove a (b's parent) — the panel-relayout case. b goes with it.
        t.a.removeFromParent()
        #expect(t.ctx.pointerCapture.target == nil)
    }

    @Test("Pointer capture is per-context (no global state)")
    func captureIsScoped() {
        let t1 = makeTree(Log())
        let t2 = makeTree(Log())
        t1.ctx.pointerCapture.acquire(t1.b)
        #expect(t1.ctx.pointerCapture.isActive)
        #expect(t2.ctx.pointerCapture.isActive == false) // unaffected
    }

    // MARK: - Hover

    @Test("Hover fires enter/leave on the changed path suffix")
    func hoverEnterLeave() {
        let log = Log()
        let t = makeTree(log)
        for (n, name) in [(t.root, "root"), (t.a, "a"), (t.b, "b")] {
            n.interaction.onPointer = nil // isolate hover logging from move delivery
            n.interaction.onHoverEnter = { log.entries.append("enter:\(name)") }
            n.interaction.onHoverLeave = { log.entries.append("leave:\(name)") }
        }
        // Move onto b → enter root, a, b (shallow→deep).
        t.disp.pointerMove(PointerEvent(position: Point(x: 20, y: 20), action: .move))
        #expect(log.entries == ["enter:root", "enter:a", "enter:b"])

        log.entries.removeAll()
        // Move to (60,60) → only root hovered → leave b, a (deep→shallow).
        t.disp.pointerMove(PointerEvent(position: Point(x: 60, y: 60), action: .move))
        #expect(log.entries == ["leave:b", "leave:a"])
    }
}
