import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Adaptive editor height", .serialized)
@MainActor
struct EditorHeightTests: GuavaUIComposeSerializedSuite {
    private enum Kind: CaseIterable { case editor, area, json }
    private final class Harness: View {
        let kind: Kind
        @State var width: Float = 390
        @State var scale: Float = 1
        @State var input: UIEnvironment.Input = [.touch]
        @State var dark = false
        @State var enabled = true
        @State var shown = true
        @State var minimum: Float = 100
        @State var maximum: Float = 300
        @State var text: TextBuffer = "{\"volume\":1}"
        @State var viewportHeight: Float = 820
        let label = "调整编辑区域高度 — Editor height"
        init(_ kind: Kind) { self.kind = kind }
        var body: some View {
            var surface = UIEnvironment(); surface.viewport.width = width; surface.viewport.height = 820; surface.input = input
            return ScrollView(.vertical) {
            Box(direction: .column, alignItems: .stretch, spacing: 12) {
                if shown {
                    if kind == .editor {
                        ResizableEditor(initialHeight: 160, minHeight: minimum, maxHeight: maximum,
                                        resizeLabel: label, isResizable: enabled) {
                            TextField(text: $text) { $0.layout.axis = .vertical }
                        }
                    } else if kind == .area {
                        ResizableTextArea(text: $text, minHeight: minimum, maxHeight: maximum,
                                          disabled: !enabled, resizeLabel: label)
                    } else {
                        JsonField(text: $text, minHeight: minimum, isEnabled: enabled, labels: .init(resize: label))
                    }
                }
                Button("After editor") {}.accessibilityLabel("After editor")
            }
            }.frame(width: width - 24, height: viewportHeight).surfaceEnvironment(surface).textScaler(.init(scale))
                .appearance(dark ? .dark : .light).layoutDirection(dark ? .rtl : .ltr)
        }
    }
    private func nodes(_ node: Node?) -> [Node] {
        guard let node else { return [] }; return [node] + node.children.flatMap { nodes($0) }
    }
    private func handle(_ graph: ViewGraph) throws -> Node {
        try #require(nodes(graph.tree.root).first { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "editor-height-handle" })
    }
    private func field(_ graph: ViewGraph) throws -> Node {
        try #require(nodes(graph.tree.root).first { $0.attachments[TextField.surfaceMarkerKey] != nil })
    }
    private func settle(_ graph: ViewGraph, _ h: Harness) {
        for _ in 0..<6 { graph.recomposer.commitAll(); graph.computeLayout(width: h.width, height: 820) }
    }
    private func scene(_ kind: Kind, _ work: (Harness, ViewGraph, PlatformInputContext, EventDispatcher) throws -> Void) rethrows {
        try GlobalTestLock.locked {
            let old = TextEnvironmentHolder.current; TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = old }
            let context = PlatformInputContext()
            try context.withCurrent {
                let h = Harness(kind), graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                graph.install(root: h); settle(graph, h)
                defer { graph.install(root: EmptyView()) }
                let input = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                                            capture: context.pointerCapture, focusChain: context.focusChain)
                try work(h, graph, context, input)
            }
        }
    }
    private func key(_ code: UInt32, _ input: EventDispatcher, shift: Bool = false) {
        input.dispatch(.keyDown(.init(scancode: code, keycode: 0, modifiers: shift ? .shift : [], isRepeat: false)))
    }
    private func down(_ handle: Node, _ input: EventDispatcher) -> CGPoint {
        let point = CGPoint(x: handle.absoluteFrame.midX, y: handle.absoluteFrame.midY)
        input.dispatch(.mouseButtonDown(.init(button: .left, x: Float(point.x), y: Float(point.y), clicks: 1)))
        return point
    }
    private func move(_ point: CGPoint, by delta: Float, _ input: EventDispatcher) {
        input.dispatch(.mouseMotion(.init(x: Float(point.x), y: Float(point.y) + delta, deltaX: 0, deltaY: delta)))
    }

    @Test("Both containers and JSON retain nodes, drafts, names and 44pt touch lanes across the surface matrix")
    func matrix() throws {
        for kind in Kind.allCases { try scene(kind) { h, graph, _, _ in
            let original = try handle(graph), originalField = try field(graph)
            for width: Float in [390, 720, 1280] { for scale: Float in [1, 2] {
                for modality: UIEnvironment.Input in [[.touch], [.touch, .pointer, .keyboard], [.pointer, .keyboard]] {
                    for dark in [false, true] {
                        h.width = width; h.scale = scale; h.input = modality; h.dark = dark; settle(graph, h)
                        let grip = try handle(graph), text = try field(graph)
                        #expect(grip === original && text === originalField)
                        #expect(grip.frame.height == CGFloat(modality.contains(.touch) ? 44 : 28))
                        #expect(grip.absoluteFrame.minY >= text.absoluteFrame.maxY)
                        #expect(grip.absoluteFrame.minX >= 0 && grip.absoluteFrame.maxX <= CGFloat(width))
                        #expect(grip.accessibility?.role == .slider && grip.accessibility?.label == h.label)
                        #expect(Float(grip.accessibility?.value ?? "") == Float(text.frame.height))
                        #expect(grip.isFocusable && grip.isHitTestable && text.frame.height >= 44)
                        #expect(h.text.stringValue == "{\"volume\":1}" && !graph.recomposer.hasPending)
                    }
                }
            } }
        } }
    }

    @Test("Drag updates the viewport, Escape rolls back, keyboard and assistive actions share limits")
    func interactions() throws {
        for kind in Kind.allCases { try scene(kind) { h, graph, context, input in
            let grip = try handle(graph), text = try field(graph), before = text.frame.height
            let point = down(grip, input); move(point, by: 60, input); settle(graph, h)
            #expect(text.frame.height == before + 60 && context.pointerCapture.target === grip)
            key(Scancode.escape, input); settle(graph, h)
            #expect(text.frame.height == before && context.pointerCapture.target == nil)
            let click = down(grip, input)
            input.dispatch(.mouseButtonUp(.init(button: .left, x: Float(click.x), y: Float(click.y), clicks: 1)))
            #expect(!context.focusChain.isFocusVisible)
            key(Scancode.arrowDown, input); settle(graph, h)
            #expect(text.frame.height == before + 16 && context.focusChain.isFocusVisible)
            key(Scancode.arrowUp, input, shift: true); settle(graph, h)
            let shrunk = text.frame.height
            grip.accessibilityActions.increment?(); settle(graph, h)
            #expect(text.frame.height == shrunk + 16)
            grip.accessibilityActions.decrement?(); settle(graph, h)
            #expect(text.frame.height == shrunk)
            grip.accessibilityActions.setValue?("200"); settle(graph, h)
            #expect(text.frame.height == 200)
            for invalid in ["nan", "inf", "invalid"] { grip.accessibilityActions.setValue?(invalid) }
            settle(graph, h); #expect(text.frame.height == 200)
            key(Scancode.home, input); settle(graph, h)
            #expect(text.frame.height == (kind == .editor ? 56 : 100))
            key(Scancode.end, input); settle(graph, h)
            #expect(text.frame.height == (kind == .editor ? 256 : kind == .area ? 300 : 360))
            key(Scancode.pageUp, input); settle(graph, h)
            let smaller = text.frame.height
            key(Scancode.pageDown, input); settle(graph, h)
            #expect(text.frame.height == smaller + 64)
            key(Scancode.tab, input); settle(graph, h)
            #expect(context.focusChain.focused?.accessibility?.label == "After editor")
        } }
    }

    @Test("Disable, density changes and unmount release capture and reject stale assistive actions")
    func lifecycle() throws {
        for kind in Kind.allCases { try scene(kind) { h, graph, context, input in
            let grip = try handle(graph), oldAction = grip.accessibilityActions.increment
            let point = down(grip, input); move(point, by: 20, input); settle(graph, h)
            h.enabled = false; settle(graph, h)
            let disabledHeight = try field(graph).frame.height
            #expect(context.pointerCapture.target == nil && context.focusChain.focused !== grip)
            #expect(!grip.isFocusable && !grip.isHitTestable && grip.accessibility?.state.isEnabled == false)
            oldAction?(); settle(graph, h)
            #expect(try field(graph).frame.height == disabledHeight)
            h.enabled = true; settle(graph, h)
            _ = down(grip, input)
            h.input = [.pointer, .keyboard]; settle(graph, h)
            #expect(context.pointerCapture.target == nil && grip.frame.height == 28)
            _ = down(grip, input)
            h.shown = false; settle(graph, h)
            #expect(context.pointerCapture.target == nil && context.focusChain.focused == nil)
            oldAction?(); #expect(!graph.recomposer.hasPending)
        } }
    }

    @Test("Undersized or non-finite authored heights still leave an editable viewport and a complete handle")
    func minimumAndInvalidBounds() throws {
        for kind in [Kind.editor, .area] { try scene(kind) { h, graph, _, input in
            h.minimum = 1; h.maximum = 2; settle(graph, h)
            let grip = try handle(graph)
            #expect(try field(graph).frame.height == 44 && grip.frame.height == 44)
            _ = down(grip, input)
            h.minimum = .nan; h.maximum = .infinity; settle(graph, h)
            let text = try field(graph)
            #expect(grip.absoluteFrame.height.isFinite && text.frame.height.isFinite)
        } }
    }

    @Test("Keyboard growth reveals the moved handle after layout without trapping ordinary wheel scrolling")
    func revealsAfterResize() throws {
        for kind in Kind.allCases { try scene(kind) { h, graph, context, input in
            h.viewportHeight = 200; settle(graph, h)
            let grip = try handle(graph)
            context.focusChain.focus(grip, visible: true)
            key(Scancode.end, input); settle(graph, h)
            #expect(grip.absoluteFrame.maxY <= 200 && grip.absoluteFrame.minY >= 0)
            let scroll = try #require(nodes(graph.tree.root).first { $0.accessibility?.role == .scrollArea })
            let before = scroll.contentOffset.y
            input.dispatch(.mouseWheel(.init(x: 0, y: 100, mouseX: 20, mouseY: 20,
                                             input: .init(unit: .points))))
            settle(graph, h)
            #expect(scroll.contentOffset.y < before)
        } }
    }
}
