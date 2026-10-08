import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Rating selection, painting and lifecycle", .serialized)
struct RatingTests: GuavaUIComposeSerializedSuite {
    private func descendants(_ node: Node) -> [Node] { [node] + node.children.flatMap(descendants) }
    private func host(_ graph: ViewGraph) -> Node { descendants(graph.tree.root!).first { $0.attachments["rating.session"] != nil }! }
    private func key(_ code: UInt32, modifiers: KeyModifiers = []) -> KeyEvent {
        KeyEvent(scancode: code, keycode: 0, modifiers: modifiers, isRepeat: false)
    }
    private func withScene(_ test: (ViewGraph, InteractionRegistry, FocusChain, PointerCapture, EventDispatcher) -> Void) {
        GlobalTestLock.locked {
            let oldRegistry = InteractionRegistryHolder.current, oldFocus = FocusChainHolder.current
            let oldCapture = PointerCaptureHolder.current, oldImages = ImageAssetRegistryHolder.current
            let registry = InteractionRegistry(), focus = FocusChain(), capture = PointerCapture()
            InteractionRegistryHolder.current = registry; FocusChainHolder.current = focus; PointerCaptureHolder.current = capture
            ImageAssetRegistryHolder.current = nil
            defer {
                InteractionRegistryHolder.current = oldRegistry; FocusChainHolder.current = oldFocus
                PointerCaptureHolder.current = oldCapture; ImageAssetRegistryHolder.current = oldImages
            }
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            let dispatcher = EventDispatcher(tree: graph.tree, interactions: registry, capture: capture, focusChain: focus)
            test(graph, registry, focus, capture, dispatcher)
            graph.install(root: EmptyView())
        }
    }
    private func pointer(_ node: Node, star: Int, fraction: Float = 0.75, yOffset: Float = 0) -> MouseButtonEvent {
        let geometry = (node.attachments["rating.session"] as! RatingSession).configuration!.geometry
        let rect = geometry.starRect(star, origin: node.absoluteOrigin, height: Float(node.frame.height))
        return MouseButtonEvent(button: .left, x: rect.x + rect.width * fraction, y: rect.y + rect.height / 2 + yOffset, clicks: 1)
    }

    @Test("Authored groups normalize independently without rewriting the controlled value")
    func configuration() {
        let rating = Rating(value: .constant(.nan)) {
            $0.selection.maximum = 200; $0.selection.precision = .half
            $0.appearance.starSize = .infinity; $0.appearance.spacing = -.infinity
        }
        #expect(rating.selection.maximum == 20 && rating.selection.precision == .half)
        #expect(rating.appearance.starSize == nil && rating.appearance.spacing == 4)
        #expect(rating.value.wrappedValue.isNaN)
        #expect(rating.selection.clamped(.nan) == 0 && rating.selection.clamped(100) == 20)
        var selection = RatingSelection(); selection.maximum = 0; selection.validate()
        #expect(selection.maximum == 1)
        selection.precision = .half; selection.allowsClear = false
        #expect(selection.snapped(0) == 0.5 && selection.snapped(0.76) == 1)
    }

    @Test("All densities preserve intrinsic height in a centered, width-constrained row")
    func density() { withScene { graph, _, _, _, _ in
        for (size, points): (ControlSize, Float) in [(.mini, 12), (.small, 16), (.regular, 20), (.large, 28)] {
            graph.install(root: Row(alignment: .center) { Rating(value: .constant(2)).controlSize(size).frame(width: 180) })
            graph.computeLayout(width: 500, height: 100)
            let node = host(graph), geometry = (node.attachments["rating.session"] as! RatingSession).configuration!.geometry
            #expect(node.frame.width == 180 && Float(node.frame.height) == max(32, points + 8))
            #expect(geometry.starSize == points)
        }
        graph.install(root: Rating(value: .constant(0)) { $0.selection.maximum = 7; $0.appearance.starSize = 36; $0.appearance.spacing = 8 })
        graph.computeLayout(width: 500, height: 100)
        #expect(host(graph).frame.width == 364 && host(graph).frame.height == 44)
    } }

    @Test("Pointer preview is transient; a complete click survives a frame and repeat clears")
    func pointerCommit() { withScene { graph, registry, focus, capture, dispatcher in
        var value = 2.0
        let rating = Rating("Overall", value: Binding(get: { value }, set: { value = $0 }))
        graph.install(root: Row { rating }.padding(20)); graph.computeLayout(width: 500, height: 100)
        let node = host(graph), event = pointer(node, star: 3), session = node.attachments["rating.session"] as! RatingSession
        graph.tree.flush()
        dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: event.x, y: event.y, deltaX: 0, deltaY: 0)))
        #expect(value == 2 && session.preview == 4 && !graph.recomposer.hasPending && graph.tree.hasRenderUpdates)
        dispatcher.dispatch(.mouseButtonUp(event)); #expect(value == 2)
        var right = event; right.button = .right
        #expect(registry.handlers(for: node).pointer?(right, .down, .target) == .ignored)
        dispatcher.dispatch(.mouseButtonDown(event))
        #expect(capture.target === node && focus.focused === node && value == 2)
        rating._updateNode(node); graph.recomposer.commitAll(); graph.computeLayout(width: 500, height: 100)
        #expect(capture.target === node)
        dispatcher.dispatch(.mouseButtonUp(event))
        #expect(value == 4 && session.preview == nil && capture.target == nil)
        rating._updateNode(node)
        dispatcher.dispatch(.mouseButtonDown(event)); dispatcher.dispatch(.mouseButtonUp(event))
        #expect(value == 0)
        #expect(node.accessibility?.label == "Overall")
    } }

    @Test("Half-star hit regions follow the absolute layout origin and outside releases cancel")
    func halfPointer() { withScene { graph, _, _, capture, dispatcher in
        var value = 0.0
        graph.install(root: Row { Rating(value: Binding(get: { value }, set: { value = $0 })) { $0.selection.precision = .half } }.padding(30))
        graph.computeLayout(width: 500, height: 100)
        let node = host(graph), session = node.attachments["rating.session"] as! RatingSession
        let half = pointer(node, star: 2, fraction: 0.25), whole = pointer(node, star: 2)
        dispatcher.dispatch(.mouseButtonDown(half)); dispatcher.dispatch(.mouseButtonUp(half)); #expect(value == 2.5)
        dispatcher.dispatch(.mouseButtonDown(whole)); dispatcher.dispatch(.mouseButtonUp(whole)); #expect(value == 3)
        dispatcher.dispatch(.mouseButtonDown(half))
        let outside = pointer(node, star: 2, fraction: 0.25, yOffset: 300)
        dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: outside.x, y: outside.y, deltaX: 0, deltaY: 300)))
        #expect(session.preview == nil && capture.target === node && value == 3)
        dispatcher.dispatch(.mouseButtonUp(outside))
        #expect(value == 3 && session.pressedCandidate == nil && capture.target == nil)
        let geometry = session.configuration!.geometry
        #expect(geometry.candidate(at: .greatestFiniteMagnitude, node: node, precision: .half) == 5)
        #expect(geometry.candidate(at: -.greatestFiniteMagnitude, node: node, precision: .half) == 0.5)
        #expect(geometry.candidate(at: .nan, node: node, precision: .half) == 0)
    } }

    @Test("One Tab stop adjusts by half steps, ignores chords and cancels a captured press")
    func keyboard() { withScene { graph, _, focus, capture, dispatcher in
        var value = 2.5
        graph.install(root: Row {
            Rating(value: Binding(get: { value }, set: { value = $0 })) { $0.selection.precision = .half }
            Rating(value: .constant(4.25)) { $0.selection.isReadOnly = true }
            Button("Next") {}
        })
        graph.computeLayout(width: 500, height: 100)
        let node = host(graph)
        dispatcher.dispatch(.keyDown(key(Scancode.tab))); #expect(focus.focused === node && focus.isFocusVisible)
        dispatcher.dispatch(.keyDown(key(Scancode.arrowRight))); #expect(value == 3)
        dispatcher.dispatch(.keyUp(key(Scancode.arrowRight))); #expect(value == 3)
        for modifier: KeyModifiers in [.lctrl, .rctrl, .lgui, .rgui, .lalt, .ralt] {
            dispatcher.dispatch(.keyDown(key(Scancode.arrowRight, modifiers: modifier))); #expect(value == 3)
        }
        dispatcher.dispatch(.keyDown(key(Scancode.arrowDown))); #expect(value == 2.5)
        dispatcher.dispatch(.keyDown(key(Scancode.end))); #expect(value == 5)
        dispatcher.dispatch(.keyDown(key(Scancode.home))); #expect(value == 0)
        dispatcher.dispatch(.keyDown(key(Scancode.arrowUp))); #expect(value == 0.5)
        dispatcher.dispatch(.keyDown(key(Scancode.delete))); #expect(value == 0)
        dispatcher.dispatch(.mouseButtonDown(pointer(node, star: 3))); #expect(capture.target === node)
        dispatcher.dispatch(.keyDown(key(Scancode.escape)))
        #expect(capture.target == nil && (node.attachments["rating.session"] as! RatingSession).preview == nil && value == 0)
        dispatcher.dispatch(.keyDown(key(Scancode.tab)))
        #expect(focus.focused !== node && focus.focused?.accessibility?.role == .button)
    } }

    @Test("Dragging back to the starting score commits without clearing and updated bindings stay live")
    func dragAndBinding() { withScene { graph, _, _, capture, dispatcher in
        var original = 3.0, replacement = 3.0
        var rating = Rating(value: Binding(get: { original }, set: { original = $0 }))
        graph.install(root: rating); graph.computeLayout(width: 300, height: 100)
        let node = host(graph), start = pointer(node, star: 2), end = pointer(node, star: 4)
        dispatcher.dispatch(.mouseButtonDown(start))
        dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: end.x, y: end.y, deltaX: end.x - start.x, deltaY: 0)))
        #expect(original == 3 && (node.attachments["rating.session"] as! RatingSession).preview == 5)
        rating._updateNode(node)
        #expect(capture.target === node)
        dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: start.x, y: start.y, deltaX: start.x - end.x, deltaY: 0)))
        dispatcher.dispatch(.mouseButtonUp(start))
        #expect(original == 3 && capture.target == nil)
        rating = Rating(value: Binding(get: { replacement }, set: { replacement = $0 }))
        rating._updateNode(node)
        dispatcher.dispatch(.keyDown(key(Scancode.arrowUp)))
        #expect(original == 3 && replacement == 4)
        dispatcher.dispatch(.mouseButtonDown(start))
        replacement = 1; rating._updateNode(node)
        #expect(capture.target == nil && (node.attachments["rating.session"] as! RatingSession).preview == nil)
        dispatcher.dispatch(.mouseButtonUp(start)); #expect(replacement == 1)
    } }

    @Test("Accessibility normalizes finite writes; read-only and disabled controls expose no actions")
    func accessibility() { withScene { graph, registry, _, _, _ in
        var value = 2.5
        let binding = Binding(get: { value }, set: { value = $0 })
        let rating = Rating("Customer score", value: binding) { $0.selection.precision = .half; $0.selection.allowsClear = false }
        graph.install(root: rating); graph.computeLayout(width: 300, height: 100)
        let node = host(graph)
        #expect(node.accessibility?.role == .slider && node.accessibility?.value == "2.5")
        node.accessibilityActions.setValue?("4.26"); #expect(value == 4.5)
        node.accessibilityActions.increment?(); #expect(value == 5)
        node.accessibilityActions.decrement?(); #expect(value == 4.5)
        for invalid in ["nan", "inf", "not a score"] { node.accessibilityActions.setValue?(invalid); #expect(value == 4.5) }
        node.accessibilityActions.setValue?("-4"); #expect(value == 0.5)
        #expect(registry.handlers(for: node).key?(key(Scancode.backspace), .target) == .ignored)
        for readOnly in [true, false] {
            var inactive = rating
            inactive.selection.isReadOnly = readOnly; inactive.selection.isEnabled = readOnly
            inactive._updateNode(node)
            #expect(!node.isFocusable && !node.isHitTestable && registry.handlers(for: node).pointer == nil)
            #expect(node.accessibilityActions.setValue == nil && node.accessibilityActions.increment == nil)
            #expect(node.accessibility?.role == (readOnly ? .image : .slider))
            #expect(node.accessibility?.state.isReadOnly == readOnly && value == 0.5)
        }
    } }

    @Test("Reconfiguration and unmount release capture, clear previews and do not retain nodes")
    func cleanup() { withScene { graph, registry, focus, capture, dispatcher in
        var rating = Rating(value: .constant(2))
        graph.install(root: rating); graph.computeLayout(width: 300, height: 100)
        weak var departed: Node?
        do {
            let node = host(graph); departed = node
            dispatcher.dispatch(.mouseButtonDown(pointer(node, star: 3)))
            rating.selection.maximum = 3; rating._updateNode(node)
            #expect(capture.target == nil && (node.attachments["rating.session"] as! RatingSession).preview == nil)
            dispatcher.dispatch(.mouseButtonDown(pointer(node, star: 1)))
            rating.selection.isEnabled = false; rating._updateNode(node)
            #expect(capture.target == nil && focus.focused == nil && registry.handlers(for: node).key == nil)
            rating.selection.isEnabled = true; rating._updateNode(node)
            dispatcher.dispatch(.mouseButtonDown(pointer(node, star: 1)))
            graph.install(root: EmptyView())
            #expect(capture.target == nil && focus.focused == nil && registry.handlers(for: node).pointer == nil)
        }
        #expect(departed == nil)
    } }

    @Test("Fractional fills clip matching SVG stars and focused ratings paint a visible ring")
    func paint() throws {
        for resource in [UICommonIcons.star, UICommonIcons.starFill] {
            let url = try #require(resource.url)
            let bitmap = try ImageDecoder.decode(url: url, targetSize: (40, 40))
            #expect(bitmap.width == 40 && bitmap.height == 40)
            #expect(stride(from: 3, to: bitmap.pixels.count, by: 4).contains { bitmap.pixels[$0] > 0 })
        }
        withScene { graph, _, focus, _, _ in
            graph.install(root: Rating(value: .constant(2.5))); graph.computeLayout(width: 300, height: 100)
            let node = host(graph), list = DrawList()
            node.draw?(list, .zero)
            #expect(list.vertices.count == 32)
            let fractional = list.batches.compactMap(\.scissor).filter { $0.width == 10 }
            #expect(fractional.count == 1 && fractional[0].x == 72 && fractional[0].height == 20)
            #expect(list.currentClip == nil)
            let unfocusedCount = list.vertices.count
            focus.focus(node, visible: true); list.reset(); node.draw?(list, .zero)
            #expect(list.vertices.count > unfocusedCount && list.currentClip == nil)
        }
    }
}
