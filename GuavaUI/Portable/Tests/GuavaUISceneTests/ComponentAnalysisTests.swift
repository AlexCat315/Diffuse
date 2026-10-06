import Foundation
import Testing
import GuavaUIComposeCore
import GuavaUISharedDemo
import GuavaUIDevToolsScene
import GuavaUIDevToolsProtocol

private struct DiagnosticLeaf: _PrimitiveView {
    var name = "leaf"
    func _makeNode() -> Node { Node() }
    func _updateNode(_ node: Node) { node.attachments[LayoutDebugAttachmentKey.debugName] = name }
    func _updateLayout(_ layout: LayoutNode) { layout.width = 20; layout.height = 20 }
}
private struct LocatedRoot: View {
    let record: (UInt) -> Void
    var body: some View {
        let _ = record(#line + 1)
        Box { DiagnosticLeaf() }
    }
}
private struct ConcreteBody: View {
    var body: DiagnosticLeaf { DiagnosticLeaf() }
}
private struct KeyedDiagnosticRoot: View {
    @State var ids = [1, 2, 3]
    var body: some View {
        Box {
            for id in ids { DiagnosticLeaf(name: String(id)).id(id) }
            if ids.count > 2 { DiagnosticLeaf(name: "conditional").sourceLocation(line: 456, column: 7) }
        }
    }
}
private struct ChildDiagnostic: View {
    var value: Int
    var body: some View { DiagnosticLeaf(name: String(value)) }
}
private struct ParentDiagnostic: View {
    @State var value = 0
    var body: some View { ChildDiagnostic(value: value) }
}
private final class DiagnosticStore {
    let registrar = ObservableStateRegistrar()
    var raw = 0
    var value: Int {
        get { registrar.access("value"); return raw }
        set { raw = newValue; registrar.invalidate("value") }
    }
}
private struct ObservableDiagnostic: View {
    let store: DiagnosticStore
    var body: some View { DiagnosticLeaf(name: String(store.value)) }
}
private struct SelfInvalidatingDiagnostic: View {
    @State var value = 0
    var body: some View {
        if value == 1 { value = 2 }
        return DiagnosticLeaf()
    }
}
private struct RemovableChild: View {
    @State var value = 0
    var body: some View { DiagnosticLeaf(name: String(value)) }
}
private struct RemovableRoot: View {
    @State var shown = true
    let child: RemovableChild
    var body: some View { if shown { child } }
}
private struct EnvironmentDiagnostic: View {
    @State var value = 0
    let local: CompositionLocal<Int>
    var body: some View { ChildDiagnostic(value: value).compositionLocal(local, value) }
}
private func flattenDiagnostics(_ node: Node) -> [Node] { [node] + node.children.flatMap(flattenDiagnostics) }
private func flattenSummaries(_ node: NodeSummary) -> [NodeSummary] { [node] + node.children.flatMap(flattenSummaries) }

@Test @MainActor
func automaticSourceCoordinatesAndExplicitConcreteBodiesRemainCompatible() throws {
    let tree = NodeTree(), graph = ViewGraph(tree: tree, recomposer: Recomposer())
    var expressionLine: UInt = 0
    graph.install(root: LocatedRoot(record: { expressionLine = $0 }))
    let nodes = flattenDiagnostics(try #require(tree.root))
    let box = try #require(nodes.first { $0.layoutNode != nil && !$0.children.isEmpty })
    #expect(box.sourceLocation?.fileID == #fileID)
    #expect(box.sourceLocation?.filePath == #filePath)
    #expect(box.sourceLocation?.line == expressionLine)
    #expect((box.sourceLocation?.column ?? 0) > 0)
    #expect(nodes.count == 4) // tree root, user anchor, Box, primitive: no source nodes.
    let other = NodeTree(), concrete = ViewGraph(tree: other, recomposer: Recomposer())
    concrete.install(root: ConcreteBody().sourceLocation(line: 789, column: 3))
    #expect(other.root?.children.first?.sourceLocation?.line == 789)
    #expect(flattenDiagnostics(other.root!).count == 3)
}

@Test @MainActor
func sourceMetadataSurvivesKeyedReorderConditionalFlatteningAndReconciliation() throws {
    let root = KeyedDiagnosticRoot(), tree = NodeTree(), recomposer = Recomposer()
    let graph = ViewGraph(tree: tree, recomposer: recomposer)
    graph.install(root: root)
    let before = flattenDiagnostics(try #require(tree.root))
    let keyed = before.filter { $0.key != nil }
    let locations = keyed.map(\.sourceLocation)
    let conditional = try #require(before.first { $0.sourceLocation?.line == 456 })
    #expect(conditional.sourceLocation?.explicit == true)
    #expect(Set(keyed.compactMap { $0.sourceLocation?.line }).count == 1)
    #expect(keyed.count == 3)
    root.ids = [3, 1, 2]; recomposer.commitAll()
    let after = flattenDiagnostics(tree.root!)
    #expect(after.filter { $0.key != nil }.map(\.id) == [keyed[2].id, keyed[0].id, keyed[1].id])
    #expect(conditional.sourceLocation?.line == 456 && conditional.sourceLocation?.column == 7)
    for (node, location) in zip(keyed, locations) { #expect(after.contains { $0 === node && $0.sourceLocation == location }) }
}

@Test @MainActor
func realRecompositionCountsCoalescedStateCausesAndIgnoresStyleAndResize() throws {
    let root = SharedCounterView(), tree = NodeTree(), recomposer = Recomposer()
    let graph = ViewGraph(tree: tree, recomposer: recomposer), context = PlatformInputContext()
    try context.withCurrent {
        graph.install(root: root); graph.computeLayout(width: 640, height: 460)
        let anchor = try #require(flattenDiagnostics(tree.root!).first { $0.recompositionMetrics != nil })
        #expect(anchor.recompositionMetrics?.count == 0)
        root.count = 1; root.count = 2; root.dark = true
        recomposer.commitAll()
        let metrics = try #require(anchor.recompositionMetrics)
        #expect(metrics.count == 1)
        #expect(Set(metrics.lastReasons.compactMap(\.detail)) == ["count", "dark"])
        #expect(metrics.lastReasons.allSatisfy { $0.kind == "state" })
        #expect(metrics.initialMs.isFinite && metrics.lastMs.isFinite && metrics.lastMs >= 0)
        #expect(metrics.totalMs == metrics.lastMs && metrics.maxMs == metrics.lastMs)
        let inspector = SceneInspector(tree: tree)
        let value = try #require(flattenDiagnostics(tree.root!).first { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "counter.value" })
        let response = inspector.editor.handle(.init(type: "inspect.style.set", payload: .object([
            "id": .string(String(value.id.rawValue)), "properties": .object(["backgroundColor": .string("#abcdef")])
        ])))
        #expect(response.type == "inspect.style.set.ok")
        graph.computeLayout(width: 400, height: 500)
        #expect(!recomposer.commitAll())
        #expect(anchor.recompositionMetrics?.count == 1)
        let summaries = flattenSummaries(try #require(inspector.snapshot().root))
        #expect(summaries.first { $0.elementID == String(value.id.rawValue) }?.ownerScopeID == String(anchor.id.rawValue))
        #expect(summaries.filter { $0.recomposition != nil }.count == 1)
        #expect(summaries.first { $0.elementID == String(value.id.rawValue) }?.source?.fileID.hasSuffix("SharedCounterView.swift") == true)
        #expect(inspector.editor.handle(.init(type: "inspect.recomposition.reset", payload: .object(["unexpected": .bool(true)]))).type.hasSuffix(".err"))
        #expect(inspector.editor.handle(.init(type: "inspect.recomposition.reset")).type.hasSuffix(".ok"))
        #expect(anchor.recompositionMetrics?.count == 0 && anchor.recompositionMetrics?.initialMs == metrics.initialMs)
        #expect(anchor.recompositionMetrics?.lastReasons.isEmpty == true)
        #expect(inspector.editor.state.overrideCount == 1 && inspector.editor.state.canUndo)
        root.count = 3; recomposer.commitAll()
        #expect(anchor.recompositionMetrics?.count == 1)
    }
}

@Test @MainActor
func parentObservableAndNextFrameInvalidationsReportTheirActualCauses() throws {
    let root = ParentDiagnostic(), tree = NodeTree(), recomposer = Recomposer()
    let graph = ViewGraph(tree: tree, recomposer: recomposer)
    graph.install(root: root)
    let scopes = flattenDiagnostics(try #require(tree.root)).filter { $0.recompositionMetrics != nil }
    #expect(scopes.count == 2)
    root.value = 10; recomposer.commitAll()
    #expect(scopes.allSatisfy { $0.recompositionMetrics?.count == 1 })
    #expect(scopes[1].recompositionMetrics?.lastReasons == [.init(kind: "parent", originScope: scopes[0].id.rawValue)])
    let store = DiagnosticStore(), observedTree = NodeTree(), observedRecomposer = Recomposer()
    let observedGraph = ViewGraph(tree: observedTree, recomposer: observedRecomposer)
    observedGraph.install(root: ObservableDiagnostic(store: store))
    store.value = 10; observedRecomposer.commitAll()
    #expect(observedTree.root?.children.first?.recompositionMetrics?.lastReasons == [.init(kind: "observable", detail: "value")])
    let selfRoot = SelfInvalidatingDiagnostic(), selfTree = NodeTree(), selfRecomposer = Recomposer()
    let selfGraph = ViewGraph(tree: selfTree, recomposer: selfRecomposer)
    selfGraph.install(root: selfRoot)
    selfRoot.value = 1; selfRecomposer.commitAll()
    #expect(selfRecomposer.hasPending)
    #expect(selfTree.root?.children.first?.recompositionMetrics?.count == 1)
    selfRecomposer.commitAll()
    #expect(selfTree.root?.children.first?.recompositionMetrics?.count == 2)
    #expect(selfTree.root?.children.first?.recompositionMetrics?.lastReasons == [.init(kind: "state", detail: "value")])
}

@Test @MainActor
func profilingCanBeDisabledAndWirePayloadRemainsBackwardCompatible() throws {
    let tree = NodeTree(), graph = ViewGraph(tree: tree, recomposer: Recomposer())
    graph.tracksRecomposition = false; graph.install(root: ConcreteBody())
    #expect(flattenDiagnostics(tree.root!).allSatisfy { $0.recompositionMetrics == nil })
    let inspector = SceneInspector(tree: tree)
    var json = try #require(DevToolsCodec.json(inspector.snapshot()).objectValue)
    let encoded = try JSONEncoder().encode(JSONValue.object(json))
    #expect(try JSONDecoder().decode(TreeSnapshotPayload.self, from: encoded).root != nil)
    func legacyNode(_ value: JSONValue) -> JSONValue {
        guard var node = value.objectValue else { return value }
        node["source"] = nil; node["ownerScopeID"] = nil; node["recomposition"] = nil
        if case .array(let children) = node["children"] { node["children"] = .array(children.map(legacyNode)) }
        return .object(node)
    }
    json["root"] = legacyNode(json["root"]!)
    let legacy = try JSONDecoder().decode(TreeSnapshotPayload.self, from: JSONEncoder().encode(JSONValue.object(json)))
    #expect(flattenSummaries(legacy.root!).allSatisfy { $0.source == nil && $0.ownerScopeID == nil && $0.recomposition == nil })
    json["root"] = .null
    #expect(try JSONDecoder().decode(TreeSnapshotPayload.self, from: JSONEncoder().encode(JSONValue.object(json))).root == nil)
}

@Test @MainActor
func removedScopesIgnoreQueuedWorkAndEnvironmentChangesAreAttributed() throws {
    let child = RemovableChild(), root = RemovableRoot(child: child), tree = NodeTree(), recomposer = Recomposer()
    let graph = ViewGraph(tree: tree, recomposer: recomposer)
    graph.install(root: root)
    let anchor = try #require(flattenDiagnostics(tree.root!).first { $0.viewTag?.hasSuffix("RemovableChild") == true })
    root.shown = false; child.value = 1
    recomposer.commitAll()
    #expect(anchor.recompositionMetrics?.count == 0)
    #expect(!flattenDiagnostics(tree.root!).contains { $0 === anchor })
    let environment = EnvironmentDiagnostic(local: CompositionLocal(defaultValue: 0))
    let environmentTree = NodeTree(), environmentRecomposer = Recomposer()
    let environmentGraph = ViewGraph(tree: environmentTree, recomposer: environmentRecomposer)
    environmentGraph.install(root: environment)
    environment.value = 1; environmentRecomposer.commitAll()
    let scope = try #require(flattenDiagnostics(environmentTree.root!).first { $0.viewTag?.hasSuffix("ChildDiagnostic") == true })
    #expect(scope.recompositionMetrics?.lastReasons.contains { $0.kind == "environment" && $0.detail == "CompositionLocal" } == true)
}

@Test
func recomposerKeepsDistinctBoundedCausesWithoutChangingAnimationOrFirstBody() {
    let recomposer = Recomposer(), identity = DiagnosticStore(), id = ObjectIdentifier(identity)
    var delivered = [RecompositionReason](), calls = 0
    var captured: Animation?
    for index in 0..<32 {
        let reason = RecompositionReason(kind: "state", detail: "field\(index)")
        recomposer.invalidateTracked(scopeID: id, animation: .linear, reason: reason) { reasons in
            delivered = reasons; calls += 1; captured = ActiveAnimationContext.current
        }
        recomposer.invalidateTracked(scopeID: id, animation: .easeIn, reason: reason) { _ in calls += 100 }
    }
    #expect(recomposer.commitAll())
    #expect(calls == 1 && delivered.count == 16)
    #expect(delivered.map(\.detail) == (0..<16).map { "field\($0)" })
    #expect(captured == .linear)
}
