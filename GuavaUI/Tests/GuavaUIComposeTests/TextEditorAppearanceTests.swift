import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Text editor appearance", .serialized)
@MainActor
struct TextEditorAppearanceTests: GuavaUIComposeSerializedSuite {
    private func nodes(_ node: Node?) -> [Node] {
        guard let node else { return [] }
        return [node] + node.children.flatMap { nodes($0) }
    }

    @Test("Line numbers reserve stable space through three digits and stay separated from document text")
    func stableGutter() throws { try GlobalTestLock.locked {
        let previous = TextEnvironmentHolder.current
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
        defer { TextEnvironmentHolder.current = previous }
        let context = PlatformInputContext()
        try context.withCurrent {
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            let textColor = Color(r: 0.9, g: 0.2, b: 0.7), numberColor = Color(r: 0.2, g: 0.8, b: 0.4)
            var origins: [Float] = []
            for count in [9, 99, 999] {
                let buffer = TextBuffer(Array(repeating: "sample", count: count).joined(separator: "\n"))
                graph.install(root: TextField(text: .constant(buffer)) { input in
                    input.layout.axis = .vertical; input.layout.wrapsLines = false
                    input.codeEditing.showsLineNumbers = true
                    input.codeEditing.lineNumberColor = numberColor
                    input.codeEditing.syntaxColorAtUTF8Offset = { _, _ in textColor }
                }.font(.monospaced(size: 15)).lineHeight(24).textFieldStyle(.editor).frame(width: 390, height: 200))
                graph.computeLayout(width: 390, height: 200)
                let field = try #require(nodes(graph.tree.root).first { $0.accessibility?.role == .textField })
                let list = DrawList(); field.draw?(list, .zero)
                let textX = try #require(list.vertices.filter { $0.color == textColor.rgba8 }.map(\.posX).min())
                let numberEnd = try #require(list.vertices.filter { $0.color == numberColor.rgba8 }.map(\.posX).max())
                #expect(textX - numberEnd >= 24)
                origins.append(textX)
            }
            #expect((origins.max() ?? 0) - (origins.min() ?? 0) < 0.5)
            graph.install(root: EmptyView())
        }
    } }

    @Test("Focused code uses a neutral full-width line band and the editor style leaves ordinary fields unchanged")
    func focusedSurface() throws { try GlobalTestLock.locked {
        let previous = TextEnvironmentHolder.current
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
        defer { TextEnvironmentHolder.current = previous }
        let context = PlatformInputContext()
        try context.withCurrent {
            for light in [false, true] {
                let theme = light ? Theme.defaultLight : .defaultDark
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                graph.install(root: TextField(text: .constant("sample\nnext")) { input in
                    input.layout.axis = .vertical; input.codeEditing.showsLineNumbers = true
                }.textFieldStyle(.editor).font(.monospaced(size: 15)).lineHeight(24)
                    .appearance(light ? .light : .dark).frame(width: 390, height: 200))
                graph.computeLayout(width: 390, height: 200)
                let field = try #require(nodes(graph.tree.root).first { $0.accessibility?.role == .textField })
                context.focusChain.focus(field); graph.recomposer.commitAll(); graph.computeLayout(width: 390, height: 200)
                let list = DrawList(); field.draw?(list, .zero)
                let band = theme.colors.stateLayerHover.multipliedAlpha(0.7).rgba8
                let points = list.vertices.filter { $0.color == band }
                #expect(!points.isEmpty)
                #expect((points.map(\.posX).max() ?? 0) - (points.map(\.posX).min() ?? 0) >= 389)
                #expect(!list.vertices.contains { $0.color == theme.colors.accent.multipliedAlpha(0.42).rgba8 })
                #expect(nodes(graph.tree.root).contains { $0.backgroundColor == theme.colors.surfaceSunken })
                #expect(!nodes(graph.tree.root).contains { $0.borderWidth > 0 })
                graph.install(root: TextField(text: .constant("Form field")).frame(width: 200, height: 32))
                graph.computeLayout(width: 200, height: 32)
                #expect(nodes(graph.tree.root).contains { $0.borderWidth > 0 })
                graph.install(root: EmptyView())
            }
        }
    } }
}
