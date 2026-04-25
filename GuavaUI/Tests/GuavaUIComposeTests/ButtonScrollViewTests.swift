import Testing
import CoreGraphics
import EngineKernel
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Phase 6.4 Button & ScrollView", .serialized)
struct ButtonScrollViewTests: GuavaUIComposeSerializedSuite {

    final class TextStore {
        var value: String = ""
    }

    private func makeBinding(_ store: TextStore) -> Binding<String> {
        Binding(get: { store.value }, set: { store.value = $0 })
    }

    private func firstNode(in root: Node?, where predicate: (Node) -> Bool) -> Node? {
        guard let root else { return nil }
        if predicate(root) { return root }
        for child in root.children {
            if let match = firstNode(in: child, where: predicate) {
                return match
            }
        }
        return nil
    }

    private func absoluteOrigin(of node: Node) -> CGPoint {
        var origin = node.frame.origin
        var current = node.parent
        while let parent = current {
            origin.x += parent.frame.origin.x
            origin.y += parent.frame.origin.y
            current = parent.parent
        }
        return origin
    }

    private func menuEntries(count: Int) -> [MenuEntry] {
        (0..<count).map { index in
            .item(MenuItem(id: index, title: "Item \(index)") {})
        }
    }

    private func inspectorSections(sectionCount: Int = 8,
                                   rowCount: Int = 8) -> [PropertyGridSection] {
        (0..<sectionCount).map { section in
            PropertyGridSection(
                id: "section-\(section)",
                title: "Section \(section)",
                rows: (0..<rowCount).map { row in
                    PropertyGridRow(id: "row-\(section)-\(row)",
                                    label: "Row \(row)") {
                        Text("value")
                    }
                },
                isCollapsible: true
            )
        }
    }

    private func inspectorLikeContent(sections: [PropertyGridSection]) -> some View {
        Box(direction: .column, alignItems: .stretch) {
            Row(alignment: .center, spacing: 8) {
                Box(direction: .column, alignItems: .stretch, spacing: 2) {
                    Text("Cube")
                    Text("Entity")
                }
                Spacer(minLength: 0)
                Text("ID 1")
            }
            .padding(horizontal: 10, vertical: 9)

            Divider()

            PropertyGrid(sections, labelWidth: 88, rowHeight: 24)
                .flex()
        }
        .frame(minWidth: 280)
    }

    private func scrollInspector(_ tree: NodeTree,
                                 registry: InteractionRegistry,
                                 capture: PointerCapture,
                                 focus: FocusChain) -> Node? {
        guard let scrollView = firstNode(in: tree.root, where: {
            registry.handlers(for: $0).wheelRoute?.role == .scroll
        }) else {
            return nil
        }

        let dispatcher = EventDispatcher(tree: tree,
                                         interactions: registry,
                                         capture: capture,
                                         focusChain: focus)
        let origin = absoluteOrigin(of: scrollView)
        dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: Float(origin.x + 12),
                                                          y: Float(origin.y + 12),
                                                          deltaX: 0,
                                                          deltaY: 0)))
        dispatcher.dispatch(.mouseWheel(MouseWheelEvent(x: 0, y: -1)))
        return scrollView
    }

    @Test("Button registers a pointer handler that fires on down+up")
    func buttonFiresOnTap() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        var taps = 0
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            Button(action: { taps += 1 }) {
                Text("OK")
            }
        )

        // Button is now a composite View → user-view anchor → _StatefulButton
        // anchor → ButtonHost primitive. Walk down two anchors.
        let buttonNode = tree.root!.children.first!.children.first!.children.first!
        #expect(buttonNode.isHitTestable == true)
        #expect(buttonNode.isFocusable == true)

        let handlers = registry.handlers(for: buttonNode)
        #expect(handlers.pointer != nil)

        let evt = MouseButtonEvent(button: .left, x: 0, y: 0, clicks: 1)
        _ = handlers.pointer!(evt, .down, .target)
        _ = handlers.pointer!(evt, .up,   .target)
        #expect(taps == 1)
    } }

    @Test("Button up without prior down does not fire action")
    func buttonIgnoresStrayUp() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        var taps = 0
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            Button(action: { taps += 1 }) {
                Text("X")
            }
        )

        let handlers = registry.handlers(for: tree.root!.children.first!.children.first!.children.first!)
        let evt = MouseButtonEvent(button: .left, x: 0, y: 0, clicks: 1)
        let result = handlers.pointer!(evt, .up, .target)
        #expect(taps == 0)
        #expect(result == .ignored)
    } }

    @Test("ScrollView is hit-testable, clips, and registers a wheel handler")
    func scrollViewSetup() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            ScrollView(.vertical) {
                Column {
                    Text("a")
                }
            }
        )

        let sv = tree.root!.children.first!
        #expect(sv.isHitTestable == true)
        #expect(sv.clipsToBounds == true)
        #expect(registry.handlers(for: sv).wheel != nil)
    } }

    @Test("ScrollView wheel handler clamps and updates contentOffset")
    func scrollViewClamps() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            ScrollView(.vertical) {
                Column {
                    // Fixed-height children that exceed the viewport.
                    Text("a").frame(height: 100)
                    Text("b").frame(height: 100)
                    Text("c").frame(height: 100)
                }
            }
            .frame(height: 150)
        )

        // Force layout so the inner column gets a frame.
        graph.computeLayout(width: 200, height: 400)

        let sv = tree.root!.children.first!
        let inner = sv.children.first!
        // Sanity: viewport 150, content ≥ 300 due to fixed-height children.
        #expect(sv.frame.height == 150)
        #expect(inner.frame.height >= 300)

        let wheel = registry.handlers(for: sv).wheel!

        // Scroll down: y = -10 (SDL3 wheel up = positive y; our convention scrolls
        // content up, i.e. offset.y increases when wheel y is negative).
        _ = wheel(MouseWheelEvent(x: 0, y: -1), .target)
        #expect(sv.contentOffset.y > 0)

        // Try to over-scroll: many notches down.
        for _ in 0..<100 {
            _ = wheel(MouseWheelEvent(x: 0, y: -1), .target)
        }
        // Clamped to contentSize - viewSize.
        let maxOffset = inner.frame.height - sv.frame.height
        #expect(sv.contentOffset.y == maxOffset)

        // Scroll back to 0 and overshoot upward.
        for _ in 0..<100 {
            _ = wheel(MouseWheelEvent(x: 0, y: 1), .target)
        }
        #expect(sv.contentOffset.y == 0)
    } }

    @Test("ScrollView scrollbar drag captures pointer before content handlers")
    func scrollViewScrollbarDragCapturesPointer() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        let focus = FocusChain()
        let capture = PointerCapture()
        InteractionRegistryHolder.current = registry
        FocusChainHolder.current = focus
        PointerCaptureHolder.current = capture

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        var contentPresses = 0
        graph.install(root:
            ScrollView(.vertical) {
                Column {
                    Button(action: { contentPresses += 1 }) {
                        Text("content")
                    }
                    .frame(width: 220, height: 120)
                    Text("tail").frame(width: 220, height: 320)
                }
            }
            .frame(width: 220, height: 160)
        )
        graph.computeLayout(width: 220, height: 220)

        let scrollView = tree.root!.children.first!
        let dispatcher = EventDispatcher(
            tree: tree,
            interactions: registry,
            capture: capture,
            focusChain: focus
        )

        let origin = absoluteOrigin(of: scrollView)
        let scrollbarX = Float(origin.x + scrollView.frame.width - 6)
        let thumbY = Float(origin.y + 10)
        dispatcher.dispatch(.mouseButtonDown(MouseButtonEvent(button: .left,
                                                              x: scrollbarX,
                                                              y: thumbY,
                                                              clicks: 1)))

        #expect(capture.target === scrollView)
        #expect(contentPresses == 0)

        dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: scrollbarX,
                                                          y: thumbY + 40,
                                                          deltaX: 0,
                                                          deltaY: 40)))
        #expect(scrollView.contentOffset.y > 0)

        dispatcher.dispatch(.mouseButtonUp(MouseButtonEvent(button: .left,
                                                            x: scrollbarX,
                                                            y: thumbY + 40,
                                                            clicks: 1)))
        #expect(capture.target == nil)
    } }

    @Test("ScrollView uses descendant overflow when its wrapper is clamped")
    func scrollViewUsesDescendantOverflowForWheelAndScrollbar() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        let capture = PointerCapture()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = capture

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            ScrollView(.vertical) {
                Column {
                    Text("content")
                }
            }
            .frame(width: 220, height: 160)
        )
        graph.computeLayout(width: 220, height: 160)

        let scrollView = tree.root!.children.first!
        let wrapper = scrollView.children.first!
        wrapper.frame = CGRect(x: 0, y: 0, width: 220, height: 160)

        let overflowingDescendant = Node()
        overflowingDescendant.frame = CGRect(x: 0, y: 0, width: 220, height: 360)
        wrapper.addChild(overflowingDescendant)

        let handlers = registry.handlers(for: scrollView)
        #expect(handlers.wheel?(MouseWheelEvent(x: 0, y: -1), .target) == .handled)
        #expect(scrollView.contentOffset.y > 0)

        scrollView.contentOffset = .zero
        let pointer = handlers.pointer!
        let motion = handlers.motion!
        let scrollbarX = Float(scrollView.frame.width - 6)
        let thumbY: Float = 10

        #expect(pointer(MouseButtonEvent(button: .left,
                                         x: scrollbarX,
                                         y: thumbY,
                                         clicks: 1), .down, .target) == .handled)
        #expect(capture.target === scrollView)

        #expect(motion(MouseMotionEvent(x: scrollbarX,
                                        y: thumbY + 40,
                                        deltaX: 0,
                                        deltaY: 40), .target) == .handled)
        #expect(scrollView.contentOffset.y > 0)

        #expect(pointer(MouseButtonEvent(button: .left,
                                         x: scrollbarX,
                                         y: thumbY + 40,
                                         clicks: 1), .up, .target) == .handled)
        #expect(capture.target == nil)
    } }

    @Test("PropertyGrid scrolls inside a constrained inspector-sized viewport")
    func propertyGridScrollsInsideConstrainedViewport() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        let capture = PointerCapture()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = capture

        let sections = inspectorSections()

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            PropertyGrid(sections, labelWidth: 88, rowHeight: 24)
                .frame(width: 260, height: 180)
        )
        graph.computeLayout(width: 260, height: 180)

        let scrollView = firstNode(in: tree.root, where: {
            registry.handlers(for: $0).wheelRoute?.role == .scroll
        })
        #expect(scrollView != nil)
        guard let scrollView else { return }

        let wheel = registry.handlers(for: scrollView).wheel!
        #expect(wheel(MouseWheelEvent(x: 0, y: -1), .target) == .handled)
        #expect(scrollView.contentOffset.y > 0)

        scrollView.contentOffset = .zero
        let pointer = registry.handlers(for: scrollView).pointer!
        let motion = registry.handlers(for: scrollView).motion!
        let scrollbarX = Float(scrollView.frame.width - 6)
        let thumbY: Float = 10

        #expect(pointer(MouseButtonEvent(button: .left,
                                         x: scrollbarX,
                                         y: thumbY,
                                         clicks: 1), .down, .target) == .handled)
        #expect(capture.target === scrollView)
        #expect(motion(MouseMotionEvent(x: scrollbarX,
                                        y: thumbY + 40,
                                        deltaX: 0,
                                        deltaY: 40), .target) == .handled)
        #expect(scrollView.contentOffset.y > 0)
    } }

    @Test("Inspector-style PropertyGrid scrolls inside Panel chrome")
    func inspectorPropertyGridScrollsInsidePanel() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        let capture = PointerCapture()
        let focus = FocusChain()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = capture
        FocusChainHolder.current = focus

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            Panel("Inspector") {
                inspectorLikeContent(sections: inspectorSections())
            }
            .frame(width: 300, height: 260)
        )
        graph.computeLayout(width: 300, height: 260)

        let scrollView = scrollInspector(tree,
                                         registry: registry,
                                         capture: capture,
                                         focus: focus)
        #expect(scrollView != nil)
        guard let scrollView else { return }
        #expect(scrollView.contentOffset.y > 0)

        scrollView.contentOffset = .zero
        let dispatcher = EventDispatcher(tree: tree,
                                         interactions: registry,
                                         capture: capture,
                                         focusChain: focus)
        let origin = absoluteOrigin(of: scrollView)
        let rootRight = tree.root.map { absoluteOrigin(of: $0).x + $0.frame.width } ?? origin.x + scrollView.frame.width
        let scrollbarX = Float(min(origin.x + scrollView.frame.width - 6, rootRight - 6))
        let thumbY = Float(origin.y + 10)
        dispatcher.dispatch(.mouseButtonDown(MouseButtonEvent(button: .left,
                                                              x: scrollbarX,
                                                              y: thumbY,
                                                              clicks: 1)))
        #expect(capture.target === scrollView)
        dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: scrollbarX,
                                                          y: thumbY + 40,
                                                          deltaX: 0,
                                                          deltaY: 40)))
        #expect(scrollView.contentOffset.y > 0)
    } }

    @Test("Inspector-style PropertyGrid scrolls when hosted by DockContainer")
    func inspectorPropertyGridScrollsInsideDockContainer() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        let capture = PointerCapture()
        let focus = FocusChain()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = capture
        FocusChainHolder.current = focus

        let tab = DockTab(userKey: "inspector", title: "Inspector")
        let controller = DockController(root: .tabs([tab]))
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            DockContainer(controller: controller, horizontalInset: 0) { _ in
                AnyView(
                    Panel("Inspector") {
                        inspectorLikeContent(sections: inspectorSections())
                    }
                )
            }
            .frame(width: 320, height: 300)
        )
        graph.computeLayout(width: 320, height: 300)

        let scrollView = scrollInspector(tree,
                                         registry: registry,
                                         capture: capture,
                                         focus: focus)
        #expect(scrollView != nil)
        guard let scrollView else { return }
        #expect(scrollView.contentOffset.y > 0)

        scrollView.contentOffset = .zero
        let dispatcher = EventDispatcher(tree: tree,
                                         interactions: registry,
                                         capture: capture,
                                         focusChain: focus)
        let origin = absoluteOrigin(of: scrollView)
        let rootRight = tree.root.map { absoluteOrigin(of: $0).x + $0.frame.width } ?? origin.x + scrollView.frame.width
        let scrollbarX = Float(min(origin.x + scrollView.frame.width - 6, rootRight - 6))
        let thumbY = Float(origin.y + 10)
        dispatcher.dispatch(.mouseButtonDown(MouseButtonEvent(button: .left,
                                                              x: scrollbarX,
                                                              y: thumbY,
                                                              clicks: 1)))
        #expect(capture.target === scrollView)
        dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: scrollbarX,
                                                          y: thumbY + 40,
                                                          deltaX: 0,
                                                          deltaY: 40)))
        #expect(scrollView.contentOffset.y > 0)
    } }

    @Test("Wheel over a scrollable TextField does not bubble into the parent ScrollView")
    func nestedTextFieldConsumesWheelBeforeParentScrollView() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        let focus = FocusChain()
        InteractionRegistryHolder.current = registry
        FocusChainHolder.current = focus
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        let store = TextStore()
        store.value = Array(repeating: "line", count: 12).joined(separator: "\n")

        graph.install(root:
            ScrollView(.vertical) {
                Column {
                    Text("header").frame(height: 240)
                    TextField(text: makeBinding(store)).frame(width: 180)
                    Text("footer").frame(height: 240)
                }
            }
            .frame(width: 220, height: 180)
        )
        graph.computeLayout(width: 220, height: 240)

        let scrollView = tree.root!.children.first!
        let field = firstNode(in: tree.root, where: { $0.attachments[TextField.surfaceMarkerKey] != nil })!
        let fieldState = field.attachments["__textfield_state"] as? TextField.FieldState
        #expect((fieldState?.maxScrollY ?? 0) > 0)
        #expect(scrollView.contentOffset.y == 0)
        fieldState?.maxScrollY = 0
        fieldState?.visibleTextHeight = 0
        fieldState?.contentHeight = 0

        let dispatcher = EventDispatcher(
            tree: tree,
            interactions: registry,
            capture: PointerCapture(),
            focusChain: focus
        )
        let origin = absoluteOrigin(of: field)
        dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: Float(origin.x + 12),
                                                          y: Float(origin.y + 12),
                                                          deltaX: 0,
                                                          deltaY: 0)))
        dispatcher.dispatch(.mouseWheel(MouseWheelEvent(x: 0, y: -1)))

        #expect(field.contentOffset.y > 0)
        #expect(scrollView.contentOffset.y == 0)
    } }

    @Test("TextField wheel at boundary passes through to parent ScrollView")
    func nestedTextFieldBoundaryPassesWheelToParentScrollView() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        let focus = FocusChain()
        InteractionRegistryHolder.current = registry
        FocusChainHolder.current = focus
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        let store = TextStore()
        store.value = Array(repeating: "line", count: 16).joined(separator: "\n")

        graph.install(root:
            ScrollView(.vertical) {
                Column {
                    Text("header").frame(height: 20)
                    TextField(text: makeBinding(store)).frame(width: 180)
                    Text("footer").frame(height: 320)
                }
            }
            .frame(width: 220, height: 180)
        )
        graph.computeLayout(width: 220, height: 260)

        let scrollView = tree.root!.children.first!
        let field = firstNode(in: tree.root, where: { $0.attachments[TextField.surfaceMarkerKey] != nil })!
        let fieldState = field.attachments["__textfield_state"] as? TextField.FieldState
        #expect((fieldState?.maxScrollY ?? 0) > 0)

        let dispatcher = EventDispatcher(
            tree: tree,
            interactions: registry,
            capture: PointerCapture(),
            focusChain: focus
        )

        let origin = absoluteOrigin(of: field)
        dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: Float(origin.x + 12),
                                                          y: Float(origin.y + 12),
                                                          deltaX: 0,
                                                          deltaY: 0)))

        fieldState?.scrollOffsetY = fieldState?.maxScrollY ?? 0
        field.contentOffset = CGPoint(x: 0, y: CGFloat(fieldState?.maxScrollY ?? 0))

        let previousFieldOffset = field.contentOffset.y
        dispatcher.dispatch(.mouseWheel(MouseWheelEvent(x: 0, y: -1)))

        #expect(field.contentOffset.y == previousFieldOffset)
        #expect(scrollView.contentOffset.y > 0)
    } }

    @Test("Scrollable Menu in Popover-style list passes boundary wheel to parent ScrollView")
    func nestedMenuBoundaryPassesWheelToParentScrollView() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        let focus = FocusChain()
        InteractionRegistryHolder.current = registry
        FocusChainHolder.current = focus

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())

        graph.install(root:
            ScrollView(.vertical) {
                Column {
                    Text("header").frame(height: 20)
                    Menu(menuEntries(count: 24), width: 180, maxVisibleRows: 5)
                    Text("footer").frame(height: 320)
                }
            }
            .frame(width: 240, height: 200)
        )
        graph.computeLayout(width: 240, height: 300)

        let parentScrollView = tree.root!.children.first!
        let menuScrollView = firstNode(in: tree.root, where: {
            $0 !== parentScrollView
                && registry.handlers(for: $0).wheel != nil
                && abs($0.frame.height - 160) < 0.1
        })
        #expect(menuScrollView != nil)
        guard let menuScrollView else { return }

        let menuWheel = registry.handlers(for: menuScrollView).wheel
        #expect(menuWheel != nil)
        if let menuWheel {
            for _ in 0..<100 {
                _ = menuWheel(MouseWheelEvent(x: 0, y: -1), .target)
            }
        }

        let dispatcher = EventDispatcher(
            tree: tree,
            interactions: registry,
            capture: PointerCapture(),
            focusChain: focus
        )

        let origin = absoluteOrigin(of: menuScrollView)
        dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: Float(origin.x + 8),
                                                          y: Float(origin.y + 8),
                                                          deltaX: 0,
                                                          deltaY: 0)))

        let previousMenuOffset = menuScrollView.contentOffset.y
        dispatcher.dispatch(.mouseWheel(MouseWheelEvent(x: 0, y: -1)))

        #expect(menuScrollView.contentOffset.y == previousMenuOffset)
        #expect(parentScrollView.contentOffset.y > 0)
    } }

    @Test("Focused TextField wheel priority outranks hovered parent ScrollView")
    func focusedTextFieldWheelPriorityBeatsHoveredParent() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        let focus = FocusChain()
        InteractionRegistryHolder.current = registry
        FocusChainHolder.current = focus
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        let store = TextStore()
        store.value = Array(repeating: "line", count: 12).joined(separator: "\n")

        graph.install(root:
            ScrollView(.vertical) {
                Column {
                    Text("header").frame(height: 20)
                    TextField(text: makeBinding(store)).frame(width: 180)
                    Text("footer").frame(height: 240)
                }
            }
            .frame(width: 220, height: 180)
        )
        graph.computeLayout(width: 220, height: 240)

        let scrollView = tree.root!.children.first!
        let field = firstNode(in: tree.root, where: { $0.attachments[TextField.surfaceMarkerKey] != nil })!
        let fieldState = field.attachments["__textfield_state"] as? TextField.FieldState
        #expect((fieldState?.maxScrollY ?? 0) > 0)

        focus.focus(field)
        #expect(field.attachments[WheelRoutingAttachmentKey.priority] as? WheelRoutingPriority
                    == .preferFocused)

        let dispatcher = EventDispatcher(
            tree: tree,
            interactions: registry,
            capture: PointerCapture(),
            focusChain: focus
        )
        let previousFieldOffset = field.contentOffset.y
        dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: 12,
                                                          y: 12,
                                                          deltaX: 0,
                                                          deltaY: 0)))
        dispatcher.dispatch(.mouseWheel(MouseWheelEvent(x: 0, y: 1)))

        #expect(field.contentOffset.y < previousFieldOffset)
        #expect(scrollView.contentOffset.y == 0)
    } }
}
