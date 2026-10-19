import Foundation
import Testing
import GuavaUIRuntime
import GuavaUICompose
@testable import GalleryContent

@Suite("Text editor story layout", .serialized)
@MainActor
struct TextEditorLayoutTests {
    private func nodes(_ node: Node) -> [Node] { [node] + node.children.flatMap(nodes) }

    @Test("Document chrome wraps at narrow widths and keeps code/plain edits through mode changes")
    func matrix() throws {
        let previous = TextEnvironmentHolder.current
        TextEnvironmentHolder.current = .bootstrapped(atlasTextureID: 1, primaryFontName: SystemFontDefaults.primaryFontName)
        defer { TextEnvironmentHolder.current = previous }
        for width: Float in [390, 720, 1280] { for scale: Float in [1, 2] { for dark in [false, true] {
            let context = PlatformInputContext()
            try context.withCurrent {
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                var surface = UIEnvironment(); surface.viewport.width = width
                surface.input = width == 1280 ? [.pointer, .keyboard] : [.touch, .keyboard]
                let available: Float = width == 390 ? 330 : width == 720 ? 600 : 970
                graph.install(root: TextEditorStory(options: GalleryOptions()).frame(width: available)
                    .surfaceEnvironment(surface).textScaler(.init(scale)).appearance(dark ? .dark : .light))
                defer { graph.install(root: EmptyView()) }
                func settle() {
                    for _ in 0..<6 { graph.recomposer.commitAll(); graph.computeLayout(width: available, height: 2000) }
                }
                settle()
                let all = nodes(try #require(graph.tree.root))
                let field = try #require(all.first { $0.accessibility?.role == .textField && $0.accessibility?.label == "Swift source" })
                for name in ["Code mode", "Sample warning", "Go to beginning", "Load 200,000 lines"] {
                    let control = try #require(all.first {
                        $0.isHitTestable && ($0.accessibility?.label == name || nodes($0).contains { $0.layoutNode?.textInputs?.text == name })
                    })
                    #expect(control.absoluteFrame.minX >= 0 && control.absoluteFrame.maxX <= CGFloat(available))
                    if width != 1280 { #expect(control.frame.height >= 44) }
                }
                let handle = try #require(all.first { $0.accessibility?.role == .slider && $0.accessibility?.label == "Editor height" })
                #expect(field.frame.width > 100 && field.frame.height >= 240)
                #expect(abs(field.frame.height + handle.frame.height - 320) < 1)
                let dispatcher = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                                                capture: context.pointerCapture, focusChain: context.focusChain)
                context.focusChain.focus(field)
                dispatcher.dispatch(.keyDown(.init(scancode: Scancode.a, keycode: 0, modifiers: .lgui, isRepeat: false)))
                dispatcher.dispatch(.textInput("A quiet document retains its draft.")); settle()
                let toggle = try #require(nodes(graph.tree.root!).first { $0.isHitTestable && $0.accessibility?.label == "Code mode" })
                let f = toggle.absoluteFrame
                let event = MouseButtonEvent(button: .left, x: Float(f.midX), y: Float(f.midY), clicks: 1)
                dispatcher.dispatch(.mouseButtonDown(event)); dispatcher.dispatch(.mouseButtonUp(event)); settle()
                let plain = try #require(nodes(graph.tree.root!).first { $0.accessibility?.role == .textField && $0.accessibility?.label == "Plain text document" })
                #expect(plain === field)
                var copied = ""
                let oldClipboard = ClipboardHolder.write; ClipboardHolder.write = { copied = $0 }
                defer { ClipboardHolder.write = oldClipboard }
                context.focusChain.focus(plain)
                dispatcher.dispatch(.keyDown(.init(scancode: Scancode.a, keycode: 0, modifiers: .lgui, isRepeat: false)))
                dispatcher.dispatch(.keyDown(.init(scancode: Scancode.c, keycode: 0, modifiers: .lgui, isRepeat: false)))
                #expect(copied == "A quiet document retains its draft.")
                settle()
                #expect(!graph.recomposer.hasPending)
            }
        } } }
    }
}
