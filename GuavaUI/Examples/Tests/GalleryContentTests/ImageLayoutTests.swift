import Foundation
import Testing
import GuavaUICompose
import GuavaUIRuntime
@testable import GalleryContent

@Suite("Image story layout", .serialized)
@MainActor
struct ImageLayoutTests {
    @Test("Image modes, URL field and retry stay within narrow and wide content at both scales and directions")
    func matrix() throws {
        let previous = TextEnvironmentHolder.current
        TextEnvironmentHolder.current = .bootstrapped(atlasTextureID: 1, primaryFontName: SystemFontDefaults.primaryFontName)
        defer { TextEnvironmentHolder.current = previous }
        for width: Float in [390, 720, 1280] { for scale: Float in [1, 2] { for rtl in [false, true] {
            let available: Float = width == 390 ? 286 : width == 720 ? 560 : 929
            var surface = UIEnvironment(); surface.viewport.width = width
            surface.input = width == 1280 ? [.pointer, .keyboard] : [.touch, .keyboard]
            let context = PlatformInputContext()
            try context.withCurrent {
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                defer { graph.install(root: EmptyView()) }
                graph.install(root: ImageStory(options: GalleryOptions()).frame(width: available)
                    .surfaceEnvironment(surface).textScaler(.init(scale)).layoutDirection(rtl ? .rtl : .ltr))
                func settle() { for _ in 0..<6 { graph.recomposer.commitAll(); graph.computeLayout(width: width, height: 3_000) } }
                func nodes(_ node: Node) -> [Node] { [node] + node.children.flatMap(nodes) }
                func named(_ name: String) throws -> Node {
                    try #require(nodes(graph.tree.root!).first { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == name })
                }
                func button(_ title: String) throws -> Node {
                    try #require(nodes(graph.tree.root!).first { node in
                        node.accessibility?.role == .button && nodes(node).contains { $0.layoutNode?.textInputs?.text == title }
                    })
                }
                settle()
                let modes = try named("image-modes")
                for mode in ["fit", "fill", "stretch"] {
                    let item = try named("image-mode-\(mode)")
                    #expect(item.absoluteFrame.minX >= modes.absoluteFrame.minX - 0.5)
                    #expect(item.absoluteFrame.maxX <= modes.absoluteFrame.maxX + 0.5)
                }
                let remote = try button("Remote")
                let input = EventDispatcher(tree: graph.tree, interactions: context.interactions, capture: context.pointerCapture, focusChain: context.focusChain)
                let frame = remote.absoluteFrame
                input.dispatch(.mouseButtonDown(.init(button: .left, x: Float(frame.midX), y: Float(frame.midY), clicks: 1)))
                input.dispatch(.mouseButtonUp(.init(button: .left, x: Float(frame.midX), y: Float(frame.midY), clicks: 1)))
                settle()
                let field = try #require(nodes(graph.tree.root!).first { $0.accessibility?.label == "Remote image URL" })
                let layout = try named("image-loading-layout")
                let retry = try button("Retry")
                for item in [field, retry, try named("image-preview")] {
                    #expect(item.absoluteFrame.minX >= -0.5)
                    #expect(item.absoluteFrame.maxX <= CGFloat(available) + 0.5)
                }
                if available < 220 + 160 * scale {
                    #expect(retry.absoluteFrame.minY >= (try named("image-preview")).absoluteFrame.maxY)
                }
                #expect(layout.frame.width <= CGFloat(available))
            }
        } } }
    }
}
