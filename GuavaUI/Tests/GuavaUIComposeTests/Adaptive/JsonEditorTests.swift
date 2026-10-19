import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Adaptive JSON editor", .serialized)
@MainActor
struct JsonEditorTests: GuavaUIComposeSerializedSuite {
    private final class Harness: View {
        @State var width: Float = 390
        @State var scale: Float = 1
        @State var input: UIEnvironment.Input = [.touch]
        @State var dark = false
        @State var rtl = false
        @State var text: TextBuffer = "{\"value\":1}"
        @State var labels = JsonFieldLabels()
        var commits = 0

        var body: some View {
            var surface = UIEnvironment()
            surface.viewport.width = width; surface.viewport.height = 820; surface.input = input
            return LayerRoot {
                JsonField(text: $text, labels: labels, onCommit: { _ in self.commits += 1 })
                    .frame(maxWidth: 520)
            }
            .frame(width: width, height: 820).surfaceEnvironment(surface).textScaler(.init(scale))
            .appearance(dark ? .dark : .light).layoutDirection(rtl ? .rtl : .ltr).reducedMotion()
            .safeAreaInsets(.init(top: 24, leading: 0, bottom: 34, trailing: 0))
        }
    }

    private func nodes(_ node: Node?) -> [Node] {
        guard let node else { return [] }
        return [node] + node.children.flatMap { nodes($0) }
    }
    private func named(_ name: String, _ graph: ViewGraph) throws -> Node {
        try #require(nodes(graph.tree.root).first { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == name })
    }
    private func settle(_ graph: ViewGraph, _ h: Harness) {
        for _ in 0..<8 { graph.recomposer.commitAll(); graph.computeLayout(width: h.width, height: 820) }
    }
    private func scene(_ work: (Harness, ViewGraph, PlatformInputContext, EventDispatcher, PortalStore) throws -> Void) rethrows {
        try GlobalTestLock.locked {
            let old = TextEnvironmentHolder.current; TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = old }
            let context = PlatformInputContext(), portals = PortalStore(), scheduler = AnimatorScheduler()
            context.addScopedAmbient(PortalStoreAmbient(portals))
            try context.withCurrent { try AnimatorScheduler.$current.withValue(scheduler) {
                let h = Harness(), graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                let dispatcher = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                                                capture: context.pointerCapture, focusChain: context.focusChain)
                graph.install(root: h); settle(graph, h)
                defer { graph.install(root: EmptyView()); scheduler.reset() }
                try work(h, graph, context, dispatcher, portals)
            } }
        }
    }
    private func click(_ node: Node, _ input: EventDispatcher) {
        let f = node.absoluteFrame
        let e = MouseButtonEvent(button: .left, x: Float(f.midX), y: Float(f.midY), clicks: 1)
        input.dispatch(.mouseButtonDown(e)); input.dispatch(.mouseButtonUp(e))
    }
    private func key(_ code: UInt32, _ input: EventDispatcher, primary: Bool = false) {
        input.dispatch(.keyDown(.init(scancode: code, keycode: 0, modifiers: primary ? .lgui : [], isRepeat: false)))
    }

    @Test("Expanded editor fits widths, safe areas, long labels, themes, 200% text and all input modes")
    func matrix() throws {
        try scene { h, graph, _, input, portals in
            h.labels.expand = "Edit project configuration and international collaboration permissions"
            h.labels.apply = "Apply configuration changes"
            h.labels.cancel = "Discard editing changes"
            settle(graph, h)
            let expand = try named("json-expand", graph)
            #expect(expand.accessibility?.label == h.labels.expand)
            click(expand, input); settle(graph, h)
            let editor = try named("json-expanded-editor", graph)
            for width: Float in [390, 720, 1280] { for scale: Float in [1, 2] {
                for modality: UIEnvironment.Input in [[.touch], [.touch, .pointer, .keyboard], [.pointer, .keyboard]] {
                    for dark in [false, true] {
                        h.width = width; h.scale = scale; h.input = modality; h.dark = dark; h.rtl = dark
                        settle(graph, h)
                        let frame = try named("json-expanded-editor", graph).absoluteFrame
                        #expect(try named("json-expanded-editor", graph) === editor)
                        #expect(portals.entries.count == 1 && !graph.recomposer.hasPending)
                        #expect(frame.minX >= 0 && frame.maxX <= CGFloat(width))
                        #expect(frame.minY >= 24 && frame.maxY <= 786)
                        if width == 390 { #expect(frame.width == 390 && frame.minY == 24 && frame.maxY == 786) }
                        let field = try #require(nodes(editor).first { $0.attachments[TextField.surfaceMarkerKey] != nil })
                        let apply = try named("json-apply", graph), cancel = try named("json-cancel", graph)
                        #expect(frame.contains(field.absoluteFrame) && field.frame.height > 150)
                        for button in [apply, cancel] {
                            #expect(frame.contains(button.absoluteFrame))
                            #expect(button.absoluteFrame.minY >= field.absoluteFrame.maxY)
                            if modality.contains(.touch) { #expect(button.frame.height >= 44 && button.frame.width >= 44) }
                        }
                        #expect(apply.accessibility?.label == h.labels.apply)
                        #expect(cancel.accessibility?.label == h.labels.cancel)
                        #expect(editor.accessibility?.role == .dialog && editor.accessibility?.label == h.labels.expand)
                        let title = try #require(nodes(editor).first { $0.accessibility?.role == .heading })
                        #expect(title.accessibility?.label == h.labels.expand)
                        #expect(frame.contains(title.absoluteFrame))
                    }
                }
            } }
        }
    }

    @Test("Invalid drafts survive resize, Apply commits once, Escape cancels and focus returns")
    func transactions() throws {
        try scene { h, graph, context, input, portals in
            let expand = try named("json-expand", graph)
            click(expand, input); settle(graph, h)
            let focused = try #require(context.focusChain.focused)
            key(Scancode.a, input, primary: true); input.dispatch(.textInput("{ invalid")); settle(graph, h)
            #expect(try named("json-apply", graph).accessibility?.state.isEnabled == false)
            key(Scancode.return, input, primary: true); settle(graph, h)
            #expect(h.text.stringValue == "{\"value\":1}" && h.commits == 0 && portals.entries.count == 1)
            for width: Float in [720, 1280, 390] { h.width = width; settle(graph, h) }
            #expect(context.focusChain.focused === focused)
            key(Scancode.a, input, primary: true); input.dispatch(.textInput("{\"value\":42}")); settle(graph, h)
            click(try named("json-apply", graph), input); settle(graph, h)
            #expect(h.text.stringValue == "{\"value\":42}" && h.commits == 1 && portals.entries.isEmpty)
            #expect(context.focusChain.focused === expand)
            click(expand, input); settle(graph, h)
            key(Scancode.a, input, primary: true); input.dispatch(.textInput("{\"value\":99}")); settle(graph, h)
            key(Scancode.escape, input); settle(graph, h)
            #expect(h.text.stringValue == "{\"value\":42}" && h.commits == 1 && portals.entries.isEmpty)
            #expect(context.focusChain.focused === expand)
        }
    }
}
