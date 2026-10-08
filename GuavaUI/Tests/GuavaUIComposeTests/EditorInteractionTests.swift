import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
import EngineKernel
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Editor interaction primitives", .serialized)
struct EditorInteractionTests: GuavaUIComposeSerializedSuite {
    final class Store { var text: TextBuffer = "alpha"; var actions = 0 }
    struct Rig {
        let registry = InteractionRegistry()
        let focus = FocusChain()
        let capture = PointerCapture()
        let tree = NodeTree()
        var graph: ViewGraph { ViewGraph(tree: tree, recomposer: Recomposer()) }
        var dispatcher: EventDispatcher {
            EventDispatcher(tree: tree, interactions: registry, capture: capture, focusChain: focus)
        }
    }
    private func withRig(_ test: (Rig) throws -> Void) rethrows {
        try GlobalTestLock.locked {
            let oldRegistry = InteractionRegistryHolder.current
            let oldFocus = FocusChainHolder.current
            let oldCapture = PointerCaptureHolder.current
            let oldText = TextEnvironmentHolder.current
            let oldStore = PortalStoreHolder.current
            let rig = Rig()
            InteractionRegistryHolder.current = rig.registry
            FocusChainHolder.current = rig.focus
            PointerCaptureHolder.current = rig.capture
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make(size: 12, lineHeight: 16)
            PortalStoreHolder.current = PortalStore()
            defer {
                InteractionRegistryHolder.current = oldRegistry
                FocusChainHolder.current = oldFocus
                PointerCaptureHolder.current = oldCapture
                TextEnvironmentHolder.current = oldText
                PortalStoreHolder.current = oldStore
            }
            try AnimatorScheduler.$current.withValue(AnimatorScheduler()) { try test(rig) }
        }
    }
    private func all(_ node: Node?) -> [Node] {
        guard let node else { return [] }
        return [node] + node.children.flatMap { all($0) }
    }
    private func field(_ tree: NodeTree) throws -> Node {
        try #require(all(tree.root).first { $0.attachments[TextField.surfaceMarkerKey] != nil })
    }
    private func key(_ scan: UInt32, modifiers: KeyModifiers = []) -> KeyEvent {
        KeyEvent(scancode: scan, keycode: 0, modifiers: modifiers, isRepeat: false)
    }

    @Test("selection replacement undo restores text and selection before scene shortcuts")
    func undoSelectionReplacement() throws { try withRig { rig in
        let store = Store()
        let graph = rig.graph
        graph.install(root: Column {
            TextField(text: Binding(get: { store.text }, set: { store.text = $0 }))
            ShortcutHost { _ in store.actions += 1; return true }
        })
        let node = try field(rig.tree)
        rig.focus.focus(node)
        let dispatcher = rig.dispatcher
        dispatcher.dispatch(.keyDown(key(Scancode.a, modifiers: .lgui)))
        dispatcher.dispatch(.textInput("中文🙂"))
        #expect(store.text.stringValue == "中文🙂")
        dispatcher.dispatch(.keyDown(key(Scancode.z, modifiers: .lgui)))
        #expect(store.text.stringValue == "alpha")
        #expect(store.actions == 0)
        let state = try #require(node.attachments["__textfield_state"] as? TextField.FieldState)
        #expect(state.selection.cursorIndex == 5)
        #expect(state.selection.anchor == 0)
        dispatcher.dispatch(.keyDown(key(Scancode.z, modifiers: [.lgui, .lshift])))
        #expect(store.text.stringValue == "中文🙂")
        dispatcher.dispatch(.keyDown(key(Scancode.z, modifiers: .lgui)))
        dispatcher.dispatch(.textInput("beta"))
        dispatcher.dispatch(.keyDown(key(Scancode.y, modifiers: .lctrl)))
        #expect(store.text.stringValue == "beta")
    } }

    @Test("invalid JSON draft survives blur and refocus")
    func invalidJsonDraftPersists() throws { try withRig { rig in
        let store = Store(); store.text = "{}"
        let graph = rig.graph
        graph.install(root: JsonField(text: Binding(get: { store.text }, set: { store.text = $0 })))
        let node = try field(rig.tree)
        rig.focus.focus(node); graph.recomposer.commitAll()
        let dispatcher = rig.dispatcher
        dispatcher.dispatch(.keyDown(key(Scancode.a, modifiers: .lgui)))
        dispatcher.dispatch(.textInput("{ invalid"))
        rig.focus.clear(); graph.recomposer.commitAll()
        #expect(store.text.stringValue == "{}")
        rig.focus.focus(node); graph.recomposer.commitAll()
        let state = try #require(node.attachments["__textfield_state"] as? TextField.FieldState)
        #expect(state.transaction.history.currentBuffer?.stringValue == "{ invalid")
        dispatcher.dispatch(.keyDown(key(Scancode.a, modifiers: .lgui)))
        dispatcher.dispatch(.textInput("{\"ok\":true}"))
        rig.focus.clear(); graph.recomposer.commitAll()
        #expect(store.text.stringValue == "{\"ok\":true}")
    } }

    @Test("platform text commands share keyboard history and reject stale external edits")
    func platformTextHistory() throws { try withRig { rig in
        let store = Store()
        let graph = rig.graph
        graph.install(root: TextField(text: Binding(get: { store.text }, set: { store.text = $0 })))
        rig.focus.focus(try field(rig.tree))
        #expect(rig.focus.textEditAvailability(.undo) == false)
        #expect(rig.focus.performTextEdit(.undo))
        rig.dispatcher.dispatch(.keyDown(key(Scancode.a, modifiers: .lgui)))
        rig.dispatcher.dispatch(.textInput("replacement"))
        #expect(rig.focus.textEditAvailability(.undo) == true)
        #expect(rig.focus.performTextEdit(.undo))
        #expect(store.text.stringValue == "alpha")
        #expect(rig.focus.textEditAvailability(.redo) == true)
        rig.focus.performTextEdit(.redo)
        #expect(store.text.stringValue == "replacement")
        store.text = "external document"
        #expect(rig.focus.textEditAvailability(.undo) == false)
        #expect(rig.focus.textEditAvailability(.redo) == false)
        rig.focus.performTextEdit(.undo)
        #expect(store.text.stringValue == "external document")
        rig.focus.clear()
        #expect(rig.focus.textEditAvailability(.undo) == nil)
        #expect(!rig.focus.performTextEdit(.undo))
    } }

    @Test("expanded JSON applies valid content atomically and Escape cancels")
    func expandedJsonTransaction() throws { try withRig { rig in
        let store = Store(); store.text = "{}"
        let graph = rig.graph
        graph.install(root: LayerRoot {
            JsonField(text: Binding(get: { store.text }, set: { store.text = $0 }))
        })
        func settle() {
            for _ in 0..<3 {
                graph.recomposer.commitAll(); AnimatorScheduler.current.tick(deltaTime: 1)
                graph.recomposer.commitAll(); graph.computeLayout(width: 640, height: 480)
            }
        }
        func activate(_ name: String) throws {
            let named = try #require(all(rig.tree.root).first { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == name })
            let button = try #require(all(named).first { rig.registry.handlers(for: $0).key != nil })
            _ = rig.registry.handlers(for: button).key?(key(Scancode.return), .target)
        }
        settle()
        let inline = try field(rig.tree)
        rig.focus.focus(inline)
        try activate("json-expand"); settle()
        let modalRoot = try #require(rig.focus.modalRoot)
        let editor = try #require(all(modalRoot).first { $0.attachments[TextField.surfaceMarkerKey] != nil })
        #expect(rig.focus.focused === editor)
        rig.dispatcher.dispatch(.keyDown(key(Scancode.a, modifiers: .lgui)))
        rig.dispatcher.dispatch(.textInput("{ invalid")); settle()
        #expect(store.text.stringValue == "{}")
        rig.dispatcher.dispatch(.keyDown(key(Scancode.return, modifiers: .lgui))); settle()
        #expect(rig.focus.modalRoot != nil)
        rig.dispatcher.dispatch(.keyDown(key(Scancode.a, modifiers: .lgui)))
        rig.dispatcher.dispatch(.textInput("{\"value\":42}")); settle()
        #expect(store.text.stringValue == "{}")
        try activate("json-apply"); settle()
        #expect(store.text.stringValue == "{\"value\":42}")
        #expect(rig.focus.modalRoot == nil)
        try activate("json-expand"); settle()
        rig.dispatcher.dispatch(.keyDown(key(Scancode.a, modifiers: .lgui)))
        rig.dispatcher.dispatch(.textInput("{\"value\":100}")); settle()
        rig.dispatcher.dispatch(.keyDown(key(Scancode.escape))); settle()
        #expect(store.text.stringValue == "{\"value\":42}")
        #expect(PortalStoreHolder.current.entries.isEmpty)
    } }

    @Test("expanded JSON has a centered editor and clickable footer after opening and resizing", arguments: [false, true])
    func expandedJsonLayout(compactInitially: Bool) throws { try withRig { rig in
        let store = Store()
        store.text = TextBuffer("[\n" + (0..<30).map { "  {\"value\":\($0)}" }.joined(separator: ",\n") + "\n]")
        let graph = rig.graph
        graph.install(root: LayerRoot {
            JsonField(text: Binding(get: { store.text }, set: { store.text = $0 }))
                .frame(width: 280)
        })
        let largeWindow = CGSize(width: 1280, height: 800)
        let compactWindow = CGSize(width: 640, height: 480)
        var window = compactInitially ? compactWindow : largeWindow
        func settle() {
            for _ in 0..<3 {
                graph.recomposer.commitAll(); AnimatorScheduler.current.tick(deltaTime: 1)
                graph.recomposer.commitAll()
                graph.computeLayout(width: Float(window.width), height: Float(window.height))
            }
        }
        func named(_ name: String) throws -> Node {
            try #require(all(rig.tree.root).first {
                $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == name
            })
        }
        func click(_ node: Node) {
            let frame = node.absoluteFrame
            let event = MouseButtonEvent(button: .left, x: Float(frame.midX), y: Float(frame.midY), clicks: 1)
            rig.dispatcher.dispatch(.mouseButtonDown(event)); settle()
            rig.dispatcher.dispatch(.mouseButtonUp(event)); settle()
        }
        settle()
        click(try named("json-expand"))
        for size in [window, compactInitially ? largeWindow : compactWindow] {
            window = size; settle()
            let dialog = try named("json-expanded-editor")
            let frame = dialog.absoluteFrame
            let expectedSize = CGSize(width: min(760, size.width - 32), height: min(560, size.height - 32))
            #expect(frame.width == expectedSize.width)
            #expect(frame.height == expectedSize.height)
            #expect(abs(frame.midX - size.width / 2) <= 1)
            #expect(abs(frame.midY - size.height / 2) <= 1)
            let editor = try #require(all(dialog).first { $0.attachments[TextField.surfaceMarkerKey] != nil })
            #expect(editor.absoluteFrame.height > frame.height / 2)
            #expect(frame.contains(editor.absoluteFrame))
            let apply = try named("json-apply")
            #expect(frame.contains(apply.absoluteFrame))
            #expect(editor.absoluteFrame.maxY <= apply.absoluteFrame.minY)
        }
        rig.dispatcher.dispatch(.keyDown(key(Scancode.a, modifiers: .lgui)))
        rig.dispatcher.dispatch(.textInput("{\"value\":42}")); settle()
        click(try named("json-apply"))
        #expect(store.text.stringValue == "{\"value\":42}")
        #expect(rig.focus.modalRoot == nil)
    } }

    private struct ModalHarness: View {
        @State var shown = false
        @State var text: TextBuffer = ""
        let store = Store()
        var body: some View {
            LayerRoot {
                Column {
                    TextField(text: $text).debugName("background-input")
                    ShortcutHost { _ in store.actions += 1; return true }
                    Modal(isPresented: $shown) {
                        Column {
                            TextField(text: $text).debugName("modal-input")
                            Button("Done") { shown = false }
                        }
                    }
                }
            }
        }
    }
    @Test("modal traps Tab and blocks app shortcuts, then restores focus on Escape")
    func modalFocus() throws { try withRig { rig in
        let graph = rig.graph
        let harness = ModalHarness()
        graph.install(root: harness); graph.computeLayout(width: 640, height: 480)
        let background = try field(rig.tree)
        rig.focus.focus(background)
        harness.shown = true
        for _ in 0..<3 { graph.recomposer.commitAll(); graph.computeLayout(width: 640, height: 480) }
        let modalRoot = try #require(rig.focus.modalRoot)
        #expect(rig.focus.focused !== background)
        for _ in 0..<6 {
            rig.dispatcher.dispatch(.keyDown(key(Scancode.tab)))
            let focused = try #require(rig.focus.focused)
            #expect(rig.focus.contains(focused, in: modalRoot))
        }
        rig.focus.focus(background)
        #expect(rig.focus.focused !== background)
        rig.dispatcher.dispatch(.keyDown(key(Scancode.s, modifiers: .lgui)))
        #expect(harness.store.actions == 0)
        rig.dispatcher.dispatch(.keyDown(key(Scancode.escape)))
        graph.recomposer.commitAll()
        AnimatorScheduler.current.tick(deltaTime: 1)
        for _ in 0..<3 { graph.recomposer.commitAll(); graph.computeLayout(width: 640, height: 480) }
        #expect(!harness.shown)
        #expect(rig.focus.focused === background)
        #expect(PortalStoreHolder.current.entries.isEmpty)
        rig.dispatcher.dispatch(.keyDown(key(Scancode.s, modifiers: .lgui)))
        #expect(harness.store.actions == 1)
    } }

    @Test("context menu fits a small window, closes on outside click and cleans up on unmount")
    func contextMenuBounds() throws { try withRig { rig in
        let graph = rig.graph
        let store = Store()
        store.text = TextBuffer((0..<20).map { "Line \($0)" }.joined(separator: "\n"))
        graph.install(root: LayerRoot {
            Column(spacing: 0) {
                TextField(text: Binding(get: { store.text }, set: { store.text = $0 })) { input in
                    input.layout.axis = .vertical
                    input.layout.maxVisibleLines = 1
                }
                    .frame(height: 20)
                Text("Row").frame(width: 230, height: 130).debugName("context-test-target")
                    .contextMenu(onOpen: { store.actions += 1 }, entries: {
                        (0..<12).map { .item(MenuItem(id: $0, title: "Action \($0)", action: {})) }
                    })
            }
        })
        graph.computeLayout(width: 240, height: 160)
        let backgroundInput = try field(rig.tree)
        rig.focus.focus(backgroundInput)
        let dispatcher = rig.dispatcher
        dispatcher.dispatch(.mouseButtonDown(MouseButtonEvent(button: .right, x: 225, y: 125, clicks: 1)))
        for _ in 0..<3 { graph.recomposer.commitAll(); graph.computeLayout(width: 240, height: 160) }
        #expect(store.actions == 1)
        let slot = try #require(all(rig.tree.root).first { $0.attachments[LayoutDebugAttachmentKey.layoutRole] as? String == "portal-entry" })
        #expect(slot.absoluteFrame.minX >= 0)
        #expect(slot.absoluteFrame.maxX <= 240)
        #expect(slot.absoluteFrame.minY >= 0)
        #expect(slot.absoluteFrame.maxY <= 160)
        let scroll = try #require(all(slot).last { rig.registry.handlers(for: $0).wheel != nil })
        let backgroundOffset = backgroundInput.contentOffset.y
        dispatcher.dispatch(.mouseWheel(MouseWheelEvent(x: 0, y: -1,
                                                        mouseX: Float(slot.absoluteFrame.midX),
                                                        mouseY: Float(slot.absoluteFrame.midY))))
        #expect(scroll.contentOffset.y > 0)
        dispatcher.dispatch(.mouseWheel(MouseWheelEvent(x: 0, y: 1,
                                                        mouseX: Float(slot.absoluteFrame.midX),
                                                        mouseY: Float(slot.absoluteFrame.midY))))
        #expect(scroll.contentOffset.y == 0)
        #expect(backgroundInput.contentOffset.y == backgroundOffset)
        for _ in 0..<4 { graph.recomposer.commitAll(); graph.computeLayout(width: 190, height: 120) }
        #expect(slot.absoluteFrame.maxX <= 190)
        #expect(slot.absoluteFrame.maxY <= 120)
        dispatcher.dispatch(.mouseButtonDown(MouseButtonEvent(button: .left, x: 0, y: 0, clicks: 1)))
        graph.recomposer.commitAll()
        #expect(PortalStoreHolder.current.entries.isEmpty)
        dispatcher.dispatch(.mouseButtonDown(MouseButtonEvent(button: .right, x: 100, y: 80, clicks: 1)))
        graph.recomposer.commitAll()
        #expect(!PortalStoreHolder.current.entries.isEmpty)
        let presenter = try #require(all(rig.tree.root).first { $0.firstResource(PortalResource.self) != nil })
        presenter.removeFromParent()
        graph.recomposer.commitAll()
        #expect(PortalStoreHolder.current.entries.isEmpty)
    } }

    @Test("modal wheel events cannot fall back to background scroll handlers")
    func modalWheelIsolation() { withRig { rig in
        let root = Node(), background = Node(), modal = Node()
        root.addChild(background); root.addChild(modal)
        rig.tree.root = root
        let store = Store()
        rig.registry.setWheel(background, route: .scroll) { _, _ in store.actions += 1; return .handled }
        modal.isFocusable = true
        rig.focus.beginModal(modal)
        rig.focus.focus(modal)
        rig.dispatcher.dispatch(.mouseWheel(MouseWheelEvent(x: 0, y: -1)))
        #expect(store.actions == 0)
        rig.focus.endModal(modal)
        rig.dispatcher.dispatch(.mouseWheel(MouseWheelEvent(x: 0, y: -1)))
        #expect(store.actions == 1)
    } }

    @Test("closing a modal cannot restore focus into a detached subtree")
    func detachedFocusRestoration() { withRig { rig in
        let root = Node(), container = Node(), previous = Node(), modal = Node()
        root.addChild(container); container.addChild(previous); root.addChild(modal)
        previous.isFocusable = true; modal.isFocusable = true
        rig.focus.focus(previous)
        rig.focus.beginModal(modal)
        root.removeChild(container)
        rig.focus.endModal(modal)
        #expect(rig.focus.focused == nil)
    } }

    struct Item { let id: Int }
    @Test("virtual list mounts a bounded row set and keeps the full scroll extent")
    func virtualRows() throws { try withRig { rig in
        let graph = rig.graph
        graph.install(root: VirtualList((0..<10000).map(Item.init), id: \.id, rowHeight: 30) { item in
            Text("Row \(item.id)").debugName("virtual-row-\(item.id)")
        }.frame(height: 300))
        for _ in 0..<3 { graph.recomposer.commitAll(); graph.computeLayout(width: 240, height: 300) }
        func rows() -> [Node] {
            all(rig.tree.root).filter { ($0.attachments[LayoutDebugAttachmentKey.debugName] as? String)?.hasPrefix("virtual-row-") == true }
        }
        #expect(rows().count < 25)
        let scroll = try #require(all(rig.tree.root).first { rig.registry.handlers(for: $0).wheel != nil })
        _ = rig.registry.handlers(for: scroll).wheel?(MouseWheelEvent(x: 0, y: -200), .target)
        for _ in 0..<3 { graph.recomposer.commitAll(); graph.computeLayout(width: 240, height: 300) }
        #expect(scroll.contentOffset.y == 6000)
        #expect(rows().count < 25)
        #expect(rows().contains { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "virtual-row-200" })
        #expect(!rows().contains { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "virtual-row-0" })
    } }

    private struct TransitionHarness: View {
        @State var shown = true
        var body: some View {
            TransitionView(isVisible: shown, transition: .opacity.combined(with: .offset(y: 10)),
                           removal: .opacity.combined(with: .offset(x: 20))) {
                Button("Action") {}.debugName("transition-content")
            }
        }
    }
    @Test("combined transition retains exit content, suppresses input and survives reversal")
    func transitionLifecycle() throws { try withRig { rig in
        try AnimatorScheduler.$current.withValue(AnimatorScheduler()) {
            let harness = TransitionHarness(); let graph = rig.graph
            graph.install(root: harness); graph.computeLayout(width: 200, height: 100)
            AnimatorScheduler.current.tick(deltaTime: 1)
            harness.shown = false; graph.recomposer.commitAll()
            #expect(all(rig.tree.root).contains { !$0.isInteractionEnabled })
            #expect(all(rig.tree.root).contains { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "transition-content" })
            AnimatorScheduler.current.tick(deltaTime: 0.05)
            let transitioning = try #require(all(rig.tree.root).first { !$0.isInteractionEnabled })
            let interruptedOffset = transitioning.contentOffset
            let interruptedOpacity = transitioning.opacity
            harness.shown = true; graph.recomposer.commitAll()
            #expect(transitioning.contentOffset == interruptedOffset)
            #expect(transitioning.opacity == interruptedOpacity)
            AnimatorScheduler.current.tick(deltaTime: 1); graph.recomposer.commitAll()
            #expect(all(rig.tree.root).allSatisfy { $0.isInteractionEnabled })
            harness.shown = false; graph.recomposer.commitAll()
            AnimatorScheduler.current.tick(deltaTime: 1); graph.recomposer.commitAll()
            #expect(!all(rig.tree.root).contains { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "transition-content" })
        }
    } }
}
