import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Markdown editing and preview", .serialized)
@MainActor
struct MarkdownEditorTests: GuavaUIComposeSerializedSuite {
    private final class Harness: View {
        @State var text: TextBuffer = "# Original\n\nA draft."
        @State var width: Float = 390
        @State var lastOpened = ""
        let surface: UIEnvironment
        let scale: Float
        let dark: Bool
        let rtl: Bool
        init(input: UIEnvironment.Input, scale: Float, dark: Bool, rtl: Bool) {
            var surface = UIEnvironment()
            surface.viewport.width = 1280 // Container width, rather than window width, must decide.
            surface.input = input
            self.surface = surface; self.scale = scale; self.dark = dark; self.rtl = rtl
        }
        var body: some View {
            MarkdownEditor(text: $text, sourceTitle: "编辑源码", previewTitle: "文档预览") { self.lastOpened = $0 }
                .frame(width: width, height: 420).surfaceEnvironment(surface)
                .textScaler(.init(scale)).appearance(dark ? .dark : .light)
                .layoutDirection(rtl ? .rtl : .ltr).reducedMotion()
        }
    }

    private nonisolated func nodes(_ node: Node) -> [Node] { [node] + node.children.flatMap(nodes) }

    @Test("Live edits, links and undo survive compact tabs and container resizing")
    func matrix() throws {
        try GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            for input: UIEnvironment.Input in [[.touch], [.touch, .pointer, .keyboard], [.pointer, .keyboard]] {
                for scale: Float in [1, 2] {
                    for dark in [false, true] {
                        let context = PlatformInputContext()
                        try context.withCurrent {
                            let harness = Harness(input: input, scale: scale, dark: dark, rtl: dark)
                            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                            graph.install(root: harness)
                            defer { graph.install(root: EmptyView()) }
                            let dispatcher = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                                                            capture: context.pointerCapture, focusChain: context.focusChain)
                            func settle() {
                                for _ in 0..<8 {
                                    graph.recomposer.commitAll()
                                    graph.computeLayout(width: harness.width, height: 420)
                                }
                            }
                            func all() -> [Node] { nodes(graph.tree.root!) }
                            func key(_ scan: UInt32, _ modifiers: KeyModifiers = []) {
                                dispatcher.dispatch(.keyDown(.init(scancode: scan, keycode: 0, modifiers: modifiers, isRepeat: false)))
                            }
                            func clickTab(_ label: String) throws {
                                let tab = try #require(all().first { $0.acceptsSubtreeInput && $0.accessibility?.role == .tab && $0.accessibility?.label == label })
                                if input.contains(.touch) { #expect(tab.frame.height >= 44) }
                                let f = tab.absoluteFrame
                                let event = MouseButtonEvent(button: .left, x: Float(f.midX), y: Float(f.midY), clicks: 1)
                                dispatcher.dispatch(.mouseButtonDown(event)); dispatcher.dispatch(.mouseButtonUp(event))
                                settle()
                            }
                            settle()
                            let field = try #require(all().first { $0.accessibility?.role == .textField })
                            let original = harness.text
                            context.focusChain.focus(field)
                            key(Scancode.a, .lgui)
                            dispatcher.dispatch(.textInput("# Changed 中文\n\n**Bold** and [guide](guide://markdown)."))
                            settle()
                            #expect(harness.text.stringValue.hasPrefix("# Changed 中文"))
                            try clickTab("文档预览")
                            #expect(!field.acceptsSubtreeInput)
                            #expect(all().contains { $0.acceptsSubtreeInput && $0.accessibility?.role == .heading && $0.accessibility?.label == "Changed 中文" })
                            let link = try #require(all().first { $0.acceptsSubtreeInput && $0.accessibility?.role == .link })
                            context.focusChain.focus(link); key(Scancode.return)
                            #expect(harness.lastOpened == "guide://markdown")
                            try clickTab("编辑源码")
                            #expect(all().first { $0.accessibility?.role == .textField } === field)
                            context.focusChain.focus(field); key(Scancode.z, .lgui); settle()
                            #expect(harness.text.hasSameContents(as: original))
                            for width: Float in [240, 720, 1280, 390] {
                                harness.width = width; settle()
                                #expect(all().first { $0.accessibility?.role == .textField } === field)
                                #expect(field.acceptsSubtreeInput)
                                #expect(field.frame.width > 100)
                                #expect(field.absoluteFrame.minX >= -0.5 && field.absoluteFrame.maxX <= Double(width) + 0.5,
                                        "width=\(width), scale=\(scale), dark/RTL=\(dark), input=\(input), field=\(field.absoluteFrame)")
                                let heading = try #require(all().first { $0.accessibility?.role == .heading && $0.accessibility?.label == "Original" })
                                #expect(heading.acceptsSubtreeInput == (width >= 600))
                                if width >= 600 {
                                    #expect(heading.absoluteFrame.minX >= -0.5 && heading.absoluteFrame.maxX <= Double(width) + 0.5)
                                }
                            }
                            // Programmatic file replacement and an empty draft also update the preview.
                            harness.text = "# Replacement"; settle()
                            try clickTab("文档预览")
                            #expect(all().contains { $0.acceptsSubtreeInput && $0.accessibility?.label == "Replacement" })
                            harness.text = .empty; settle()
                            #expect(!all().contains { $0.accessibility?.role == .heading })
                            #expect(!graph.recomposer.hasPending)
                        }
                    }
                }
            }
        }
    }
}
