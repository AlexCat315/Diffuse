import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose
@testable import GuavaUITerminal

@Suite("Terminal view", .serialized)
@MainActor
struct ViewTests {
    /// Process-wide holders (text environment, input context) are shared with
    /// every other UI suite in the process.
    private static let lock = NSLock()

    private static func environment() -> TextEnvironment {
        let path = ["/System/Library/Fonts/Menlo.ttc", "/System/Library/Fonts/Monaco.ttf",
                    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
                    "/usr/share/fonts/TTF/DejaVuSansMono.ttf"].first { FileManager.default.fileExists(atPath: $0) } ?? ""
        let atlas = FontAtlas(width: 512, height: 512)
        atlas.loadFont(path: path, size: 13)
        let shaper = TextShaper()
        if let face = atlas.freetypeFace { shaper.setFont(ftFace: face, size: 13) }
        return TextEnvironment(atlas: atlas, shaper: shaper, atlasTextureID: 1, defaultLineHeight: 17,
                               defaultColor: .white, defaultFont: .monospaced(size: 13),
                               fontResolver: TextFontResolver(primaryFontName: "Menlo", atlas: atlas))
    }

    private nonisolated func nodes(_ node: Node) -> [Node] { [node] + node.children.flatMap(nodes) }

    @Test("Mounting starts the program, layout fits the grid, output repaints, a click focuses")
    func mountAndDraw() throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let previous = TextEnvironmentHolder.current
        let environment = Self.environment()
        TextEnvironmentHolder.current = environment
        defer { TextEnvironmentHolder.current = previous }

        let session = TerminalSession(command: TerminalCommand(executable: "/bin/sleep", arguments: ["30"]),
                                      scrollbackLines: 10) { $0() }
        defer { session.terminate() }
        let context = PlatformInputContext()
        try context.withCurrent {
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: TerminalView(session: session).frame(width: 400, height: 200))
            defer { graph.install(root: EmptyView()) }
            graph.recomposer.commitAll()
            graph.computeLayout(width: 400, height: 200)
            #expect(session.status == .running)

            let surface = try #require(nodes(graph.tree.root!).first { $0.isFocusable && $0.draw != nil })
            let metrics = CellMetrics(font: .monospaced(size: 13), environment: environment)
            let expected = metrics.grid(width: Float(surface.frame.width), height: Float(surface.frame.height))

            let list = DrawList()
            surface.draw?(list, .zero)
            #expect(session.frame.columns == expected.columns)
            #expect(session.frame.rows == expected.rows)
            #expect(!list.vertices.isEmpty)

            graph.tree.flush()
            #expect(!surface.renderDirty)
            session.feed(Array("\u{1B}[31mred\u{1B}[0m".utf8))
            #expect(surface.renderDirty)
            #expect(session.frame.text(ofRow: 0) == "red")

            let dispatcher = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                                             capture: context.pointerCapture, focusChain: context.focusChain)
            let center = (x: Float(surface.absoluteFrame.midX), y: Float(surface.absoluteFrame.midY))
            dispatcher.dispatch(.mouseButtonDown(.init(button: .left, x: center.x, y: center.y, clicks: 1)))
            #expect(context.focusChain.focused === surface)
        }
    }
}
