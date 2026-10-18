import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Boolean control labels", .serialized)
struct BoolControlLabelTests: GuavaUIComposeSerializedSuite {
    @Test("Toggle and Checkbox expose their label slot and keep one accessible control")
    func labels() throws {
        try GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            var toggleOn = false
            var checked = false
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: Column(alignment: .leading, spacing: 8) {
                Toggle("Notifications", isOn: Binding(get: { toggleOn }, set: { toggleOn = $0 }))
                Checkbox("Accept the terms", isOn: Binding(get: { checked }, set: { checked = $0 }))
            }.frame(width: 260))
            graph.computeLayout(width: 260, height: 120)
            let nodes = allNodes(graph.tree.root)
            let toggle = try #require(nodes.first {
                $0.accessibility?.role == .toggle && $0.accessibility?.label == "Notifications"
            })
            let checkbox = try #require(nodes.first {
                $0.accessibility?.role == .checkbox && $0.accessibility?.label == "Accept the terms"
            })
            #expect(toggle.frame.width == 38 && checkbox.frame.width == 18)
            #expect(nodes.contains { $0.layoutNode?.textInputs?.text == "Notifications" })
            #expect(nodes.contains { $0.layoutNode?.textInputs?.text == "Accept the terms" })
            #expect(nodes.filter { $0.accessibility?.role == .toggle && $0.accessibility?.label == "Notifications" }.count == 1)
            #expect(nodes.filter { $0.accessibility?.role == .checkbox && $0.accessibility?.label == "Accept the terms" }.count == 1)
            toggle.accessibilityActions.activate?()
            checkbox.accessibilityActions.activate?()
            #expect(toggleOn && checked)
        }
    }

    private func allNodes(_ root: Node?) -> [Node] {
        guard let root else { return [] }
        return [root] + root.children.flatMap { allNodes($0) }
    }
}
