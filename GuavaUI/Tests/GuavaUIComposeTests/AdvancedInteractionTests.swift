import Foundation
import EngineKernel
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Advanced UI interaction", .serialized)
struct AdvancedInteractionTests: GuavaUIComposeSerializedSuite {
    private func nodes(_ node: Node?) -> [Node] {
        guard let node else { return [] }; return [node] + node.children.flatMap { nodes($0) }
    }
    private func settle(_ graph: ViewGraph, width: Float = 400, height: Float = 300) {
        for _ in 0..<4 {
            graph.recomposer.commitAll(); graph.computeLayout(width: width, height: height)
            if let root = graph.tree.root { NodeRenderer().render(root: root, into: DrawList()) }
        }
    }
    private func dispatcher(_ graph: ViewGraph, _ context: PlatformInputContext) -> EventDispatcher {
        EventDispatcher(tree: graph.tree, interactions: context.interactions,
                        capture: context.pointerCapture, focusChain: context.focusChain)
    }
    private func key(_ code: UInt32, primary: Bool = false, shift: Bool = false) -> KeyEvent {
        var modifiers: KeyModifiers = []
        if primary { modifiers.insert(.lgui) }; if shift { modifiers.insert(.lshift) }
        return KeyEvent(scancode: code, keycode: 0, modifiers: modifiers, isRepeat: false)
    }

    @Test("history groups typing, restores Unicode selections, branches redo, and resets on external replacement")
    func historyTransactions() {
        let history = TextEditHistory()
        let a = TextEditHistory.Snapshot(text: "中", cursor: 1)
        let b = TextEditHistory.Snapshot(text: "中😀", cursor: 2)
        let c = TextEditHistory.Snapshot(text: "中😀a", cursor: 3)
        history.synchronize(a.text)
        history.record(before: a, after: b, kind: .typing, time: 1)
        history.record(before: b, after: c, kind: .typing, time: 1.2)
        #expect(history.undo() == a)
        #expect(history.redo() == c)
        let selection = TextEditHistory.Snapshot(text: c.text, cursor: 3, anchor: 0)
        let paste = TextEditHistory.Snapshot(text: "替换", cursor: 2)
        history.record(before: selection, after: paste, kind: .atomic, time: 2)
        #expect(history.undo() == selection)
        history.record(before: selection, after: a, kind: .atomic, time: 3)
        #expect(!history.canRedo)
        history.synchronize("another document")
        #expect(!history.canUndo)
    }

    @Test("text undo wins over scene shortcuts; paste is one transaction and redo restores it")
    func fieldUndoRouting() throws { try GlobalTestLock.locked {
        let context = PlatformInputContext()
        try context.withCurrent {
            var text = "中😀"; var sceneUndos = 0
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: Box {
                ShortcutHost { event in if event.scancode == Scancode.z { sceneUndos += 1; return true }; return false }
                TextField(text: Binding(get: { text }, set: { text = $0 }))
            })
            settle(graph)
            let field = try #require(nodes(graph.tree.root).first { $0.attachments[TextField.surfaceMarkerKey] != nil })
            context.focusChain.focus(field)
            let input = dispatcher(graph, context)
            input.dispatch(.textInput("a")); input.dispatch(.textInput("b"))
            input.dispatch(.keyDown(key(Scancode.z, primary: true)))
            #expect(text == "中😀"); #expect(sceneUndos == 0)
            input.dispatch(.keyDown(key(Scancode.z, primary: true, shift: true)))
            #expect(text == "中😀ab")
            let previousRead = ClipboardHolder.read
            defer { ClipboardHolder.read = previousRead }
            ClipboardHolder.read = { "粘贴\n值" }
            input.dispatch(.keyDown(key(Scancode.a, primary: true)))
            input.dispatch(.keyDown(key(Scancode.v, primary: true)))
            #expect(text == "粘贴\n值")
            input.dispatch(.keyDown(key(Scancode.z, primary: true)))
            #expect(text == "中😀ab")
            let state = try #require(field.attachments["__textfield_state"] as? TextField.FieldState)
            #expect(state.selectionAnchor == 0 && state.cursorIndex == 4)
        }
    } }

    @Test("nested modal scopes wrap Tab, reject background focus, and restore pointer focus")
    func focusScopes() {
        let chain = FocusChain(); let root = Node()
        let outside = Node(); outside.isFocusable = true; root.addChild(outside)
        let modal = Node(); root.addChild(modal)
        let first = Node(); first.isFocusable = true; modal.addChild(first)
        let last = Node(); last.isFocusable = true; modal.addChild(last)
        chain.focus(outside, visible: false); chain.pushScope(modal)
        #expect(chain.focused === first)
        chain.focusPrevious(in: root); #expect(chain.focused === last)
        chain.focusNext(in: root); #expect(chain.focused === first)
        chain.focus(outside); #expect(chain.focused === first)
        let nested = Node(); root.addChild(nested)
        let nestedInput = Node(); nestedInput.isFocusable = true; nested.addChild(nestedInput)
        chain.pushScope(nested); #expect(chain.focused === nestedInput)
        chain.popScope(nested); #expect(chain.focused === first)
        chain.popScope(modal); #expect(chain.focused === outside); #expect(!chain.isFocusVisible)
    }

    private struct ModalHarness: View {
        @State var presented = false
        let onBackground: () -> Void
        var body: some View {
            LayerRoot {
                Button("Background", action: onBackground).debugName("background")
            } portals: {
                Modal(isPresented: $presented, width: 260, height: 160) {
                    TextField(text: .constant("JSON")).debugName("modal-input")
                }
                PortalHost()
            }.frame(width: 400, height: 300)
        }
    }
    @Test("modal Escape restores focus, inside clicks do not dismiss, and background action stays inert")
    func modalLifecycle() throws { try GlobalTestLock.locked {
        let context = PlatformInputContext(); let store = PortalStore()
        context.addScopedAmbient(PortalStoreAmbient(store))
        try context.withCurrent {
            var actions = 0
            let harness = ModalHarness { actions += 1 }
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: harness); settle(graph)
            let background = try #require(nodes(graph.tree.root).first { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "background" })
            context.focusChain.focus(background, visible: false)
            harness.$presented.wrappedValue = true; settle(graph)
            let field = try #require(nodes(graph.tree.root).first { $0.attachments[TextField.surfaceMarkerKey] != nil })
            let frame = field.absoluteFrame
            let input = dispatcher(graph, context)
            let click = MouseButtonEvent(button: .left, x: Float(frame.midX), y: Float(frame.midY), clicks: 1)
            input.dispatch(.mouseButtonDown(click)); input.dispatch(.mouseButtonUp(click))
            #expect(harness.presented); #expect(actions == 0); #expect(context.focusChain.hasModalScope)
            input.dispatch(.keyDown(key(Scancode.escape))); graph.recomposer.commitAll()
            AnimatorScheduler.current.tick(deltaTime: 1); settle(graph)
            #expect(!harness.presented); #expect(!context.focusChain.hasModalScope)
            #expect(context.focusChain.focused === background)
        }
    } }

    private struct Row: Identifiable { let id: Int }
    private struct VirtualHarness: View {
        @State var count = 10_000
        @State var target: Int? = nil
        var body: some View {
            VirtualStack((0..<count).map { Row(id: $0) }, id: \.id, rowHeight: 32, spacing: 2, scrollToIndex: target) { row in
                Button("Row \(row.id)") {}.debugName("virtual-row-\(row.id)")
            }.frame(width: 300, height: 200)
        }
    }
    @Test("ten thousand rows mount only the viewport; wheel, reveal, and filtering clamp correctly")
    func virtualViewport() throws { try GlobalTestLock.locked {
        let context = PlatformInputContext()
        try context.withCurrent {
            let harness = VirtualHarness()
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: harness); settle(graph, width: 300, height: 200)
            func mounted() -> [Node] { nodes(graph.tree.root).filter { ($0.attachments[LayoutDebugAttachmentKey.debugName] as? String)?.hasPrefix("virtual-row-") == true } }
            #expect(mounted().count <= 18)
            #expect(mounted().contains { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "virtual-row-0" })
            let input = dispatcher(graph, context)
            input.dispatch(.mouseWheel(MouseWheelEvent(x: 0, y: -20, mouseX: 100, mouseY: 100)))
            settle(graph, width: 300, height: 200)
            #expect(mounted().count <= 18)
            #expect(!mounted().contains { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "virtual-row-0" })
            harness.$target.wrappedValue = 9000; settle(graph, width: 300, height: 200)
            let target = try #require(mounted().first { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "virtual-row-9000" })
            #expect(target.absoluteFrame.minY >= 0 && target.absoluteFrame.maxY <= 201)
            harness.$count.wrappedValue = 3; harness.$target.wrappedValue = nil
            settle(graph, width: 300, height: 200)
            #expect(mounted().count == 3)
            #expect(mounted().first?.absoluteFrame.minY == 0)
        }
    } }

    @Test("right click opens a keyboard menu without activating the row")
    func contextMenuLifecycle() throws { try GlobalTestLock.locked {
        let context = PlatformInputContext(); let portals = PortalStore()
        context.addScopedAmbient(PortalStoreAmbient(portals))
        try context.withCurrent {
            var activations = 0; var action = 0
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: LayerRoot {
                Button("Entity") { activations += 1 }.frame(width: 80, height: 32)
                    .contextMenu([.item(MenuItem(id: "rename", title: "Rename", action: { action = 1 })),
                                  .separator("actions"),
                                  .item(MenuItem(id: "delete", title: "Delete", action: { action = 2 }))])
                    .absolutePosition(left: 280, top: 220)
            } portals: { PortalHost() }.frame(width: 400, height: 300))
            settle(graph)
            let input = dispatcher(graph, context)
            let event = MouseButtonEvent(button: .right, x: 300, y: 235, clicks: 1)
            input.dispatch(.mouseButtonDown(event)); input.dispatch(.mouseButtonUp(event))
            settle(graph)
            #expect(activations == 0); #expect(portals.entries.count == 1)
            let slot = try #require(nodes(graph.tree.root).first { $0.attachments[LayoutDebugAttachmentKey.layoutRole] as? String == "portal-entry" })
            #expect(CGRect(x: 0, y: 0, width: 400, height: 300).contains(slot.absoluteFrame))
            input.dispatch(.keyDown(key(Scancode.arrowDown)))
            input.dispatch(.keyDown(key(Scancode.return))); settle(graph)
            #expect(action == 2); #expect(portals.entries.isEmpty)
        }
    } }

    @Test("dragging the resize grip changes the actual editor viewport and releases capture")
    func resizableViewport() throws { try GlobalTestLock.locked {
        let context = PlatformInputContext()
        try context.withCurrent {
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: ResizableEditor(initialHeight: 160, minHeight: 100, maxHeight: 300) {
                TextField(text: .constant("JSON"), axis: .vertical)
            }.frame(width: 300))
            settle(graph, width: 300, height: 400)
            let grip = try #require(nodes(graph.tree.root).first { $0.cursor == .resizeVertical })
            let field = try #require(nodes(graph.tree.root).first { $0.attachments[TextField.surfaceMarkerKey] != nil })
            let initial = field.frame.height
            let point = grip.absoluteFrame
            let input = dispatcher(graph, context)
            input.dispatch(.mouseButtonDown(MouseButtonEvent(button: .left, x: Float(point.midX), y: Float(point.midY), clicks: 1)))
            input.dispatch(.mouseMotion(MouseMotionEvent(x: Float(point.midX), y: Float(point.midY + 100), deltaX: 0, deltaY: 100)))
            settle(graph, width: 300, height: 400)
            #expect(field.frame.height >= initial + 99)
            input.dispatch(.mouseButtonUp(MouseButtonEvent(button: .left, x: Float(point.midX), y: Float(point.midY + 100), clicks: 1)))
            #expect(context.pointerCapture.target == nil)
        }
    } }

    @Test("window fitting flips or clamps popovers at every edge", arguments: [CGPoint(x: -100, y: -30), CGPoint(x: 500, y: 260)])
    func portalEdges(position: CGPoint) {
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 240)
        let rect = PortalPlacement.fit(position: position, size: CGSize(width: 220, height: 180), in: bounds,
                                      anchor: CGRect(x: 290, y: 210, width: 20, height: 20))
        #expect(bounds.contains(rect))
        #expect(rect.minX >= 6 && rect.minY >= 6)
    }

    @Test("composed asymmetric transitions reverse without a visible jump")
    func composedTransition() throws { try GlobalTestLock.locked {
        struct Harness: View {
            @State var visible = false
            var body: some View {
                AnimatedVisibility(isVisible: visible,
                    transition: .asymmetric(insertion: .opacity.combined(with: .move(edge: .top, distance: 20)),
                                            removal: .opacity.combined(with: .move(edge: .bottom, distance: 30))),
                    animation: Animation(duration: 0.2, curve: .linear)) {
                    Button("Animated") {}.frame(height: 40)
                }
            }
        }
        let scheduler = AnimatorScheduler()
        try AnimatorScheduler.$current.withValue(scheduler) {
            let harness = Harness(); let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: harness)
            harness.$visible.wrappedValue = true; graph.recomposer.commitAll()
            scheduler.tick(deltaTime: 0.1)
            let host = try #require(nodes(graph.tree.root).first { $0.contentOffset.y != 0 })
            let opacity = host.opacity; let offset = host.contentOffset
            harness.$visible.wrappedValue = false; graph.recomposer.commitAll()
            #expect(host.opacity == opacity && host.contentOffset == offset)
            scheduler.tick(deltaTime: 1); graph.recomposer.commitAll()
            #expect(host.children.isEmpty)
        }
    } }
}
