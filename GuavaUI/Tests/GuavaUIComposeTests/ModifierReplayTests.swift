import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Caller modifiers survive local recomposition")
struct ModifierReplayTests {
    @Test("Repeated modifier types through AnyView keep each declaration and replace parent values")
    func erasedDeclarations() { GlobalTestLock.locked {
        struct Parent: View {
            @State var width: Float = 240
            let content: StatefulContent
            var body: some View {
                AnyView(AnyView(content).frame(width: width)).frame(height: 360).debugName("erased-frame")
            }
        }
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        let content = StatefulContent()
        let parent = Parent(content: content)
        graph.install(root: parent)
        for width: Float in [240, 380, 200] {
            parent.width = width
            for _ in 0..<3 {
                content.expanded.toggle()
                for _ in 0..<3 { graph.recomposer.commitAll(); graph.computeLayout(width: 800, height: 700) }
                let frame = graph.layoutSnapshot().first { $0.debugName == "erased-frame" }!.absoluteFrame
                #expect(frame.width == CGFloat(width))
                #expect(frame.height == 360)
            }
        }
    } }

    @Test("A width-only caller preserves owned height and auto explicitly clears an axis")
    func partialFrameAndAuto() { GlobalTestLock.locked {
        struct SizedContent: View {
            @State var height: Float = 120
            var body: some View { Box {}.frame(width: 100, height: height) }
        }
        struct Parent: View {
            @State var width: FrameDimension = .points(240)
            let content: SizedContent
            var body: some View { content.frame(width: width).debugName("partial-frame") }
        }
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        let content = SizedContent()
        let parent = Parent(content: content)
        graph.install(root: parent)
        for (width, height): (FrameDimension, Float) in [(.points(240), 120), (.points(240), 200), (.auto, 160)] {
            parent.width = width
            content.height = height
            for _ in 0..<3 { graph.recomposer.commitAll(); graph.computeLayout(width: 800, height: 700) }
            let frame = graph.layoutSnapshot().first { $0.debugName == "partial-frame" }!.absoluteFrame
            #expect(frame.height == CGFloat(height))
            if case .points(let value) = width { #expect(frame.width == CGFloat(value)) }
            else { #expect(frame.width != 100 && frame.width != 240) }
        }
    } }

    private struct StatefulContent: View {
        @State var expanded = false
        var body: some View {
            if expanded {
                Row { Box {}.frame(height: 600) }.frame(width: .percent(100), height: .percent(100))
                    .background(.surface)
            } else {
                Box { Box {}.frame(height: 100) }.frame(width: .percent(100), height: .percent(100))
                    .background(.surface)
            }
        }
    }
    private struct Forwarder: View {
        let content: StatefulContent
        var body: some View { content.foregroundColor(.onSurface) }
    }

    @Test("Fixed frame and outer style survive a local branch replacement through transparent wrappers")
    func localStatePreservesCaller() { GlobalTestLock.locked {
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        let content = StatefulContent()
        graph.install(root: Forwarder(content: content).frame(width: 240, height: 360)
            .background(Color(red: 255, green: 0, blue: 0)).debugName("bounded-component"))
        for value in [false, true, false, true] {
            content.expanded = value
            for _ in 0..<3 { graph.recomposer.commitAll(); graph.computeLayout(width: 800, height: 700) }
            let node = graph.layoutSnapshot().first { $0.debugName == "bounded-component" }!
            #expect(node.absoluteFrame.width == 240)
            #expect(node.absoluteFrame.height == 360)
            func target(in node: Node) -> Node? {
                if (node.attachments[LayoutDebugAttachmentKey.debugName] as? String) == "bounded-component" { return node }
                return node.children.lazy.compactMap { target(in: $0) }.first
            }
            #expect(target(in: tree.root!)?.backgroundColor == Color(red: 255, green: 0, blue: 0))
        }
    } }

    @Test("Modifier values update in declaration order without retaining obsolete caller values")
    func updatedCallerValues() { GlobalTestLock.locked {
        struct Parent: View {
            @State var height: Float = 360
            let child: StatefulContent
            var body: some View { child.frame(height: 200).frame(width: 240, height: height).debugName("child") }
        }
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        let content = StatefulContent()
        let parent = Parent(child: content)
        graph.install(root: parent)
        for height: Float in [360, 280, 420] {
            parent.height = height
            content.expanded.toggle()
            for _ in 0..<3 { graph.recomposer.commitAll(); graph.computeLayout(width: 800, height: 700) }
            #expect(graph.layoutSnapshot().first { $0.debugName == "child" }!.absoluteFrame.height == CGFloat(height))
        }
    } }
}
