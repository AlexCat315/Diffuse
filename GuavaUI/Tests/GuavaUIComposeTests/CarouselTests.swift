import Testing
import EngineKernel
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Carousel paging", .serialized)
struct CarouselTests: GuavaUIComposeSerializedSuite {
    private func nodes(_ root: Node) -> [Node] { [root] + root.children.flatMap(nodes) }
    private func key(_ code: UInt32) -> KeyEvent { KeyEvent(scancode: code, keycode: 0, modifiers: [], isRepeat: false) }

    private func withScene(_ test: (ViewGraph, InteractionRegistry, PointerCapture) -> Void) {
        GlobalTestLock.locked {
            let oldRegistry = InteractionRegistryHolder.current
            let oldCapture = PointerCaptureHolder.current
            let registry = InteractionRegistry(), capture = PointerCapture()
            InteractionRegistryHolder.current = registry
            PointerCaptureHolder.current = capture
            defer {
                InteractionRegistryHolder.current = oldRegistry
                PointerCaptureHolder.current = oldCapture
            }
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            test(graph, registry, capture)
            graph.install(root: EmptyView())
            AnimatorScheduler.current.tick(deltaTime: 1)
        }
    }

    private func pages() -> [CarouselPage<String>] {
        (0..<3).map { index in
            CarouselPage("page-\(index)", caption: "Page \(index)") { Text("Page \(index)") }
        }
    }

    private func keyNode(in graph: ViewGraph, _ registry: InteractionRegistry) -> Node? {
        nodes(graph.tree.root!).first { registry.handlers(for: $0).key != nil }
    }

    private func swipeNode(in graph: ViewGraph, _ registry: InteractionRegistry) -> Node? {
        nodes(graph.tree.root!).first { $0.attachments["horizontal-swipe-host"] != nil }
    }

    @Test("Arrow keys page, wrap and jump to the ends")
    func keyboardPaging() {
        withScene { graph, registry, _ in
            var page = "page-0"
            graph.install(root: Carousel(pages: pages(), selection: Binding(get: { page }, set: { page = $0 })))
            graph.computeLayout(width: 320, height: 200)
            let host = keyNode(in: graph, registry)!
            let handler = registry.handlers(for: host).key!

            #expect(handler(key(Scancode.arrowRight), .target) == .handled)
            #expect(page == "page-1")
            _ = handler(key(Scancode.end), .target)
            #expect(page == "page-2")
            // Wrapping keeps the gesture useful on the last page.
            _ = handler(key(Scancode.arrowRight), .target)
            #expect(page == "page-0")
            _ = handler(key(Scancode.arrowLeft), .target)
            #expect(page == "page-2")
            _ = handler(key(Scancode.home), .target)
            #expect(page == "page-0")
            // Unrelated keys are left for the rest of the tree.
            #expect(handler(key(Scancode.arrowDown), .target) == .ignored)
        }
    }

    @Test("Without wrapping the first and last page are boundaries")
    func noWrapClamps() {
        withScene { graph, registry, _ in
            var page = "page-2"
            graph.install(root: Carousel(pages: pages(), selection: Binding(get: { page }, set: { page = $0 })) {
                $0.allowsWrap = false
            })
            graph.computeLayout(width: 320, height: 200)
            let handler = registry.handlers(for: keyNode(in: graph, registry)!).key!
            _ = handler(key(Scancode.arrowRight), .target)
            #expect(page == "page-2")
            _ = handler(key(Scancode.home), .target)
            #expect(page == "page-0")
            _ = handler(key(Scancode.arrowLeft), .target)
            #expect(page == "page-0")
        }
    }

    @Test("A horizontal drag pages and only takes the pointer once it is a swipe")
    func swipePaging() {
        withScene { graph, registry, capture in
            var page = "page-0"
            graph.install(root: Carousel(pages: pages(), selection: Binding(get: { page }, set: { page = $0 })))
            graph.computeLayout(width: 320, height: 200)
            let host = swipeNode(in: graph, registry)!
            let pointer = registry.handlers(for: host).pointer!
            let motion = registry.handlers(for: host).motion!
            let down = { MouseButtonEvent(button: .left, x: $0, y: $1, clicks: 1) }
            let move = { MouseMotionEvent(x: $0, y: $1, deltaX: 0, deltaY: 0) }

            // The press stays available to whatever the page puts under it.
            #expect(pointer(down(200, 100), .down, .target) == .ignored)
            #expect(capture.target == nil)
            // A small or mostly-vertical movement is not a swipe.
            #expect(motion(move(194, 100), .target) == .ignored)
            #expect(page == "page-0")
            // Past the slop the gesture takes over; release commits the page.
            #expect(motion(move(140, 104), .target) == .handled)
            #expect(capture.target === host)
            #expect(page == "page-0")
            // One completed gesture advances at most one page.
            _ = motion(move(40, 104), .target)
            #expect(page == "page-0")
            _ = pointer(down(40, 104), .up, .target)
            #expect(page == "page-1" && capture.target == nil)
        }
    }

    @Test("A disabled carousel keeps its page")
    func disabledIgnoresInput() {
        withScene { graph, registry, _ in
            var page = "page-0"
            graph.install(root: Carousel(pages: pages(), selection: Binding(get: { page }, set: { page = $0 })) {
                $0.isEnabled = false
            })
            graph.computeLayout(width: 320, height: 200)
            let handler = registry.handlers(for: keyNode(in: graph, registry)!).key!
            #expect(handler(key(Scancode.arrowRight), .target) == .ignored)
            #expect(page == "page-0")
        }
    }

    @Test("The viewport reports the page it is showing")
    func accessibilityValue() {
        withScene { graph, _, _ in
            var page = "page-1"
            graph.install(root: Carousel(pages: pages(), selection: Binding(get: { page }, set: { page = $0 })))
            graph.computeLayout(width: 320, height: 200)
            let semantics = nodes(graph.tree.root!).compactMap(\.accessibility).first { $0.label == "Carousel" }
            #expect(semantics?.value == "Page 2 of 3")
        }
    }
    // MARK: - Autoplay and indicators

    private func settle(_ graph: ViewGraph) {
        for _ in 0..<3 { graph.recomposer.commitAll(); graph.computeLayout(width: 360, height: 260) }
    }
    private func tick(_ seconds: Double, _ graph: ViewGraph) {
        AnimatorScheduler.current.tick(deltaTime: seconds); settle(graph)
    }
    private func labelled(_ label: String, in graph: ViewGraph) -> Node? {
        nodes(graph.tree.root!).first { $0.accessibility?.label == label }
    }

    @Test("Autoplay advances each interval, and a manual page change restarts the interval")
    func autoplayAdvances() {
        withScene { graph, registry, _ in
            var page = "page-0"
            graph.install(root: Carousel(pages: pages(), selection: Binding(get: { page }, set: { page = $0 })) {
                $0.autoplay = CarouselAutoplay(interval: 2)
            })
            settle(graph)
            tick(1.5, graph); #expect(page == "page-0")
            tick(0.6, graph); #expect(page == "page-1")
            tick(1.5, graph)
            _ = registry.handlers(for: keyNode(in: graph, registry)!).key!(key(Scancode.arrowRight), .target)
            settle(graph); #expect(page == "page-2")
            tick(1.5, graph); #expect(page == "page-2", "the manual change restarted the interval")
            tick(0.6, graph); #expect(page == "page-0", "rotation wraps")
        }
    }

    @Test("Hover, focus inside and the pause control stop rotation; without wrapping it stops at the end")
    func autoplayPauses() {
        withScene { graph, registry, _ in
            var page = "page-0"
            graph.install(root: Carousel(pages: pages(), selection: Binding(get: { page }, set: { page = $0 })) {
                $0.autoplay = CarouselAutoplay(interval: 2); $0.allowsWrap = false
            })
            settle(graph)
            let hover = nodes(graph.tree.root!).compactMap { registry.handlers(for: $0).hover }.first!
            hover(.enter); tick(3, graph); #expect(page == "page-0", "hovered")
            hover(.leave); tick(2.1, graph); #expect(page == "page-1")

            let pause = labelled("Pause automatic rotation", in: graph)!
            pause.accessibilityActions.activate?(); settle(graph)
            tick(5, graph); #expect(page == "page-1", "paused by the viewer")
            #expect(labelled("Start automatic rotation", in: graph) != nil)
            labelled("Start automatic rotation", in: graph)!.accessibilityActions.activate?(); settle(graph)
            tick(2.1, graph); #expect(page == "page-2")
            tick(10, graph); #expect(page == "page-2", "no wrap: rotation ends on the last page")
        }
    }

    @Test("Keyboard focus inside the carousel pauses rotation")
    func autoplayFocusPauses() {
        withScene { graph, _, _ in
            let oldFocus = FocusChainHolder.current, focus = FocusChain()
            FocusChainHolder.current = focus; defer { FocusChainHolder.current = oldFocus }
            var page = "page-0"
            graph.install(root: Carousel(pages: pages(), selection: Binding(get: { page }, set: { page = $0 })) {
                $0.autoplay = CarouselAutoplay(interval: 2)
            })
            settle(graph)
            focus.focus(labelled("Next page", in: graph)!)
            tick(3, graph); #expect(page == "page-0")
            focus.clear()
            tick(2.1, graph); #expect(page == "page-1")
        }
    }

    @Test("Reduced motion starts paused with a visible start control")
    func autoplayReducedMotion() {
        withScene { graph, _, _ in
            var page = "page-0"
            graph.install(root: Carousel(pages: pages(), selection: Binding(get: { page }, set: { page = $0 })) {
                $0.autoplay = CarouselAutoplay(interval: 2)
            }.reducedMotion())
            settle(graph)
            tick(5, graph); #expect(page == "page-0")
            #expect(labelled("Start automatic rotation", in: graph) != nil)
            #expect(CarouselAutoplay(interval: 0.1).interval == 2 && CarouselAutoplay(interval: .nan).interval == 5)
        }
    }

    @Test("The viewport spans the carousel, so pages of different widths never move the arrows")
    func stableViewport() {
        withScene { graph, registry, _ in
            var page = 0
            let pages = [CarouselPage(0) { Text("A") }, CarouselPage(1) { Text("A much wider page title") }]
            graph.install(root: Carousel(pages: pages, selection: Binding(get: { page }, set: { page = $0 })).frame(width: 400))
            settle(graph)
            let first = swipeNode(in: graph, registry)!.frame
            page = 1; graph.install(root: Carousel(pages: pages, selection: Binding(get: { page }, set: { page = $0 })).frame(width: 400))
            settle(graph)
            let second = swipeNode(in: graph, registry)!.frame
            #expect(first == second && first.width > 300, "\(first) vs \(second)")
        }
    }

    @Test("Automatic indicators use dots up to eight pages and a count beyond")
    func indicatorStyles() {
        withScene { graph, _, _ in
            let many = (0..<9).map { index in CarouselPage(index) { Text("Page \(index)") } }
            graph.install(root: Carousel(pages: many)); settle(graph)
            #expect(labelled("Page 1", in: graph) == nil)
            #expect(nodes(graph.tree.root!).contains { $0.layoutNode?.textInputs?.text == "1 / 9" })
            graph.install(root: Carousel(pages: pages())); settle(graph)
            #expect(labelled("Page 3", in: graph) != nil)
            graph.install(root: Carousel(pages: pages()) { $0.indicator = .hidden }); settle(graph)
            #expect(labelled("Page 3", in: graph) == nil)
            #expect(CarouselIndicator.dots.resolved(pageCount: 1) == .hidden)
        }
    }
}
