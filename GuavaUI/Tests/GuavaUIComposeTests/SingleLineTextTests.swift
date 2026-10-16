import Foundation
import GuavaUIRuntime
import Testing
@testable import GuavaUICompose

@Suite("Single-line ellipsis", .serialized)
struct SingleLineTextTests: GuavaUIComposeSerializedSuite {
    @Test("Ellipsis preserves emoji, combining sequences and flags; insufficient width and explicit line breaks stay bounded")
    func graphemes() {
        let text = "A👩🏽‍💻e\u{301}🇨🇳B"
        func fitting(_ width: Float) -> String { SingleLineText.fitting(text, width: width) { Float($0.count) } }
        #expect(fitting(3) == "A👩🏽‍💻…")
        #expect(fitting(4) == "A👩🏽‍💻e\u{301}…")
        #expect(fitting(5) == text && fitting(.infinity) == text)
        #expect(fitting(0) == "" && fitting(0.5) == "" && fitting(1) == "…")
        #expect(SingleLineText.fitting("A\r\nB\u{2028}C", width: 20) { Float($0.count) } == "A B C")
    }

    @Test("Shaping, font scaling, live edits and painting use the same constrained line while semantics retain the original")
    func measurementAndPaint() throws {
        try GlobalTestLock.locked {
            let prior = TextEnvironmentHolder.current; TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = prior }
            struct Sample: View {
                let text: String
                let width: Float
                let scale: Float
                var body: some View { Text(text).truncated().font(.bodyStrong).frame(width: width).textScaler(.init(scale)) }
            }
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            defer { graph.install(root: EmptyView()) }
            for text in ["AVfi office 👩🏽‍💻 permissions 文件", "مرحبا بالمستخدم في مساحة العمل", "Changed document"] {
                for scale: Float in [1, 2] {
                    for width: Float in [0, 5, 60, 160, 1000] {
                        graph.install(root: Sample(text: text, width: width, scale: scale))
                        for _ in 0..<3 { graph.recomposer.commitAll(); graph.computeLayout(width: 1100, height: 200) }
                        var pending = graph.tree.root.map { [$0] } ?? []
                        var found: Node?
                        while let node = pending.popLast() {
                            if node.layoutNode?.textInputs?.text == text { found = node; break }
                            pending.append(contentsOf: node.children)
                        }
                        let node = try #require(found), layout = try #require(node.layoutNode)
                        #expect(node.accessibility?.label == text && layout.textInputs?.lineLimit == 1)
                        let list = DrawList(); NodeRenderer().render(root: try #require(graph.tree.root), into: list)
                        let measured = try #require(layout.textMeasure)
                        #expect(measured.result.lines.count <= 1 && measured.result.totalWidth <= width + 1)
                        if width == 0 { #expect(list.vertices.isEmpty) }
                        if width == 1000 { #expect(measured.key.text == text) }
                    }
                }
            }
        }
    }
}
