import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Control density", .serialized)
struct ControlDensityTests {
    @Test("control sizing is inherited and explicit text field sizes win")
    func inheritedSizing() { GlobalTestLock.locked {
        let previous = TextEnvironmentHolder.current
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
        defer { TextEnvironmentHolder.current = previous }
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: Column(alignment: .leading, spacing: 4) {
            Button("Build") {}.debugName("small-button")
            TextField("Find", text: Binding(get: { "" }, set: { _ in }))
                .debugName("inherited-field")
            TextField("Find", text: Binding(get: { "" }, set: { _ in }), size: .large)
                .debugName("explicit-field")
            Button("Large") {}.controlSize(.large).debugName("large-button")
        }.controlSize(.small))
        graph.computeLayout(width: 320, height: 240)
        let snapshot = graph.layoutSnapshot()
        #expect(snapshot.first { $0.debugName == "small-button" }?.absoluteFrame.height == 24)
        #expect(snapshot.first { $0.debugName == "inherited-field" }?.absoluteFrame.height == 24)
        #expect(snapshot.first { $0.debugName == "explicit-field" }?.absoluteFrame.height == 40)
        #expect(snapshot.first { $0.debugName == "large-button" }?.absoluteFrame.height == 36)
    } }
}
