import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Product interaction regressions", .serialized)
struct ProductInteractionRegressionTests: GuavaUIComposeSerializedSuite {
    private func nodes(_ root: Node) -> [Node] { [root] + root.children.flatMap(nodes) }
    private func key(_ code: UInt32, modifiers: KeyModifiers = []) -> KeyEvent {
        KeyEvent(scancode: code, keycode: 0, modifiers: modifiers, isRepeat: false)
    }
    private func withScene(_ body: (ViewGraph, PlatformInputContext, EventDispatcher, PortalStore) throws -> Void) rethrows {
        try GlobalTestLock.locked {
            let context = PlatformInputContext(), store = PortalStore()
            context.addScopedAmbient(PortalStoreAmbient(store))
            let previousText = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previousText }
            try context.withCurrent {
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                let dispatcher = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                    capture: context.pointerCapture, focusChain: context.focusChain)
                defer { graph.install(root: EmptyView()); AnimatorScheduler.current.tick(deltaTime: 1) }
                try body(graph, context, dispatcher, store)
            }
        }
    }
    private func settle(_ graph: ViewGraph) {
        for _ in 0..<12 {
            graph.recomposer.commitAll()
            graph.computeLayout(width: 900, height: 700)
            AnimatorScheduler.current.tick(deltaTime: 1.0 / 60.0)
        }
    }
    private func buttons(_ graph: ViewGraph) -> [Node] {
        nodes(graph.tree.root!).filter { $0.attachments[ButtonHost.markerKey] as? Bool == true }
    }

    @Test("Command search folds case, accents and width and keeps every group exactly once")
    func commandProjection() {
        let items = [CommandItem("Café", id: "a", group: "Tools") {},
                     CommandItem("Open File", id: "b", group: "File") {},
                     CommandItem("Camera", id: "c", group: "Tools") {},
                     CommandItem("关于", id: "d") {}]
        #expect(CommandSearch.ranked(items, query: "ＣＡＦＥ").map(\.id) == ["a"])
        #expect(CommandSearch.ranked(items, query: "OPEN FILE").map(\.id) == ["b"])
        #expect(CommandSearch.ranked(items, query: "关于").map(\.id) == ["d"])
        let entries = CommandSearch.entries(items, groupsResults: true)
        #expect(entries.compactMap { if case .item(let item) = $0 { item.id } else { nil } } == ["a", "c", "b", "d"])
        #expect(entries.compactMap { if case .header(let title) = $0 { title } else { nil } } == ["Tools", "File"])
        let ranked = CommandSearch.ranked(items, query: "ca")
        #expect(CommandSearch.entries(ranked, groupsResults: false).compactMap {
            if case .item(let item) = $0 { item.id } else { nil }
        } == ranked.map(\.id))
        for count in 1...12 {
            for index in 0..<count {
                for delta in [Int.min, -10, -1, 0, 1, 10, Int.max] {
                    let wrapped = CommandSearch.destination(count: count, current: index, delta: delta, wraps: true)!
                    let clamped = CommandSearch.destination(count: count, current: index, delta: delta, wraps: false)!
                    #expect((0..<count).contains(wrapped) && (0..<count).contains(clamped))
                }
            }
        }
        #expect(CommandSearch.destination(count: 0, current: nil, delta: -10, wraps: true) == nil)
    }

    @Test("Command palette uses real search input, skips disabled results and clamps page jumps")
    func commandInput() {
        withScene { graph, context, dispatcher, _ in
            var open = true, ran = ""
            graph.install(root: LayerRoot {
                CommandPalette(isPresented: Binding(get: { open }, set: { open = $0 }), items: [
                    CommandItem("Go First", group: "Navigate") { ran = "first" },
                    CommandItem("Go Disabled", group: "Edit", isEnabled: false) { ran = "disabled" },
                    CommandItem("Go Last", group: "Navigate") { ran = "last" }
                ])
            })
            settle(graph)
            #expect(context.focusChain.focused?.accessibility?.role == .textField)
            dispatcher.dispatch(.textInput("GO")); settle(graph)
            #expect(buttons(graph).filter { $0.accessibility?.label == "Go First" }.count == 1)
            #expect(buttons(graph).filter { $0.accessibility?.label == "Go Last" }.count == 1)
            dispatcher.dispatch(.keyDown(key(Scancode.pageUp))); settle(graph)
            dispatcher.dispatch(.keyDown(key(Scancode.pageDown))); settle(graph)
            #expect(buttons(graph).first { $0.accessibility?.label == "Go Last" }?.accessibility?.state.isSelected == true)
            dispatcher.dispatch(.keyDown(key(Scancode.return))); settle(graph)
            #expect(!open && ran == "last")
        }
    }

    @Test("Command palette virtualizes large result sets")
    func commandVirtualization() {
        withScene { graph, _, _, _ in
            var open = true
            let items = (0..<1_000).map {
                CommandItem("Command \($0)", id: "command-\($0)") {}
            }
            graph.install(root: LayerRoot {
                CommandPalette(isPresented: Binding(get: { open }, set: { open = $0 }), items: items)
            })
            for _ in 0..<20 {
                graph.recomposer.commitAll()
                graph.computeLayout(width: 900, height: 700)
                AnimatorScheduler.current.tick(deltaTime: 0.1)
            }
            let rows = buttons(graph).filter { ($0.accessibility?.label ?? "").hasPrefix("Command ") }
            #expect(rows.count > 0)
            #expect(rows.count < 60)
        }
    }

    @Test("Hover card cancels pending work on unmount and survives the trigger-card gap")
    func hoverLifecycle() throws {
        try withScene { graph, context, dispatcher, store in
            graph.install(root: LayerRoot {
                HoverCard(label: { Text("Profile") }, content: { Button("Open profile") {} })
            })
            settle(graph)
            let host = try #require(nodes(graph.tree.root!).first { $0.attachments["hoverCard.host"] as? Bool == true })
            let frame = host.absoluteFrame
            dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: Float(frame.midX), y: Float(frame.midY), deltaX: 0, deltaY: 0)))
            AnimatorScheduler.current.tick(deltaTime: 0.1)
            #expect(store.entries.isEmpty)
            graph.install(root: EmptyView()); AnimatorScheduler.current.tick(deltaTime: 1)
            #expect(store.entries.isEmpty && AnimatorScheduler.current.activeCount == 0)
            graph.install(root: LayerRoot { HoverCard(label: { Text("Profile") }, content: { Text("Detail") }) })
            settle(graph)
            let next = try #require(nodes(graph.tree.root!).first { $0.attachments["hoverCard.host"] as? Bool == true })
            let session = try #require(next.firstResource(HoverCardSession.self))
            context.interactions.handlers(for: next).hover?(.enter)
            AnimatorScheduler.current.tick(deltaTime: 0.31); settle(graph)
            #expect(store.entries.count == 1)
            session.setTriggerHovered(false); AnimatorScheduler.current.tick(deltaTime: 0.1)
            session.setCardHovered(true); AnimatorScheduler.current.tick(deltaTime: 1)
            #expect(store.entries.count == 1)
            session.setCardHovered(false); AnimatorScheduler.current.tick(deltaTime: 0.16)
            #expect(store.entries.isEmpty)
            session.setTriggerHovered(true); AnimatorScheduler.current.tick(deltaTime: 0.31)
            #expect(session.dismiss()); AnimatorScheduler.current.tick(deltaTime: 1)
            #expect(store.entries.isEmpty)
            session.setTriggerHovered(false); session.setTriggerHovered(true)
            AnimatorScheduler.current.tick(deltaTime: 0.31)
            #expect(store.entries.count == 1)
            session.configure(content: AnyView(Text("Detail")), options: HoverCardTiming(
                openDelay: .nan, closeDelay: .infinity, width: .nan, isEnabled: false))
            #expect(store.entries.isEmpty && AnimatorScheduler.current.activeCount == 0)
        }
    }

    @Test("Toolbar arrows move focus, input keeps caret keys, and disabled bars block captured input")
    func toolbarNavigation() throws {
        try withScene { graph, context, dispatcher, _ in
            var calls = 0
            graph.install(root: Toolbar {
                ToolbarGroup(label: "History") {
                    Button("Undo") { calls += 1 }
                    Button("Unavailable", isEnabled: false) {}
                }
                ToolbarSeparator()
                Button("Redo") { calls += 1 }
                TextField("Search", text: .constant("query"))
            })
            settle(graph)
            let items = buttons(graph)
            context.focusChain.focus(items[0])
            dispatcher.dispatch(.keyDown(key(Scancode.arrowRight)))
            #expect(context.focusChain.focused === items[2])
            dispatcher.dispatch(.keyDown(key(Scancode.arrowLeft)))
            #expect(context.focusChain.focused === items[0])
            dispatcher.dispatch(.keyDown(key(Scancode.end)))
            let field = try #require(context.focusChain.focused)
            #expect(field.accessibility?.role == .textField)
            dispatcher.dispatch(.keyDown(key(Scancode.arrowLeft)))
            #expect(context.focusChain.focused === field)
            #expect(nodes(graph.tree.root!).contains { $0.accessibility?.role == .toolbar })
            let event = MouseButtonEvent(button: .left, x: Float(items[0].absoluteFrame.midX), y: Float(items[0].absoluteFrame.midY), clicks: 1)
            dispatcher.dispatch(.mouseButtonDown(event))
            #expect(context.pointerCapture.target === items[0])
            let toolbar = try #require(nodes(graph.tree.root!).first { $0.accessibility?.role == .toolbar })
            toolbar.allowsHitTesting = false
            dispatcher.dispatch(.mouseButtonUp(event)); dispatcher.dispatch(.keyDown(key(Scancode.return)))
            #expect(calls == 0 && context.pointerCapture.target == nil && context.focusChain.focused == nil)
        }
    }

    @Test("Hover card actions and Escape stay in the trigger's modal scope without stealing focus")
    func hoverCardPortalKeys() throws {
        try withScene { graph, context, dispatcher, store in
            var actions = 0
            graph.install(root: LayerRoot {
                FocusScope {
                    Column(spacing: 10) {
                        Button("Previous focus") {}
                        HoverCard(configure: { $0.openDelay = 0 }, label: { Text("Profile") }) {
                            Button("Follow") { actions += 1 }
                        }
                    }
                }
            })
            settle(graph)
            let previous = try #require(buttons(graph).first)
            context.focusChain.focus(previous)
            let trigger = try #require(nodes(graph.tree.root!).first { $0.attachments["hoverCard.host"] != nil })
            let point = trigger.absoluteFrame
            dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: Float(point.midX), y: Float(point.midY), deltaX: 0, deltaY: 0)))
            settle(graph)
            #expect(context.focusChain.focused === previous)
            let cardID = try #require(trigger.firstResource(PortalResource.self)?.entryID)
            let action = try #require(buttons(graph).first { $0 !== previous })
            context.focusChain.focus(action); settle(graph)
            #expect(context.focusChain.focused === action && context.focusChain.accessoryRoots.count == 1)
            dispatcher.dispatch(.keyDown(key(Scancode.return))); settle(graph)
            #expect(actions == 1 && store.contains(cardID))
            dispatcher.dispatch(.keyDown(key(Scancode.escape))); settle(graph)
            #expect(!store.contains(cardID) && context.focusChain.focused === previous)
            AnimatorScheduler.current.tick(deltaTime: 1); settle(graph)
            #expect(!store.contains(cardID) && trigger.firstResource(PortalResource.self)?.entryID == nil)
        }
    }

    @Test("Link keeps its frame when hover reveals an underline and activates through dispatch")
    func linkGeometry() throws {
        try withScene { graph, context, dispatcher, _ in
            var calls = 0
            graph.install(root: Link("Documentation", configure: { $0.underline = .hover }) { calls += 1 })
            settle(graph)
            let link = try #require(buttons(graph).first)
            let before = link.absoluteFrame
            context.interactions.handlers(for: link).hover?(.enter); settle(graph)
            #expect(link.absoluteFrame == before)
            context.interactions.handlers(for: link).hover?(.leave); settle(graph)
            context.focusChain.focus(link); settle(graph)
            #expect(link.absoluteFrame == before && link.accessibility?.role == .link)
            dispatcher.dispatch(.keyDown(key(Scancode.return)))
            #expect(calls == 1)
        }
    }

    @Test("Changing toolbar availability while a child is pressed cancels the live transaction")
    func toolbarLiveDisable() throws {
        try withScene { graph, context, dispatcher, _ in
            var actions = 0
            let scene = ToolbarAvailabilityScene(action: { actions += 1 })
            graph.install(root: scene); settle(graph)
            let button = try #require(buttons(graph).first)
            let point = button.absoluteFrame
            let event = MouseButtonEvent(button: .left, x: Float(point.midX), y: Float(point.midY), clicks: 1)
            dispatcher.dispatch(.mouseButtonDown(event)); settle(graph)
            #expect(context.pointerCapture.target === button)
            scene.isEnabled = false; settle(graph)
            #expect(context.pointerCapture.target == nil && context.focusChain.focused == nil)
            dispatcher.dispatch(.mouseButtonUp(event)); settle(graph)
            #expect(actions == 0)
            scene.isEnabled = true; settle(graph)
            dispatcher.dispatch(.mouseButtonDown(event)); settle(graph)
            dispatcher.dispatch(.mouseButtonUp(event)); settle(graph)
            #expect(actions == 1)
        }
    }
    @Test("Carousel preserves taps, cancels child presses on swipe and locks vertical intent")
    func carouselNestedInput() throws {
        try withScene { graph, context, dispatcher, _ in
            var selected = "a", actions = 0
            let pages = [CarouselPage("a") { Button("Page action") { actions += 1 }.frame(width: 200, height: 100) },
                         CarouselPage("b") { Text("Second page") }]
            graph.install(root: Carousel(pages: pages, selection: Binding(get: { selected }, set: { selected = $0 })) {
                $0.height = 160; $0.showsArrows = false
            })
            settle(graph)
            let button = try #require(buttons(graph).first { $0.accessibility?.role == .button && $0.absoluteFrame.height >= 100 })
            let frame = button.absoluteFrame
            let start = MouseButtonEvent(button: .left, x: Float(frame.midX), y: Float(frame.midY), clicks: 1)
            dispatcher.dispatch(.mouseButtonDown(start)); dispatcher.dispatch(.mouseButtonUp(start))
            #expect(actions == 1 && selected == "a")
            dispatcher.dispatch(.mouseButtonDown(start))
            #expect(context.pointerCapture.target === button)
            dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: start.x - 160, y: start.y, deltaX: -160, deltaY: 0)))
            let swipe = try #require(nodes(graph.tree.root!).first { $0.attachments["horizontal-swipe-host"] != nil })
            #expect(context.pointerCapture.target === swipe)
            #expect(button.attachments[ButtonHost.pressedKey] as? Bool == false)
            dispatcher.dispatch(.mouseButtonUp(MouseButtonEvent(button: .left, x: start.x - 160, y: start.y, clicks: 1)))
            #expect(actions == 1 && selected == "b" && context.pointerCapture.target == nil)
            // A fresh state is needed here because caller-owned data is not a State wrapper.
            graph.install(root: Carousel(pages: pages, selection: Binding(get: { selected }, set: { selected = $0 })) {
                $0.height = 160; $0.showsArrows = false
            })
            settle(graph)
            let host = try #require(nodes(graph.tree.root!).first { $0.attachments["horizontal-swipe-host"] != nil })
            let session = try #require(host.firstResource(HorizontalSwipeSession.self))
            _ = session.pointer(start, phase: .down)
            #expect(session.motion(MouseMotionEvent(x: start.x, y: start.y + 20, deltaX: 0, deltaY: 20)) == .ignored)
            #expect(session.motion(MouseMotionEvent(x: start.x - 200, y: start.y + 20, deltaX: -200, deltaY: 0)) == .ignored)
            _ = session.pointer(start, phase: .up)
            #expect(selected == "b")
            _ = session.pointer(start, phase: .down)
            _ = session.motion(MouseMotionEvent(x: start.x - 200, y: start.y, deltaX: -200, deltaY: 0))
            dispatcher.dispatch(.keyDown(key(Scancode.escape)))
            #expect(context.pointerCapture.target == nil && selected == "b")
            _ = session.pointer(start, phase: .down)
            _ = session.motion(MouseMotionEvent(x: start.x - 200, y: start.y, deltaX: -200, deltaY: 0))
            session.configure(isEnabled: false, onSwipe: { _ in Issue.record("Disabled swipe committed") })
            #expect(context.pointerCapture.target == nil)
            _ = session.pointer(start, phase: .up)
        }
    }

    @Test("Skeleton stops and restarts its clock and remains decorative")
    func skeletonLifecycle() throws {
        try withScene { graph, _, _, _ in
            graph.install(root: Skeleton { $0.appearance.shape = .circle; $0.appearance.height = 48 })
            settle(graph)
            let node = try #require(nodes(graph.tree.root!).first { $0.firstResource(LoadingAnimationClock.self) != nil })
            let clock = try #require(node.firstResource(LoadingAnimationClock.self))
            AnimatorScheduler.current.tick(deltaTime: 0.5)
            #expect(clock.phase > 0 && AnimatorScheduler.current.activeCount == 1 && node.accessibility?.isHidden == true)
            Skeleton { $0.motion.isAnimated = false }._updateNode(node)
            #expect(clock.phase == 0 && AnimatorScheduler.current.activeCount == 0)
            Skeleton()._updateNode(node)
            AnimatorScheduler.current.tick(deltaTime: 0.1)
            #expect(clock.phase > 0)
            graph.install(root: Skeleton().reducedMotion())
            settle(graph)
            #expect(AnimatorScheduler.current.activeCount == 0)
            graph.install(root: EmptyView())
            #expect(AnimatorScheduler.current.activeCount == 0)
        }
    }

    @Test("A disabled carousel rejects nested page actions and focus")
    func disabledCarouselContent() throws {
        try withScene { graph, context, dispatcher, _ in
            var actions = 0
            graph.install(root: Carousel(pages: [CarouselPage("only") {
                Button("Nested action") { actions += 1 }.frame(width: 200, height: 100)
            }]) { $0.isEnabled = false; $0.height = 160 })
            settle(graph)
            let button = try #require(buttons(graph).first)
            let point = button.absoluteFrame
            let event = MouseButtonEvent(button: .left, x: Float(point.midX), y: Float(point.midY), clicks: 1)
            dispatcher.dispatch(.mouseButtonDown(event)); dispatcher.dispatch(.mouseButtonUp(event))
            context.focusChain.focusNext(in: graph.tree.root!)
            #expect(actions == 0 && context.focusChain.focused == nil && context.pointerCapture.target == nil)
        }
    }

    @Test("Stepper owns one Tab stop, skips locked steps and preserves authored outcomes")
    func stepperNavigation() throws {
        try withScene { graph, context, dispatcher, _ in
            var selected: String? = "first"
            let steps = [StepperItem("first", "Account") { $0.status = .completed },
                         StepperItem("locked", "Locked") { $0.isEnabled = false },
                         StepperItem("last", "Details") { $0.status = .failed }]
            graph.install(root: Stepper(steps, selection: Binding(get: { selected }, set: { selected = $0 })))
            settle(graph)
            let items = buttons(graph).filter { $0.acceptsSubtreeInput }
            #expect(items.count == 3 && items.filter { $0.isFocusable && $0.isTabStop }.count == 1)
            context.focusChain.focusNext(in: graph.tree.root!)
            settle(graph)
            #expect(context.focusChain.focused === items[0])
            #expect(items[0].accessibility?.value == "Step 1 of 3 · Completed")
            dispatcher.dispatch(.keyDown(key(Scancode.arrowRight)))
            #expect(selected == "last" && context.focusChain.focused === items[2])
            dispatcher.dispatch(.keyDown(key(Scancode.arrowRight)))
            #expect(selected == "last" && context.focusChain.focused === items[2])
            dispatcher.dispatch(.keyDown(key(Scancode.home)))
            #expect(selected == "first" && context.focusChain.focused === items[0])
            #expect(steps.map(\.status) == [.completed, .pending, .failed])
            #expect(items[2].accessibility?.role == .listItem && items[2].accessibility?.help.contains("Failed") == true)
            graph.install(root: Stepper(steps, selection: Binding(get: { selected }, set: { selected = $0 })) { $0.axis = .vertical })
            settle(graph)
            let vertical = buttons(graph).filter { $0.acceptsSubtreeInput }
            context.focusChain.focus(vertical[0])
            dispatcher.dispatch(.keyDown(key(Scancode.arrowRight)))
            #expect(selected == "first")
            dispatcher.dispatch(.keyDown(key(Scancode.arrowDown)))
            #expect(selected == "last" && context.focusChain.focused === vertical[2])
            graph.install(root: Stepper(steps, selection: Binding(get: { selected }, set: { selected = $0 })) { $0.isEnabled = false })
            settle(graph)
            #expect(buttons(graph).allSatisfy { !$0.isFocusable })
            graph.install(root: Stepper<String>([], selection: .constant(nil)))
            settle(graph)
            #expect(buttons(graph).isEmpty)
        }
    }

}

private struct ToolbarAvailabilityScene: View {
    @State var isEnabled = true
    let action: () -> Void
    var body: some View {
        Toolbar(configure: { $0.isEnabled = isEnabled }) { Button("Run", action: action) }
    }
}
