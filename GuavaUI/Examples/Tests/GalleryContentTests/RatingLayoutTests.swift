import Foundation
import Testing
import GuavaUIRuntime
import GuavaUICompose
@testable import GalleryContent

@Suite("Rating sample layout", .serialized)
@MainActor
struct RatingLayoutTests {
    private func nodes(_ node: Node) -> [Node] { [node] + node.children.flatMap(nodes) }

    @Test("Scores stay below bounded star strips at both scales, themes and directions")
    func matrix() throws {
        let previous = TextEnvironmentHolder.current
        TextEnvironmentHolder.current = .bootstrapped(atlasTextureID: 1, primaryFontName: SystemFontDefaults.primaryFontName)
        defer { TextEnvironmentHolder.current = previous }
        for width: Float in [390, 720, 1280] {
            for scale: Float in [1, 2] {
                for rtl in [false, true] {
                    for theme in [Theme.defaultLight, Theme.defaultDark] {
                        let context = PlatformInputContext()
                        try context.withCurrent {
                            var surface = UIEnvironment(); surface.viewport.width = width
                            surface.input = width == 1280 ? [.pointer, .keyboard] : [.touch, .keyboard]
                            let available = width == 390 ? Float(286) : width == 720 ? 560 : 929
                            var value = 7.0
                            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                            graph.install(root: RatingSample(Rating("Ten stars", value: Binding(get: { value }, set: { value = $0 })) { $0.selection.maximum = 10 }) {
                                Text("Score: 7 / 10").font(.bodyStrong)
                                Button("Clear") {}
                            }.frame(width: available).surfaceEnvironment(surface).textScaler(.init(scale))
                                .layoutDirection(rtl ? .rtl : .ltr).theme(theme))
                            defer { graph.install(root: EmptyView()) }
                            for _ in 0..<6 { graph.recomposer.commitAll(); graph.computeLayout(width: width, height: 400) }
                            let all = nodes(graph.tree.root!)
                            let strip = try #require(all.first { $0.accessibility?.role == .scrollArea })
                            let rating = try #require(all.first { $0.accessibility?.role == .slider })
                            let score = try #require(all.first { $0.layoutNode?.textInputs?.text == "Score: 7 / 10" })
                            #expect(strip.clipsToBounds && strip.frame.width == CGFloat(available))
                            // Pointer surfaces reserve the 12pt lane; touch overlays a thin indicator.
                            #expect(strip.frame.height >= rating.frame.height + (surface.supportsHover ? 12 : 0))
                            #expect(score.absoluteFrame.minX >= 0 && score.absoluteFrame.maxX <= CGFloat(available))
                            #expect(score.absoluteFrame.minY >= strip.absoluteFrame.maxY)
                            // The scroll coordinate system starts at x=0 even in
                            // RTL, while keyboard behavior retains the star order.
                            #expect(rating.absoluteFrame.minX >= strip.absoluteFrame.minX)
                            context.focusChain.focus(rating)
                            let input = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                                capture: context.pointerCapture, focusChain: context.focusChain)
                            input.dispatch(.keyDown(.init(scancode: Scancode.arrowLeft, keycode: 0, modifiers: [], isRepeat: false)))
                            #expect(value == (rtl ? 8 : 6))
                        }
                    }
                }
            }
        }
    }
}
