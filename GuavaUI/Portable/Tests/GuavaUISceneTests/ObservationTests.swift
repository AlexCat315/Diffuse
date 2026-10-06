import Foundation
import Testing
import GuavaUIComposeCore
import GuavaUIDevToolsScene
import GuavaUIDevToolsProtocol

private struct ExposedChild: View {
    @State(expose: true) var count = 3
    @State(expose: true, summary: { _ in "<redacted>" }) var token = "secret"
    @State var hidden = "private"
    var body: some View { EmptyView() }
}
private struct ExposedParent: View {
    @State var visible = true
    @State var revision = 0
    var body: some View {
        if visible { ExposedChild().id("child") }
    }
}

@Test @MainActor
func stateRegistrationIsExplicitLazyAndFollowsScopeLifetime() throws {
    let registry = StateRegistry()
    var reads = 0
    let provider = try #require(registry.register(name: "host", valueType: "String", read: { reads += 1; return String(repeating: "x", count: 2000) }))
    #expect(registry.observation(ids: []).registered.count == 1 && reads == 0)
    let values = registry.values(for: [provider, provider, "missing"])
    #expect(reads == 1 && values.count == 1 && values[0].summary.count == 1024 && values[0].truncated)
    registry.unregister(provider); #expect(registry.values(for: [provider]).isEmpty)

    let parent = ExposedParent(), tree = NodeTree(), recomposer = Recomposer()
    let graph = ViewGraph(tree: tree, recomposer: recomposer)
    graph.install(root: parent)
    let fields = graph.stateRegistry.descriptors
    #expect(Set(fields.map(\.name)) == ["count", "token"])
    let ids = fields.map(\.id)
    #expect(graph.stateRegistry.values(for: ids).map(\.summary).contains("<redacted>"))
    parent.revision += 1; recomposer.commitAll()
    #expect(graph.stateRegistry.descriptors.map(\.id) == ids)
    #expect(graph.stateRegistry.values(for: ids).map(\.summary).contains("3"))
    parent.visible = false; recomposer.commitAll()
    #expect(graph.stateRegistry.descriptors.isEmpty)
    #expect(graph.stateRegistry.values(for: ids).isEmpty)
}

@Test @MainActor
func observedValuesTrackBindingWritesAndTimelineRecordsActualWork() throws {
    let child = ExposedChild(), tree = NodeTree(), recomposer = Recomposer()
    let graph = ViewGraph(tree: tree, recomposer: recomposer)
    graph.install(root: child)
    let id = try #require(graph.stateRegistry.descriptors.first { $0.name == "count" }?.id)
    #expect(tree.timeline.events.isEmpty && tree.timeline.begin() == nil)
    tree.timeline.setEnabled(true)
    child.$count.wrappedValue = 9; recomposer.commitAll()
    #expect(graph.stateRegistry.values(for: [id]).first?.summary == "9")
    graph.computeLayoutIfNeeded(width: 100, height: 100)
    let count = tree.timeline.events.count
    #expect(!graph.computeLayoutIfNeeded(width: 100, height: 100))
    #expect(tree.timeline.events.count == count)
    let paint = tree.timeline.begin()
    NodeRenderer().render(root: tree.root!, into: DrawList())
    tree.timeline.end(paint, phase: "draw", name: "Paint")
    let snapshot = tree.timeline.snapshot()
    #expect(Set(snapshot.events.map(\.phase)) == ["component", "recomposition", "layout", "draw"])
    #expect(snapshot.events.allSatisfy { $0.startMs >= 0 && $0.durationMs >= 0 && $0.durationMs.isFinite })
    #expect(snapshot.events.first?.reasons.first?.kind == "state")
    tree.timeline.setEnabled(false)
    child.count = 12; recomposer.commitAll()
    #expect(tree.timeline.events.count == snapshot.events.count)
}

@Test
func timelineIsBoundedAndNewCapturesKeepSequenceIdentity() {
    let timeline = PerformanceTimeline(capacity: 2)
    timeline.setEnabled(true)
    for _ in 0..<3 { timeline.end(timeline.begin(), phase: "draw", name: "Draw") }
    #expect(timeline.events.count == 2 && timeline.dropped == 1)
    #expect(timeline.events(after: 2).map(\.sequence) == [3])
    #expect(timeline.events(after: 0).map(\.sequence) == [2, 3])
    #expect(timeline.events(after: 3).isEmpty)
    let sequence = timeline.events.last!.sequence
    timeline.setEnabled(false); timeline.setEnabled(true)
    #expect(timeline.events.isEmpty && timeline.dropped == 0)
    timeline.end(timeline.begin(), phase: "layout", name: "Layout")
    #expect(timeline.events[0].sequence > sequence)
    let session = DevToolsSession()
    #expect(session.validate(DevToolsEnvelope(type: "state.subscribe", payload: .object(["ids": .array([.string("a"), .string("a")])])))?.type == "state.subscribe.err")
    #expect(session.validate(DevToolsEnvelope(type: "state.subscribe", payload: DevToolsCodec.json(StateWatchPayload(ids: ["a"])))) == nil)
    #expect(session.validate(DevToolsEnvelope(type: "timeline.subscribe", payload: .string("bad"))) != nil)
}
