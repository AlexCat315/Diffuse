import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Control density", .serialized)
struct ControlDensityTests {
    @Test("flat tab underlines span the full tab, not a zero-width empty view")
    func tabIndicatorFillsWidth() { GlobalTestLock.locked {
        let previous = TextEnvironmentHolder.current
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
        defer { TextEnvironmentHolder.current = previous }
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: Row {
            Button("Profiler", isSelected: true) {}.buttonStyle(.tab).debugName("selected-tab")
        })
        graph.computeLayout(width: 320, height: 100)
        let snapshot = graph.layoutSnapshot()
        let tab = snapshot.first { $0.debugName == "selected-tab" }?.absoluteFrame
        let indicator = snapshot.first { $0.debugName == "tab-selection-indicator" }?.absoluteFrame
        #expect(tab?.width ?? 0 > 20)
        #expect(indicator?.width == tab?.width)
        #expect(indicator?.height == 2)
    } }

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
