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
        nodes(graph.tree.root!).first { $0.attachments["carousel-swipe-host"] != nil }
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
}
