import Testing
@testable import GuavaKit

@Suite("Keyboard focus & text input")
struct InputFocusTests {

    // MARK: - Focus acquisition

    @Test("TextField acquires keyboard focus on pointer-down")
    func textFieldAcquiresFocusOnPointerDown() {
        struct App: View { var body: some View { TextField(text: "") } }
        let ctx = UIContext(); let graph = ViewGraph(context: ctx)
        graph.install(root: App())
        let field = graph.root.children[0]
        field.setFrame(Rect(x: 0, y: 0, width: 100, height: 30)) // place for hit-testing

        #expect(ctx.focusedNode == nil)
        EventDispatcher(context: ctx)
            .pointerDown(PointerEvent(position: Point(x: 10, y: 10), action: .down))
        #expect(ctx.focusedNode === field)
    }

    @Test("Focus is released when the focused node detaches")
    func focusReleasedOnDetach() {
        let ctx = UIContext()
        let root = UINode(); ctx.install(root: root)
        let child = UINode(); root.append(child)
        ctx.focusedNode = child
        #expect(ctx.focusedNode === child)

        child.removeFromParent() // → UIContext.detach clears focus (Rule 2)
        #expect(ctx.focusedNode == nil)
    }

    // MARK: - Key routing

    @Test("Key events route only to the focused node")
    func keyRoutesToFocusedNode() {
        let ctx = UIContext()
        let node = UINode(); ctx.install(root: node)
        var received: String?
        node.interaction.onKeyDown = { received = $0.character; return .handled }
        let disp = EventDispatcher(context: ctx)

        // No focus → ignored, handler untouched.
        #expect(disp.dispatchKeyDown(KeyboardEvent(key: "", character: "x")) == .ignored)
        #expect(received == nil)

        // Focused → delivered.
        ctx.focusedNode = node
        #expect(disp.dispatchKeyDown(KeyboardEvent(key: "", character: "y")) == .handled)
        #expect(received == "y")
    }

    @Test("TextField key handler inserts text, deletes, and submits")
    func textFieldKeyHandling() {
        struct App: View {
            let onChange: (String) -> Void
            let onSubmit: () -> Void
            var body: some View {
                TextField(text: "ab", onChange: onChange, onSubmit: onSubmit)
            }
        }
        var changed: String?
        var submitted = false
        let ctx = UIContext(); let graph = ViewGraph(context: ctx)
        graph.install(root: App(onChange: { changed = $0 }, onSubmit: { submitted = true }))
        let handler = graph.root.children[0].interaction.onKeyDown
        // The field is stateless: its captured text stays "ab" across these calls.

        _ = handler?(KeyboardEvent(key: "", character: "c"))
        #expect(changed == "abc")

        _ = handler?(KeyboardEvent(key: "Backspace"))
        #expect(changed == "a")

        _ = handler?(KeyboardEvent(key: "Enter"))
        #expect(submitted)
    }

    // MARK: - Select overlay lifecycle

    @Test("Select opens a portal on click and releases it on teardown")
    func selectPortalLifecycle() {
        struct App: View {
            var body: some View {
                Select(value: 1, options: [1, 2, 3], onChange: { _ in }) { Text("\($0)") }
            }
        }
        let ctx = UIContext(); let graph = ViewGraph(context: ctx)
        graph.install(root: App())
        let select = graph.root.children[0]
        select.setFrame(Rect(x: 0, y: 0, width: 120, height: 24))

        #expect(ctx.portals.count == 0)
        // Drive the trigger's target-phase handler directly (the label child has
        // no frame yet, so a real hit-test would be ambiguous in a unit test).
        _ = select.interaction.onPointer?(
            PointerEvent(position: Point(x: 5, y: 5), action: .down), .target, ctx)
        #expect(ctx.portals.count == 1)

        // Detaching the trigger must release the portal entry — no modifier needed.
        select.removeFromParent()
        #expect(ctx.portals.count == 0)
    }

    // MARK: - Press-outside / Escape dismissal

    @Test("Pointer-down outside a focused field blurs it")
    func outsidePressBlursField() {
        struct App: View { var body: some View { TextField(text: "") } }
        let ctx = UIContext(); let graph = ViewGraph(context: ctx)
        graph.install(root: App())
        let field = graph.root.children[0]
        field.setFrame(Rect(x: 0, y: 0, width: 100, height: 30))
        let disp = EventDispatcher(context: ctx)

        disp.pointerDown(PointerEvent(position: Point(x: 10, y: 10), action: .down))
        #expect(ctx.focusedNode === field)
        // Press on empty space (no hit) → focus released.
        disp.pointerDown(PointerEvent(position: Point(x: 500, y: 500), action: .down))
        #expect(ctx.focusedNode == nil)
    }

    @Test("Pressing outside an open overlay dismisses it; opening one does not")
    func outsidePressDismissesOverlay() {
        struct App: View {
            var body: some View {
                Select(value: 1, options: [1, 2], onChange: { _ in }) { Text("\($0)") }
            }
        }
        let ctx = UIContext(); let graph = ViewGraph(context: ctx)
        graph.install(root: App())
        let select = graph.root.children[0]
        select.setFrame(Rect(x: 0, y: 0, width: 120, height: 24))
        let disp = EventDispatcher(context: ctx)

        // The press that opens the dropdown must not also dismiss it.
        disp.pointerDown(PointerEvent(position: Point(x: 5, y: 5), action: .down))
        #expect(ctx.portals.count == 1)
        // A press elsewhere closes it.
        disp.pointerDown(PointerEvent(position: Point(x: 500, y: 500), action: .down))
        #expect(ctx.portals.count == 0)
    }

    @Test("Escape clears focus and open overlays")
    func escapeClearsFocusAndOverlays() {
        let ctx = UIContext()
        let node = UINode(); ctx.install(root: node)
        ctx.focusedNode = node
        _ = ctx.portals.register(content: EmptyView(), position: .zero)
        #expect(ctx.portals.count == 1)

        let result = EventDispatcher(context: ctx).dispatchKeyDown(KeyboardEvent(key: "Escape"))
        #expect(result == .handled)
        #expect(ctx.focusedNode == nil)
        #expect(ctx.portals.count == 0)
    }
}
