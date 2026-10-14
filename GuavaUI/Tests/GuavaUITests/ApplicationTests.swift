import Testing
import GuavaUIRuntime
@testable import GuavaUI

private struct ConsumerView: View {
    @State private var count = 0
    @State private var name: TextBuffer = "Guava"

    var body: some View {
        Column {
            Text("Hello, \(name.stringValue)")
            TextField("Name", text: $name)
            Button("Count: \(count)") { count += 1 }
        }.padding(20)
    }
}

@Test func applicationDefaultsAreIdleAndConfigurationGroupsAreIndependent() {
    let original = ApplicationConfiguration()
    #expect(original.frames.policy == .eventDriven)
    #expect(original.rendering.vsync)
    let customized = ApplicationConfiguration(title: "Consumer") {
        $0.window.showsDockIcon = false
        $0.typography.fontSize = 18
        $0.frames.targetRate = 120
    }
    #expect(customized.window.title == "Consumer")
    #expect(customized.frames.validatedTargetRate == 120)
    #expect(customized.rendering.sampleCount == original.rendering.sampleCount)
    #expect(original.window.showsDockIcon)
    _ = ConsumerView()
}

@Test func invalidFrameRatesUseTheDisplayCadence() {
    for value in [Double.nan, .infinity, 0, -1] {
        let config = ApplicationConfiguration { $0.frames.targetRate = value }
        #expect(config.frames.validatedTargetRate == nil)
    }
    #expect(ApplicationConfiguration { $0.frames.targetRate = 1000 }.frames.validatedTargetRate == 240)
}

@Test @MainActor func safeAreaKeepsAuthoredPadding() throws {
    var surface = UIEnvironment()
    surface.safeArea.top = 60
    surface.safeArea.leading = 12
    let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
    graph.install(root: AdaptiveApplicationContent(content:
        Box { Spacer().frame(width: 10, height: 10).debugName("adaptive-marker") }.padding(24),
        environment: State(wrappedValue: surface)))
    graph.computeLayout(width: 400, height: 800)
    func marker(_ node: Node) -> Node? {
        if node.attachments[LayoutDebugAttachmentKey.debugName] as? String == "adaptive-marker" { return node }
        return node.children.lazy.compactMap(marker).first
    }
    let content = try #require(graph.tree.root.flatMap(marker))
    #expect(content.frame.minX == 36)
    #expect(content.frame.minY == 84)
}
