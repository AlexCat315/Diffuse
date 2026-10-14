import Foundation
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
    #expect(content.absoluteFrame.minX == 36)
    #expect(content.absoluteFrame.minY == 84)
}


@Test @MainActor func applicationRootAllocatesViewportToFlexibleContent() throws {
    var surface = UIEnvironment()
    surface.safeArea.top = 20; surface.safeArea.leading = 12
    let environment = State(wrappedValue: surface)
    let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
    graph.install(root: AdaptiveApplicationContent(content:
        Box(direction: .column, alignItems: .stretch) {
            Box {}.frame(height: 40).flex(0, shrink: 0).debugName("root-header")
            Box {}.flex(1, shrink: 1, basis: 0).debugName("root-content")
        }.flex(1, shrink: 1, basis: 0).frame(minWidth: 0, minHeight: 0).debugName("root-shell"),
        environment: environment))
    func frame(_ name: String) throws -> CGRect {
        try #require(graph.layoutSnapshot().first { $0.debugName == name }?.absoluteFrame)
    }
    graph.computeLayoutIfNeeded(width: 400, height: 800)
    let firstShell = try frame("root-shell"), firstContent = try frame("root-content")
    #expect(firstShell == CGRect(x: 12, y: 20, width: 388, height: 780))
    #expect(firstContent == CGRect(x: 12, y: 60, width: 388, height: 740))
    surface.safeArea.top = 30; surface.safeArea.leading = 24
    environment.wrappedValue = surface; graph.recomposer.commitAll()
    graph.computeLayoutIfNeeded(width: 300, height: 600)
    let resizedShell = try frame("root-shell"), resizedContent = try frame("root-content")
    #expect(resizedShell == CGRect(x: 24, y: 30, width: 276, height: 570))
    #expect(resizedContent == CGRect(x: 24, y: 70, width: 276, height: 530))
    #expect(!graph.layoutNeedsUpdate(width: 300, height: 600))
}
