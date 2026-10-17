import Foundation
import Testing
import GuavaUIRuntime
import GuavaUIAgent
@testable import GuavaUICompose

@Suite("Scratch", .serialized)
@MainActor
struct ScratchGeometryTests: GuavaUIComposeSerializedSuite {
    private struct Harness: View {
        let label = "Workspace permissions and international collaboration 👩🏽‍💻"
        var body: some View {
            Box(direction: .column, alignItems: .flexStart, justifyContent: .center, spacing: 12) {
                Combobox(selection: .constant(0), options: [
                    SelectOption(value: 0, label: "Workspace permissions and international collaboration 👩🏽‍💻"),
                    SelectOption(value: 1, label: "Personal workspace")
                ]) { $0.isClearable = true }.frame(width: .percent(100))
            }.frame(width: 390, height: 200)
        }
    }
    private func nodes(_ root: Node?) -> [Node] {
        var pending = root.map { [$0] } ?? [], result: [Node] = []
        while let node = pending.popLast() { result.append(node); pending.append(contentsOf: node.children.reversed()) }
        return result
    }
    @Test("print")
    func print_() throws {
        try GlobalTestLock.locked {
            let old = TextEnvironmentHolder.current; TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = old }
            let context = PlatformInputContext(), portals = PortalStore(), scheduler = AnimatorScheduler()
            context.addScopedAmbient(PortalStoreAmbient(portals))
            try context.withCurrent { try AnimatorScheduler.$current.withValue(scheduler) {
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                graph.install(root: Harness())
                for _ in 0..<10 { graph.recomposer.commitAll(); graph.computeLayout(width: 390, height: 200) }
                for node in nodes(graph.tree.root) {
                    let f = node.absoluteFrame
                    print("id=\(node.id) role=\(node.accessibility?.role.rawValue ?? "-") "
                        + "abs=(\(f.minX),\(f.minY),\(f.width),\(f.height)) "
                        + "text=\(node.layoutNode?.textInputs?.text ?? "") "
                        + "measure=\(node.layoutNode?.textMeasure?.result.totalWidth ?? -1)")
                }
                graph.install(root: EmptyView()); scheduler.reset()
            } }
        }
    }
}
