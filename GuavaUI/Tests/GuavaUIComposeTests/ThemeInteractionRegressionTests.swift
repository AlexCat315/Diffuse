import Foundation
import Testing
import EngineKernel
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Theme and input regressions", .serialized)
struct ThemeInteractionRegressionTests: GuavaUIComposeSerializedSuite {
    private func find(_ node: Node?, matching predicate: (Node) -> Bool) -> Node? {
        guard let node else { return nil }
        if predicate(node) { return node }
        for child in node.children {
            if let match = find(child, matching: predicate) { return match }
        }
        return nil
    }

    @Test("selected disabled icons keep their accent surface and stay centered",
          arguments: [false, true])
    func selectedDisabledIcon(dark: Bool) throws { try GlobalTestLock.locked {
        let theme = dark ? Theme.defaultDark : Theme.defaultLight
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: Button(icon: .texture(7), size: 12, isEnabled: false, isSelected: true) {}
            .buttonStyle(ToggleButtonStyle(minWidth: 28, height: 24))
            .frame(width: 28, height: 24).theme(theme))
        graph.computeLayout(width: 100, height: 60)
        let chrome = try #require(find(tree.root) { $0.attachments[BuiltinButtonChrome.stateKey] != nil })
        let icon = try #require(find(chrome) { $0.draw != nil && $0.frame.width == 12 })
        #expect(chrome.backgroundColor == theme.colors.accent)
        #expect(abs(icon.absoluteFrame.midX - chrome.absoluteFrame.midX) < 0.5)
        #expect(abs(icon.absoluteFrame.midY - chrome.absoluteFrame.midY) < 0.5)
        #expect(icon.foregroundColor == theme.colors.onAccent)
        #expect(chrome.opacity == 0.75)
    } }

    @Test("pointer focus clears the ring while keyboard focus retains it")
    func focusModality() throws { try GlobalTestLock.locked {
        let context = PlatformInputContext()
        try context.withCurrent {
            let scheduler = AnimatorScheduler()
            try AnimatorScheduler.$current.withValue(scheduler) {
                let tree = NodeTree()
                let graph = ViewGraph(tree: tree, recomposer: Recomposer())
                graph.install(root: Button(icon: .texture(7), size: 12) {}
                    .buttonStyle(.toggle).frame(width: 28, height: 24))
                graph.computeLayout(width: 100, height: 60)
                let host = try #require(find(tree.root) { $0.attachments[ButtonHost.markerKey] != nil })
                let chrome = try #require(find(host) { $0.attachments[BuiltinButtonChrome.stateKey] != nil })
                let dispatcher = EventDispatcher(tree: tree, interactions: context.interactions,
                    capture: context.pointerCapture, focusChain: context.focusChain)
                let event = MouseButtonEvent(button: .left, x: Float(host.absoluteFrame.midX),
                                             y: Float(host.absoluteFrame.midY), clicks: 1)
                dispatcher.dispatch(.mouseButtonDown(event))
                dispatcher.dispatch(.mouseButtonUp(event))
                scheduler.tick(deltaTime: 1)
                #expect(context.focusChain.focused === host)
                #expect(chrome.borderWidth == 0)
                context.focusChain.focus(host, visible: true)
                scheduler.tick(deltaTime: 1)
                #expect(chrome.borderWidth == 2)
            }
        }
    } }

    @Test("composite labels inherit the button foreground, including disabled icons", arguments: [false, true])
    func compositeForeground(enabled: Bool) throws { try GlobalTestLock.locked {
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        let theme = Theme.defaultLight
        graph.install(root: Button(isEnabled: enabled, action: {}) {
            Row { Icon(UICommonIcons.close, size: 12); Text("Build") }
        }.buttonStyle(.primary).theme(theme))
        graph.computeLayout(width: 180, height: 60)
        let icon = try #require(find(tree.root) { $0.draw != nil && $0.frame.width == 12 })
        let expected = enabled ? theme.colors.onAccent : theme.colors.onSurfaceMuted
        #expect(icon.inheritedForegroundColor == expected)
        let draw = DrawList()
        icon.draw?(draw, .zero)
        let vertex = try #require(draw.vertices.first)
        #expect(abs(Int(vertex.color & 255) - Int((expected.r * 255).rounded())) <= 1)
        #expect(abs(Int((vertex.color >> 16) & 255) - Int((expected.b * 255).rounded())) <= 1)
    } }

    @Test("font and line height reach the styled multiline field surface")
    func textStyleInheritance() throws { try GlobalTestLock.locked {
        let environment = TestTextEnvironmentFactory.make()
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        let field = TextField(text: .constant("alpha\nbeta"), axis: .vertical)
        graph.install(root: Box { field }.font(Font.monospaced(size: 17)).lineHeight(25))
        graph.computeLayout(width: 240, height: 200)
        let surface = try #require(find(tree.root) { $0.attachments[TextField.surfaceMarkerKey] != nil })
        #expect(field.resolvedFont(node: surface, env: environment) == Font.monospaced(size: 17))
        #expect(field.resolvedLineHeight(node: surface, env: environment) == 25)
    } }

    private struct MenuHarness: View {
        @State var presented = true
        let onOutside: () -> Void
        var body: some View {
            LayerRoot {
                Column(alignment: .leading, spacing: 70) {
                    Popover(isPresented: $presented, width: 120) {
                        Text("Menu").frame(width: 80, height: 24)
                    } content: {
                        Text("Contents").frame(width: 120, height: 48)
                    }
                    Button("Outside", action: onOutside).frame(width: 100, height: 24)
                        .debugName("outside-action")
                }
            }
        }
    }

    @Test("outside click dismisses a popover and activates the underlying button; Escape also dismisses")
    func menuDismissal() throws { try GlobalTestLock.locked {
        let context = PlatformInputContext()
        let portals = PortalStore()
        context.addScopedAmbient(PortalStoreAmbient(portals))
        try context.withCurrent {
            var activations = 0
            let harness = MenuHarness(onOutside: { activations += 1 })
            let tree = NodeTree()
            let graph = ViewGraph(tree: tree, recomposer: Recomposer())
            graph.install(root: harness)
            graph.recomposer.commitAll()
            graph.computeLayout(width: 300, height: 240)
            let dispatcher = EventDispatcher(tree: tree, interactions: context.interactions,
                capture: context.pointerCapture, focusChain: context.focusChain)
            let outside = try #require(find(tree.root) {
                $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "outside-action"
            })
            let point = outside.absoluteFrame
            let event = MouseButtonEvent(button: .left, x: Float(point.midX), y: Float(point.midY), clicks: 1)
            dispatcher.dispatch(.mouseButtonDown(event))
            dispatcher.dispatch(.mouseButtonUp(event))
            graph.recomposer.commitAll()
            #expect(!harness.presented)
            #expect(portals.entries.isEmpty)
            #expect(activations == 1)
            harness.$presented.wrappedValue = true
            graph.recomposer.commitAll()
            dispatcher.dispatch(.keyDown(KeyEvent(scancode: Scancode.escape, keycode: 0,
                                                   modifiers: [], isRepeat: false)))
            graph.recomposer.commitAll()
            #expect(!harness.presented)
            #expect(portals.entries.isEmpty)
        }
    } }

    @Test("IME preview clamps a stale search caret after external clearing")
    func staleCompositionCaret() {
        let state = TextField.FieldState()
        state.cursorIndex = 20
        state.compositionText = "属性"
        let field = TextField(text: Binding(get: { "" }, set: { _ in }))
        let result = TextField.LayoutEngine(textField: field)
            .makeRenderState(current: "", state: state, isFocused: true)
        #expect(result.displayText == "属性")
        #expect(result.cursorIndex == 2)
    }

    @Test("numeric step does not round authored values and arrow keys increment from the draft")
    func numberDraftAndStep() throws { try GlobalTestLock.locked {
        let context = PlatformInputContext()
        try context.withCurrent {
            var value: Float = 0.5
            let tree = NodeTree()
            let graph = ViewGraph(tree: tree, recomposer: Recomposer())
            graph.install(root: NumberField(value: Binding(get: { value }, set: { value = $0 }), step: 1))
            let field = try #require(find(tree.root) { $0.attachments[TextField.surfaceMarkerKey] != nil })
            context.focusChain.focus(field)
            graph.recomposer.commitAll()
            let handlers = context.interactions.handlers(for: field)
            _ = handlers.key?(KeyEvent(scancode: Scancode.a, keycode: 0, modifiers: [.lgui], isRepeat: false), .target)
            _ = handlers.text?("0.75", .target)
            _ = handlers.key?(KeyEvent(scancode: Scancode.return, keycode: 0, modifiers: [], isRepeat: false), .target)
            #expect(value == 0.75)
            _ = handlers.key?(KeyEvent(scancode: Scancode.arrowUp, keycode: 0, modifiers: [.shift], isRepeat: false), .target)
            #expect(value == 10.75)
            #expect(NumberField.format(-0.00001, decimals: 2) == "0")
        }
    } }

    @Test("Tab indents selected code lines; Shift-Tab reverses; Return carries block indentation")
    func codeIndentation() throws { try GlobalTestLock.locked {
        let context = PlatformInputContext()
        try context.withCurrent {
            var text = "甲\n乙"
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: TextField(text: Binding(get: { text }, set: { text = $0 }),
                                         axis: .vertical, indentationWidth: 2))
            let node = try #require(find(graph.tree.root) { $0.attachments[TextField.surfaceMarkerKey] != nil })
            context.focusChain.focus(node)
            graph.recomposer.commitAll()
            let handlers = context.interactions.handlers(for: node)
            _ = handlers.key?(KeyEvent(scancode: Scancode.a, keycode: 0, modifiers: [.lgui], isRepeat: false), .target)
            _ = handlers.key?(KeyEvent(scancode: 43, keycode: 0, modifiers: [], isRepeat: false), .target)
            #expect(text == "  甲\n  乙")
            _ = handlers.key?(KeyEvent(scancode: 43, keycode: 0, modifiers: [.shift], isRepeat: false), .target)
            #expect(text == "甲\n乙")
            _ = handlers.key?(KeyEvent(scancode: Scancode.a, keycode: 0, modifiers: [.lgui], isRepeat: false), .target)
            _ = handlers.text?("  if true {", .target)
            _ = handlers.key?(KeyEvent(scancode: Scancode.return, keycode: 0, modifiers: [], isRepeat: false), .target)
            #expect(text == "  if true {\n    ")
        }
    } }

    @Test("Tab and Shift-Tab traverse controls through the dispatcher")
    func keyboardTraversal() throws { try GlobalTestLock.locked {
        let context = PlatformInputContext()
        try context.withCurrent {
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: Row { Button("One") {}.debugName("one"); Button("Two") {}.debugName("two") })
            let one = try #require(find(graph.tree.root) { $0.isFocusable && $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "one" })
            let two = try #require(find(graph.tree.root) { $0.isFocusable && $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "two" })
            let dispatcher = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                capture: context.pointerCapture, focusChain: context.focusChain)
            context.focusChain.focus(one, visible: false)
            dispatcher.dispatch(.keyDown(KeyEvent(scancode: 43, keycode: 0, modifiers: [], isRepeat: false)))
            #expect(context.focusChain.focused === two)
            #expect(context.focusChain.isFocusVisible)
            dispatcher.dispatch(.keyDown(KeyEvent(scancode: 43, keycode: 0, modifiers: [.shift], isRepeat: false)))
            #expect(context.focusChain.focused === one)
        }
    } }

    @Test("clicking blank canvas blurs and commits a number draft")
    func outsideFieldCommit() throws { try GlobalTestLock.locked {
        let context = PlatformInputContext()
        try context.withCurrent {
            var value: Float = 1
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: NumberField(value: Binding(get: { value }, set: { value = $0 })).frame(width: 100, height: 32))
            graph.computeLayout(width: 200, height: 100)
            let node = try #require(find(graph.tree.root) { $0.attachments[TextField.surfaceMarkerKey] != nil })
            context.focusChain.focus(node)
            graph.recomposer.commitAll()
            let handlers = context.interactions.handlers(for: node)
            _ = handlers.key?(KeyEvent(scancode: Scancode.a, keycode: 0, modifiers: [.lgui], isRepeat: false), .target)
            _ = handlers.text?("0.75", .target)
            let dispatcher = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                capture: context.pointerCapture, focusChain: context.focusChain)
            dispatcher.dispatch(.mouseButtonDown(MouseButtonEvent(button: .left, x: 180, y: 80, clicks: 1)))
            #expect(context.focusChain.focused == nil)
            #expect(value == 0.75)
        }
    } }
}
