import Testing
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Editor Vec3Field", .serialized)
struct Vec3FieldTests: GuavaUIComposeSerializedSuite {
    final class Store {
        var x: Float = 1
        var y: Float = 2
        var z: Float = 3
    }

    @Test("Vec3Field keeps all three axes inside a narrow inspector row")
    func compactLayoutStaysInsideRow() { GlobalTestLock.locked {
        let store = Store()
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())

        graph.install(root:
            Vec3Field(
                x: Binding(get: { store.x }, set: { store.x = $0 }),
                y: Binding(get: { store.y }, set: { store.y = $0 }),
                z: Binding(get: { store.z }, set: { store.z = $0 })
            )
            .frame(width: 180, height: 24)
        )
        graph.computeLayout(width: 180, height: 24)

        let root = tree.root!
        let vec3Row = firstNode(in: root) { node in
            node.children.count == 3
        }!
        #expect(vec3Row.frame.size == CGSize(width: 180, height: 24))

        let axisRows = vec3Row.children
        #expect(axisRows.count == 3)
        #expect(axisRows.allSatisfy { $0.frame.width <= 60 })
        #expect(axisRows.last!.frame.maxX <= 180)
    } }

    private func firstNode(in root: Node, where predicate: (Node) -> Bool) -> Node? {
        if predicate(root) { return root }
        for child in root.children {
            if let match = firstNode(in: child, where: predicate) {
                return match
            }
        }
        return nil
    }
}
