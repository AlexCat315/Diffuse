@testable import EditorCore
import EngineKernel
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import SceneRuntime
import Testing
@testable import EditorApp

@Suite("Inspector compact authoring", .serialized)
struct InspectorLayoutTests {
    private final class Shapes {
        var value: [ColliderShapeInstance] = [
            .init(shape: .box(halfExtents: SIMD3<Float>(repeating: 0.5), center: .zero)),
            .init(shape: .sphere(radius: 0.75, center: .zero)),
        ]
        var binding: Binding<[ColliderShapeInstance]> {
            Binding(get: { self.value }, set: { self.value = $0 })
        }
    }

    private func root(_ shapes: Shapes, session: InspectorColliderShapeEditorState) -> some View {
        PropertyGrid([PropertyGridSection(id: "collider", title: "Collider", rows: [
            PropertyGridRow(id: "shapes", label: "Compound Shapes", layout: .fullWidth, sizing: .intrinsic) {
                InspectorPanel.InspectorColliderShapeInstancesValue(binding: shapes.binding, session: session)
            },
            PropertyGridRow(id: "trigger", label: "Trigger") {
                Text("Enabled").debugName("following-collider-property")
            },
        ])], labelWidth: 72, minValueWidth: 80, scrollAxes: .vertical)
            .theme(EditorVisualTheme.make(dark: false))
    }

    @Test("one shape is expanded and transform disclosure reflows the next property",
          arguments: [Float(260), Float(320)])
    func compactLayout(width: Float) throws { try WorkbenchUITestSupport.withEnvironment { registry, _ in
        let shapes = Shapes()
        let session = InspectorColliderShapeEditorState()
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: root(shapes, session: session))
        graph.computeLayout(width: width, height: 680)
        var layout = graph.layoutSnapshot()
        let initial = try #require(layout.first { $0.debugName == "collider-shapes-editor" }?.absoluteFrame)
        #expect(initial.height < 240)
        #expect(!layout.contains { $0.debugName == "collider-shape-0-position" })
        #expect(!layout.contains { $0.debugName == "collider-shape-1-transform" })

        try WorkbenchUITestSupport.activate("collider-shape-0-transform", in: tree.root, registry: registry)
        graph.recomposer.commitAll()
        graph.computeLayout(width: width, height: 680)
        layout = graph.layoutSnapshot()
        let expanded = try #require(layout.first { $0.debugName == "collider-shapes-editor" }?.absoluteFrame)
        let following = try #require(layout.first { $0.debugName == "following-collider-property" }?.absoluteFrame)
        #expect(expanded.height > initial.height + 90)
        #expect(following.minY >= expanded.maxY)
        #expect(layout.contains { $0.debugName == "collider-shape-0-position" })
        for entry in layout where entry.debugName?.hasPrefix("collider-") == true {
            #expect(entry.absoluteFrame.maxX <= CGFloat(width))
        }

        try WorkbenchUITestSupport.activate("collider-shape-1-disclosure", in: tree.root, registry: registry)
        graph.recomposer.commitAll()
        graph.computeLayout(width: width, height: 680)
        layout = graph.layoutSnapshot()
        #expect(session.selectedIndex == 1)
        #expect(!layout.contains { $0.debugName == "collider-shape-0-position" })
        #expect(layout.contains { $0.debugName == "collider-shape-1-transform" })
    } }

    @Test("editing, sorting, deleting and adding retain the active shape and session preferences")
    func editingAndStructuralActions() throws { try WorkbenchUITestSupport.withEnvironment { registry, focus in
        let shapes = Shapes()
        let session = InspectorColliderShapeEditorState()
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: root(shapes, session: session))
        try WorkbenchUITestSupport.activate("collider-shape-1-disclosure", in: tree.root, registry: registry)
        graph.recomposer.commitAll()
        try WorkbenchUITestSupport.activate("collider-shape-1-transform", in: tree.root, registry: registry)
        graph.recomposer.commitAll()
        let position = try WorkbenchUITestSupport.named("collider-shape-1-position", in: tree.root)
        let input = try #require(WorkbenchUITestSupport.firstNode(position) {
            registry.handlers(for: $0).text != nil
        })
        focus.focus(input)
        graph.recomposer.commitAll()
        let handlers = registry.handlers(for: input)
        _ = handlers.key?(KeyEvent(scancode: 4, keycode: 0, modifiers: [.lgui], isRepeat: false), .target)
        _ = handlers.text?("3.5", .target)
        _ = handlers.key?(KeyEvent(scancode: 40, keycode: 0, modifiers: [], isRepeat: false), .target)
        focus.clear()
        graph.recomposer.commitAll()
        #expect(shapes.value[1].localPosition.x == 3.5)

        try WorkbenchUITestSupport.activate("collider-shape-1-up", in: tree.root, registry: registry)
        graph.recomposer.commitAll()
        #expect(shapes.value[0].shape.kind == .sphere)
        #expect(shapes.value[0].localPosition.x == 3.5)
        #expect(session.selectedIndex == 0)
        #expect(session.expandedTransformIndices == [0])

        try WorkbenchUITestSupport.activate("collider-shape-1-remove", in: tree.root, registry: registry)
        graph.recomposer.commitAll()
        #expect(shapes.value.count == 1)
        #expect(session.selectedIndex == 0)
        let remove = try WorkbenchUITestSupport.named("collider-shape-0-remove", in: tree.root)
        #expect(WorkbenchUITestSupport.firstNode(remove) { registry.handlers(for: $0).key != nil } == nil)

        try WorkbenchUITestSupport.activate("collider-add-shape", in: tree.root, registry: registry)
        graph.recomposer.commitAll()
        #expect(shapes.value.count == 2)
        #expect(shapes.value[1].shape.kind == .box)
        #expect(session.selectedIndex == 1)

        let recreated = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        recreated.install(root: root(shapes, session: session))
        #expect(recreated.layoutSnapshot().contains { $0.debugName == "collider-shape-1-transform" })
        #expect(!recreated.layoutSnapshot().contains { $0.debugName == "collider-shape-0-transform" })
    } }

    @Test("typed collider form replaces duplicate legacy fields and keeps advanced JSON discoverable")
    func schemaPresentation() throws {
        let scene = EditorSceneAdapter()
        let entity = scene.scene.createEntity()
        _ = scene.scene.setComponent(Collider(shape: .box(halfExtents: SIMD3<Float>(repeating: 0.5),
                                                        center: .zero)), for: entity)
        let section = try #require(scene.inspectorSections(for: entity.rawValue).first { $0.id == "collider" })
        let json = try #require(section.fields.first { $0.id == "shape-instances-json" })
        #expect(json.presentation == .advanced)
        let presented = InspectorSectionPresentation.presentedSection(section)
        #expect(!presented.fields.contains { $0.id == "shape-kind" || $0.id == "shape-instance-count" })
        #expect(presented.fields.contains { $0.id == "shape-instances" })
        #expect(presented.fields.contains { $0.id == "trigger" })
        #expect(InspectorSectionFilter.filter([presented], query: "JSON").first?.fields.count == 1)
    }
}
